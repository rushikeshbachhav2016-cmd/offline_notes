import 'package:flutter/material.dart';

import '../model/note.dart';
import 'sync_status_icon.dart';

class NoteTile extends StatelessWidget {
  const NoteTile({super.key, required this.note, required this.onTap});

  final Note note;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(note.title.isEmpty ? 'Untitled' : note.title),
      subtitle: Text(note.body, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: SyncStatusIcon(note.syncStatus),
      onTap: onTap,
    );
  }
}