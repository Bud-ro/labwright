import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:labwright_teststand/labwright_teststand.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'src/binary_view.dart';
import 'src/document_view.dart';
import 'src/property_outline.dart';
import 'src/properties_view.dart';
import 'src/recent_files.dart';
import 'src/sequence_outline.dart';
import 'src/sequences_view.dart';
import 'src/ui.dart';

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
  List<String> _recent = const [];
  // Owned here so Ctrl/Cmd+F can focus the active tab's search field; passed
  // down into the respective view's TextField.
  final _sequencesSearchFocus = FocusNode();
  final _propertiesSearchFocus = FocusNode();

  static const _recentPrefsKey = 'recentFiles';
  SharedPreferences? _prefs;

  @override
  void initState() {
    super.initState();
    _loadRecent();
    if (widget.initialPath != null) _loadPath(widget.initialPath!);
  }

  Future<void> _loadRecent() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList(_recentPrefsKey) ?? const [];
    // Drop entries whose file no longer exists — don't list dead paths.
    final alive = saved.where((p) => File(p).existsSync()).toList();
    if (!mounted) return;
    setState(() {
      _prefs = prefs;
      // Merge: keep anything already added during async load, then saved.
      for (final p in alive.reversed) {
        if (!_recent.contains(p)) _recent = addRecent(_recent, p);
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
    super.dispose();
  }

  /// Focuses the search field of the tab at [tabIndex] (Dump has none → no-op).
  /// Indices match the TabBar order: 0 Dump, 1 Sequences, 2 Properties.
  void _focusSearch(int tabIndex) {
    if (tabIndex == 1) _sequencesSearchFocus.requestFocus();
    if (tabIndex == 2) _propertiesSearchFocus.requestFocus();
  }

  void _loadBytes(String path, Uint8List bytes, {bool remember = true}) {
    setState(() {
      _path = path;
      _error = null;
      try {
        _doc = SeqDocument.parse(bytes);
      } catch (e) {
        _doc = null;
        _error = '$e';
      }
      // Remember real filesystem paths so the entry is re-openable.
      if (remember && File(path).existsSync()) {
        _recent = addRecent(_recent, path);
        _saveRecent();
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
    final bytes =
        f.bytes ?? (f.path != null ? File(f.path!).readAsBytesSync() : null);
    if (bytes != null) _loadBytes(f.path ?? f.name, bytes);
  }

  @override
  Widget build(BuildContext context) {
    final doc = _doc;
    // The Sequences/Properties tabs only apply to XML files we parsed into a
    // SeqFile.
    final file = doc is StructuredSeqDocument ? doc.file : null;
    final outline = file != null ? SeqOutline.of(file) : null;
    final tree = file != null ? propertyTree(file) : null;
    final coverage = file != null ? coverageLabel(measureCoverage(file)) : null;
    final typeCount = file?.types.length;
    return DefaultTabController(
      length: file != null ? 3 : 1,
      // Builder so the shortcut can read the active tab via DefaultTabController.
      child: Builder(
        builder: (context) {
          return CallbackShortcuts(
            bindings: {
              // Ctrl+O / Cmd+O → open a file.
              const SingleActivator(LogicalKeyboardKey.keyO, control: true):
                  _pick,
              const SingleActivator(LogicalKeyboardKey.keyO, meta: true): _pick,
              // Ctrl+F / Cmd+F → focus the active tab's search field.
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
                  child: _body(doc, outline, tree, coverage, typeCount),
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

  Widget _body(
    SeqDocument? doc,
    SeqOutline? outline,
    PropertyNode? tree,
    String? coverage,
    int? typeCount,
  ) {
    if (_error != null) {
      return Center(
        child: Text(
          'Error: $_error',
          style: const TextStyle(color: Colors.red),
        ),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_path != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 2),
            child: Text(_path!, style: Theme.of(context).textTheme.bodySmall),
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
                BinaryView(doc: doc)
              else
                _dumpTab(doc),
              if (outline != null)
                SequencesView(
                  outline: outline,
                  searchFocusNode: _sequencesSearchFocus,
                  typeCount: typeCount,
                ),
              if (tree != null)
                PropertiesView(
                  root: tree,
                  searchFocusNode: _propertiesSearchFocus,
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// The Dump tab: the scrollable monospace text plus a copy-to-clipboard button.
  Widget _dumpTab(SeqDocument doc) {
    final text = documentText(doc);
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
              tooltip: 'Copy dump to clipboard',
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: text));
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Copied dump to clipboard'),
                    duration: Duration(seconds: 1),
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
