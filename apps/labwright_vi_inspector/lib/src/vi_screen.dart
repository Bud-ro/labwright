import 'dart:io';
import 'dart:typed_data';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import 'coverage_view.dart';
import 'diagram_view.dart';
import 'hex_view.dart';
import 'images_view.dart';
import 'representative_vis.dart';
import 'subvi_icon_resolver.dart';
import 'types_view.dart';
import 'vi_demo.dart';

/// Imports a LabVIEW `.vi`/`.ctl` file and shows what it is and does — type,
/// version, capability flags, and the resource-block inventory — via the
/// clean-room `labwright_rsrc_parse` reader. A read-only viewer (block-diagram
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
    this.initialLibraryNames,
    this.initialEmbeddedVis,
    this.initialAttribution,
    this.initialImages,
    this.fetchBytes = fetchViBytes,
  });

  /// Fetches one URL's bytes during a representative-VI fetch (the main file
  /// and each dependency-closure file). Defaults to [fetchViBytes] (a real
  /// HTTPS GET); overridable in tests to avoid network I/O.
  final Future<Uint8List> Function(Uri) fetchBytes;

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

  /// Optional owning-library names (from LIBN) to show on first build (tests).
  final List<String>? initialLibraryNames;

  /// Optional embedded sub-VIs (from VINS) to show on first build (tests).
  final List<ViEmbeddedVi>? initialEmbeddedVis;

  /// Optional writer byte-attribution to show on first build (tests).
  final WriterAttribution? initialAttribution;

  /// Optional embedded images to show on first build (tests).
  final ViImages? initialImages;

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
  List<String> _libraryNames = const [];
  List<ViEmbeddedVi> _embeddedVis = const [];
  WriterAttribution? _attribution;
  ViImages _images = const ViImages();

  /// The representative VI currently being fetched from GitHub, or null. Drives
  /// the Examples menu's busy state.
  String? _fetchingRep;

  /// The temp project directory of the last representative-VI fetch (the main
  /// file + its dependency closure), deleted when the next fetch replaces it.
  Directory? _repProjectDir;

  /// Resolves a subVI-call node's target `.vi` to its bytes so the block diagram
  /// can stamp the node with the called VI's icon. Set only when a file was
  /// opened from disk (drag/browse/path) — demo and embedded VIs have no project
  /// directory to search, so their nodes keep the neutral plate.
  Future<Uint8List? Function(String fileName)>? _subViIconLoader;

  @override
  void initState() {
    super.initState();
    _summary = widget.initial;
    _source = widget.initialSource ?? '';
    _version = widget.initialVersion;
    _strings = widget.initialStrings ?? const [];
    _components = widget.initialComponents ?? const [];
    _model = widget.initialModel;
    _libraryNames = widget.initialLibraryNames ?? const [];
    _embeddedVis = widget.initialEmbeddedVis ?? const [];
    _attribution = widget.initialAttribution;
    _images = widget.initialImages ?? const ViImages();
  }

  @override
  void dispose() {
    _pathCtrl.dispose();
    super.dispose();
  }

  /// Parse + decode a VI from its bytes, then show it. Decoding is total, so the
  /// UI never crashes on a file from the wild.
  void _loadBytes(
    Uint8List bytes,
    String source, {
    Future<Uint8List? Function(String fileName)>? subViIconLoader,
  }) {
    final load = summarize(bytes);
    ViVersionInfo? version;
    var strings = const <String>[];
    var components = const <BlockComponent>[];
    ViModel? model;
    var sections = const <DecodedSection>[];
    var libraryNames = const <String>[];
    var embeddedVis = const <ViEmbeddedVi>[];
    WriterAttribution? attribution;
    var images = const ViImages();
    if (load.isOk) {
      try {
        sections = decodeSections(bytes);
        model = buildViModelFromDecoded(
          sections,
          subViNames: readSubViNames(bytes),
        );
        strings = heapStringsFromDecoded(sections);
        components = model.components;
        version = decodeVersion(bytes);
        libraryNames = readOwningLibraryNames(bytes);
        embeddedVis = readEmbeddedVis(bytes);
      } catch (_) {
        sections = const [];
        model = null;
      }
      // Byte attribution is independent of heap decode; compute it separately so
      // a heap-decode failure still leaves the writer-fidelity view populated.
      try {
        attribution = attributeVi(bytes);
      } catch (_) {
        attribution = null;
      }
      // Image extraction is isolated so a malformed VI still loads other tabs.
      try {
        images = extractViImages(sections);
      } catch (_) {
        images = const ViImages();
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
      _libraryNames = libraryNames;
      _embeddedVis = embeddedVis;
      _attribution = attribution;
      _images = images;
      _subViIconLoader = subViIconLoader;
    });
  }

  /// The decompressed `VCTP` section body, or null when the VI carries none —
  /// feeds the Types tab's bytes↔types correlation view.
  Uint8List? _vctpBytes() {
    for (final section in _sections) {
      if (section.tag == 'VCTP') return section.bytes;
    }
    return null;
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
    // The project index is built off the UI isolate, so a large or slow project
    // tree never blocks the load; the on-node subVI icons appear once it
    // resolves. The future is passed straight through to the diagram view.
    _loadBytes(bytes, path, subViIconLoader: buildProjectViLoader(path));
  }

  /// Fetches a curated representative VI — the main file plus its in-repo subVI
  /// dependency closure, written to a fresh temp project directory — and
  /// inspects it, with subVI icons resolved from that directory exactly as for
  /// a locally-opened file. Network failure of the main file surfaces as a
  /// clean error; an individual dependency failure only costs that subVI's
  /// icon. The previous fetch's temp directory is deleted first.
  Future<void> _openRepresentative(RepresentativeVi vi) async {
    if (_fetchingRep != null) return;
    setState(() => _fetchingRep = vi.name);
    final previous = _repProjectDir;
    try {
      final fetched = await fetchRepresentativeVi(vi, fetch: widget.fetchBytes);
      if (!mounted) return;
      _repProjectDir = fetched.projectDir;
      final deps = vi.dependencies.isEmpty
          ? ''
          : ' (+${fetched.fetchedDeps} subVIs'
                '${fetched.failedDeps > 0 ? ', ${fetched.failedDeps} failed' : ''})';
      // Clamp the icon walk's root to the temp project directory: the main
      // file sits vi.path-segments deep inside it, so walking up one fewer
      // level than that lands exactly on the project dir (never the system
      // temp directory above it).
      _loadBytes(
        fetched.bytes,
        'GitHub: ${vi.repo} · ${vi.name}$deps',
        subViIconLoader: buildProjectViLoader(
          fetched.mainPath,
          levelsUp: vi.path.split('/').length - 1,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _summary = null;
        _error = 'Could not fetch ${vi.name}: $e';
        _source = vi.rawUrl.toString();
      });
    } finally {
      if (mounted) setState(() => _fetchingRep = null);
      try {
        previous?.deleteSync(recursive: true);
      } catch (_) {
        // Best-effort cleanup of the prior fetch's temp files.
      }
    }
  }

  /// Opens the OS file-open dialog and inspects the chosen file.
  Future<void> _browse() async {
    final result = await FilePicker.pickFiles(
      dialogTitle: 'Open a LabVIEW VI',
      type: FileType.custom,
      allowedExtensions: const ['vi', 'ctl', 'llb'],
    );
    if (!mounted) return;
    final files = result?.files ?? const [];
    if (files.isNotEmpty && files.first.path != null)
      _loadPath(files.first.path!);
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
            // A Wrap (not a Row) so the toolbar flows to a second line instead
            // of overflowing when the window is narrower than the buttons.
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(
                    minWidth: 260,
                    maxWidth: 460,
                  ),
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
                FilledButton.icon(
                  key: const Key('browse'),
                  onPressed: _browse,
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Browse…'),
                ),
                OutlinedButton.icon(
                  key: const Key('open'),
                  onPressed: _openPath,
                  icon: const Icon(Icons.subdirectory_arrow_right),
                  label: const Text('Open path'),
                ),
                OutlinedButton.icon(
                  key: const Key('demo'),
                  onPressed: () =>
                      _loadBytes(demoViBytes(), 'demo VI (synthetic)'),
                  icon: const Icon(Icons.science_outlined),
                  label: const Text('Load demo VI'),
                ),
                // Curated interesting VIs, fetched from GitHub on demand — in
                // the toolbar so they stay reachable after a VI is loaded.
                MenuAnchor(
                  menuChildren: [
                    for (final vi in kRepresentativeVis)
                      MenuItemButton(
                        onPressed: _fetchingRep == null
                            ? () => _openRepresentative(vi)
                            : null,
                        leadingIcon: _fetchingRep == vi.name
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(
                                Icons.cloud_download_outlined,
                                size: 16,
                              ),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 460),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(vi.name),
                              Text(
                                vi.feature +
                                    (vi.missingNote == null
                                        ? ''
                                        : ' · ${vi.missingNote}'),
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Colors.grey,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                  builder: (context, controller, _) => OutlinedButton.icon(
                    key: const Key('examples'),
                    onPressed: () => controller.isOpen
                        ? controller.close()
                        : controller.open(),
                    icon: _fetchingRep != null
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.auto_awesome_outlined),
                    label: const Text('Examples'),
                  ),
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
                  if (detail.files.isNotEmpty)
                    _loadPath(detail.files.first.path);
                },
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: _dragging
                          ? Theme.of(context).colorScheme.primary
                          : const Color(0x22FFFFFF),
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
                          length: 6,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const TabBar(
                                isScrollable: true,
                                tabs: [
                                  Tab(text: 'Inspect'),
                                  Tab(text: 'Front Panel'),
                                  Tab(text: 'Block Diagram'),
                                  Tab(text: 'Types'),
                                  Tab(text: 'Images'),
                                  Tab(text: 'Coverage'),
                                ],
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
                                      model: _model,
                                      libraryNames: _libraryNames,
                                      embeddedVis: _embeddedVis,
                                      onOpenEmbedded: (vi) {
                                        final bytes = vi.bytes;
                                        if (bytes == null) return;
                                        _loadBytes(
                                          bytes,
                                          'embedded: ${vi.name ?? 'sub-VI'}',
                                        );
                                      },
                                    ),
                                    ViDiagramView(
                                      key: ValueKey('fp:$_model'),
                                      diagrams: _model?.frontPanelDiagrams,
                                      emptyHint:
                                          'No front-panel objects recovered in this file.',
                                      isFrontPanel: true,
                                    ),
                                    // Block Diagram, headed by the honest
                                    // recovery-summary strip (previously
                                    // the Review tab's header).
                                    Column(
                                      children: [
                                        if (_model != null) ...[
                                          _RecoverySummary(_model!),
                                          const Divider(height: 1),
                                        ],
                                        Expanded(
                                          child: ViDiagramView(
                                            key: ValueKey('bd:$_model'),
                                            diagrams: _model?.blockDiagrams,
                                            emptyHint:
                                                'No block-diagram objects recovered in this file.',
                                            subViNames:
                                                _model?.subViNames ?? const [],
                                            viImages: _images,
                                            subViIconLoader: _subViIconLoader,
                                          ),
                                        ),
                                      ],
                                    ),
                                    ViTypesView(
                                      key: ValueKey('types:$_model'),
                                      model: _model,
                                      vctpBytes: _vctpBytes(),
                                    ),
                                    ViImagesView(
                                      key: ValueKey('img:${_images.count}'),
                                      images: _images,
                                    ),
                                    ViCoverageView(
                                      key: ValueKey(
                                        'cov:${_attribution?.fileLength}',
                                      ),
                                      attribution: _attribution,
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
        Icon(
          dragging ? Icons.file_download : Icons.upload_file,
          size: 48,
          color: dragging ? Theme.of(context).colorScheme.primary : Colors.grey,
        ),
        const SizedBox(height: 12),
        Text(
          dragging
              ? 'Drop the .vi to inspect it'
              : 'Drag a .vi here, or use Browse… / Load demo VI / Examples',
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
    this.model,
    this.libraryNames = const [],
    this.embeddedVis = const [],
    this.onOpenEmbedded,
  });
  final ViSummary summary;
  final String source;
  final ViVersionInfo? version;
  final List<String> strings;
  final List<BlockComponent> components;
  final List<DecodedSection> sections;

  /// The decoded model, used to surface recovered subVI deps + data-type summary.
  final ViModel? model;

  /// Owning-library names (from LIBN sections), e.g. `MQTT Server.lvlib`.
  final List<String> libraryNames;

  /// Embedded sub-VIs (from VINS sections) — each a complete nested VI.
  final List<ViEmbeddedVi> embeddedVis;

  /// Invoked when the user taps an embedded sub-VI to open it in the inspector.
  final void Function(ViEmbeddedVi)? onOpenEmbedded;

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
    final hasDecoded =
        version != null && (version.version != null || version.title != null);
    final needle = _filter.trim().toLowerCase();
    final filtered = needle.isEmpty
        ? widget.strings
        : [
            for (final text in widget.strings)
              if (text.toLowerCase().contains(needle)) text,
          ];

    return ListView(
      children: [
        Text(
          summary.name ?? '(unnamed)',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 4),
        Text(summary.describe(), style: const TextStyle(color: Colors.grey)),
        const SizedBox(height: 4),
        Text(
          'source: ${widget.source}',
          style: const TextStyle(color: Colors.grey, fontSize: 12),
        ),
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
            if (version.version != null)
              _kv('LabVIEW version', version.version!),
            if (version.title != null) _kv('Title', version.title!),
          ]),
          const SizedBox(height: 16),
        ],

        if (widget.model?.subViNames.isNotEmpty ?? false) ...[
          Text(
            'SubVIs called (${widget.model!.subViNames.length})',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Text(
            widget.model!.subViNames.take(40).join(', ') +
                (widget.model!.subViNames.length > 40
                    ? ', … (+${widget.model!.subViNames.length - 40} more)'
                    : ''),
            style: const TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 16),
        ],

        if (widget.model != null && widget.model!.types.isNotEmpty) ...[
          Builder(
            builder: (context) {
              final viModel = widget.model!;
              final hist = typeKindHistogram(viModel.types);
              final named = namedTypes(viModel.types).length;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Data types (${viModel.types.length}${named > 0 ? ', $named named' : ''})',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    hist.entries.map((e) => '${e.key}:${e.value}').join('  '),
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 16),
        ],

        if (widget.libraryNames.isNotEmpty) ...[
          const Text(
            'Owning library',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Text(
            widget.libraryNames.join(', '),
            style: const TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 16),
        ],

        if (widget.embeddedVis.isNotEmpty) ...[
          Text(
            'Embedded VIs (${widget.embeddedVis.length})',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          const Text(
            'Tap to open a nested VI.',
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
          const SizedBox(height: 4),
          for (final vi in widget.embeddedVis.take(60))
            Builder(
              builder: (context) {
                final clean =
                    vi.name != null && vi.name!.toLowerCase().endsWith('.vi');
                final label = clean ? vi.name! : '(name not recovered)';
                final openable =
                    vi.bytes != null && widget.onOpenEmbedded != null;
                return InkWell(
                  onTap: openable ? () => widget.onOpenEmbedded!(vi) : null,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Icon(
                          openable
                              ? Icons.open_in_new
                              : Icons.insert_drive_file,
                          size: 14,
                          color: openable
                              ? Theme.of(context).colorScheme.primary
                              : Colors.grey,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            label,
                            style: TextStyle(
                              fontSize: 12,
                              color: clean ? null : Colors.grey,
                              decoration: openable
                                  ? TextDecoration.underline
                                  : null,
                            ),
                          ),
                        ),
                        Text(
                          _fmtSize(vi.sizeBytes),
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.grey,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          if (widget.embeddedVis.length > 60)
            Text(
              '… (+${widget.embeddedVis.length - 60} more)',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          const SizedBox(height: 16),
        ],

        const Text(
          'Capabilities',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _cap('Front panel', summary.hasFrontPanel),
            _cap('Block diagram (logic)', summary.hasBlockDiagram),
            _cap('Connector pane', summary.hasConnectorPane),
            _cap('Sub-VI links', summary.hasSubViLinks),
          ],
        ),
        const SizedBox(height: 16),

        const Text(
          'Resource-block inventory',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        Text(
          widget.sections.isEmpty
              ? 'No section bytes recovered for this file.'
              : 'Click a highlighted block to inspect its bytes + parsed records (hex view).',
          style: const TextStyle(color: Colors.grey, fontSize: 12),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final block in summary.blocks)
              if (_hasSection(block))
                Tooltip(
                  message: kBlockGlossary[block] ?? 'resource block',
                  child: ActionChip(
                    label: Text(block),
                    avatar: const Icon(Icons.data_object, size: 16),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _openHex(context, block),
                  ),
                )
              else
                Tooltip(
                  message:
                      '${kBlockGlossary[block] ?? 'resource block'}\n(bytes not yet extracted for this block)',
                  child: Opacity(
                    opacity: 0.4,
                    child: Chip(
                      label: Text(block),
                      avatar: const Icon(Icons.block, size: 14),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ),
          ],
        ),

        if (widget.components.isNotEmpty) ...[
          const SizedBox(height: 16),
          const Text(
            'Components (by decompressed size)',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          for (final component in widget.components.take(20))
            _kv(
              component.sectionCount > 1
                  ? '${component.tag} ×${component.sectionCount}'
                  : component.tag,
              component.compressed
                  ? '${_fmtSize(component.decompressedBytes)}  (zlib ${_fmtSize(component.rawBytes)})'
                  : _fmtSize(component.decompressedBytes),
            ),
        ],

        if (widget.components.isNotEmpty) ...[
          const SizedBox(height: 16),
          const Text(
            'Block inventory (by category)',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          const Text(
            'Every resource block, identified via the clean-room catalog (name · confidence · size).',
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
          const SizedBox(height: 8),
          ..._blockInventory(),
        ],

        if (widget.strings.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(
            'Embedded strings (${widget.strings.length})',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
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
          for (final text in filtered.take(1000))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 1),
              child: Text(
                text,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          if (filtered.length > 1000)
            Text('… and ${filtered.length - 1000} more'),
          if (filtered.isEmpty)
            const Text('(no match)', style: TextStyle(color: Colors.grey)),
        ],

        const SizedBox(height: 20),
        Card(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: const Padding(
            padding: EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Read-only viewer',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 6),
                Text(
                  'Shows the RSRC container, decoded version/title, embedded strings, and — '
                  'in the Diagram tab — the recovered block-diagram object layout (each '
                  'object at its absolute position, colored by kind, with its label and data '
                  'type). Decoded clean-room from the heap; honest by construction — signal '
                  'wires are not drawn yet (geometry decoded, endpoints not yet), and '
                  'function-vs-subVI is not yet distinguished from the block diagram alone.',
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  bool _hasSection(String tag) => widget.sections.any((s) => s.tag == tag);

  /// A one-glance map of every block in the VI, grouped by the catalog category,
  /// showing the human name + clean-room confidence + decompressed size. Purely
  /// catalog-driven (blockInfo) — no fabrication.
  List<Widget> _blockInventory() {
    final byCat = <ViBlockCategory, List<BlockComponent>>{};
    for (final component in widget.components) {
      (byCat[blockInfo(component.tag).category] ??= []).add(component);
    }
    final cats = byCat.keys.toList()..sort((a, b) => a.name.compareTo(b.name));
    final rows = <Widget>[];
    for (final cat in cats) {
      rows.add(
        Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 2),
          child: Text(
            cat.name,
            style: const TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 12,
              color: Color(0xFF4C8C4C),
            ),
          ),
        ),
      );
      final items = byCat[cat]!..sort((a, b) => a.tag.compareTo(b.tag));
      for (final item in items) {
        final info = blockInfo(item.tag);
        final label = item.sectionCount > 1
            ? '${item.tag} ×${item.sectionCount}'
            : item.tag;
        rows.add(
          _kv(
            '$label  ${info.name}',
            '${info.confidence.name} · ${_fmtSize(item.decompressedBytes)}',
          ),
        );
      }
    }
    return rows;
  }

  void _openHex(BuildContext context, String tag) {
    final matches = [
      for (final section in widget.sections)
        if (section.tag == tag) section,
    ]..sort((a, b) => b.length.compareTo(a.length));
    if (matches.isEmpty) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.all(24),
        child: SizedBox(
          width: 1120,
          height: 740,
          child: _HexDialog(
            tag: tag,
            sections: matches,
            allSections: widget.sections,
          ),
        ),
      ),
    );
  }

  static Widget _kv(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 140,
          child: Text(label, style: const TextStyle(color: Colors.grey)),
        ),
        Expanded(child: Text(value)),
      ],
    ),
  );

  static String _fmtSize(int byteCount) => byteCount >= 1024
      ? '${(byteCount / 1024).toStringAsFixed(1)} KB'
      : '$byteCount B';

  static Widget _cap(String label, bool on) => Chip(
    avatar: Icon(
      on ? Icons.check_circle : Icons.remove_circle_outline,
      color: on ? Colors.green : Colors.grey,
      size: 18,
    ),
    label: Text(label),
    backgroundColor: on ? Colors.green.withValues(alpha: 0.12) : null,
  );
}

class _HexDialog extends StatefulWidget {
  const _HexDialog({
    required this.tag,
    required this.sections,
    this.allSections = const [],
  });
  final String tag;
  final List<DecodedSection> sections;

  /// All decoded sections of the VI (for cross-block resolution, e.g. CONP→VCTP).
  final List<DecodedSection> allSections;

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
              Icon(
                Icons.data_object,
                size: 18,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Text(
                '${widget.tag} — byte inspector',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(width: 16),
              if (widget.sections.length > 1)
                DropdownButton<int>(
                  value: _idx,
                  isDense: true,
                  onChanged: (v) => setState(() => _idx = v ?? 0),
                  items: [
                    for (var i = 0; i < widget.sections.length; i++)
                      DropdownMenuItem(
                        value: i,
                        child: Text(
                          'section ${widget.sections[i].index} (${widget.sections[i].length} B)',
                        ),
                      ),
                  ],
                ),
              const Spacer(),
              IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: BlockHexView(
              key: ValueKey('${section.tag}:${section.index}'),
              section: section,
              siblings: widget.allSections,
            ),
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

/// An honest "what we recovered vs what's still unknown" strip for the Block
/// Diagram tab, derived entirely from real model counts — never fabricated,
/// and explicit that only STRUCTURE is recovered (dataflow/wires are not).
class _RecoverySummary extends StatelessWidget {
  const _RecoverySummary(this.model);
  final ViModel model;

  @override
  Widget build(BuildContext context) {
    final objs = [
      for (final diagram in model.blockDiagrams) ...diagram.objects,
    ];
    final classified = objs
        .where((o) => o.category != ViObjectKind.unknown)
        .length;
    final unknown = objs.length - classified;
    final structures = objs
        .where((o) => o.category == ViObjectKind.structure)
        .length;
    final nodes = objs.where((o) => o.category == ViObjectKind.node).length;
    final parts = <String>[
      '${objs.length} BD objects',
      '$classified classified / $unknown unknown',
      '$structures structures',
      '$nodes nodes',
      '${model.subViNames.length} subVI calls',
      '${model.types.length} types',
    ];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Recovered: ${parts.join('  ·  ')}',
            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 2),
          const Text(
            'Structure only — node→node dataflow / wires are not recovered.',
            style: TextStyle(fontSize: 11, color: Colors.grey),
          ),
        ],
      ),
    );
  }
}
