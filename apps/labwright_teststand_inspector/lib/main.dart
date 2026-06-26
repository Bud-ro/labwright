import 'dart:io';
import 'dart:typed_data';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:labwright_teststand/labwright_teststand.dart';

import 'src/document_view.dart';
import 'src/property_outline.dart';
import 'src/properties_view.dart';
import 'src/sequence_outline.dart';
import 'src/sequences_view.dart';

void main(List<String> args) {
  // Allow `flutter run -- path/to/file.seq` to open a file at launch.
  runApp(InspectorApp(initialPath: args.isNotEmpty ? args.first : null));
}

class InspectorApp extends StatelessWidget {
  const InspectorApp({super.key, this.initialPath});
  final String? initialPath;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Labwright TestStand Inspector',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: InspectorPage(initialPath: initialPath),
    );
  }
}

class InspectorPage extends StatefulWidget {
  const InspectorPage({super.key, this.initialPath});
  final String? initialPath;

  @override
  State<InspectorPage> createState() => _InspectorPageState();
}

class _InspectorPageState extends State<InspectorPage> {
  SeqDocument? _doc;
  String? _path;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.initialPath != null) _loadPath(widget.initialPath!);
  }

  void _loadBytes(String path, Uint8List bytes) {
    setState(() {
      _path = path;
      _error = null;
      try {
        _doc = SeqDocument.parse(bytes);
      } catch (e) {
        _doc = null;
        _error = '$e';
      }
    });
  }

  void _loadPath(String path) {
    try {
      _loadBytes(path, File(path).readAsBytesSync());
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  Future<void> _pick() async {
    final res = await FilePicker.pickFiles(withData: true);
    final f = res?.files.single;
    if (f == null) return;
    final bytes = f.bytes ?? (f.path != null ? File(f.path!).readAsBytesSync() : null);
    if (bytes != null) _loadBytes(f.path ?? f.name, bytes);
  }

  @override
  Widget build(BuildContext context) {
    final doc = _doc;
    // The Sequences/Properties tabs only apply to XML files we parsed into a
    // SeqFile.
    final file = doc is XmlSeqDocument ? doc.file : null;
    final outline = file != null ? SeqOutline.of(file) : null;
    final tree = file != null ? propertyTree(file) : null;
    return DefaultTabController(
      length: file != null ? 3 : 1,
      child: Scaffold(
        appBar: AppBar(
          title:
              Text(doc != null ? documentTitle(doc) : 'Labwright TestStand Inspector'),
          actions: [
            IconButton(
                onPressed: _pick,
                icon: const Icon(Icons.folder_open),
                tooltip: 'Open .seq'),
          ],
          bottom: TabBar(
            tabs: [
              const Tab(text: 'Dump'),
              if (file != null) const Tab(text: 'Sequences'),
              if (file != null) const Tab(text: 'Properties'),
            ],
          ),
        ),
        body: DropTarget(
          onDragDone: (d) {
            final file = d.files.isNotEmpty ? d.files.first : null;
            if (file != null) _loadPath(file.path);
          },
          child: _body(doc, outline, tree),
        ),
      ),
    );
  }

  Widget _body(SeqDocument? doc, SeqOutline? outline, PropertyNode? tree) {
    if (_error != null) {
      return Center(
          child: Text('Error: $_error', style: const TextStyle(color: Colors.red)));
    }
    if (doc == null) {
      return const Center(
        child: Text('Open a TestStand .seq file (button above) or drag one here.'),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_path != null)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(_path!, style: Theme.of(context).textTheme.bodySmall),
          ),
        const Divider(height: 1),
        Expanded(
          child: TabBarView(
            children: [
              SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: SelectableText(
                  documentText(doc),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                ),
              ),
              if (outline != null) SequencesView(outline: outline),
              if (tree != null) PropertiesView(root: tree),
            ],
          ),
        ),
      ],
    );
  }
}
