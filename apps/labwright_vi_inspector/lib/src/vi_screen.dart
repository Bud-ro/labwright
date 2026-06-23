import 'dart:io';
import 'dart:typed_data';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:labwright_videcode/labwright_videcode.dart';
import 'package:labwright_viparse/labwright_viparse.dart';

import 'vi_demo.dart';

/// Imports a LabVIEW `.vi`/`.ctl` file and shows what it is and does — type,
/// version, capability flags, and the resource-block inventory — via the
/// clean-room `labwright_viparse` reader. A read-only viewer (block-diagram
/// logic decode, and therefore editing, is future work).
class ViInspectorScreen extends StatefulWidget {
  const ViInspectorScreen({
    super.key,
    this.initial,
    this.initialSource,
    this.initialVersion,
    this.initialStrings,
    this.initialComponents,
  });

  /// Optional summary to show on first build (used by tests).
  final ViSummary? initial;

  /// Label describing where [initial] came from.
  final String? initialSource;

  /// Optional decoded version/title to show on first build (tests).
  final ViVersionInfo? initialVersion;

  /// Optional embedded strings to show on first build (tests).
  final List<String>? initialStrings;

  /// Optional per-block components to show on first build (tests).
  final List<BlockComponent>? initialComponents;

  @override
  State<ViInspectorScreen> createState() => _ViInspectorScreenState();
}

class _ViInspectorScreenState extends State<ViInspectorScreen> {
  final _pathCtrl = TextEditingController();
  ViSummary? _summary;
  String? _error;
  String _source = '';
  bool _dragging = false;
  ViVersionInfo? _version;
  List<String> _strings = const [];
  List<BlockComponent> _components = const [];

  @override
  void initState() {
    super.initState();
    _summary = widget.initial;
    _source = widget.initialSource ?? '';
    _version = widget.initialVersion;
    _strings = widget.initialStrings ?? const [];
    _components = widget.initialComponents ?? const [];
  }

  @override
  void dispose() {
    _pathCtrl.dispose();
    super.dispose();
  }

  /// Parse + decode a VI from its bytes, then show it. Decoding is total, so the
  /// UI never crashes on a file from the wild.
  void _loadBytes(Uint8List bytes, String source) {
    final load = summarize(bytes);
    ViVersionInfo? version;
    var strings = const <String>[];
    var components = const <BlockComponent>[];
    if (load.isOk) {
      version = decodeVersion(bytes);
      strings = extractHeapStrings(bytes);
      components = blockComponents(bytes);
    }
    setState(() {
      _summary = load.summary;
      _error = load.error;
      _source = source;
      _version = version;
      _strings = strings;
      _components = components;
    });
  }

  void _openPath() => _loadPath(_pathCtrl.text.trim());

  /// Reads and inspects the file at [path] (shared by the text field, the
  /// Browse dialog, and drag-and-drop). Surfaces missing/unreadable files as a
  /// clean error rather than throwing.
  void _loadPath(String path) {
    if (path.isEmpty) return;
    _pathCtrl.text = path;
    final file = File(path);
    if (!file.existsSync()) {
      setState(() {
        _summary = null;
        _error = 'No such file: $path';
        _source = path;
      });
      return;
    }
    final Uint8List bytes;
    try {
      bytes = file.readAsBytesSync();
    } on FileSystemException catch (e) {
      setState(() {
        _summary = null;
        _error = 'Could not read $path: ${e.message}';
        _source = path;
      });
      return;
    }
    _loadBytes(bytes, path);
  }

  /// Opens the OS file-open dialog and inspects the chosen file.
  Future<void> _browse() async {
    final result = await FilePicker.pickFiles(
      dialogTitle: 'Open a LabVIEW VI',
      type: FileType.custom,
      allowedExtensions: const ['vi', 'ctl', 'llb'],
    );
    final files = result?.files ?? const [];
    if (files.isNotEmpty && files.first.path != null) _loadPath(files.first.path!);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Labwright · VI Inspector')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('path'),
                    controller: _pathCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Path to a .vi / .ctl file',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onSubmitted: (_) => _openPath(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  key: const Key('browse'),
                  onPressed: _browse,
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Browse…'),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  key: const Key('open'),
                  onPressed: _openPath,
                  icon: const Icon(Icons.subdirectory_arrow_right),
                  label: const Text('Open path'),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  key: const Key('demo'),
                  onPressed: () => _loadBytes(demoViBytes(), 'demo VI (synthetic)'),
                  icon: const Icon(Icons.science_outlined),
                  label: const Text('Load demo VI'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Expanded(
              child: DropTarget(
                onDragEntered: (_) => setState(() => _dragging = true),
                onDragExited: (_) => setState(() => _dragging = false),
                onDragDone: (detail) {
                  setState(() => _dragging = false);
                  if (detail.files.isNotEmpty) _loadPath(detail.files.first.path);
                },
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: _dragging ? Theme.of(context).colorScheme.primary : const Color(0x22FFFFFF),
                      width: _dragging ? 2 : 1,
                      style: _dragging ? BorderStyle.solid : BorderStyle.none,
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding: const EdgeInsets.all(8),
                  child: _error != null
                      ? _ErrorCard(_error!)
                      : _summary == null
                          ? _Empty(dragging: _dragging)
                          : _SummaryView(
                              summary: _summary!,
                              source: _source,
                              version: _version,
                              strings: _strings,
                              components: _components,
                            ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.dragging});
  final bool dragging;

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(dragging ? Icons.file_download : Icons.upload_file,
                size: 48, color: dragging ? Theme.of(context).colorScheme.primary : Colors.grey),
            const SizedBox(height: 12),
            Text(
              dragging ? 'Drop the .vi to inspect it' : 'Drag a .vi here, or use Browse… / Load demo VI',
              style: const TextStyle(color: Colors.grey),
            ),
          ],
        ),
      );
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard(this.message);
  final String message;

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.topCenter,
        child: Card(
          color: Colors.red.shade900,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(message, style: const TextStyle(color: Colors.white)),
          ),
        ),
      );
}

class _SummaryView extends StatefulWidget {
  const _SummaryView({
    required this.summary,
    required this.source,
    required this.version,
    required this.strings,
    required this.components,
  });
  final ViSummary summary;
  final String source;
  final ViVersionInfo? version;
  final List<String> strings;
  final List<BlockComponent> components;

  @override
  State<_SummaryView> createState() => _SummaryViewState();
}

class _SummaryViewState extends State<_SummaryView> {
  final _filterCtrl = TextEditingController();
  String _filter = '';

  @override
  void dispose() {
    _filterCtrl.dispose();
    super.dispose();
  }

  String get _kind => switch (widget.summary.fileType) {
        'LVIN' => 'VI',
        'LVCC' => 'Control / typedef',
        _ => widget.summary.fileType,
      };

  @override
  Widget build(BuildContext context) {
    final summary = widget.summary;
    final version = widget.version;
    final hasDecoded = version != null && (version.version != null || version.title != null);
    final q = _filter.trim().toLowerCase();
    final filtered = q.isEmpty
        ? widget.strings
        : [for (final s in widget.strings) if (s.toLowerCase().contains(q)) s];

    return ListView(
      children: [
        Text(summary.name ?? '(unnamed)', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 4),
        Text(summary.describe(), style: const TextStyle(color: Colors.grey)),
        const SizedBox(height: 4),
        Text('source: ${widget.source}', style: const TextStyle(color: Colors.grey, fontSize: 12)),
        const SizedBox(height: 16),

        _Section('Identity', [
          _kv('Kind', _kind),
          _kv('File type', summary.fileType),
          _kv('Creator', summary.creator),
          _kv('Format version', '${summary.formatVersion}'),
          _kv('Resource blocks', '${summary.blocks.length}'),
        ]),
        const SizedBox(height: 16),

        if (hasDecoded) ...[
          _Section('Decoded', [
            if (version.version != null) _kv('LabVIEW version', version.version!),
            if (version.title != null) _kv('Title', version.title!),
          ]),
          const SizedBox(height: 16),
        ],

        const Text('Capabilities', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          _cap('Front panel', summary.hasFrontPanel),
          _cap('Block diagram (logic)', summary.hasBlockDiagram),
          _cap('Connector pane', summary.hasConnectorPane),
          _cap('Sub-VI links', summary.hasSubViLinks),
        ]),
        const SizedBox(height: 16),

        const Text('Resource-block inventory', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final b in summary.blocks)
            Tooltip(
              message: kBlockGlossary[b] ?? 'resource block',
              child: Chip(label: Text(b), visualDensity: VisualDensity.compact),
            ),
        ]),

        if (widget.components.isNotEmpty) ...[
          const SizedBox(height: 16),
          const Text('Components (by decompressed size)', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          for (final c in widget.components.take(20))
            _kv(
              c.sectionCount > 1 ? '${c.tag} ×${c.sectionCount}' : c.tag,
              c.compressed
                  ? '${_fmtSize(c.decompressedBytes)}  (zlib ${_fmtSize(c.rawBytes)})'
                  : _fmtSize(c.decompressedBytes),
            ),
        ],

        if (widget.strings.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('Embedded strings (${widget.strings.length})', style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          const Text(
            'Labels, help text and value lists found in the heaps (best-effort).',
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('string-search'),
            controller: _filterCtrl,
            onChanged: (v) => setState(() => _filter = v),
            decoration: const InputDecoration(
              labelText: 'Filter strings',
              prefixIcon: Icon(Icons.search),
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          for (final s in filtered.take(1000))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 1),
              child: Text(s, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
            ),
          if (filtered.length > 1000) Text('… and ${filtered.length - 1000} more'),
          if (filtered.isEmpty) const Text('(no match)', style: TextStyle(color: Colors.grey)),
        ],

        const SizedBox(height: 20),
        Card(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: const Padding(
            padding: EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Read-only viewer', style: TextStyle(fontWeight: FontWeight.bold)),
                SizedBox(height: 6),
                Text(
                  'Shows the RSRC container, decoded version/title, and the human-readable '
                  'strings embedded in the heaps. Recovering the full block-diagram graph '
                  '(the BDEx/BDHb heap is LabVIEW opcode-serialized) — the step needed to '
                  'view or auto-translate the actual logic — is the in-progress next stage.',
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  static Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 140, child: Text(k, style: const TextStyle(color: Colors.grey))),
            Expanded(child: Text(v)),
          ],
        ),
      );

  static String _fmtSize(int n) => n >= 1024 ? '${(n / 1024).toStringAsFixed(1)} KB' : '$n B';

  static Widget _cap(String label, bool on) => Chip(
        avatar: Icon(on ? Icons.check_circle : Icons.remove_circle_outline,
            color: on ? Colors.green : Colors.grey, size: 18),
        label: Text(label),
        backgroundColor: on ? Colors.green.withValues(alpha: 0.12) : null,
      );
}

class _Section extends StatelessWidget {
  const _Section(this.title, this.rows);
  final String title;
  final List<Widget> rows;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          ...rows,
        ],
      );
}
