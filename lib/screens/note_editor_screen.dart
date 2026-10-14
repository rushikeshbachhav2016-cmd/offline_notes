import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../data/database_helper.dart';
import '../data/sync_engine.dart';
import '../model/attachment.dart';
import '../model/note.dart';
import '../utils/constants.dart';
import '../widgets/attachment_tile.dart';
import '../widgets/sync_status_icon.dart';

class NoteEditorScreen extends StatefulWidget {
  const NoteEditorScreen({super.key, required this.noteId});

  final String noteId;

  @override
  State<NoteEditorScreen> createState() => _NoteEditorScreenState();
}

class _NoteEditorScreenState extends State<NoteEditorScreen> {
  final _db = DatabaseHelper.instance;
  final _title = TextEditingController();
  final _body = TextEditingController();
  Note? _note;
  List<Attachment> _attachments = [];
  bool _deleted = false;
  StreamSubscription<void>? _sub;

  // The text last loaded from the database. If the fields still match it,
  // the user hasn't typed anything.
  String _shownTitle = '';
  String _shownBody = '';

  bool get _dirty => _title.text != _shownTitle || _body.text != _shownBody;

  @override
  void initState() {
    super.initState();
    _load();
    _sub = _db.changes.listen((_) => _load());
    // Attachments download lazily: only when the note is opened.
    syncEngine.downloadAttachments(widget.noteId);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final note = await _db.getNote(widget.noteId);
    final attachments = await _db.getAttachments(widget.noteId);
    if (!mounted || note == null) return;
    setState(() {
      // Show the latest saved text, unless the user is typing.
      if (_note == null || !_dirty) {
        if (_title.text != note.title) _title.text = note.title;
        if (_body.text != note.body) _body.text = note.body;
        _shownTitle = note.title;
        _shownBody = note.body;
      }
      _note = note;
      _attachments = attachments;
    });
  }

  /// Runs when leaving the screen. Saves only if the user changed something.
  Future<void> _save() async {
    final note = _note;
    if (note == null || _deleted || !_dirty) return;
    _shownTitle = _title.text;
    _shownBody = _body.text;
    await _db.updateNote(note.id, _title.text, _body.text);
    syncEngine.sync();
  }

  Future<void> _delete() async {
    _deleted = true; // stops _save() from queueing an update after delete
    await _db.deleteNote(widget.noteId);
    syncEngine.sync();
    if (mounted) Navigator.pop(context);
  }

  Future<void> _attach() async {
    final result = await FilePicker.platform.pickFiles();
    final picked = result?.files.single;
    if (picked == null || picked.path == null) return;
    await _db.addAttachment(
      noteId: widget.noteId,
      sourcePath: picked.path!,
      fileName: picked.name,
    );
    syncEngine.sync();
  }

  Future<void> _resolve({required bool keepMine}) async {
    await _save(); // keep anything typed so far
    await _db.resolveConflict(widget.noteId, keepMine: keepMine);
    syncEngine.sync();
  }

  Widget _conflictBanner(Note note) {
    final theirs = note.serverDeleted
        ? 'Deleted on the other device'
        : '${note.serverTitle}\n${note.serverBody}';
    final mine = note.deleted
        ? 'You deleted this note'
        : 'The text in the fields below';

    return Card(
      color: Colors.amber.shade100,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Conflict: this note was changed on another device',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text('Theirs: $theirs'),
            const SizedBox(height: 4),
            Text('Mine: $mine'),
            Row(
              children: [
                TextButton(
                  onPressed: () => _resolve(keepMine: true),
                  child: const Text('Keep mine'),
                ),
                TextButton(
                  onPressed: () => _resolve(keepMine: false),
                  child: const Text('Keep theirs'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final note = _note;

    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _save();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Edit note'),
          actions: [
            if (note != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: SyncStatusIcon(note.syncStatus),
              ),
            IconButton(
              icon: const Icon(Icons.attach_file),
              onPressed: _attach,
            ),
            IconButton(
              icon: const Icon(Icons.delete),
              onPressed: _delete,
            ),
          ],
        ),
        body: note == null
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (note.syncStatus == SyncStatus.conflict)
                    _conflictBanner(note),
                  TextField(
                    controller: _title,
                    decoration: const InputDecoration(labelText: 'Title'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _body,
                    decoration: const InputDecoration(
                      labelText: 'Body',
                      alignLabelWithHint: true,
                    ),
                    minLines: 6,
                    maxLines: null,
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Attachments',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  if (_attachments.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Text('None'),
                    ),
                  for (final a in _attachments)
                    AttachmentTile(attachment: a, file: _db.fileFor(a)),
                ],
              ),
      ),
    );
  }
}
