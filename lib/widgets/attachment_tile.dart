import 'dart:io';

import 'package:flutter/material.dart';

import '../model/attachment.dart';
import '../utils/app_theme.dart';
import '../utils/file_utils.dart';
import 'sync_status_icon.dart';

class AttachmentTile extends StatelessWidget {
  const AttachmentTile({super.key, required this.attachment, this.file});

  final Attachment attachment;
  final File? file; // local copy, null if not downloaded yet

  @override
  Widget build(BuildContext context) {
    final localFile = file;

    Widget preview;
    if (localFile == null || !localFile.existsSync()) {
      preview = const Icon(Icons.cloud_download_outlined, color: AppTheme.muted);
    } else if (FileUtils.isImage(attachment.mimeType)) {
      preview = Image.file(localFile, fit: BoxFit.cover);
    } else {
      preview = const Icon(Icons.insert_drive_file_outlined, color: AppTheme.muted);
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Container(
                width: 48,
                height: 48,
                color: AppTheme.background,
                child: preview,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    attachment.fileName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${attachment.sizeBytes ~/ 1024} KB',
                    style: const TextStyle(fontSize: 12, color: AppTheme.muted),
                  ),
                ],
              ),
            ),
            SyncStatusIcon(attachment.syncStatus),
          ],
        ),
      ),
    );
  }
}
