import 'dart:io';
import 'dart:typed_data';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:labwright_videcode/labwright_videcode.dart';
import 'package:labwright_viparse/labwright_viparse.dart';

import 'diagram_view.dart';
import 'hex_view.dart';
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
    this.initialModel,
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

  /// Optional decoded model (for the Diagram tab) to show on first build (tests).
  final ViModel? initialModel;

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
  ViModel? _model;
  List<DecodedSection> _sections = const [];

  @override
  void initState() {
    super.initState();
    _summary = widget.initial;
    _source = widget.initialSource ?? '';
    _version = widget.initialVersion;
    _strings = widget.initialStrings ?? const [];
    _components = widget.initialComponents ?? const [];
    _model = widget.initialModel;
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
    ViModel? model;
    var sections = const <DecodedSection>[];
    if (load.isOk) {
      // Decode the heaps ONCE and derive everything from that single inflate
      // pass (previously version/strings/components/model/sections each re-ran
      // decodeSections → ~4 redundant zlib inflations of the heaviest heaps).
      // Wrapped so a container that parses for the summary but throws on a
      // section keeps the UI total.
      try {
        sections = decodeSections(bytes);
        model = buildViModelFromDecoded(sections);
        strings = heapStringsFromDecoded(sections);
        components = model.components;
        version = decodeVersion(bytes); // cheap: reads descriptors, no heap inflation
      } catch (_) {
        sections = const [];
        model = null;
      }
    }
    setState(() {
      _summary = load.summary;
      _error = load.error;
      _source = source;
      _version = version;
      _strings = strings;
      _components = components;
      _model = model;
      _sections = sections;
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
    if (!mounted) return; // the dialog await may outlive this State
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
                          : DefaultTabController(
                              length: 3,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  const TabBar(
                                    tabs: [Tab(text: 'Inspect'), Tab(text: 'Front Panel'), Tab(text: 'Block Diagram')],
                                  ),
                                  const SizedBox(height: 8),
                                  Expanded(
                                    child: TabBarView(
                                      children: [
                                        _SummaryView(
                                          summary: _summary!,
                                          source: _source,
                                          version: _version,
                                          strings: _strings,
                                          components: _components,
                                          sections: _sections,
                                        ),
                                        // Each layout view is keyed by model identity so loading a
                                        // new VI builds fresh state (resets selection + re-fits).
                                        // Front panel ← FPHb/FPHP, block diagram ← BDHb/BDHP.
                                        ViDiagramView(
                                          key: ValueKey('fp:$_model'),
                                          diagrams: _model?.frontPanelDiagrams,
                                          emptyHint: 'No front-panel objects recovered in this file.',
                                        ),
                                        ViDiagramView(
                                          key: ValueKey('bd:$_model'),
                                          diagrams: _model?.blockDiagrams,
                                          emptyHint: 'No block-diagram objects recovered in this file.',
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
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
    required this.sections,
  });
  final ViSummary summary;
  final String source;
  final ViVersionInfo? version;
  final List<String> strings;
  final List<BlockComponent> components;
  final List<DecodedSection> sections;

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
        // NOTE: the embedded 20x20 RGB picture is NOT shown here as a per-VI
        // identity icon — on the corpus it is a generic LabVIEW glyph
        // (checkmark/X) shared across files, so presenting it next to the name
        // would imply identity it doesn't carry. It remains viewable, in context,
        // as a typed display in the hex viewer for the block that holds it.
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
        const SizedBox(height: 4),
        Text(
          widget.sections.isEmpty
              ? 'No section bytes recovered for this file.'
              : 'Click a highlighted block to inspect its bytes + parsed records (hex view).',
          style: const TextStyle(color: Colors.grey, fontSize: 12),
        ),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final b in summary.blocks)
            if (_hasSection(b))
              Tooltip(
                message: kBlockGlossary[b] ?? 'resource block',
                child: ActionChip(
                  label: Text(b),
                  avatar: const Icon(Icons.data_object, size: 16),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _openHex(context, b),
                ),
              )
            else
              Tooltip(
                // Honest: these blocks are listed in the file's block table but
                // readViSections can't yet locate their section bytes (their
                // descriptor uses a layout the sentinel heuristic misses), so
                // there is nothing to show in the hex view.
                message: '${kBlockGlossary[b] ?? 'resource block'}\n(bytes not recoverable yet — descriptor layout not decoded)',
                child: Opacity(
                  opacity: 0.4,
                  child: Chip(
                    label: Text(b),
                    avatar: const Icon(Icons.block, size: 14),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
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
                  'Shows the RSRC container, decoded version/title, embedded strings, and — '
                  'in the Diagram tab — the recovered block-diagram object layout (each '
                  'object at its absolute position, colored by kind, with its label and data '
                  'type). Decoded clean-room from the heap; honest by construction — signal '
                  'wires are not drawn (no recoverable endpoints), and function-vs-subVI is '
                  'not distinguishable from the block diagram alone.',
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  bool _hasSection(String tag) => widget.sections.any((s) => s.tag == tag);

  void _openHex(BuildContext context, String tag) {
    final matches = [for (final s in widget.sections) if (s.tag == tag) s]
      ..sort((a, b) => b.length.compareTo(a.length));
    if (matches.isEmpty) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.all(24),
        child: SizedBox(width: 1120, height: 740, child: _HexDialog(tag: tag, sections: matches)),
      ),
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

class _HexDialog extends StatefulWidget {
  const _HexDialog({required this.tag, required this.sections});
  final String tag;
  final List<DecodedSection> sections;

  @override
  State<_HexDialog> createState() => _HexDialogState();
}

class _HexDialogState extends State<_HexDialog> {
  int _idx = 0;

  @override
  Widget build(BuildContext context) {
    final section = widget.sections[_idx];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
          child: Row(
            children: [
              Icon(Icons.data_object, size: 18, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 8),
              Text('${widget.tag} — byte inspector', style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(width: 16),
              if (widget.sections.length > 1)
                DropdownButton<int>(
                  value: _idx,
                  isDense: true,
                  onChanged: (v) => setState(() => _idx = v ?? 0),
                  items: [
                    for (var i = 0; i < widget.sections.length; i++)
                      DropdownMenuItem(value: i, child: Text('section ${widget.sections[i].index} (${widget.sections[i].length} B)')),
                  ],
                ),
              const Spacer(),
              IconButton(onPressed: () => Navigator.of(context).pop(), icon: const Icon(Icons.close)),
            ],
          ),
        ),
        const Divider(height: 1),
        // Key per section so switching the dropdown rebuilds a fresh state — the
        // parse (records/byte-map/preview) is recomputed for the selected section
        // instead of crashing on the previous section's byte-map.
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: BlockHexView(key: ValueKey('${section.tag}:${section.index}'), section: section),
          ),
        ),
      ],
    );
  }
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
