import 'package:flutter_test/flutter_test.dart';
import 'package:offline_notes/model/note.dart';
import 'package:offline_notes/model/outbox_entry.dart';
import 'package:offline_notes/utils/constants.dart';

void main() {
  test('Note: toJson -> fromJson gives the same note', () {
    const note = Note(id: 'n1', title: 'Hello', body: 'World', version: 3);
    final copy = Note.fromJson(note.toJson());

    expect(copy.id, 'n1');
    expect(copy.title, 'Hello');
    expect(copy.body, 'World');
    expect(copy.version, 3);
    expect(copy.deleted, false);
    expect(copy.syncStatus, SyncStatus.pending);
  });

  test('Note: reads a server row (deleted is a bool there)', () {
    final note = Note.fromJson({
      'id': 'n1',
      'title': 'T',
      'body': 'B',
      'deleted': true,
      'version': 2,
    });

    expect(note.deleted, true);
    expect(note.version, 2);
    expect(note.syncStatus, SyncStatus.synced);
  });

  test('OutboxEntry: payload survives the JSON string round trip', () {
    const entry = OutboxEntry(
      entityType: EntityType.note,
      entityId: 'n1',
      noteId: 'n1',
      op: OutboxOp.update,
      payload: {'title': 'A', 'body': 'B'},
      baseVersion: 1,
      createdAt: 0,
    );
    final copy = OutboxEntry.fromJson(entry.toJson());

    expect(copy.payload, {'title': 'A', 'body': 'B'});
    expect(copy.status, OutboxStatus.queued);
    expect(copy.lane, Lane.data);
  });
}
