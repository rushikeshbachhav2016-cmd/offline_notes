import '../utils/constants.dart';

class Attachment {
  const Attachment({
    required this.id,
    required this.noteId,
    required this.fileName,
    required this.mimeType,
    required this.sizeBytes,
    this.localPath,
    this.storagePath,
    this.deleted = false,
    this.version = 0,
    this.syncStatus = SyncStatus.pending,
  });

  final String id;
  final String noteId;
  final String fileName;
  final String mimeType;
  final int sizeBytes;
  final String? localPath; // relative to app folder; null until downloaded
  final String? storagePath; // set only after the server has the file
  final bool deleted;
  final int version;
  final String syncStatus;

  factory Attachment.fromJson(Map<String, Object?> json) {
    return Attachment(
      id: json['id'] as String,
      noteId: json['note_id'] as String,
      fileName: json['file_name'] as String,
      mimeType: json['mime_type'] as String,
      sizeBytes: json['size_bytes'] as int,
      localPath: json['local_path'] as String?,
      storagePath: json['storage_path'] as String?,
      deleted: json['deleted'] == 1 || json['deleted'] == true,
      version: json['version'] as int? ?? 0,
      syncStatus: json['sync_status'] as String? ?? SyncStatus.synced,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'note_id': noteId,
      'file_name': fileName,
      'mime_type': mimeType,
      'size_bytes': sizeBytes,
      'local_path': localPath,
      'storage_path': storagePath,
      'deleted': deleted ? 1 : 0,
      'version': version,
      'sync_status': syncStatus,
    };
  }
}