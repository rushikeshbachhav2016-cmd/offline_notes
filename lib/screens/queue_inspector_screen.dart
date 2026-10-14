import 'dart:async';

import 'package:flutter/material.dart';

import '../data/database_helper.dart';
import '../data/sync_engine.dart';
import '../model/outbox_entry.dart';
import '../utils/constants.dart';

/// Shows every outbox entry with its status, attempts and last error.
class QueueInspectorScreen extends StatefulWidget {
  const QueueInspectorScreen({super.key});

  @override
  State<QueueInspectorScreen> createState() => _QueueInspectorScreenState();
}

class _QueueInspectorScreenState extends State<QueueInspectorScreen> {
  final _db = DatabaseHelper.instance;
  List<OutboxEntry> _entries = [];
  StreamSubscription<void>? _sub;

  @override
  void initState() {
    super.initState();
    _load();
    _sub = _db.changes.listen((_) => _load());
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final entries = await _db.getOutbox();
    if (mounted) setState(() => _entries = entries);
  }

  Color _statusColor(String status) => switch (status) {
        OutboxStatus.done => Colors.green,
        OutboxStatus.inFlight => Colors.blue,
        OutboxStatus.failed => Colors.red,
        _ => Colors.orange,
      };

  String _retryIn(OutboxEntry e) {
    final seconds =
        (e.nextAttemptAt - DateTime.now().millisecondsSinceEpoch) ~/ 1000;
    return seconds > 0 ? ' · retry in ${seconds}s' : '';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Queue (${_entries.length})'),
        actions: [
          IconButton(
            icon: const Icon(Icons.replay),
            tooltip: 'Retry failed',
            onPressed: () async {
              await _db.retryFailed();
              syncEngine.sync();
            },
          ),
          IconButton(
            icon: const Icon(Icons.cleaning_services),
            tooltip: 'Clear done',
            onPressed: _db.clearDone,
          ),
        ],
      ),
      body: _entries.isEmpty
          ? const Center(child: Text('Queue is empty'))
          : ListView.separated(
              itemCount: _entries.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final e = _entries[i];
                return ListTile(
                  dense: true,
                  title: Text(
                    '#${e.id}  ${e.op} ${e.entityType}  [${e.lane} lane]',
                  ),
                  subtitle: Text(
                    'note ${e.noteId.substring(0, 8)} · '
                    'attempts ${e.attempts}${_retryIn(e)}\n'
                    'payload ${e.payload}'
                    '${e.lastError == null ? '' : '\nerror: ${e.lastError}'}',
                  ),
                  trailing: Text(
                    e.status,
                    style: TextStyle(
                      color: _statusColor(e.status),
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                );
              },
            ),
    );
  }
}
