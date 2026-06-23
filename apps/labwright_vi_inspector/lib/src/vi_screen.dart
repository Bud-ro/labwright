import 'dart:io';
import 'dart:typed_data';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:labwright_viparse/labwright_viparse.dart';

import 'vi_demo.dart';

/// Imports a LabVIEW `.vi`/`.ctl` file and shows what it is and does — type,
/// version, capability flags, and the resource-block inventory — via the
/// clean-room `labwright_viparse` reader. A read-only viewer (block-diagram
/// logic decode, and therefore editing, is future work).
class ViInspectorScreen extends StatefulWidget {
  const ViInspectorScreen({super.key, this.initial, this.initialSource});

  /// Optional summary to show on first build (used by tests).
  final ViSummary? initial;

  /// Label describing where [initial] came from.
  final String? initialSource;

  @override
  State<ViInspectorScreen> createState() => _ViInspectorScreenState();
}

class _ViInspectorScreenState extends State<ViInspectorScreen> {
  final _pathCtrl = TextEditingController();
  ViSummary? _summary;
  String? _error;
  String _source = '';
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    _summary = widget.initial;
    _source = widget.initialSource ?? '';
  }

  @override
  void dispose() {
    _pathCtrl.dispose();
    super.dispose();
  }

  void _show(ViLoad load, String source) {
    setState(() {
      _summary = load.summary;
      _error = load.error;
      _source = source;
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
    _show(summarize(bytes), path);
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
                  onPressed: () => _show(summarize(demoViBytes()), 'demo VI (synthetic)'),
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
                          : _SummaryView(summary: _summary!, source: _source),
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

class _SummaryView extends StatelessWidget {
  const _SummaryView({required this.summary, required this.source});
  final ViSummary summary;
  final String source;

  String get _kind => switch (summary.fileType) {
        'LVIN' => 'VI',
        'LVCC' => 'Control / typedef',
        _ => summary.fileType,
      };

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        Text(summary.name ?? '(unnamed)', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 4),
        Text(summary.describe(), style: const TextStyle(color: Colors.grey)),
        const SizedBox(height: 4),
        Text('source: $source', style: const TextStyle(color: Colors.grey, fontSize: 12)),
        const SizedBox(height: 16),

        _Section('Identity', [
          _kv('Kind', _kind),
          _kv('File type', summary.fileType),
          _kv('Creator', summary.creator),
          _kv('Format version', '${summary.formatVersion}'),
          _kv('Resource blocks', '${summary.blocks.length}'),
        ]),
        const SizedBox(height: 16),

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
                  'This inspects the RSRC container — what the VI is and does. Recovering '
                  'the block-diagram logic from the BDHb heap (the step needed to view or '
                  'migrate the actual graph, and the prerequisite for any editing) is '
                  'deferred until a corpus of real, non-trivial VI samples is available.',
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
