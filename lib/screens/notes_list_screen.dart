import 'dart:async';

import 'package:flutter/material.dart';

import '../data/database_helper.dart';
import '../data/sync_engine.dart';
import '../model/note.dart';
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

  String _formatTime(String? iso) {
    if (iso == null) return 'never';
    return DateTime.parse(iso).toLocal().toString().substring(0, 19);
  }

  Future<void> _newNote() async {
    final id = await _db.createNote();
    if (!mounted) return;
    _open(id);
  }

  void _open(String id) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => NoteEditorScreen(noteId: id)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Notes'),
            Text(
              'Last synced: ${_formatTime(_lastSynced)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.bug_report),
            tooltip: 'Debug menu',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const DebugScreen()),
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => syncEngine.sync(), // sync on pull-to-refresh
        child: _notes.isEmpty
            ? ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const [
            SizedBox(height: 200),
            Center(child: Text('No notes yet')),
          ],
        )
            : ListView.builder(
          physics: const AlwaysScrollableScrollPhysics(),
          itemCount: _notes.length,
          itemBuilder: (context, i) => NoteTile(
            note: _notes[i],
            onTap: () => _open(_notes[i].id),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _newNote,
        child: const Icon(Icons.add),
      ),
    );
  }
}