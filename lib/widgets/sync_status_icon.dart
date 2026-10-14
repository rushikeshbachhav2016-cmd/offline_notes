import 'package:flutter/material.dart';

import '../utils/constants.dart';

/// Small pill: coloured dot + word (Synced, Pending, Failed, Conflict).
class SyncStatusIcon extends StatelessWidget {
  const SyncStatusIcon(this.status, {super.key});

  final String status;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      SyncStatus.synced => ('Synced', const Color(0xFF2E7D32)),
      SyncStatus.pending => ('Pending', const Color(0xFFEF6C00)),
      SyncStatus.failed => ('Failed', const Color(0xFFC62828)),
      SyncStatus.conflict => ('Conflict', const Color(0xFFB8860B)),
      _ => (status, Colors.grey),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
