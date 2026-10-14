import 'dart:async';

import 'package:flutter/material.dart';

import '../data/database_helper.dart';
import '../data/sync_engine.dart';
import '../fake_server.dart';
import '../model/note.dart';
import 'queue_inspector_screen.dart';

/// Fault switches, "the other device", wipe, and the queue inspector.
/// Everything here goes through the sync engine, never straight to the server.
class DebugScreen extends StatefulWidget {
  const DebugScreen({super.key});

  @override
  State<DebugScreen> createState() => _DebugScreenState();
}

class _DebugScreenState extends State<DebugScreen> {
  final _db = DatabaseHelper.instance;
  List<Note> _notes = [];
  StreamSubscription<void>? _sub;

  FaultConfig get _faults => syncEngine.faults;

  @override
  void initState() {
    super.initState();
    _loadNotes();
    // Reload whenever local data changes (e.g. after a pull).
    _sub = _db.changes.listen((_) => _loadNotes());
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _loadNotes() async {
    final notes = await _db.getNotes();
    if (mounted) setState(() => _notes = notes);
  }

  void _show(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _otherDevice(Note note, Map<String, Object?> changes) {
    try {
      syncEngine.simulateOtherDeviceEdit(note.id, changes);
    } on NotFound {
      _show('This note is not on the server yet. Sync it first.');
      return;
    }

    if (_faults.offline) {
      // Like a real phone: you only see the other device's change once online.
      _show('Changed on the server. You are offline, so it shows when you go online.');
    } else {
      _show('Changed on the other device. Syncing…');
      syncEngine.sync(); // pull it now, so this list and the notes list update
    }
  }

  Future<void> _wipe() async {
    await _db.wipeLocalData();
    await _loadNotes();
    if (!mounted) return;
    _show('Local data wiped. The server folder is kept.');
    syncEngine.sync(); // pull everything back
  }

  @override
  Widget build(BuildContext context) {
    final time = TimeOfDay.now().format(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Debug menu')),
      body: ListView(
        children: [
          SwitchListTile(
            title: const Text('Offline'),
            value: _faults.offline,
            onChanged: (value) {
              setState(() => _faults.offline = value);
              if (!value) syncEngine.sync(); // sync on reconnect
            },
          ),
          SwitchListTile(
            title: const Text('30% random failures'),
            value: _faults.failureRate > 0,
            onChanged: (value) =>
                setState(() => _faults.failureRate = value ? 0.3 : 0),
          ),
          SwitchListTile(
            title: const Text('2 second latency'),
            value: _faults.latency > Duration.zero,
            onChanged: (value) => setState(() => _faults.latency =
                value ? const Duration(seconds: 2) : Duration.zero),
          ),
          SwitchListTile(
            title: const Text('Lose response after server commit'),
            value: _faults.loseResponseAfterCommit,
            onChanged: (value) =>
                setState(() => _faults.loseResponseAfterCommit = value),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.list_alt),
            title: const Text('Queue inspector'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const QueueInspectorScreen()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.sync),
            title: const Text('Sync now'),
            onTap: () => syncEngine.sync(),
          ),
          ListTile(
            leading: const Icon(Icons.delete_forever, color: Colors.red),
            title: const Text('Wipe local data (keep server)'),
            subtitle: const Text('Fresh-install demo'),
            onTap: _wipe,
          ),
          const Divider(),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              'Other device (simulateOtherDeviceEdit)',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          for (final note in _notes)
            ListTile(
              title: Text(note.title.isEmpty ? 'Untitled' : note.title),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.edit),
                    tooltip: 'Edit on other device',
                    onPressed: () => _otherDevice(
                      note,
                      {'body': 'Changed on the other device at $time'},
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: 'Delete on other device',
                    onPressed: () => _otherDevice(note, {'deleted': true}),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
