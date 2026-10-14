import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_notes/data/database_helper.dart';
import 'package:offline_notes/data/sync_engine.dart';
import 'package:offline_notes/fake_server.dart';
import 'package:offline_notes/utils/constants.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  final local = DatabaseHelper.instance;
  late Directory dir;
  late FakeServer server;
  late SyncEngine engine;

  setUpAll(() {
    // Real SQLite on the desktop instead of the phone plugin.
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('offline_notes_test');
    await local.init(dir.path);
    server = FakeServer.open(Directory('${dir.path}/fake_server'));
    engine = SyncEngine(
      db: local.db,
      server: server,
      filesDir: dir.path,
      onChanged: () {},
    );
  });

  tearDown(() async {
    await local.db.close();
    await dir.delete(recursive: true);
  });

  // Skip the backoff wait so the next sync retries straight away.
  Future<void> makeRetriesDue() =>
      local.db.update('outbox', {'next_attempt_at': 0});

  Future<int> serverNoteCount() async =>
      (await server.changesSince('notes', 0)).length;

  test('note created offline is pushed once back online', () async {
    server.faults.offline = true;
    final id = await local.createNote(title: 'Offline note');
    await engine.sync();
    expect((await local.getNote(id))!.syncStatus, SyncStatus.pending);
    expect(await serverNoteCount(), 0);

    server.faults.offline = false;
    await engine.sync();

    final note = (await local.getNote(id))!;
    expect(note.syncStatus, SyncStatus.synced);
    expect(note.version, 1);
    expect((await server.get('notes', id))!['title'], 'Offline note');
  });

  test('lost response on create: retry gives no duplicate', () async {
    final id = await local.createNote(title: 'A');

    server.faults.loseResponseAfterCommit = true;
    await engine.sync(); // server stores it, we get NetworkError
    expect((await local.getNote(id))!.syncStatus, SyncStatus.pending);

    server.faults.loseResponseAfterCommit = false;
    await makeRetriesDue();
    await engine.sync(); // retry -> AlreadyExists -> treated as success

    expect(await serverNoteCount(), 1);
    final note = (await local.getNote(id))!;
    expect(note.syncStatus, SyncStatus.synced);
    expect(note.version, 1);
  });

  test('lost response on update: retry is not a false conflict', () async {
    final id = await local.createNote(title: 'A');
    await engine.sync();
    await local.updateNote(id, 'B', '');

    server.faults.loseResponseAfterCommit = true;
    await engine.sync(); // update lands on the server, response lost

    server.faults.loseResponseAfterCommit = false;
    await makeRetriesDue();
    await engine.sync(); // retry -> Conflict, but it's our own write

    final note = (await local.getNote(id))!;
    expect(note.syncStatus, SyncStatus.synced);
    expect(note.version, 2);
    expect((await server.get('notes', id))!['title'], 'B');
  });

  test('conflict keeps both edits until the user picks one', () async {
    final id = await local.createNote(title: 'Note', body: 'v1');
    await engine.sync();

    await local.updateNote(id, 'Note', 'my edit');
    server.simulateOtherDeviceEdit('notes', id, {'body': 'their edit'});
    await engine.sync();

    var note = (await local.getNote(id))!;
    expect(note.syncStatus, SyncStatus.conflict);
    expect(note.body, 'my edit'); // mine is kept
    expect(note.serverBody, 'their edit'); // theirs is kept too

    await local.resolveConflict(id, keepMine: true);
    await engine.sync();

    note = (await local.getNote(id))!;
    expect(note.syncStatus, SyncStatus.synced);
    expect((await server.get('notes', id))!['body'], 'my edit');
    expect((await server.get('notes', id))!['version'], 3);
  });

  test('edit vs delete on other device: keep theirs deletes it', () async {
    final id = await local.createNote(title: 'Note');
    await engine.sync();

    await local.updateNote(id, 'Edited offline', '');
    server.simulateOtherDeviceEdit('notes', id, {'deleted': true});
    await engine.sync();

    var note = (await local.getNote(id))!;
    expect(note.syncStatus, SyncStatus.conflict);
    expect(note.serverDeleted, true);

    await local.resolveConflict(id, keepMine: false);
    note = (await local.getNote(id))!;
    expect(note.deleted, true);
    expect(note.syncStatus, SyncStatus.synced);
  });

  test('5 edits become one push; create + delete cancels out', () async {
    final a = await local.createNote(title: 'A');
    await engine.sync();

    server.faults.offline = true;
    for (var i = 1; i <= 5; i++) {
      await local.updateNote(a, 'A$i', '');
    }
    final b = await local.createNote(title: 'B');
    await local.deleteNote(b);

    final waiting = (await local.getOutbox())
        .where((e) => e.status != OutboxStatus.done)
        .toList();
    expect(waiting, hasLength(1)); // one update for A, nothing for B
    expect(waiting.single.payload['title'], 'A5');
    expect(await local.getNote(b), isNull);

    server.faults.offline = false;
    await engine.sync();

    final serverA = (await server.get('notes', a))!;
    expect(serverA['title'], 'A5');
    expect(serverA['version'], 2); // one update, not five
    expect(await server.get('notes', b), isNull);
  });
}
