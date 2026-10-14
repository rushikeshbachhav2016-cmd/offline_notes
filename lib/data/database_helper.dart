import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../model/attachment.dart';
import '../model/note.dart';
import '../model/outbox_entry.dart';
import '../utils/constants.dart';
import '../utils/file_utils.dart';

/// Local database. Screens read and write ONLY through this class.
/// Every write saves the data change and its outbox entry in one transaction.
class DatabaseHelper {
  DatabaseHelper._();
  static final DatabaseHelper instance = DatabaseHelper._();

  static const _dbName = 'offline_notes.db';
  static const _dbVersion = 2;
  final _uuid = const Uuid();

  late Database _db;
  late String filesDir; // app support folder (not temp/cache)

  Database get db => _db;

  // Screens listen to this and reload when data changes.
  final _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;
  void notifyChanged() => _changes.add(null);

  int _now() => DateTime.now().millisecondsSinceEpoch;

  Future<void> init(String folder) async {
    filesDir = folder;
    _db = await openDatabase(
      '$folder/$_dbName',
      version: _dbVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE notes (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        body TEXT NOT NULL,
        deleted INTEGER NOT NULL DEFAULT 0,
        version INTEGER NOT NULL DEFAULT 0,
        sync_status TEXT NOT NULL,
        local_updated_at INTEGER NOT NULL,
        server_title TEXT,
        server_body TEXT,
        server_version INTEGER,
        server_deleted INTEGER NOT NULL DEFAULT 0
      )''');

    await db.execute('''
      CREATE TABLE attachments (
        id TEXT PRIMARY KEY,
        note_id TEXT NOT NULL,
        file_name TEXT NOT NULL,
        mime_type TEXT NOT NULL,
        size_bytes INTEGER NOT NULL,
        local_path TEXT,
        storage_path TEXT,
        deleted INTEGER NOT NULL DEFAULT 0,
        version INTEGER NOT NULL DEFAULT 0,
        sync_status TEXT NOT NULL
      )''');

    await db.execute('''
      CREATE TABLE outbox (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        entity_type TEXT NOT NULL,
        entity_id TEXT NOT NULL,
        note_id TEXT NOT NULL,
        op TEXT NOT NULL,
        payload TEXT NOT NULL,
        base_version INTEGER NOT NULL,
        lane TEXT NOT NULL,
        status TEXT NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 0,
        next_attempt_at INTEGER NOT NULL DEFAULT 0,
        last_error TEXT,
        created_at INTEGER NOT NULL
      )''');

    await db.execute('''
      CREATE TABLE sync_meta (
        table_name TEXT PRIMARY KEY,
        cursor INTEGER NOT NULL,
        last_synced_at TEXT
      )''');
    await db.insert('sync_meta', {'table_name': 'notes', 'cursor': 0});
    await db.insert('sync_meta', {'table_name': 'attachments', 'cursor': 0});
  }

  // Dev only: on a schema change, recreate the local tables.
  // The server folder is untouched, so notes come back on the next pull.
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    for (final table in ['notes', 'attachments', 'outbox', 'sync_meta']) {
      await db.execute('DROP TABLE IF EXISTS $table');
    }
    await _onCreate(db, newVersion);
  }

  Future<void> _enqueue(Transaction txn, OutboxEntry entry) async {
    await txn.insert('outbox', entry.toJson());
  }

  Future<Note?> _noteInTxn(Transaction txn, String id) async {
    final rows = await txn.query('notes', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : Note.fromJson(rows.first);
  }

  // ---------------- Reads ----------------

  Future<List<Note>> getNotes() async {
    final rows = await _db.query(
      'notes',
      // deleted notes are hidden, unless the delete is in conflict
      where: 'deleted = 0 OR sync_status = ?',
      whereArgs: [SyncStatus.conflict],
      orderBy: 'local_updated_at DESC',
    );
    return rows.map(Note.fromJson).toList();
  }

  Future<Note?> getNote(String id) async {
    final rows = await _db.query('notes', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : Note.fromJson(rows.first);
  }

  Future<List<Attachment>> getAttachments(String noteId) async {
    final rows = await _db.query(
      'attachments',
      where: 'note_id = ? AND deleted = 0',
      whereArgs: [noteId],
    );
    return rows.map(Attachment.fromJson).toList();
  }

  Future<String?> getLastSyncedAt() async {
    final rows = await _db.query(
      'sync_meta',
      where: 'table_name = ?',
      whereArgs: ['notes'],
    );
    return rows.first['last_synced_at'] as String?;
  }

  Future<List<OutboxEntry>> getOutbox() async {
    final rows = await _db.query('outbox', orderBy: 'id');
    return rows.map(OutboxEntry.fromJson).toList();
  }

  File? fileFor(Attachment a) =>
      a.localPath == null ? null : File('$filesDir/${a.localPath}');

  // ------- Writes: data change + outbox entry in ONE transaction -------

  Future<String> createNote({String title = '', String body = ''}) async {
    final note = Note(
      id: _uuid.v4(), // ID made on the device before saving
      title: title,
      body: body,
      localUpdatedAt: _now(),
    );

    await _db.transaction((txn) async {
      await txn.insert('notes', note.toJson());
      await _enqueue(
        txn,
        OutboxEntry(
          entityType: EntityType.note,
          entityId: note.id,
          noteId: note.id,
          op: OutboxOp.insert,
          payload: {'title': title, 'body': body},
          createdAt: _now(),
        ),
      );
    });

    notifyChanged();
    return note.id;
  }

  Future<void> updateNote(String id, String title, String body) async {
    await _db.transaction((txn) async {
      final note = await _noteInTxn(txn, id);
      if (note == null) return;

      await txn.update(
        'notes',
        {
          'title': title,
          'body': body,
          // a note in conflict stays in conflict until the user picks a side
          'sync_status': note.syncStatus == SyncStatus.conflict
              ? SyncStatus.conflict
              : SyncStatus.pending,
          'local_updated_at': _now(),
        },
        where: 'id = ?',
        whereArgs: [id],
      );

      // Coalescing: if a create/update for this note was never sent yet,
      // fold this edit into it instead of adding a new entry.
      final unsent = await txn.query(
        'outbox',
        where: "entity_id = ? AND op IN ('insert', 'update') "
            'AND status = ? AND attempts = 0',
        whereArgs: [id, OutboxStatus.queued],
        orderBy: 'id DESC',
        limit: 1,
      );
      if (unsent.isNotEmpty) {
        await txn.update(
          'outbox',
          {'payload': jsonEncode({'title': title, 'body': body})},
          where: 'id = ?',
          whereArgs: [unsent.first['id']],
        );
        return;
      }

      await _enqueue(
        txn,
        OutboxEntry(
          entityType: EntityType.note,
          entityId: id,
          noteId: id,
          op: OutboxOp.update,
          payload: {'title': title, 'body': body},
          baseVersion: note.version,
          createdAt: _now(),
        ),
      );
    });

    notifyChanged();
  }

  /// Soft delete: the row stays until the server accepts the tombstone.
  Future<void> deleteNote(String id) async {
    var cancelled = false;

    await _db.transaction((txn) async {
      final note = await _noteInTxn(txn, id);
      if (note == null) return;

      // Create + delete before the create was ever sent: they cancel out.
      // The server never saw this note, so there is no tombstone to send.
      final unsentCreate = await txn.query(
        'outbox',
        where: 'entity_id = ? AND op = ? AND status = ? AND attempts = 0',
        whereArgs: [id, OutboxOp.insert, OutboxStatus.queued],
      );
      if (unsentCreate.isNotEmpty) {
        await txn.delete('outbox', where: 'note_id = ?', whereArgs: [id]);
        await txn.delete('attachments', where: 'note_id = ?', whereArgs: [id]);
        await txn.delete('notes', where: 'id = ?', whereArgs: [id]);
        cancelled = true;
        return;
      }

      await txn.update(
        'notes',
        {
          'deleted': 1,
          'sync_status': SyncStatus.pending,
          'local_updated_at': _now(),
        },
        where: 'id = ?',
        whereArgs: [id],
      );
      await _enqueue(
        txn,
        OutboxEntry(
          entityType: EntityType.note,
          entityId: id,
          noteId: id,
          op: OutboxOp.delete,
          payload: {'deleted': true},
          baseVersion: note.version,
          createdAt: _now(),
        ),
      );
    });

    if (cancelled) {
      final dir = Directory('$filesDir/attachments/$id');
      if (await dir.exists()) await dir.delete(recursive: true);
    }
    notifyChanged();
  }

  /// The user picked a side in a conflict.
  /// keepMine: push my version on top of the server's.
  /// keepTheirs: take the server's version, drop my unsent changes.
  Future<void> resolveConflict(String id, {required bool keepMine}) async {
    await _db.transaction((txn) async {
      final note = await _noteInTxn(txn, id);
      if (note == null || note.serverVersion == null) return;

      // The old conflicting entries are replaced by this decision.
      await txn.delete(
        'outbox',
        where: 'entity_id = ? AND status IN (?, ?)',
        whereArgs: [id, OutboxStatus.queued, OutboxStatus.failed],
      );

      const clearConflict = {
        'server_title': null,
        'server_body': null,
        'server_version': null,
        'server_deleted': 0,
      };

      if (keepMine) {
        await txn.update(
          'notes',
          {
            ...clearConflict,
            'version': note.serverVersion,
            'sync_status': SyncStatus.pending,
          },
          where: 'id = ?',
          whereArgs: [id],
        );
        await _enqueue(
          txn,
          OutboxEntry(
            entityType: EntityType.note,
            entityId: id,
            noteId: id,
            op: OutboxOp.update,
            payload: {
              'title': note.title,
              'body': note.body,
              'deleted': note.deleted,
            },
            baseVersion: note.serverVersion!,
            createdAt: _now(),
          ),
        );
      } else {
        await txn.update(
          'notes',
          {
            ...clearConflict,
            'title': note.serverTitle ?? '',
            'body': note.serverBody ?? '',
            'deleted': note.serverDeleted ? 1 : 0,
            'version': note.serverVersion,
            'sync_status': SyncStatus.synced,
          },
          where: 'id = ?',
          whereArgs: [id],
        );
      }
    });
    notifyChanged();
  }

  Future<void> addAttachment({
    required String noteId,
    required String sourcePath,
    required String fileName,
  }) async {
    final id = _uuid.v4();
    final relativePath = 'attachments/$noteId/$id-$fileName';

    // Copy into app storage first, so it shows offline.
    final target = File('$filesDir/$relativePath');
    await target.parent.create(recursive: true);
    await File(sourcePath).copy(target.path);

    final attachment = Attachment(
      id: id,
      noteId: noteId,
      fileName: fileName,
      mimeType: FileUtils.mimeFor(fileName),
      sizeBytes: await target.length(),
      localPath: relativePath,
    );

    await _db.transaction((txn) async {
      await txn.insert('attachments', attachment.toJson());

      // 1) attachment row (data lane, waits behind the note's create)
      await _enqueue(
        txn,
        OutboxEntry(
          entityType: EntityType.attachment,
          entityId: id,
          noteId: noteId,
          op: OutboxOp.insert,
          payload: {
            'note_id': noteId,
            'file_name': attachment.fileName,
            'mime_type': attachment.mimeType,
            'size_bytes': attachment.sizeBytes,
          },
          createdAt: _now(),
        ),
      );

      // 2) file upload (file lane, so it never blocks note text).
      //    3) storage_path is queued by the sync engine after the upload.
      await _enqueue(
        txn,
        OutboxEntry(
          entityType: EntityType.attachment,
          entityId: id,
          noteId: noteId,
          op: OutboxOp.upload,
          lane: Lane.file,
          createdAt: _now(),
        ),
      );
    });

    notifyChanged();
  }

  // ---------------- Queue inspector / debug ----------------

  /// Puts failed entries back in the queue with a fresh attempt count.
  Future<void> retryFailed() async {
    await _db.transaction((txn) async {
      final rows = await txn.query(
        'outbox',
        where: 'status = ?',
        whereArgs: [OutboxStatus.failed],
      );
      for (final row in rows) {
        final e = OutboxEntry.fromJson(row);
        await txn.update(
          'outbox',
          {
            'status': OutboxStatus.queued,
            'attempts': 0,
            'next_attempt_at': 0,
            'last_error': null,
          },
          where: 'id = ?',
          whereArgs: [e.id],
        );
        await txn.update(
          e.entityType == EntityType.note ? 'notes' : 'attachments',
          {'sync_status': SyncStatus.pending},
          where: 'id = ? AND sync_status = ?',
          whereArgs: [e.entityId, SyncStatus.failed],
        );
      }
    });
    notifyChanged();
  }

  Future<void> clearDone() async {
    await _db.delete(
      'outbox',
      where: 'status = ?',
      whereArgs: [OutboxStatus.done],
    );
    notifyChanged();
  }

  /// "Fresh install": wipes local data but NOT the fake server's folder.
  Future<void> wipeLocalData() async {
    await _db.transaction((txn) async {
      await txn.delete('notes');
      await txn.delete('attachments');
      await txn.delete('outbox');
      await txn.update('sync_meta', {'cursor': 0, 'last_synced_at': null});
    });
    final files = Directory('$filesDir/attachments');
    if (await files.exists()) await files.delete(recursive: true);
    notifyChanged();
  }
}
