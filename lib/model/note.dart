import '../utils/constants.dart';

class Note {
  const Note({
    required this.id,
    required this.title,
    required this.body,
    this.deleted = false,
    this.version = 0,
    this.syncStatus = SyncStatus.pending,
    this.localUpdatedAt = 0,
    this.serverTitle,
    this.serverBody,
    this.serverVersion,
    this.serverDeleted = false,
  });

  final String id;
  final String title;
  final String body;
  final bool deleted;
  final int version; // server version this copy is based on (0 = not on server yet)
  final String syncStatus; // synced | pending | failed | conflict
  final int localUpdatedAt; // only for sorting the list, never for conflicts

  // Filled only while in conflict: the server's copy, so nothing is lost.
  final String? serverTitle;
  final String? serverBody;
  final int? serverVersion;
  final bool serverDeleted;

  /// Reads a DB row (deleted = 0/1) or a server row (deleted = true/false).
  factory Note.fromJson(Map<String, Object?> json) {
    return Note(
      id: json['id'] as String,
      title: json['title'] as String? ?? '',
      body: json['body'] as String? ?? '',
      deleted: json['deleted'] == 1 || json['deleted'] == true,
      version: json['version'] as int? ?? 0,
      syncStatus: json['sync_status'] as String? ?? SyncStatus.synced,
      localUpdatedAt: json['local_updated_at'] as int? ?? 0,
      serverTitle: json['server_title'] as String?,
      serverBody: json['server_body'] as String?,
      serverVersion: json['server_version'] as int?,
      serverDeleted: json['server_deleted'] == 1,
    );
  }

  /// Shape of a row in the local `notes` table.
  Map<String, Object?> toJson() {
    return {
      'id': id,
      'title': title,
      'body': body,
      'deleted': deleted ? 1 : 0,
      'version': version,
      'sync_status': syncStatus,
      'local_updated_at': localUpdatedAt,
      'server_title': serverTitle,
      'server_body': serverBody,
      'server_version': serverVersion,
      'server_deleted': serverDeleted ? 1 : 0,
    };
  }
}
