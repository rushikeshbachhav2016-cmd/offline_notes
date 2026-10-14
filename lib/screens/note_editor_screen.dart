import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../data/database_helper.dart';
import '../data/sync_engine.dart';
import '../model/attachment.dart';
import '../model/note.dart';
import '../utils/app_theme.dart';
import '../utils/constants.dart';
import '../widgets/attachment_tile.dart';
import '../widgets/sync_status_icon.dart';

/// noteId == null  -> "New note": nothing is saved until the user writes something.
/// noteId != null  -> "Edit note".
class NoteEditorScreen extends StatefulWidget {
  const NoteEditorScreen({super.key, this.noteId});

  final String? noteId;

  @override
  State<NoteEditorScreen> createState() => _NoteEditorScreenState();
}

class _NoteEditorScreenState extends State<NoteEditorScreen> {
  final _db = DatabaseHelper.instance;
  final _title = TextEditingController();
  final _body = TextEditingController();

  String? _noteId; // set once the note exists in the database
  Note? _note;
  List<Attachment> _attachments = [];
  bool _deleted = false;
  StreamSubscription<void>? _sub;

  // The text last loaded/saved. If the fields still match it,
  // the user hasn't changed anything.
  String _shownTitle = '';
  String _shownBody = '';

  bool get _isNew => widget.noteId == null;
  bool get _dirty => _title.text != _shownTitle || _body.text != _shownBody;
  bool get _isEmpty => _title.text.trim().isEmpty && _body.text.trim().isEmpty;

  @override
  void initState() {
    super.initState();
    _noteId = widget.noteId;
    if (_noteId != null) {
      _load();
      // Attachments download lazily: only when the note is opened.
      syncEngine.downloadAttachments(_noteId!);
    }
    _sub = _db.changes.listen((_) => _load());
  }

  @override
  void dispose() {
    _sub?.cancel();
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final id = _noteId;
    if (id == null) return;
    final note = await _db.getNote(id);
    final attachments = await _db.getAttachments(id);
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

  /// Saves when leaving the screen. An empty note is never saved.
  Future<void> _save() async {
    if (_deleted || !_dirty || _isEmpty) return;
    _shownTitle = _title.text;
    _shownBody = _body.text;

    if (_noteId == null) {
      _noteId = await _db.createNote(title: _title.text, body: _body.text);
    } else {
      await _db.updateNote(_noteId!, _title.text, _body.text);
    }
    syncEngine.sync();
  }

  void _show(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _delete() async {
    _deleted = true; // stops _save() from queueing an update after delete
    final id = _noteId;
    if (id != null) {
      await _db.deleteNote(id);
      syncEngine.sync();
    }
    if (mounted) Navigator.pop(context);
  }

  Future<void> _attach() async {
    // A new note must exist (and not be empty) before it can get a file.
    if (_noteId == null) {
      if (_isEmpty) {
        _show('Write a title or some text first');
        return;
      }
      await _save();
      await _load();
    }

    final result = await FilePicker.platform.pickFiles();
    final picked = result?.files.single;
    if (picked == null || picked.path == null) return;
    await _db.addAttachment(
      noteId: _noteId!,
      sourcePath: picked.path!,
      fileName: picked.name,
    );
    syncEngine.sync();
  }

  Future<void> _resolve({required bool keepMine}) async {
    await _save(); // keep anything typed so far
    await _db.resolveConflict(_noteId!, keepMine: keepMine);
    syncEngine.sync();
  }

  Widget _conflictBanner(Note note) {
    final theirs = note.serverDeleted
        ? 'Deleted on the other device'
        : '${note.serverTitle}\n${note.serverBody}';
    final mine =
        note.deleted ? 'You deleted this note' : 'The text below';

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF8E1),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFFFE082)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Changed on another device',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text('Theirs: $theirs', style: const TextStyle(height: 1.4)),
          const SizedBox(height: 4),
          Text('Mine: $mine', style: const TextStyle(height: 1.4)),
          const SizedBox(height: 8),
          Row(
            children: [
              FilledButton(
                onPressed: () => _resolve(keepMine: true),
                child: const Text('Keep mine'),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () => _resolve(keepMine: false),
                child: const Text('Keep theirs'),
              ),
            ],
          ),
        ],
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
          title: Text(_isNew ? 'New note' : 'Edit note'),
          actions: [
            if (note != null) Center(child: SyncStatusIcon(note.syncStatus)),
            IconButton(
              icon: const Icon(Icons.attach_file),
              tooltip: 'Attach file',
              onPressed: _attach,
            ),
            if (!_isNew)
              IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Delete note',
                onPressed: _delete,
              ),
            const SizedBox(width: 4),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          children: [
            if (note != null && note.syncStatus == SyncStatus.conflict)
              _conflictBanner(note),
            TextField(
              controller: _title,
              autofocus: _isNew,
              textCapitalization: TextCapitalization.sentences,
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
              decoration: const InputDecoration(
                hintText: 'Title',
                border: InputBorder.none,
              ),
            ),
            TextField(
              controller: _body,
              textCapitalization: TextCapitalization.sentences,
              minLines: 8,
              maxLines: null,
              style: const TextStyle(fontSize: 16, height: 1.5),
              decoration: const InputDecoration(
                hintText: 'Start writing…',
                border: InputBorder.none,
              ),
            ),
            if (_attachments.isNotEmpty) ...[
              const SizedBox(height: 16),
              const Text(
                'ATTACHMENTS',
                style: TextStyle(
                  fontSize: 11,
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.muted,
                ),
              ),
              const SizedBox(height: 8),
              for (final a in _attachments)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: AttachmentTile(attachment: a, file: _db.fileFor(a)),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
