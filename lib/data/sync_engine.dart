// Sync layer: the ONLY code that talks to FakeServer.
// No Flutter imports, so it can be unit tested.
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:sqflite_common/sqlite_api.dart';

import '../fake_server.dart';
import '../model/attachment.dart';
import '../model/note.dart';
import '../model/outbox_entry.dart';
import '../utils/constants.dart';

/// App-wide instance, set once in main().
late SyncEngine syncEngine;

class SyncEngine {
  SyncEngine({
    required this.db,
    required this.server,
    required this.filesDir,
    required this.onChanged,
  });

  final Database db;
  final FakeServer server;
  final String filesDir;
  final void Function() onChanged; // tells the screens to reload

  static const maxAttempts = 5;
  static const pageSize = 200;

  final _random = Random();
  bool _dataLaneBusy = false;
  bool _fileLaneBusy = false;
  Timer? _timer;

  FaultConfig get faults => server.faults;

  /// Called once at app start.
  Future<void> start() async {
    // Crash recovery: entries left "in flight" by a kill go back to the queue.
    // Resending is safe: AlreadyExists / Conflict checks catch repeats.
    await db.update(
      'outbox',
      {'status': OutboxStatus.queued},
      where: 'status = ?',
      whereArgs: [OutboxStatus.inFlight],
    );
    // Wakes up the queue so entries waiting on backoff get retried.
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => sync());
    unawaited(sync());
  }

  void stop() => _timer?.cancel();

  /// Push then pull. Safe to call from anywhere, any number of times:
  /// each lane has one worker, so a second call during a run does nothing.
  Future<void> sync() async {
    // The "Offline" switch is our stand-in for the phone's connectivity.
    if (faults.offline) return;
    await Future.wait([_runDataLane(), _runFileLane()]);
  }

  // Lane 1: note rows + attachment rows, then pull.
  Future<void> _runDataLane() async {
    if (_dataLaneBusy) return;
    _dataLaneBusy = true;
    try {
      await _drain(Lane.data);
      await _pull();
    } on NetworkError {
      // Pull failed: the next sync will try again.
    } finally {
      _dataLaneBusy = false;
    }
  }

  // Lane 2: file uploads, so a big file never holds up note text.
  Future<void> _runFileLane() async {
    if (_fileLaneBusy) return;
    _fileLaneBusy = true;
    try {
      await _drain(Lane.file);
    } finally {
      _fileLaneBusy = false;
    }
  }

  // ---------------- PUSH ----------------

  Future<void> _drain(String lane) async {
    final rows = await db.query(
      'outbox',
      where: 'lane = ? AND status != ?',
      whereArgs: [lane, OutboxStatus.done],
      orderBy: 'id', // oldest first
    );
    final now = DateTime.now().millisecondsSinceEpoch;
    final blockedNotes = <String>{};

    for (final row in rows) {
      final entry = OutboxEntry.fromJson(row);

      // FIFO per note: once an entry of a note can't run, later entries of
      // the SAME note wait. Other notes carry on.
      if (blockedNotes.contains(entry.noteId)) continue;
      if (entry.status == OutboxStatus.failed || entry.nextAttemptAt > now) {
        blockedNotes.add(entry.noteId);
        continue;
      }

      final done = await _process(entry);
      if (!done) blockedNotes.add(entry.noteId);
    }
  }

  /// Sends one entry. Returns true when the server accepted it.
  Future<bool> _process(OutboxEntry snapshot) async {
    // Claim it, then re-read it: an edit may have been coalesced into it.
    final claimed = await db.update(
      'outbox',
      {'status': OutboxStatus.inFlight},
      where: 'id = ? AND status = ?',
      whereArgs: [snapshot.id, OutboxStatus.queued],
    );
    if (claimed == 0) return false; // removed (e.g. create+delete cancelled)
    final rows =
        await db.query('outbox', where: 'id = ?', whereArgs: [snapshot.id]);
    final entry = OutboxEntry.fromJson(rows.first);
    onChanged();

    try {
      await _send(entry);
      await _markDone(entry);
      return true;
    } on _NotReady {
      // Waiting for a dependency: put it back, no attempt used.
      await _update(entry, {'status': OutboxStatus.queued});
    } on _Conflicted {
      // The note now holds both versions; the user picks one.
      await _update(entry, {
        'status': OutboxStatus.failed,
        'last_error': 'Conflict: open the note and pick a version',
      });
    } on NetworkError catch (e) {
      await _retryLater(entry, e.toString());
    } on ConstraintViolation catch (e) {
      await _retryLater(entry, e.toString());
    } catch (e) {
      // NotFound, missing local file, ... retrying won't fix these.
      await _fail(entry, e.toString(), entry.attempts + 1);
    }
    return false;
  }

  Future<void> _send(OutboxEntry e) async {
    if (e.entityType == EntityType.note) {
      await _sendNote(e);
    } else if (e.op == OutboxOp.insert) {
      await _sendAttachmentRow(e);
    } else if (e.op == OutboxOp.upload) {
      await _uploadFile(e);
    } else if (e.op == OutboxOp.setPath) {
      await _sendStoragePath(e);
    }
  }

  Future<void> _sendNote(OutboxEntry e) async {
    final note = await _getNote(e.entityId);
    if (note == null) return; // gone locally, nothing to send

    var baseVersion = note.version;

    if (e.op == OutboxOp.insert) {
      try {
        final row = await server.insert('notes', {'id': note.id, ...e.payload});
        await _saveVersion('notes', note.id, row['version'] as int);
        return;
      } on AlreadyExists {
        // An earlier attempt landed but the response was lost.
        final row = (await server.get('notes', note.id))!;
        await _saveVersion('notes', note.id, row['version'] as int);
        if (_alreadyApplied(e.payload, row)) return;
        // Edits were folded into this create after it was first sent:
        // send them as an update on top.
        baseVersion = row['version'] as int;
      }
    }

    // Update or delete: only applies if the server is still at baseVersion.
    try {
      final row =
          await server.update('notes', note.id, baseVersion, e.payload);
      await _saveVersion('notes', note.id, row['version'] as int);
    } on Conflict catch (c) {
      final serverRow = c.serverRow;
      if (_alreadyApplied(e.payload, serverRow)) {
        // Our own earlier attempt landed (lost response): not a conflict.
        await _saveVersion('notes', note.id, serverRow['version'] as int);
        return;
      }
      // Someone else changed it. Keep BOTH sides; the user decides.
      await db.update(
        'notes',
        {
          'sync_status': SyncStatus.conflict,
          'server_title': serverRow['title'],
          'server_body': serverRow['body'],
          'server_version': serverRow['version'],
          'server_deleted': serverRow['deleted'] == true ? 1 : 0,
        },
        where: 'id = ?',
        whereArgs: [note.id],
      );
      throw _Conflicted();
    }
  }

  /// True if the server row already contains every change we want to send.
  bool _alreadyApplied(Map<String, Object?> changes, Map<String, Object?> row) {
    return changes.entries.every((c) => row[c.key] == c.value);
  }

  Future<void> _sendAttachmentRow(OutboxEntry e) async {
    final att = await _getAttachment(e.entityId);
    if (att == null) return;
    Map<String, Object?> row;
    try {
      // storage_path is NOT sent yet: it is set after the file upload.
      row = await server.insert('attachments', {'id': att.id, ...e.payload});
    } on AlreadyExists {
      row = (await server.get('attachments', att.id))!;
    }
    await _saveVersion('attachments', att.id, row['version'] as int);
  }

  Future<void> _uploadFile(OutboxEntry e) async {
    final att = await _getAttachment(e.entityId);
    if (att == null) return;
    // Dependency: the attachment row must be on the server first.
    if (att.version == 0) throw _NotReady();

    final bytes = await File('$filesDir/${att.localPath}').readAsBytes();
    // Same path every time, so a retried upload just overwrites.
    await server.uploadFile(_remotePath(att), bytes);
  }

  Future<void> _sendStoragePath(OutboxEntry e) async {
    final att = await _getAttachment(e.entityId);
    if (att == null) return;
    final path = _remotePath(att);
    Map<String, Object?> row;
    try {
      row = await server.update(
          'attachments', att.id, att.version, {'storage_path': path});
    } on Conflict catch (c) {
      if (c.serverRow['storage_path'] != path) rethrow;
      row = c.serverRow; // our earlier attempt landed
    }
    await db.update(
      'attachments',
      {'version': row['version'], 'storage_path': path},
      where: 'id = ?',
      whereArgs: [att.id],
    );
  }

  String _remotePath(Attachment att) => '${att.noteId}/${att.id}';

  Future<void> _markDone(OutboxEntry e) async {
    await db.transaction((txn) async {
      await txn.update(
        'outbox',
        {'status': OutboxStatus.done, 'last_error': null},
        where: 'id = ?',
        whereArgs: [e.id],
      );

      // File is on the server: NOW queue the storage_path update.
      if (e.op == OutboxOp.upload) {
        await txn.insert(
          'outbox',
          OutboxEntry(
            entityType: EntityType.attachment,
            entityId: e.entityId,
            noteId: e.noteId,
            op: OutboxOp.setPath,
            createdAt: DateTime.now().millisecondsSinceEpoch,
          ).toJson(),
        );
      }

      // Nothing left for this row? Then it is synced.
      final left = await txn.query(
        'outbox',
        where: 'entity_id = ? AND status != ?',
        whereArgs: [e.entityId, OutboxStatus.done],
      );
      if (left.isEmpty) {
        await txn.update(
          e.entityType == EntityType.note ? 'notes' : 'attachments',
          {'sync_status': SyncStatus.synced},
          where: 'id = ? AND sync_status != ?',
          whereArgs: [e.entityId, SyncStatus.conflict],
        );
      }
    });
    onChanged();
  }

  Future<void> _retryLater(OutboxEntry e, String error) async {
    final attempts = e.attempts + 1;
    if (attempts >= maxAttempts) {
      await _fail(e, error, attempts);
      return;
    }
    // Exponential backoff with jitter, capped at 60s: ~1s, 2s, 4s, 8s...
    final baseMs = min(60000, 1000 * pow(2, attempts - 1).toInt());
    final delayMs = baseMs ~/ 2 + _random.nextInt(baseMs ~/ 2 + 1);
    await _update(e, {
      'status': OutboxStatus.queued,
      'attempts': attempts,
      'next_attempt_at': DateTime.now().millisecondsSinceEpoch + delayMs,
      'last_error': error,
    });
  }

  /// Gives up for now. The entry stays in the queue (never dropped)
  /// and the user can retry it from the queue inspector.
  Future<void> _fail(OutboxEntry e, String error, int attempts) async {
    await _update(e, {
      'status': OutboxStatus.failed,
      'attempts': attempts,
      'last_error': error,
    });
    await db.update(
      e.entityType == EntityType.note ? 'notes' : 'attachments',
      {'sync_status': SyncStatus.failed},
      where: 'id = ? AND sync_status != ?',
      whereArgs: [e.entityId, SyncStatus.conflict],
    );
    onChanged();
  }

  Future<void> _update(OutboxEntry e, Map<String, Object?> values) async {
    await db.update('outbox', values, where: 'id = ?', whereArgs: [e.id]);
    onChanged();
  }

  Future<void> _saveVersion(String table, String id, int version) async {
    await db.update(table, {'version': version},
        where: 'id = ?', whereArgs: [id]);
  }

  // ---------------- PULL ----------------

  Future<void> _pull() async {
    await _pullTable('notes');
    await _pullTable('attachments');
    await db.update(
      'sync_meta',
      {'last_synced_at': DateTime.now().toUtc().toIso8601String()},
      where: 'table_name = ?',
      whereArgs: ['notes'],
    );
    onChanged();
  }

  Future<void> _pullTable(String table) async {
    while (true) {
      final meta = await db
          .query('sync_meta', where: 'table_name = ?', whereArgs: [table]);
      final cursor = meta.first['cursor'] as int;

      final rows = await server.changesSince(table, cursor, limit: pageSize);
      if (rows.isEmpty) return;

      // Apply the page AND move the cursor in one transaction,
      // so the cursor is never saved before the rows are stored.
      await db.transaction((txn) async {
        for (final row in rows) {
          if (table == 'notes') {
            await _applyNote(txn, row);
          } else {
            await _applyAttachment(txn, row);
          }
        }
        await txn.update(
          'sync_meta',
          {'cursor': rows.last['server_seq']},
          where: 'table_name = ?',
          whereArgs: [table],
        );
      });

      if (rows.length < pageSize) return; // last page
    }
  }

  Future<void> _applyNote(Transaction txn, Map<String, Object?> row) async {
    final id = row['id'] as String;
    // Never overwrite a row with local changes waiting. The push is
    // conditional on the version, so it will surface the conflict.
    if (await _hasPending(txn, id)) return;

    final local = await txn.query('notes', where: 'id = ?', whereArgs: [id]);
    final serverVersion = row['version'] as int;
    if (local.isNotEmpty && (local.first['version'] as int) >= serverVersion) {
      return; // we already have this version (e.g. our own push)
    }

    final values = Note(
      id: id,
      title: row['title'] as String? ?? '',
      body: row['body'] as String? ?? '',
      deleted: row['deleted'] == true, // tombstones are kept, just hidden
      version: serverVersion,
      syncStatus: SyncStatus.synced,
      localUpdatedAt: DateTime.now().millisecondsSinceEpoch,
    ).toJson();

    if (local.isEmpty) {
      await txn.insert('notes', values);
    } else {
      await txn.update('notes', values, where: 'id = ?', whereArgs: [id]);
    }
  }

  Future<void> _applyAttachment(
      Transaction txn, Map<String, Object?> row) async {
    final id = row['id'] as String;
    if (await _hasPending(txn, id)) return;

    final local =
        await txn.query('attachments', where: 'id = ?', whereArgs: [id]);
    final serverVersion = row['version'] as int;
    if (local.isNotEmpty && (local.first['version'] as int) >= serverVersion) {
      return;
    }

    final values = {
      'note_id': row['note_id'],
      'file_name': row['file_name'],
      'mime_type': row['mime_type'],
      'size_bytes': row['size_bytes'],
      'storage_path': row['storage_path'],
      'deleted': row['deleted'] == true ? 1 : 0,
      'version': serverVersion,
      'sync_status': SyncStatus.synced,
    };

    if (local.isEmpty) {
      // local_path stays null: the file downloads when the note is opened.
      await txn.insert('attachments', {'id': id, ...values});
    } else {
      await txn.update('attachments', values, where: 'id = ?', whereArgs: [id]);
    }
  }

  Future<bool> _hasPending(Transaction txn, String entityId) async {
    final rows = await txn.query(
      'outbox',
      where: 'entity_id = ? AND status != ?',
      whereArgs: [entityId, OutboxStatus.done],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  // ---------------- FILES ----------------

  /// Lazy download, called when a note is opened. The file is then
  /// cached in app storage, so it is only downloaded once.
  Future<void> downloadAttachments(String noteId) async {
    if (faults.offline) return;
    final rows = await db.query(
      'attachments',
      where: 'note_id = ? AND local_path IS NULL AND storage_path IS NOT NULL '
          'AND deleted = 0',
      whereArgs: [noteId],
    );
    for (final row in rows) {
      final att = Attachment.fromJson(row);
      try {
        final bytes = await server.downloadFile(att.storagePath!);
        final relativePath = 'attachments/$noteId/${att.id}-${att.fileName}';
        final file = File('$filesDir/$relativePath');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes);
        await db.update('attachments', {'local_path': relativePath},
            where: 'id = ?', whereArgs: [att.id]);
        onChanged();
      } on NetworkError {
        // Try again next time the note is opened.
      } on NotFound {
        // Upload never finished; nothing to download yet.
      }
    }
  }

  // ---------------- DEBUG ----------------

  /// Plays "the other device". Throws NotFound if the note isn't on the server.
  void simulateOtherDeviceEdit(String noteId, Map<String, Object?> changes) {
    server.simulateOtherDeviceEdit('notes', noteId, changes);
  }

  // ---------------- helpers ----------------

  Future<Note?> _getNote(String id) async {
    final rows = await db.query('notes', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : Note.fromJson(rows.first);
  }

  Future<Attachment?> _getAttachment(String id) async {
    final rows =
        await db.query('attachments', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : Attachment.fromJson(rows.first);
  }
}

/// A dependency isn't on the server yet (e.g. upload before its row).
class _NotReady implements Exception {}

/// The server row changed under us; the note now holds both versions.
class _Conflicted implements Exception {}
