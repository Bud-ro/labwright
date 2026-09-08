import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import 'bd_oracle.dart';
import 'coverage_view.dart';
import 'diagram_view.dart';
import 'hex_view.dart';
import 'images_view.dart';
import 'representative_vis.dart';
import 'span_annotations.dart';
import 'subvi_icon_resolver.dart';
import 'types_view.dart';
import 'vi_demo.dart';

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

  final Future<Uint8List> Function(Uri) fetchBytes;

  final ViSummary? initial;

  final String? initialSource;

  final ViVersionInfo? initialVersion;

  final List<String>? initialStrings;

  final List<BlockComponent>? initialComponents;

  final ViModel? initialModel;

  final List<String>? initialLibraryNames;

  final List<ViEmbeddedVi>? initialEmbeddedVis;

  final WriterAttribution? initialAttribution;

  final ViImages? initialImages;

  @override
  State<ViInspectorScreen> createState() => _ViInspectorScreenState();
}

class _ViInspectorScreenState extends State<ViInspectorScreen> {
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

  Uint8List? _snippetPng;

  String? _fetchingRep;

  Directory? _repProjectDir;

  Future<Map<String, ViLegacyIcon>> Function(Set<String>)? _subViIconResolver;

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

  void _loadBytes(
    Uint8List bytes,
    String source, {
    Future<Map<String, ViLegacyIcon>> Function(Set<String>)? subViIconResolver,
  }) {
    Uint8List? snippetPng;
    if (isPngBytes(bytes)) {
      final embedded = extractSnippetVi(bytes);
      if (embedded == null) {
        setState(() {
          _summary = null;
          _error =
              'This PNG carries no embedded VI (no niVI chunk) — only '
              'VI-snippet PNGs can be opened.';
          _source = source;
          _snippetPng = null;
        });
        return;
      }
      snippetPng = bytes;
      bytes = embedded;
      source = 'snippet: $source';
    }
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
      try {
        attribution = attributeVi(bytes);
      } catch (_) {
        attribution = null;
      }
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
      _snippetPng = snippetPng;
      _subViIconResolver = subViIconResolver;
    });
  }

  Uint8List? _vctpBytes() {
    for (final section in _sections) {
      if (section.tag == 'VCTP') return section.bytes;
    }
    return null;
  }

  void _loadPath(String path) {
    if (path.isEmpty) return;
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
    _loadBytes(
      bytes,
      path,
      subViIconResolver: (wanted) => resolveSubViIconsFor(path, wanted),
    );
  }

  Future<void> _openRepresentative(RepresentativeVi representative) async {
    if (_fetchingRep != null) return;
    setState(() => _fetchingRep = representative.name);
    final previous = _repProjectDir;
    try {
      final fetched = await fetchRepresentativeVi(
        representative,
        fetch: widget.fetchBytes,
      );
      if (!mounted) return;
      _repProjectDir = fetched.projectDir;
      final deps = representative.dependencies.isEmpty
          ? ''
          : ' (+${fetched.fetchedDeps} subVIs'
                '${fetched.failedDeps > 0 ? ', ${fetched.failedDeps} failed' : ''})';
      final mainPath = fetched.mainPath;
      final levelsUp = representative.path.split('/').length - 1;
      _loadBytes(
        fetched.bytes,
        'GitHub: ${representative.repo} · ${representative.name}${deps}',
        subViIconResolver: (wanted) =>
            resolveSubViIconsFor(mainPath, wanted, levelsUp: levelsUp),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _summary = null;
        _error = 'Could not fetch ${representative.name}: $error';
        _source = representative.rawUrl.toString();
      });
    } finally {
      if (mounted) setState(() => _fetchingRep = null);
      try {
        previous?.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  Future<void> _browse() async {
    final result = await FilePicker.pickFiles(
      dialogTitle: 'Open a LabVIEW VI (or a VI-snippet PNG)',
      type: FileType.custom,
      allowedExtensions: const ['vi', 'ctl', 'llb', 'png'],
    );
    if (!mounted) return;
    final files = result?.files ?? const [];
    if (files.isNotEmpty && files.first.path != null)
      _loadPath(files.first.path!);
  }

  @override
  Widget build(BuildContext context) {
    final icon = bestLegacyIcon(_images);
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 28,
                  height: 28,
                  child: icon != null
                      ? CustomPaint(painter: LegacyIconPainter(icon))
                      : DecoratedBox(
                          decoration: BoxDecoration(
                            border: Border.all(color: const Color(0xFF666666)),
                            color: const Color(0x14000000),
                          ),
                          child: const Icon(
                            Icons.memory_outlined,
                            size: 16,
                            color: Color(0xFF888888),
                          ),
                        ),
                ),
                if (_summary?.name != null)
                  Text(
                    _summary!.name!,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                if (_source.isNotEmpty)
                  IconButton(
                    key: const Key('copy-path'),
                    tooltip: 'Copy path\n$_source',
                    visualDensity: VisualDensity.compact,
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: _source));
                      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                        const SnackBar(
                          content: Text('Path copied'),
                          duration: Duration(seconds: 2),
                        ),
                      );
                    },
                    icon: const Icon(Icons.copy_outlined, size: 18),
                  ),
                FilledButton.icon(
                  key: const Key('browse'),
                  onPressed: _browse,
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Browse…'),
                ),
                OutlinedButton.icon(
                  key: const Key('demo'),
                  onPressed: () =>
                      _loadBytes(demoViBytes(), 'demo VI (synthetic)'),
                  icon: const Icon(Icons.science_outlined),
                  label: const Text('Load demo VI'),
                ),
                MenuAnchor(
                  menuChildren: [
                    for (final representative in kRepresentativeVis)
                      MenuItemButton(
                        onPressed: _fetchingRep == null
                            ? () => _openRepresentative(representative)
                            : null,
                        leadingIcon: _fetchingRep == representative.name
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
                              Text(representative.name),
                              Text(
                                representative.feature +
                                    (representative.missingNote == null
                                        ? ''
                                        : ' · ${representative.missingNote}'),
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
                          length: _snippetPng == null ? 6 : 7,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              TabBar(
                                isScrollable: true,
                                tabs: [
                                  const Tab(text: 'Inspect'),
                                  const Tab(text: 'Front Panel'),
                                  const Tab(text: 'Block Diagram'),
                                  const Tab(text: 'Types'),
                                  const Tab(text: 'Images'),
                                  const Tab(text: 'Coverage'),
                                  if (_snippetPng != null)
                                    const Tab(text: 'Oracle'),
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
                                            subViIconResolver:
                                                _subViIconResolver,
                                            sections: _sections,
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
                                    if (_snippetPng != null)
                                      BdOracleView(
                                        key: ValueKey('oracle:$_model'),
                                        diagram: _model == null
                                            ? null
                                            : bestBlockDiagram(_model!),
                                        referenceBytes: _snippetPng,
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
              : 'Drag a .vi or a VI-snippet .png here, or use '
                    'Browse… / Load demo VI / Examples',
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

  final ViModel? model;

  final List<String> libraryNames;

  final List<ViEmbeddedVi> embeddedVis;

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
        Text(summary.describe(), style: const TextStyle(color: Colors.grey)),
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
                    hist.entries
                        .map((entry) => '${entry.key}:${entry.value}')
                        .join('  '),
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
          for (final embedded in widget.embeddedVis.take(60))
            Builder(
              builder: (context) {
                final clean =
                    embedded.name != null &&
                    embedded.name!.toLowerCase().endsWith('.vi');
                final label = clean ? embedded.name! : '(name not recovered)';
                final openable =
                    embedded.bytes != null && widget.onOpenEmbedded != null;
                return InkWell(
                  onTap: openable
                      ? () => widget.onOpenEmbedded!(embedded)
                      : null,
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
                          _fmtSize(embedded.sizeBytes),
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
            onChanged: (value) => setState(() => _filter = value),
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
      ],
    );
  }

  bool _hasSection(String tag) =>
      widget.sections.any((section) => section.tag == tag);

  List<Widget> _blockInventory() {
    final byCat = <ViBlockCategory, List<BlockComponent>>{};
    for (final component in widget.components) {
      (byCat[blockInfo(component.tag).category] ??= []).add(component);
    }
    final cats = byCat.keys.toList()
      ..sort((first, second) => first.name.compareTo(second.name));
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
      final items = byCat[cat]!
        ..sort((first, second) => first.tag.compareTo(second.tag));
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
    ]..sort((first, second) => second.length.compareTo(first.length));
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
                  onChanged: (value) => setState(() => _idx = value ?? 0),
                  items: [
                    for (var index = 0; index < widget.sections.length; index++)
                      DropdownMenuItem(
                        value: index,
                        child: Text(
                          'section ${widget.sections[index].index} (${widget.sections[index].length} B)',
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

class _RecoverySummary extends StatelessWidget {
  const _RecoverySummary(this.model);
  final ViModel model;

  @override
  Widget build(BuildContext context) {
    final objs = [
      for (final diagram in model.blockDiagrams) ...diagram.objects,
    ];
    final classified = objs
        .where((object) => object.category != ViObjectKind.unknown)
        .length;
    final unknown = objs.length - classified;
    final structures = objs
        .where((object) => object.category == ViObjectKind.structure)
        .length;
    final nodes = objs
        .where((object) => object.category == ViObjectKind.node)
        .length;
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
            'Dataflow wires are drawn from decoded signal endpoints; the wire '
            'datatype and packed route geometry are not decoded.',
            style: TextStyle(fontSize: 11, color: Colors.grey),
          ),
        ],
      ),
    );
  }
}
