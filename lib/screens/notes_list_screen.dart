import 'dart:async';

import 'package:flutter/material.dart';

import '../data/database_helper.dart';
import '../data/sync_engine.dart';
import '../model/note.dart';
import '../utils/app_theme.dart';
import '../widgets/note_tile.dart';
import 'debug_screen.dart';
import 'note_editor_screen.dart';

class NotesListScreen extends StatefulWidget {
  const NotesListScreen({super.key});

  @override
  State<NotesListScreen> createState() => _NotesListScreenState();
}

class _NotesListScreenState extends State<NotesListScreen> {
  final _db = DatabaseHelper.instance;
  List<Note> _notes = [];
  String? _lastSynced;
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
    final notes = await _db.getNotes();
    final lastSynced = await _db.getLastSyncedAt();
    if (!mounted) return;
    setState(() {
      _notes = notes;
      _lastSynced = lastSynced;
    });
  }

  String _syncedText() {
    final iso = _lastSynced;
    if (iso == null) return 'Not synced yet';
    final t = DateTime.parse(iso).toLocal();
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    return 'Last synced $hh:$mm';
  }

  /// Opens the editor in "new note" mode (nothing is saved yet),
  /// or in "edit" mode for an existing note.
  void _open({String? noteId}) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => NoteEditorScreen(noteId: noteId)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 72,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Notes',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 2),
            Text(
              _syncedText(),
              style: const TextStyle(fontSize: 12, color: AppTheme.muted),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.bug_report_outlined),
            tooltip: 'Debug menu',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const DebugScreen()),
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => syncEngine.sync(), // sync on pull-to-refresh
        child: _notes.isEmpty
            ? ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: const [
                  SizedBox(height: 180),
                  Icon(Icons.sticky_note_2_outlined,
                      size: 48, color: AppTheme.muted),
                  SizedBox(height: 12),
                  Text(
                    'No notes yet',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  SizedBox(height: 4),
                  Text(
                    'Tap + to write your first note',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppTheme.muted),
                  ),
                ],
              )
            : ListView.separated(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                itemCount: _notes.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (context, i) => NoteTile(
                  note: _notes[i],
                  onTap: () => _open(noteId: _notes[i].id),
                ),
              ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _open(),
        tooltip: 'New note',
        child: const Icon(Icons.add),
      ),
    );
  }
}
