import 'package:flutter/material.dart';

import '../utils/constants.dart';

class SyncStatusIcon extends StatelessWidget {
  const SyncStatusIcon(this.status, {super.key});

  final String status;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (status) {
      SyncStatus.synced => (Icons.cloud_done, Colors.green),
      SyncStatus.pending => (Icons.cloud_upload, Colors.orange),
      SyncStatus.failed => (Icons.error, Colors.red),
      SyncStatus.conflict => (Icons.warning, Colors.amber),
      _ => (Icons.help_outline, Colors.grey),
    };
    return Tooltip(message: status, child: Icon(icon, color: color));
  }
}