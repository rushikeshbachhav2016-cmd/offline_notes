import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'data/database_helper.dart';
import 'data/sync_engine.dart';
import 'fake_server.dart';
import 'screens/notes_list_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final dir = await getApplicationSupportDirectory();

  // Local database + attachment files live in the app support folder.
  await DatabaseHelper.instance.init(dir.path);

  // The fake server keeps its state in its own folder ("the cloud"),
  // so "wipe local data" can keep it. Only the sync engine talks to it.
  syncEngine = SyncEngine(
    db: DatabaseHelper.instance.db,
    server: FakeServer.open(Directory('${dir.path}/fake_server')),
    filesDir: dir.path,
    onChanged: DatabaseHelper.instance.notifyChanged,
  );
  await syncEngine.start(); // crash recovery + first sync

  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Sync on app resume.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) syncEngine.sync();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Offline Notes',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.indigo),
      home: const NotesListScreen(),
    );
  }
}
