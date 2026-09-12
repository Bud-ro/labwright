import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:labwright_seq/labwright_seq.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'src/binary_view.dart';
import 'src/document_view.dart';
import 'src/property_outline.dart';
import 'src/properties_view.dart';
import 'src/recent_files.dart';
import 'src/sequence_outline.dart';
import 'src/sequences_view.dart';
import 'src/types_view.dart';
import 'src/ui.dart';

void main(List<String> args) {
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
  List<String> _recent = const [];

  BinaryByteCoverage? _binaryCoverage;

  final _sequencesSearchFocus = FocusNode();
  final _propertiesSearchFocus = FocusNode();
  final _typesSearchFocus = FocusNode();

  static const _recentPrefsKey = 'recentFiles';
  SharedPreferences? _prefs;

  @override
  void initState() {
    super.initState();
    _loadRecent();
    if (widget.initialPath case final path?) _loadPath(path);
  }

  Future<void> _loadRecent() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList(_recentPrefsKey) ?? const [];
    final alive = saved.where((p) => File(p).existsSync()).toList();
    if (!mounted) return;
    setState(() {
      _prefs = prefs;
      for (final path in alive.reversed) {
        if (!_recent.contains(path)) _recent = addRecent(_recent, path);
      }
    });
    if (alive.length != saved.length) _saveRecent();
  }

  void _saveRecent() {
    _prefs?.setStringList(_recentPrefsKey, _recent);
  }

  @override
  void dispose() {
    _sequencesSearchFocus.dispose();
    _propertiesSearchFocus.dispose();
    _typesSearchFocus.dispose();
    super.dispose();
  }

  void _focusSearch(int tabIndex) {
    if (tabIndex == 2) _sequencesSearchFocus.requestFocus();
    if (tabIndex == 3) _propertiesSearchFocus.requestFocus();
    if (tabIndex == 4) _typesSearchFocus.requestFocus();
  }

  void _loadBytes(String path, Uint8List bytes) {
    setState(() {
      _path = path;
      _error = null;
      try {
        _doc = SeqDocument.parse(bytes);
        _binaryCoverage = _doc is BinarySeqDocument
            ? binaryByteCoverage(bytes)
            : null;
      } catch (e) {
        _doc = null;
        _binaryCoverage = null;
        _error = '$e';
      }
      if (File(path).existsSync()) {
        _recent = addRecent(_recent, path);
        _saveRecent();
      }
    });
  }

  void _loadPath(String path) {
    try {
      _loadBytes(path, File(path).readAsBytesSync());
    } catch (e) {
      setState(() {
        _doc = null;
        _binaryCoverage = null;
        _path = path;
        _error = '$e';
      });
    }
  }

  Future<void> _pick() async {
    final res = await FilePicker.pickFiles(withData: true);
    final file = res?.files.single;
    if (file == null) return;
    final path = file.path;
    final bytes =
        file.bytes ?? (path == null ? null : File(path).readAsBytesSync());
    if (bytes != null) _loadBytes(path ?? file.name, bytes);
  }

  @override
  Widget build(BuildContext context) {
    final doc = _doc;
    final file = _fileOf(doc);
    final hasTypes = file != null && file.types.isNotEmpty;
    return DefaultTabController(
      length: file != null ? (hasTypes ? 5 : 4) : 1,
      child: Builder(
        builder: (context) {
          return CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.keyO, control: true):
                  _pick,
              const SingleActivator(LogicalKeyboardKey.keyO, meta: true): _pick,
              const SingleActivator(
                LogicalKeyboardKey.keyF,
                control: true,
              ): () =>
                  _focusSearch(DefaultTabController.of(context).index),
              const SingleActivator(LogicalKeyboardKey.keyF, meta: true): () =>
                  _focusSearch(DefaultTabController.of(context).index),
            },
            child: Focus(
              autofocus: true,
              child: Scaffold(
                appBar: AppBar(
                  title: Text(
                    doc != null
                        ? documentTitle(doc)
                        : 'Labwright TestStand Inspector',
                  ),
                  actions: [
                    if (_recent.isNotEmpty) _recentMenu(),
                    IconButton(
                      onPressed: _pick,
                      icon: const Icon(Icons.folder_open),
                      tooltip: 'Open .seq (Ctrl/Cmd+O)',
                    ),
                  ],
                  bottom: TabBar(
                    tabs: [
                      const Tab(text: 'Dump'),
                      if (file != null) ...[
                        const Tab(text: 'Logic'),
                        const Tab(text: 'Sequences'),
                        const Tab(text: 'Properties'),
                      ],
                      if (hasTypes) const Tab(text: 'Types'),
                    ],
                  ),
                ),
                body: DropTarget(
                  onDragDone: (d) {
                    final file = d.files.isNotEmpty ? d.files.first : null;
                    if (file != null) _loadPath(file.path);
                  },
                  child: _body(doc, file),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _recentMenu() {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.history),
      tooltip: 'Recent files',
      onSelected: _loadPath,
      itemBuilder: (context) => [
        for (final path in _recent)
          PopupMenuItem<String>(
            value: path,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(pathBasename(path)),
                Text(
                  path,
                  style: Theme.of(context).textTheme.bodySmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _body(SeqDocument? doc, SeqFile? file) {
    if (_error case final error?) {
      return Center(
        child: Text('Error: $error', style: const TextStyle(color: Colors.red)),
      );
    }
    if (doc == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Open a TestStand .seq file (Ctrl/Cmd+O) or drag one here.',
            ),
            if (_recent.isNotEmpty) ...[
              const SizedBox(height: 24),
              Text('Recent', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 4),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Column(
                  children: [
                    for (final path in _recent)
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.description_outlined),
                        title: Text(pathBasename(path)),
                        subtitle: Text(path, overflow: TextOverflow.ellipsis),
                        onTap: () => _loadPath(path),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      );
    }
    final coverage = file == null
        ? null
        : doc is BinarySeqDocument
        ? 'binary TOF1 · partial typed model (sequences + typed steps + '
              'modules + typedef heads and decoded bodies; a body marked '
              'undecoded, and populated-array element values, are not yet '
              'decoded)'
        : coverageLabel(measureCoverage(file));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_path case final path?)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 2),
            child: Text(path, style: Theme.of(context).textTheme.bodySmall),
          ),
        if (coverage != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
            child: Row(
              children: [
                Icon(
                  Icons.donut_small,
                  size: 14,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 4),
                Text(
                  coverage,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ],
            ),
          ),
        const Divider(height: 1),
        Expanded(
          child: TabBarView(
            children: [
              if (doc is BinarySeqDocument)
                BinaryView(doc: doc, coverage: _binaryCoverage)
              else
                _dumpTab(doc),
              if (file != null) ...[
                _logicTab(file),
                SequencesView(
                  outline: SeqOutline.of(file),
                  searchFocusNode: _sequencesSearchFocus,
                  typeCount: file.types.length,
                ),
                PropertiesView(
                  root: propertyTree(file),
                  searchFocusNode: _propertiesSearchFocus,
                ),
                if (file.types.isNotEmpty)
                  TypesView(
                    types: file.types,
                    searchFocusNode: _typesSearchFocus,
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  static SeqFile? _fileOf(SeqDocument? doc) => switch (doc) {
    StructuredSeqDocument() => doc.file,
    BinarySeqDocument() => doc.partialFile,
    _ => null,
  };

  Widget _dumpTab(SeqDocument doc) => _monoTextTab(documentText(doc), 'dump');

  Widget _logicTab(SeqFile file) =>
      _monoTextTab(exportSequenceLogic(file), 'logic');

  Widget _monoTextTab(String text, String label) {
    return Stack(
      children: [
        Positioned.fill(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
            child: SelectableText(
              text,
              style: const TextStyle(fontFamily: monoFamily, fontSize: 13),
            ),
          ),
        ),
        Positioned(
          top: 4,
          right: 4,
          child: Material(
            color: Theme.of(
              context,
            ).colorScheme.surface.withValues(alpha: 0.85),
            shape: const CircleBorder(),
            child: IconButton(
              icon: const Icon(Icons.copy, size: 18),
              tooltip: 'Copy $label to clipboard',
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: text));
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Copied $label to clipboard'),
                    duration: const Duration(seconds: 1),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}
