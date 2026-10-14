import 'dart:convert';

import '../utils/constants.dart';

class OutboxEntry {
  const OutboxEntry({
    this.id,
    required this.entityType,
    required this.entityId,
    required this.noteId,
    required this.op,
    this.payload = const {},
    this.baseVersion = 0,
    this.lane = Lane.data,
    this.status = OutboxStatus.queued,
    this.attempts = 0,
    this.nextAttemptAt = 0,
    this.lastError,
    required this.createdAt,
  });

  final int? id; // auto-increment, gives FIFO order
  final String entityType; // note | attachment
  final String entityId;
  final String noteId; // groups entries of one note (FIFO per note)
  final String op; // insert | update | delete | upload
  final Map<String, Object?> payload;
  final int baseVersion;
  final String lane; // data | file
  final String status; // queued | in_flight | done | failed
  final int attempts;
  final int nextAttemptAt; // millis; 0 = run now
  final String? lastError;
  final int createdAt;

  factory OutboxEntry.fromJson(Map<String, Object?> json) {
    return OutboxEntry(
      id: json['id'] as int?,
      entityType: json['entity_type'] as String,
      entityId: json['entity_id'] as String,
      noteId: json['note_id'] as String,
      op: json['op'] as String,
      // payload is stored as a JSON string in SQLite
      payload: jsonDecode(json['payload'] as String) as Map<String, Object?>,
      baseVersion: json['base_version'] as int,
      lane: json['lane'] as String,
      status: json['status'] as String,
      attempts: json['attempts'] as int,
      nextAttemptAt: json['next_attempt_at'] as int,
      lastError: json['last_error'] as String?,
      createdAt: json['created_at'] as int,
    );
  }

  Map<String, Object?> toJson() {
    return {
      if (id != null) 'id': id,
      'entity_type': entityType,
      'entity_id': entityId,
      'note_id': noteId,
      'op': op,
      'payload': jsonEncode(payload),
      'base_version': baseVersion,
      'lane': lane,
      'status': status,
      'attempts': attempts,
      'next_attempt_at': nextAttemptAt,
      'last_error': lastError,
      'created_at': createdAt,
    };
  }
}