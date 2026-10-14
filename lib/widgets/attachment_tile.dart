import 'dart:io';

import 'package:flutter/material.dart';

import '../model/attachment.dart';
import '../utils/file_utils.dart';
import 'sync_status_icon.dart';

class AttachmentTile extends StatelessWidget {
  const AttachmentTile({super.key, required this.attachment, this.file});

  final Attachment attachment;
  final File? file; // local copy, null if not downloaded yet

  @override
  Widget build(BuildContext context) {
    final localFile = file;

    Widget leading;
    if (localFile == null || !localFile.existsSync()) {
      leading = const Icon(Icons.cloud_download); // not downloaded yet
    } else if (FileUtils.isImage(attachment.mimeType)) {
      leading = Image.file(localFile, width: 48, height: 48, fit: BoxFit.cover);
    } else {
      leading = const Icon(Icons.insert_drive_file);
    }

    return ListTile(
      leading: leading,
      title: Text(attachment.fileName),
      subtitle: Text('${attachment.sizeBytes ~/ 1024} KB'),
      trailing: SyncStatusIcon(attachment.syncStatus),
    );
  }
}
