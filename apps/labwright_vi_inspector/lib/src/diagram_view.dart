import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import 'faithful_controls.dart';
import 'images_view.dart';
import 'span_annotations.dart';

/// How the diagram is drawn: a debug **wireframe** (colored boxes + labels,
/// click-to-inspect) or a **faithful** render (real-looking interactive controls).
enum DiagramRenderMode { wireframe, faithful }

/// Faithful mode mounts one live (stateful) Flutter control per object, so it is
/// capped: diagrams with more drawable objects than this fall back to the cheap
/// single-CustomPaint wireframe (a few corpus VIs reach several thousand objects,
/// which would otherwise mount thousands of controllers/render objects at once).
const int kFaithfulMaxObjects = 1500;

/// A read-only **layout view** of a decoded VI block diagram, rendered to a
/// faithful, LabVIEW-like canvas: every recovered object drawn at its absolute
/// coordinates, with nesting-aware z-order, type-faithful terminal colors,
/// structure frames, labels, click-to-inspect, pan/zoom and auto-fit.
///
/// Backed entirely by the clean-room `labwright_rsrc_parse` decode
/// (`buildViModel` → `blockDiagrams`/`frontPanelDiagrams`). Honest by
/// construction: only objects with recovered absolute bounds are drawn.
/// Dataflow wires are drawn from the decoded signal (`0x17`) endpoint binding
/// ([ViDiagram.wires]) — routed as right-angle runs between each signal's real
/// endpoint anchors — but the wire **datatype is not decoded**, so runs are a
/// neutral tone (only tinted where an anchor coincides with a typed terminal),
/// never a fabricated per-type colour. This is a faithful object/position view,
/// not a re-render of LabVIEW's canvas.
class ViDiagramView extends StatefulWidget {
  const ViDiagramView({
    super.key,
    required this.diagrams,
    this.emptyHint = 'No decodable layout in this file.',
    this.subViNames = const [],
    this.isFrontPanel = false,
    this.viImages = const ViImages(),
    this.subViIconLoader,
  });

  /// The diagrams to render (block-diagram or front-panel heap trees); the
  /// richest is shown. Pass `model.blockDiagrams` or `model.frontPanelDiagrams`.
  final List<ViDiagram>? diagrams;

  /// Shown when no diagram has positioned objects.
  final String emptyHint;

  /// The VI's sub-VI dependency names from the LIbd linker block
  /// (`model.subViNames`) — the names LabVIEW records as block-diagram
  /// dependencies (recoverable for ~82% of VIs; the rest call no subVIs or none
  /// with a stored name). This is a dependency list from the linker, NOT a
  /// per-node call mapping, but it does not depend on individual BD node labels.
  /// Pass only for the block diagram (empty for the front panel).
  final List<String> subViNames;

  /// True when rendering the front panel. On the FP, structure containers
  /// (clusters/arrays/panes) show their caption instead of a class-kind badge so
  /// the badge never obscures the control's label; the BD keeps kind badges.
  final bool isFrontPanel;

  /// The VI's own recovered images — its 32×32 icon (`icl8`/`icl4`/`ICON`) and
  /// any embedded diagram PNGs (`MNGI`/`DSIM`). Rendered as an identity strip
  /// above the diagram: the icon is what a *caller's* subVI node would display
  /// for this VI. (This diagram's own subVI-call nodes are stamped with their
  /// targets' icons when a [subViIconLoader] resolves the called VIs' files.)
  /// Empty by default.
  final ViImages viImages;

  /// Optional `filename → bytes` lookup used to stamp each **subVI-call node**
  /// with the icon of the VI it targets (see [resolveSubViIcons]): the node's
  /// `.vi`/`.vim` caption is loaded and its icon decoded. Only meaningful for the
  /// block diagram (subVI nodes live there); a node whose target the loader can't
  /// find keeps the neutral connector-pane plate. Null (the default) draws no
  /// on-node icons.
  final Uint8List? Function(String fileName)? subViIconLoader;

  @override
  State<ViDiagramView> createState() => _ViDiagramViewState();
}

class _ViDiagramViewState extends State<ViDiagramView> {
  final _transform = TransformationController();
  ViHeapObject? _selected;
  Set<ViHeapObject> _members = const {};
  Size? _lastViewport;
  Rect? _lastContent;
  bool _fitted = false;
  DiagramRenderMode _mode = DiagramRenderMode.wireframe;

  late final ViDiagram? _diagram = _largestDiagram(widget.diagrams);
  late final Map<int, ViHeapObject> _byId = _diagram?.byId ?? const {};
  // SubVI-call node icons resolved from the called VIs' own files (block diagram
  // only). Empty when no loader is supplied or nothing resolves.
  late final Map<int, ViLegacyIcon> _subViIcons =
      (_diagram == null ||
          widget.isFrontPanel ||
          widget.subViIconLoader == null)
      ? const {}
      : resolveSubViIcons(_diagram, widget.subViIconLoader!);
  late final List<ViHeapObject> _drawable = _diagram == null
      ? const []
      : bdDrawableObjects(_diagram);
  late final List<ViHeapObject> _ordered = bdPaintOrder(_drawable, _byId);
  // Decoded dataflow wires (empty on a front-panel heap). Drawn under the nodes.
  late final List<ViWire> _wires = _diagram?.wires ?? const [];
  // Wires are excluded from the fit: their absolute anchoring is not yet
  // verified (a misanchored run must not blow up the zoom-to-fit envelope).
  late final Rect _content = _drawable.isEmpty
      ? Rect.zero
      : bdContentRect(_drawable, includeWires: false);
  late final Map<ViObjectKind, int> _counts = _computeCounts();

  Map<ViObjectKind, int> _computeCounts() {
    final countsByKind = <ViObjectKind, int>{};
    for (final object in _drawable) {
      countsByKind[object.category] = (countsByKind[object.category] ?? 0) + 1;
    }
    return countsByKind;
  }

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_diagram == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            widget.emptyHint,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.grey),
          ),
        ),
      );
    }
    if (_drawable.isEmpty) {
      return const Center(
        child: Text(
          'Diagram has no positioned objects.',
          style: TextStyle(color: Colors.grey),
        ),
      );
    }

    final content = _content;
    _lastContent = content;
    final ordered = _ordered;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!widget.isFrontPanel && !widget.viImages.isEmpty)
          _ViImageStrip(widget.viImages),
        _toolbar(_drawable.length, _counts),
        _BdOutline(
          outline: computeBdOutline(_drawable),
          linkedSubVis: widget.subViNames,
        ),
        const SizedBox(height: 6),
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final viewport = Size(
                      constraints.maxWidth,
                      constraints.maxHeight,
                    );
                    if (viewport != _lastViewport) {
                      _lastViewport = viewport;
                      _fitted = false;
                    }
                    if (!_fitted) {
                      WidgetsBinding.instance.addPostFrameCallback(
                        (_) => _fit(),
                      );
                    }
                    return ClipRect(
                      child: ColoredBox(
                        color: const Color(0xFFE9E9E9),
                        child: InteractiveViewer(
                          transformationController: _transform,
                          constrained: false,
                          minScale: 0.02,
                          maxScale: 16,
                          boundaryMargin: const EdgeInsets.all(2000),
                          child:
                              (_mode == DiagramRenderMode.faithful &&
                                  ordered.length <= kFaithfulMaxObjects)
                              ? FaithfulLayer(
                                  objects: ordered,
                                  origin: content.topLeft,
                                  size: content.size,
                                  isFrontPanel: widget.isFrontPanel,
                                )
                              : GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTapDown: (d) => _selectAt(
                                    d.localPosition,
                                    ordered,
                                    content,
                                  ),
                                  child: CustomPaint(
                                    size: Size(content.width, content.height),
                                    painter: BdDiagramPainter(
                                      objects: ordered,
                                      origin: content.topLeft,
                                      wires: _wires,
                                      subViIcons: _subViIcons,
                                    ),
                                    foregroundPainter: _OverlayPainter(
                                      origin: content.topLeft,
                                      selected: _selected,
                                      members: _members,
                                    ),
                                  ),
                                ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              if (_mode == DiagramRenderMode.wireframe && _selected != null)
                Positioned(
                  left: 8,
                  right: 8,
                  bottom: 8,
                  child: _DetailsCard(
                    object: _selected!,
                    members: _members,
                    onClose: () => setState(() {
                      _selected = null;
                      _members = const {};
                    }),
                  ),
                ),
              if (_mode == DiagramRenderMode.faithful &&
                  _ordered.length > kFaithfulMaxObjects)
                Positioned(
                  left: 8,
                  right: 8,
                  top: 8,
                  child: Material(
                    color: const Color(0xFFFFF3CD),
                    borderRadius: BorderRadius.circular(4),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text(
                        'Faithful mode is disabled for large diagrams '
                        '(${_ordered.length} objects > $kFaithfulMaxObjects) — showing wireframe.',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF7A5B00),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const Padding(
          padding: EdgeInsets.only(top: 6),
          child: Text(
            'Object layout decoded clean-room. Dataflow wires (signal 0x17) are '
            'routed between their decoded endpoint anchors; the wire datatype is '
            'not decoded, so runs are neutral unless an anchor meets a typed '
            'terminal. Visual wire segments (class 0x1d) are drawn from their '
            'stored Manhattan runs.',
            style: TextStyle(color: Colors.grey, fontSize: 11),
          ),
        ),
      ],
    );
  }

  Widget _toolbar(int objectCount, Map<ViObjectKind, int> counts) => Wrap(
    spacing: 12,
    runSpacing: 4,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      Text(
        '$objectCount objects',
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
      for (final entry in counts.entries)
        _LegendChip(
          color: _kindColor(entry.key),
          label: '${entry.key.name} ${entry.value}',
        ),
      const Tooltip(
        message:
            'Dataflow wires (signal 0x17) are routed between their decoded\n'
            'endpoint anchors (100% resolve; 91% source+sink). Visual segments\n'
            '(0x1d: stored Manhattan runs) are also drawn. Not decoded: the wire\n'
            'datatype (for per-type colors) — runs stay neutral unless an anchor\n'
            'meets a terminal whose type was recovered.',
        child: Chip(
          avatar: Icon(Icons.linear_scale, size: 14),
          label: Text('wires: dataflow routed', style: TextStyle(fontSize: 11)),
          visualDensity: VisualDensity.compact,
        ),
      ),
      SegmentedButton<DiagramRenderMode>(
        style: const ButtonStyle(visualDensity: VisualDensity.compact),
        segments: const [
          ButtonSegment(
            value: DiagramRenderMode.wireframe,
            icon: Icon(Icons.grid_4x4, size: 16),
            label: Text('Wireframe'),
          ),
          ButtonSegment(
            value: DiagramRenderMode.faithful,
            icon: Icon(Icons.widgets_outlined, size: 16),
            label: Text('Faithful'),
          ),
        ],
        selected: {_mode},
        onSelectionChanged: (s) => setState(() {
          _mode = s.first;
          if (_mode == DiagramRenderMode.faithful) {
            _selected = null;
            _members = const {};
          }
        }),
      ),
      IconButton(
        tooltip: 'Fit to view',
        onPressed: _fit,
        icon: const Icon(Icons.fit_screen),
      ),
    ],
  );

  void _selectAt(Offset local, List<ViHeapObject> objects, Rect content) {
    final x = local.dx + content.left;
    final y = local.dy + content.top;
    ViHeapObject? hit;
    var bestArea = double.infinity;
    for (final object in objects) {
      final bounds = object.absBounds!;
      if (x >= bounds.left &&
          x <= bounds.right &&
          y >= bounds.top &&
          y <= bounds.bottom) {
        final area = (bounds.width * bounds.height).toDouble();
        if (area <= bestArea) {
          bestArea = area;
          hit = object;
        }
      }
    }
    setState(() {
      _selected = hit;
      _members = _membersOf(hit);
    });
  }

  Set<ViHeapObject> _membersOf(ViHeapObject? o) =>
      o != null && o.category == ViObjectKind.structure
      ? nodesWithin(o, _drawable)
      : membersOf(o, _byId);

  void _fit() {
    final viewport = _lastViewport;
    final content = _lastContent;
    if (viewport == null ||
        content == null ||
        content.width <= 0 ||
        content.height <= 0)
      return;
    final widthScale = (viewport.width / content.width).clamp(
      0.0,
      double.infinity,
    );
    final scale =
        (widthScale < viewport.height / content.height
            ? widthScale
            : viewport.height / content.height) *
        0.94;
    final tx = (viewport.width - content.width * scale) / 2;
    final ty = (viewport.height - content.height * scale) / 2;
    _transform.value = Matrix4.identity()
      ..translateByDouble(tx, ty, 0, 1)
      ..scaleByDouble(scale, scale, 1, 1);
    _fitted = true;
  }

  static ViDiagram? _largestDiagram(List<ViDiagram>? diagrams) {
    if (diagrams == null || diagrams.isEmpty) return null;
    ViDiagram? best;
    var bestN = -1;
    for (final diagram in diagrams) {
      final placedCount = diagram.objects
          .where((o) => o.absBounds != null)
          .length;
      if (placedCount > bestN) {
        bestN = placedCount;
        best = diagram;
      }
    }
    return bestN <= 0 ? null : best;
  }
}

/// Faithful-ish LabVIEW palette: terminals colored by data type, else by class.
Color _typeColor(ViTypeKind t) => switch (t) {
  ViTypeKind.numericFloat => const Color(0xFFE8732A),
  ViTypeKind.numericInt => const Color(0xFF1F6FE0),
  ViTypeKind.enumRing => const Color(0xFF1FA0C0),
  ViTypeKind.path => const Color(0xFF3FA64B),
  ViTypeKind.clnNode => const Color(0xFFE8C547),
  ViTypeKind.unknown => const Color(0xFF707070),
};

Color _kindColor(ViObjectKind k) => switch (k) {
  ViObjectKind.node => const Color(0xFFE8C547),
  ViObjectKind.terminal => const Color(0xFF5C9BD6),
  ViObjectKind.terminalCluster => const Color(0xFF2BB8A8),
  ViObjectKind.structure => const Color(0xFF9A6B2E),
  ViObjectKind.decoration => const Color(0xFFBDBDBD),
  ViObjectKind.wire => const Color(0xFF303030),
  ViObjectKind.unknown => const Color(0xFF9E9E9E),
};

Color _objectColor(ViHeapObject object) =>
    object.category == ViObjectKind.terminal &&
        object.typeKind != ViTypeKind.unknown
    ? _typeColor(object.typeKind)
    : _kindColor(object.category);

/// LabVIEW's canonical datatype colors, applied to terminals so the diagram
/// reads like the original: orange = float, blue = int/enum, green-brown =
/// path, yellow = call-library node. Unknown stays neutral (never guessed).
Color labviewTypeColor(ViTypeKind kind) => switch (kind) {
  ViTypeKind.numericFloat => const Color(0xFFFF8000),
  ViTypeKind.numericInt => const Color(0xFF0066CC),
  ViTypeKind.enumRing => const Color(0xFF0066CC),
  ViTypeKind.path => const Color(0xFF669900),
  ViTypeKind.clnNode => const Color(0xFFE8C547),
  ViTypeKind.unknown => const Color(0xFF8A8A8A),
};

/// LabVIEW's block-diagram canvas is a near-white field (the default panel is a
/// hair off pure white). The reference renders and the letterbox share this so
/// the empty margin matches instead of reading as a grey plate.
const Color kBdCanvas = Color(0xFFFFFFFF);

/// The faint alignment-grid dot color on [kBdCanvas] — low enough contrast that a
/// dot pixel stays within the oracle's per-channel match threshold of the canvas.
const Color kBdGridDot = Color(0x0C000000);

/// Block-diagram node class codes that are **subVI call** nodes (they carry a
/// called-VI filename caption). LabVIEW draws these as a plain connector-pane
/// **icon plate** — commonly light grey — distinct from the pale-gold primitive
/// function nodes. Any node class not listed renders as a generic primitive
/// plate; the node's specific icon is not recovered, so it is never guessed.
const Set<int> kSubViCallNodeCodes = {0x31, 0x32, 0xc5, 0x104, 0x103, 0x8c};

/// Fill for a subVI-call node icon plate (light grey, per LabVIEW's default
/// connector-pane icon background).
const Color kBdSubViNodeFill = Color(0xFFECECEC);

/// Fill for a primitive/function node plate — LabVIEW's numeric-function palette
/// pale gold. Used for every node that is not a recognised subVI call.
const Color kBdPrimitiveNodeFill = Color(0xFFFBEEC2);

/// Fill for a terminal whose datatype is not recovered — a neutral light grey
/// (no datatype colour is guessed). Datatype-known terminals use
/// [labviewTypeColor] instead.
const Color kBdUnknownTerminalFill = Color(0xFFD8D8D8);

/// Neutral dataflow-wire colour — a thin dark run. A [ViWire] (signal `0x17`)
/// carries endpoint binding but **no decoded datatype**, so a wire is drawn in
/// this neutral tone rather than a fabricated per-type colour; a wire is only
/// tinted when one of its endpoint anchors coincides with a terminal whose
/// datatype *was* recovered (see [bdWireColor]).
const Color kBdWireColor = Color(0xFF2B2B2B);

/// The opaque [Color] of a decoded 24-bit `0xRRGGBB` object colour ([rgb]), or
/// null when the object carried no such colour. Used to fill a decoration or
/// control in its own stored LabVIEW colour instead of a generic category tint.
Color? bdDecodedColor(int? rgb) =>
    rgb == null ? null : Color(0xFF000000 | (rgb & 0xFFFFFF));

/// The decoded **fill** colour for [object] when one was recovered: a control's
/// interior [ViHeapObject.contentRgb] if present, else its
/// [ViHeapObject.bgRgb]. Null when neither was decoded (the object keeps its
/// neutral category fill — no colour is guessed). See the corpus placement
/// probe: these colours sit on the drawable object itself.
Color? bdFillColor(ViHeapObject object) =>
    bdDecodedColor(object.contentRgb) ?? bdDecodedColor(object.bgRgb);

/// The Manhattan (right-angle) route between two endpoint-anchor rectangles, as
/// an ordered polyline in the anchors' own coordinate space: it leaves [source]
/// on the horizontal side facing [sink], turns at the mid-x column, then enters
/// [sink] on its facing side (the LabVIEW H–V–H elbow). Pure + public so the
/// routing is unit-testable independent of the canvas.
List<Offset> bdWireRoute(Rect source, Rect sink) {
  final sinkRight = sink.center.dx >= source.center.dx;
  final start = Offset(
    sinkRight ? source.right : source.left,
    source.center.dy,
  );
  final end = Offset(sinkRight ? sink.left : sink.right, sink.center.dy);
  final midX = (start.dx + end.dx) / 2;
  return [start, Offset(midX, start.dy), Offset(midX, end.dy), end];
}

/// The colour a [wire] is drawn in: [kBdWireColor] unless one of its endpoint
/// anchors exactly matches a terminal whose datatype was recovered, in which
/// case that terminal's [labviewTypeColor] is used. [typedTerminalColors] maps a
/// packed endpoint-anchor rectangle (`t,l,b,r`) to that terminal's colour. The
/// wire's own datatype is not decoded, so no colour is ever guessed from the
/// signal itself. Pure + public for testing.
Color bdWireColor(ViWire wire, Map<int, Color> typedTerminalColors) {
  for (final anchor in wire.endpointAnchors) {
    if (anchor == null) continue;
    final color =
        typedTerminalColors[_packRect(
          anchor.top,
          anchor.left,
          anchor.bottom,
          anchor.right,
        )];
    if (color != null) return color;
  }
  return kBdWireColor;
}

/// Packs a rectangle's four `s16` edges into one int key for anchor↔terminal
/// matching (each edge is offset into a non-negative 16-bit lane).
int _packRect(int top, int left, int bottom, int right) =>
    ((top + 0x8000) << 48) |
    ((left + 0x8000) << 32) |
    ((bottom + 0x8000) << 16) |
    (right + 0x8000);

/// Class codes LabVIEW draws as **free text** on the canvas, not as a filled
/// part: the control caption / free-label (`0x0a`) and the case-selector label
/// (`0x95`). The painter renders only their recovered caption text, never a box.
const Set<int> kBdTextLabelCodes = {0x0a, 0x95};

/// The label drawn on a wireframe object. Structures (never text-labeled) show
/// their catalog kind via [structureBadge] (so the wireframe reads as logic too,
/// honestly tracking the class catalog — e.g. "For loop", "Case structure",
/// "Loop (BD) / container (FP)"); other objects show their recovered name and
/// (for terminals) data type. Pure + public for unit testing the canvas text.
String? wireframeAnnotation(ViHeapObject o) {
  if (o.category == ViObjectKind.structure) return structureBadge(o);
  final label = o.label;
  final type = o.typeKind == ViTypeKind.unknown ? null : o.typeKind.name;
  if (label != null && type != null) return '$label · $type';
  return label ?? type;
}

/// An honest, wire-free **control-flow outline** of a block diagram: the
/// structures grouped by catalog kind (e.g. `While loop`, `Case structure`), the
/// distinct **labeled-node captions** (a node's `C4 22` caption — for a subVI
/// usually its name, but NOT a proven call; many node kinds carry captions), and
/// the total node count. Conveys the diagram's control-flow shape at a glance
/// without claiming any dataflow edges (LabVIEW stores wires as geometry, with no
/// recoverable node→node endpoints). Pure + public so it is unit-testable.
({
  Map<String, int> structuresByKind,
  List<String> labeledNodes,
  int nodeCount,
  Map<ClassConfidence, int> confidence,
})
computeBdOutline(Iterable<ViHeapObject> objects) {
  const notControlFlow = {
    HeapObjectClass.diagramRoot,
    HeapObjectClass.diagramProps,
    HeapObjectClass.diagramFrame,
    HeapObjectClass.rootAux,
  };
  final byKind = <String, int>{};
  final labeledNodes = <String>[];
  var nodeCount = 0;
  final confidence = <ClassConfidence, int>{};
  for (final object in objects) {
    if (object.category == ViObjectKind.structure) {
      if (notControlFlow.contains(object.objectClass)) continue;
      final badge = structureBadge(object);
      byKind[badge] = (byKind[badge] ?? 0) + 1;
      confidence[object.objectClass.confidence] =
          (confidence[object.objectClass.confidence] ?? 0) + 1;
    } else if (object.category == ViObjectKind.node) {
      nodeCount++;
      confidence[object.objectClass.confidence] =
          (confidence[object.objectClass.confidence] ?? 0) + 1;
      final dl = nodeDisplayLabel(object);
      if (!dl.isHint && !labeledNodes.contains(dl.text))
        labeledNodes.add(dl.text);
    }
  }
  return (
    structuresByKind: byKind,
    labeledNodes: labeledNodes,
    nodeCount: nodeCount,
    confidence: confidence,
  );
}

/// Control-terminal classes — their internal sub-terminals are scaffolding.

/// Whether [o] is pure LabVIEW chrome that a faithful layout view should not
/// draw (corpus-validated; suppresses ~76% of raw heap objects, leaving real
/// structures, nodes, controls, decorations and caption bars):
/// - resize/scroll handles (`0x09`);
/// - content viewports (`0x11c`) — used only as the re-anchor frame, the
///   enclosing cluster/structure is drawn instead;
/// - hidden no-bounds terminals (`0x68`);
/// - the display/increment/terminal/item-list parts internal to a control
///   (`0xe0`/`0x0b`/`0x0c`/`0x0d` with a control-kind ancestor) — the control is
///   drawn as a single unit, not its internals (`0x0d`'s enum items are already
///   propagated up to the control, so suppressing it loses nothing);
/// - subVI-node internal display sub-parts (`0xe5`) — corpus: 947, all under a
///   `0xc5` node; they overlap the parent node and would otherwise paint a stray
///   unknown rectangle over it.
/// The control/indicator terminal classes that, when they appear as a **named**
/// leaf inside a block-diagram constant/structural subtree, are a called subVI's
/// own connector-pane controls spliced into the caller's heap (an inlined/
/// malleable subVI stores its panel controls here), NOT a top-level diagram
/// object LabVIEW draws. See [_isInlinedSubViControl].
const Set<int> _controlTerminalDrawCodes = {
  0x50,
  0x4f,
  0x57,
  0x5b,
  0x51,
  0x55,
  0x10c,
  0xc2,
  0x56,
};

/// Whether [o] is a **subVI connector-pane control spliced into this heap** by an
/// inlined/malleable subVI call — a control-terminal class ([_controlTerminalDrawCodes])
/// that (a) nests inside a block-diagram constant/structural subtree (a `0x13`
/// `bDConstDCO` or `0x15` structural record ancestor) and (b) carries a named
/// `0x0a` caption child (the subVI control's data name, e.g. `Requirement ID`,
/// `Label (VI Title)`). LabVIEW draws the subVI as a single icon node, not its
/// inlined internal controls, so these are not part of *this* VI's top-level
/// block diagram and are excluded from the drawn/fit set. A bare unnamed constant
/// terminal (a numeric/string diagram constant) has no such named caption child
/// and is kept. [childrenByOid] is the positional child index.
bool _isInlinedSubViControl(
  ViHeapObject o,
  Map<int, ViHeapObject> byId,
  Map<int, List<ViHeapObject>> childrenByOid,
) {
  if (!_controlTerminalDrawCodes.contains(o.kind)) return false;
  var parentOid = o.parentOid;
  final seen = <int>{};
  var underConstOrStruct = false;
  while (parentOid != null && seen.add(parentOid)) {
    final po = byId[parentOid];
    if (po == null) break;
    if (po.kind == 0x13 || po.kind == 0x15) {
      underConstOrStruct = true;
      break;
    }
    parentOid = po.parentOid;
  }
  if (!underConstOrStruct) return false;
  final kids = childrenByOid[o.oid];
  if (kids == null) return false;
  return kids.any(
    (c) => c.kind == 0x0a && (c.label?.trim().isNotEmpty ?? false),
  );
}

bool _isScaffolding(ViHeapObject o, Map<int, ViHeapObject> byId) {
  if (o.kind == 0x09 || o.kind == 0x11c) return true;
  if (o.kind == 0xe5) return true;
  if (o.kind == 0x68 && o.bounds == null) return true;
  if (o.kind == 0xe0 || o.kind == 0x0b || o.kind == 0x0c || o.kind == 0x0d) {
    var parentOid = o.parentOid;
    var depth = 0;
    while (parentOid != null && depth < 64) {
      final po = byId[parentOid];
      if (po == null) break;
      if (kControlTerminalCodes.contains(po.kind)) return true;
      parentOid = po.parentOid;
      depth++;
    }
  }
  return false;
}

/// The **drawn** objects [o] declares as members (childRef ∪ dcoRef from the
/// 0x14 ref graph), resolved via [byId] and filtered to objects actually on the
/// canvas (has bounds, not scaffolding-suppressed, not [o] itself) so a highlight
/// never floats over empty canvas. In practice members resolve to a drawn object
/// mostly for loops/structures — most other carriers' refs point at non-drawn
/// internal records — so the amber typically appears only for a selected structure.
/// Public for testing.
Set<ViHeapObject> membersOf(ViHeapObject? o, Map<int, ViHeapObject> byId) {
  if (o == null) return const {};
  return {
    for (final oid in o.memberOids)
      if (byId[oid] case final m?
          when m.absBounds != null &&
              !identical(m, o) &&
              !_isScaffolding(m, byId))
        m,
  };
}

/// The **logic nodes/structures spatially inside** [structure] — the honest
/// "what this loop/case contains" signal (LabVIEW does not store an explicit
/// member list for the diagram, so containment is positional). Returns drawable
/// node/structure objects whose absolute bounds fall within [structure]'s bounds
/// (excluding itself and same-size overlaps); terminals/decorations are omitted
/// so the highlight reads as the contained logic. Public for testing.
Set<ViHeapObject> nodesWithin(
  ViHeapObject structure,
  Iterable<ViHeapObject> objects,
) {
  final structureBounds = structure.absBounds;
  if (structureBounds == null) return const {};
  final out = <ViHeapObject>{};
  for (final object in objects) {
    if (identical(object, structure)) continue;
    if (object.category != ViObjectKind.node &&
        object.category != ViObjectKind.structure)
      continue;
    final bounds = object.absBounds;
    if (bounds == null) continue;
    if (bounds.left < structureBounds.left ||
        bounds.top < structureBounds.top ||
        bounds.right > structureBounds.right ||
        bounds.bottom > structureBounds.bottom)
      continue;
    if (bounds.left == structureBounds.left &&
        bounds.top == structureBounds.top &&
        bounds.right == structureBounds.right &&
        bounds.bottom == structureBounds.bottom)
      continue;
    out.add(object);
  }
  return out;
}

/// The **drawable** objects of [diagram] — the layout layer the BD/FP view and
/// the [BdOracle] both paint: objects with a valid absolute rectangle, excluding
/// the scaffolding parts ([_isScaffolding]) and implausibly large boxes. Wires
/// (degenerate zero-area Manhattan runs) are kept via the wire exemption. Single
/// source of truth so the on-screen view and the off-screen oracle render the
/// same object set. Pure + public for the oracle and tests.
List<ViHeapObject> bdDrawableObjects(ViDiagram diagram) {
  final byId = diagram.byId;
  final childrenByOid = <int, List<ViHeapObject>>{};
  for (final object in diagram.objects) {
    if (object.parentOid != null) {
      (childrenByOid[object.parentOid!] ??= <ViHeapObject>[]).add(object);
    }
  }
  return [
    for (final object in diagram.objects)
      if (object.absBounds != null &&
          object.absBounds!.isValid &&
          (object.category == ViObjectKind.wire ||
              (object.absBounds!.width > 0 && object.absBounds!.height > 0)) &&
          object.absBounds!.width < 8000 &&
          object.absBounds!.height < 8000 &&
          // An inlined/malleable subVI splices its own connector-pane controls
          // into this heap; LabVIEW draws the subVI as one icon node, not those
          // internal controls, so they are not this diagram's top-level content.
          !_isInlinedSubViControl(object, byId, childrenByOid) &&
          !_isScaffolding(object, byId))
        object,
  ];
}

/// Resolves the **on-node subVI icons** for [diagram]: for each subVI-call node
/// (a [kSubViCallNodeCodes] class whose caption is a `.vi`/`.vim` filename), its
/// target VI is fetched by name via [loadByName] and that VI's richest legacy
/// icon (icl8 → icl4 → ICON) is decoded. Returns an [ViHeapObject.oid] → icon map
/// for the nodes that resolved; a node whose target is not found is absent from
/// the map and keeps the neutral connector-pane plate (the icon is never
/// guessed). [loadByName] maps a bare filename to that file's bytes (or null) —
/// the file I/O lives in the caller's callback so this stays pure and testable.
Map<int, ViLegacyIcon> resolveSubViIcons(
  ViDiagram diagram,
  Uint8List? Function(String fileName) loadByName,
) {
  final out = <int, ViLegacyIcon>{};
  final cache = <String, ViLegacyIcon?>{};
  for (final object in diagram.objects) {
    if (!kSubViCallNodeCodes.contains(object.kind)) continue;
    final name = object.label?.trim();
    if (name == null || !_isViFileName(name)) continue;
    final icon = cache.putIfAbsent(name, () {
      final bytes = loadByName(name);
      if (bytes == null) return null;
      try {
        return bestLegacyIcon(extractViImages(decodeSections(bytes)));
      } catch (_) {
        return null;
      }
    });
    if (icon != null) out[object.oid] = icon;
  }
  return out;
}

/// Whether [name] is a LabVIEW VI filename a subVI node targets (`.vi`/`.vim`).
bool _isViFileName(String name) {
  final lower = name.toLowerCase();
  return lower.endsWith('.vi') || lower.endsWith('.vim');
}

/// [drawable] sorted by nesting depth (shallowest first) — the paint order that
/// puts containers behind the nodes/controls they hold. Public for the oracle.
List<ViHeapObject> bdPaintOrder(
  List<ViHeapObject> drawable,
  Map<int, ViHeapObject> byId,
) =>
    [...drawable]
      ..sort((a, b) => _depthOf(a, byId).compareTo(_depthOf(b, byId)));

/// The content rectangle enclosing every object in [objects] (plus a fixed
/// margin) — the canvas extent the view fits to and the oracle rasterises.
/// [includeWires] is false for the view's zoom-to-fit (a misanchored wire run
/// must not blow up the envelope) and true when a caller wants the full extent.
/// Returns [Rect.zero] for an empty input. Pure + public.
Rect bdContentRect(
  Iterable<ViHeapObject> objects, {
  bool includeWires = true,
  int margin = 40,
}) {
  var minX = 1 << 30, minY = 1 << 30, maxX = -(1 << 30), maxY = -(1 << 30);
  var any = false;
  for (final object in objects) {
    if (!includeWires && object.category == ViObjectKind.wire) continue;
    final bounds = object.absBounds;
    if (bounds == null) continue;
    any = true;
    if (bounds.left < minX) minX = bounds.left;
    if (bounds.top < minY) minY = bounds.top;
    if (bounds.right > maxX) maxX = bounds.right;
    if (bounds.bottom > maxY) maxY = bounds.bottom;
  }
  if (!any) return Rect.zero;
  return Rect.fromLTRB(
    (minX - margin).toDouble(),
    (minY - margin).toDouble(),
    (maxX + margin).toDouble(),
    (maxY + margin).toDouble(),
  );
}

/// The nesting depth of [object] in the positional [byId] tree (root == 0),
/// capped so a malformed parent cycle cannot loop.
int _depthOf(ViHeapObject object, Map<int, ViHeapObject> byId) {
  var depth = 0;
  var cur = object;
  while (cur.parentOid != null && depth < 64) {
    final parent = byId[cur.parentOid];
    if (parent == null) break;
    cur = parent;
    depth++;
  }
  return depth;
}

/// The **static** diagram layer: grid, objects, and labels. Depends only on the
/// (memoized, stable) object list + origin, so a selection tap never repaints it
/// — the cheap [_OverlayPainter] handles highlights instead. Public so the
/// off-screen [BdOracle] rasterises with the exact same drawing as the view.
class BdDiagramPainter extends CustomPainter {
  BdDiagramPainter({
    required this.objects,
    required this.origin,
    this.wires = const [],
    this.subViIcons = const {},
  });

  final List<ViHeapObject> objects;
  final Offset origin;

  /// The decoded dataflow wires ([ViDiagram.wires], one per `0x17` signal),
  /// routed under the nodes/structures between their endpoint anchors. Empty
  /// leaves the diagram wire-free. See [_drawWires].
  final List<ViWire> wires;

  /// Resolved subVI-call node icons, keyed by [ViHeapObject.oid] — the 32×32
  /// icon of the VI a subVI-call node targets, loaded from that VI's own file
  /// (see [resolveSubViIcons]). A node with an entry here stamps the real icon on
  /// its plate; a node without one keeps the neutral connector-pane plate (the
  /// icon is never guessed).
  final Map<int, ViLegacyIcon> subViIcons;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = kBdCanvas);
    _drawDotGrid(canvas, size);
    // Dataflow wires paint first (over the canvas, under every structure/node)
    // so nodes and terminals always sit on top of the runs that reach them.
    _drawWires(canvas);

    Rect rectOf(ViHeapObject o) {
      final bounds = o.absBounds!;
      return Rect.fromLTRB(
        bounds.left - origin.dx,
        bounds.top - origin.dy,
        bounds.right - origin.dx,
        bounds.bottom - origin.dy,
      );
    }

    final structures = objects
        .where((o) => o.category == ViObjectKind.structure)
        .toList();
    final decorations = objects
        .where((o) => o.category == ViObjectKind.decoration)
        .toList();
    final wires = objects
        .where((o) => o.category == ViObjectKind.wire)
        .toList();
    final solids =
        objects
            .where(
              (o) =>
                  o.category != ViObjectKind.structure &&
                  o.category != ViObjectKind.decoration &&
                  o.category != ViObjectKind.wire,
            )
            .toList()
          ..sort(
            (a, b) => (b.absBounds!.width * b.absBounds!.height).compareTo(
              a.absBounds!.width * a.absBounds!.height,
            ),
          );

    for (final object in decorations) {
      // A decoration (coloured free-label backing, box, separator) is drawn in
      // its own decoded LabVIEW colour when one was recovered — decorations
      // paint first, under every node/wire — and otherwise a faint category
      // tint so its extent still reads without inventing a colour.
      final decoded =
          bdDecodedColor(object.bgRgb) ?? bdDecodedColor(object.contentRgb);
      canvas.drawRect(
        rectOf(object),
        decoded != null
            ? (Paint()..color = decoded)
            : (Paint()
                ..color = _kindColor(object.category).withValues(alpha: 0.10)),
      );
    }
    for (final object in structures) {
      // LabVIEW draws structures as a double-line frame; the badge tab at the
      // top-left names the construct (While/For/Case) like the original's
      // border furniture does. When the structure's own colour was decoded
      // (structColor — the LabVIEW structure greys, or the pale sequence/timed
      // tint) the frame is drawn in it, over a faint fill of the same colour so
      // the construct reads as itself; structures nest heavily, so the fill
      // stays light to avoid a muddy stack. Undecoded structures keep the
      // neutral category frame — no colour is guessed.
      final rect = rectOf(object);
      final structColor = bdDecodedColor(object.structRgb);
      final frame = structColor ?? _kindColor(ViObjectKind.structure);
      if (structColor != null) {
        canvas.drawRect(
          rect,
          Paint()..color = structColor.withValues(alpha: 0.12),
        );
      }
      canvas.drawRect(
        rect,
        Paint()
          ..color = frame
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0,
      );
      canvas.drawRect(
        rect.deflate(3),
        Paint()
          ..color = frame.withValues(alpha: 0.55)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0,
      );
    }
    // Wires: each 0x1d object is one Manhattan run; consecutive runs in heap
    // order that share an endpoint x get their implicit vertical connector.
    final wirePaint = Paint()
      ..color = _kindColor(ViObjectKind.wire)
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.square;
    Offset startOf(Rect r) => Offset(r.left, r.top);
    Offset endOf(Rect r) => Offset(r.right, r.bottom);
    Rect? previousWire;
    for (final object in wires) {
      final rect = rectOf(object);
      canvas.drawLine(startOf(rect), endOf(rect), wirePaint);
      if (previousWire != null) {
        final gapStart = endOf(previousWire);
        final gapEnd = startOf(rect);
        // implicit connector: same column (or row) continuation between runs
        final connects =
            (gapStart.dx - gapEnd.dx).abs() < 0.5 ||
            (gapStart.dy - gapEnd.dy).abs() < 0.5;
        if (connects && (gapStart - gapEnd).distance <= 400) {
          canvas.drawLine(gapStart, gapEnd, wirePaint);
        }
      }
      previousWire = rect;
    }

    for (final object in solids) {
      final rect = rectOf(object);
      // Free-text label parts (control caption 0x0a, case selector 0x95) are drawn
      // by LabVIEW as plain text on the canvas, not as a filled box — painting a
      // plate here would stamp a solid rectangle where the reference shows only
      // text (or nothing, when the caption is empty). The text pass below renders
      // any recovered caption.
      if (kBdTextLabelCodes.contains(object.kind)) continue;
      switch (object.category) {
        case ViObjectKind.terminal:
          // LabVIEW terminal: sharp rect, datatype fill, thin dark border, and
          // the inner double-border that marks a control/indicator terminal.
          // A recovered datatype drives the fill (blue int, orange float, …); an
          // unrecovered one stays a neutral grey rather than guessing a colour.
          final fill = object.typeKind == ViTypeKind.unknown
              ? kBdUnknownTerminalFill
              : labviewTypeColor(object.typeKind);
          canvas.drawRect(rect, Paint()..color = fill.withValues(alpha: 0.9));
          canvas.drawRect(
            rect,
            Paint()
              ..color = Colors.black.withValues(alpha: 0.65)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 0.8,
          );
          if (rect.width > 8 && rect.height > 8) {
            canvas.drawRect(
              rect.deflate(2),
              Paint()
                ..color = Colors.white.withValues(alpha: 0.7)
                ..style = PaintingStyle.stroke
                ..strokeWidth = 0.8,
            );
          }
        case ViObjectKind.node:
          // LabVIEW node icon plate: subVI calls get a light-grey connector-pane
          // plate, primitive/function nodes the pale-gold numeric-palette plate.
          // A raised bevel (light top/left, dark bottom/right) mimics the icon's
          // 3-D edge. When the subVI's real icon has been resolved from its own
          // file ([subViIcons]) it is stamped on the plate; otherwise no icon
          // glyph is drawn (it is never guessed).
          final isSubVi = kSubViCallNodeCodes.contains(object.kind);
          final icon = subViIcons[object.oid];
          if (icon != null) {
            paintLegacyIcon(canvas, icon, rect);
          } else {
            final fill = isSubVi ? kBdSubViNodeFill : kBdPrimitiveNodeFill;
            canvas.drawRect(rect, Paint()..color = fill);
            if (rect.width > 6 && rect.height > 6) {
              canvas.drawLine(
                rect.topLeft,
                rect.topRight,
                Paint()
                  ..color = Colors.white.withValues(alpha: 0.85)
                  ..strokeWidth = 1.0,
              );
              canvas.drawLine(
                rect.topLeft,
                rect.bottomLeft,
                Paint()
                  ..color = Colors.white.withValues(alpha: 0.85)
                  ..strokeWidth = 1.0,
              );
            }
          }
          canvas.drawRect(
            rect,
            Paint()
              ..color = isSubVi
                  ? const Color(0xFF8C8C8C)
                  : const Color(0xFF9A8730)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.0,
          );
        default:
          final rr = RRect.fromRectAndRadius(rect, const Radius.circular(2.5));
          // A control/indicator is filled with its decoded interior colour when
          // recovered (the field/background LabVIEW stored), else its neutral
          // category colour — never a guessed tint.
          final fill = bdFillColor(object) ?? _objectColor(object);
          canvas.drawRRect(rr, Paint()..color = fill.withValues(alpha: 0.92));
          canvas.drawRRect(
            rr,
            Paint()
              ..color = Colors.black.withValues(alpha: 0.5)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 0.8,
          );
      }
    }
    // Text pass: LabVIEW shows a structure's construct name on its frame and a
    // control/subVI's own caption, but not per-terminal datatype annotations.
    // Only a structure badge or a genuine recovered caption is drawn (the
    // wireframe's debug "name · type" suffix is omitted so the render stays as
    // close to LabVIEW's sparse on-canvas text as the decode allows).
    for (final object in objects) {
      // Standalone label sub-parts (0x0a/0x95) are not stamped on the canvas:
      // their bounds are often origin-pinned (a node's name label anchors at the
      // diagram origin, not above the node), so drawing them scatters mislocated
      // text. Their captions remain reachable through the inspector.
      if (kBdTextLabelCodes.contains(object.kind)) continue;
      final onFrame = object.category == ViObjectKind.structure;
      // A node's identity is carried by its icon plate (and a separate free
      // label), never by stamping its subVI-filename/function label inside the
      // icon box — LabVIEW draws no text there. A constant/terminal shows the
      // recovered literal value ([ViHeapObject.constText]) when one exists — e.g.
      // a string constant's `"report.txt"` — falling back to its recovered label;
      // a value that was not decoded renders no text (never guessed).
      final String? text;
      if (onFrame) {
        text = structureBadge(object);
      } else if (object.category == ViObjectKind.node) {
        text = null;
      } else {
        final literal = object.constText?.trim();
        final label = object.label?.trim();
        text = (literal != null && literal.isNotEmpty)
            ? literal
            : (label != null && label.isNotEmpty ? label : null);
      }
      if (text == null) continue;
      final rect = rectOf(object);
      if (rect.width < 26 || rect.height < 11) continue;
      // A caption/constant is inked in the object's decoded foreground colour
      // when one was recovered (fgColor is the LabVIEW text/line colour), else a
      // neutral near-black. A structure badge keeps its frame-chrome colour.
      final textColor = onFrame
          ? const Color(0xCC4A2E00)
          : (bdDecodedColor(object.fgRgb) ??
                Colors.black.withValues(alpha: 0.75));
      final tp = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            color: textColor,
            fontSize: 10,
            fontWeight: FontWeight.w400,
            fontFamily: 'Roboto',
          ),
        ),
        maxLines: 1,
        ellipsis: '…',
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: rect.width - 5);
      tp.paint(canvas, rect.topLeft + const Offset(3, 1));
    }
  }

  /// Routes each decoded [ViWire] as a Manhattan run between its endpoint anchor
  /// rectangles (index-aligned nearest-bounded-owner bounds). A wire is drawn in
  /// the neutral [kBdWireColor] unless an endpoint anchor coincides with a
  /// terminal whose datatype was recovered — then that terminal's LabVIEW colour
  /// is used ([bdWireColor]). Multi-endpoint (branch) wires route from the first
  /// endpoint to each other endpoint. The wire datatype itself is not decoded, so
  /// no per-wire colour is fabricated.
  void _drawWires(Canvas canvas) {
    if (wires.isEmpty) return;
    // Endpoint-anchor rectangle → recovered terminal colour, for honest tinting.
    final typedTerminalColors = <int, Color>{};
    for (final object in objects) {
      if (object.category != ViObjectKind.terminal) continue;
      if (object.typeKind == ViTypeKind.unknown) continue;
      final bounds = object.absBounds;
      if (bounds == null) continue;
      typedTerminalColors[_packRect(
        bounds.top,
        bounds.left,
        bounds.bottom,
        bounds.right,
      )] = labviewTypeColor(
        object.typeKind,
      );
    }
    for (final wire in wires) {
      final anchors = <Rect>[];
      for (final anchor in wire.endpointAnchors) {
        if (anchor == null) continue;
        anchors.add(
          Rect.fromLTRB(
            anchor.left - origin.dx,
            anchor.top - origin.dy,
            anchor.right - origin.dx,
            anchor.bottom - origin.dy,
          ),
        );
      }
      if (anchors.length < 2) continue;
      final paint = Paint()
        ..color = bdWireColor(wire, typedTerminalColors)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..strokeJoin = StrokeJoin.miter
        ..strokeCap = StrokeCap.butt;
      final source = anchors.first;
      for (var i = 1; i < anchors.length; i++) {
        final points = bdWireRoute(source, anchors[i]);
        final path = Path()..moveTo(points.first.dx, points.first.dy);
        for (final point in points.skip(1)) {
          path.lineTo(point.dx, point.dy);
        }
        canvas.drawPath(path, paint);
      }
    }
  }

  void _drawDotGrid(Canvas canvas, Size size) {
    const stepPx = 12.0;
    const maxDots = 20000;
    final cells = (size.width / stepPx) * (size.height / stepPx);
    final step = cells > maxDots ? stepPx * (cells / maxDots) : stepPx;
    // LabVIEW's alignment grid is a faint dot lattice on the near-white canvas;
    // kept very low-contrast so it reads as texture, not content.
    final dot = Paint()..color = kBdGridDot;
    for (var x = 0.0; x < size.width; x += step) {
      for (var y = 0.0; y < size.height; y += step) {
        canvas.drawCircle(Offset(x, y), 0.5, dot);
      }
    }
  }

  @override
  bool shouldRepaint(covariant BdDiagramPainter old) =>
      !identical(old.objects, objects) ||
      !identical(old.wires, wires) ||
      old.origin != origin;
}

/// The **overlay** layer: just the selection + declared-member highlight strokes.
/// A few `drawRect`s, so a selection tap repaints this (not the static object
/// layer). Shares the object→canvas mapping with [BdDiagramPainter].
class _OverlayPainter extends CustomPainter {
  _OverlayPainter({
    required this.origin,
    required this.selected,
    required this.members,
  });

  final Offset origin;
  final ViHeapObject? selected;
  final Set<ViHeapObject> members;

  Rect _rectOf(ViHeapObject o) {
    final bounds = o.absBounds!;
    return Rect.fromLTRB(
      bounds.left - origin.dx,
      bounds.top - origin.dy,
      bounds.right - origin.dx,
      bounds.bottom - origin.dy,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (members.isNotEmpty) {
      final mp = Paint()
        ..color = const Color(0xFFEF6C00)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;
      for (final member in members) {
        if (member.absBounds != null)
          canvas.drawRect(_rectOf(member).inflate(1.5), mp);
      }
    }
    final sel = selected;
    if (sel != null && sel.absBounds != null) {
      canvas.drawRect(
        _rectOf(sel).inflate(2.5),
        Paint()
          ..color = const Color(0xFF1565C0)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _OverlayPainter old) =>
      old.origin != origin ||
      !identical(old.selected, selected) ||
      old.members.length != members.length ||
      !old.members.containsAll(members);
}

/// A "label: value" detail row for the selected-object card (decoded semantics).
Widget _detail(String label, String value) => Padding(
  padding: const EdgeInsets.only(top: 3),
  child: RichText(
    maxLines: 3,
    overflow: TextOverflow.ellipsis,
    text: TextSpan(
      style: const TextStyle(fontSize: 12, color: Color(0xFF333333)),
      children: [
        TextSpan(
          text: '$label: ',
          style: const TextStyle(
            fontWeight: FontWeight.w600,
            color: Color(0xFF1565C0),
          ),
        ),
        TextSpan(text: value),
      ],
    ),
  ),
);

class _DetailsCard extends StatelessWidget {
  const _DetailsCard({
    required this.object,
    required this.onClose,
    this.members = const {},
  });
  final ViHeapObject object;
  final VoidCallback onClose;

  /// The logic objects this one contains (for a selected structure) — listed so
  /// the user can read "this loop/case contains these subVIs" textually.
  final Set<ViHeapObject> members;

  static String _contentLabel(ViHeapObject o) {
    final label = o.label?.trim();
    return (label != null && label.isNotEmpty) ? label : o.objectClass.label;
  }

  @override
  Widget build(BuildContext context) {
    final bounds = object.absBounds;
    final cls = object.objectClass;
    final conf = cls.confidence == ClassConfidence.confirmed
        ? ''
        : ' (${cls.confidence.name})';
    return Card(
      margin: const EdgeInsets.only(top: 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 14,
              height: 14,
              margin: const EdgeInsets.only(top: 2, right: 8),
              decoration: BoxDecoration(
                color: _objectColor(object),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    object.label ??
                        (cls != HeapObjectClass.unknown
                            ? cls.label
                            : switch (object.category) {
                                ViObjectKind.node => 'Node',
                                ViObjectKind.structure => 'Structure',
                                ViObjectKind.terminal => 'Terminal',
                                _ => cls.label,
                              }),
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${cls.label}$conf · class 0x${object.kind.toRadixString(16)} · oid ${object.oid}'
                    '${object.typeKind != ViTypeKind.unknown ? ' · type ${object.typeKind.name}' : ''}'
                    '${bounds != null ? ' · ${bounds.width}×${bounds.height} @(${bounds.left},${bounds.top})' : ''}'
                    '${object.parentOid != null ? ' · parent ${object.parentOid}' : ''}',
                    style: const TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                  if (object.items.isNotEmpty)
                    _detail(
                      'values',
                      object.items.take(8).join(', ') +
                          (object.items.length > 8 ? ', …' : ''),
                    ),
                  if (formatControlRange(object.controlMin, object.controlMax)
                      case final range?)
                    _detail('range', range),
                  if (object.helpText != null &&
                      stripHelpMarkup(object.helpText!).isNotEmpty)
                    _detail('help', stripHelpMarkup(object.helpText!)),
                  if (object.constText != null && object.constText!.isNotEmpty)
                    _detail('const', object.constText!),
                  if (members.isNotEmpty)
                    _detail(
                      'contains',
                      members.map(_contentLabel).take(10).join(', ') +
                          (members.length > 10 ? ', …' : ''),
                    ),
                ],
              ),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              onPressed: onClose,
              icon: const Icon(Icons.close, size: 18),
            ),
          ],
        ),
      ),
    );
  }
}

/// A compact, honest control-flow outline strip under the diagram toolbar:
/// structures grouped by catalog kind + the named subVI/function calls. Renders
/// nothing when the diagram has no structures or named calls.
class _BdOutline extends StatelessWidget {
  const _BdOutline({required this.outline, this.linkedSubVis = const []});
  final ({
    Map<String, int> structuresByKind,
    List<String> labeledNodes,
    int nodeCount,
    Map<ClassConfidence, int> confidence,
  })
  outline;

  /// The VI's sub-VI dependency names from the LIbd linker block — recoverable
  /// for ~82% of VIs; a linker dependency list, not a per-node call mapping.
  /// Shown separately from the heap-derived diagram-labeled nodes.
  final List<String> linkedSubVis;

  @override
  Widget build(BuildContext context) {
    final structs = outline.structuresByKind.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final labeledNodes = outline.labeledNodes;
    if (structs.isEmpty &&
        labeledNodes.isEmpty &&
        linkedSubVis.isEmpty &&
        outline.confidence.isEmpty) {
      return const SizedBox.shrink();
    }

    const muted = TextStyle(fontSize: 12, color: Colors.grey);
    Widget capped(String prefix, List<String> items) => Text(
      '$prefix: ' +
          items.take(20).join(', ') +
          (items.length > 20 ? ', … (+${items.length - 20})' : ''),
      style: muted,
    );
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (structs.isNotEmpty)
            Wrap(
              spacing: 10,
              runSpacing: 2,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text(
                  'Control flow:',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                ),
                for (final entry in structs)
                  Text('${entry.key} ×${entry.value}', style: muted),
              ],
            ),
          if (linkedSubVis.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: capped(
                'Linked subVIs (${linkedSubVis.length})',
                linkedSubVis,
              ),
            ),
          if (labeledNodes.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: capped(
                'Diagram-labeled nodes (${labeledNodes.length})',
                labeledNodes,
              ),
            ),
          if (outline.confidence.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Wrap(
                spacing: 10,
                runSpacing: 2,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text(
                    'Class confidence:',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                  Text(
                    '${outline.confidence[ClassConfidence.confirmed] ?? 0} confirmed',
                    style: muted,
                  ),
                  Text(
                    '${outline.confidence[ClassConfidence.inferred] ?? 0} inferred',
                    style: muted,
                  ),
                  Text(
                    '${outline.confidence[ClassConfidence.kindOnly] ?? 0} guessed',
                    style: muted,
                  ),
                ],
              ),
            ),
            const Text(
              '(how solid each object’s classification is — not dataflow / execution order)',
              style: TextStyle(
                fontSize: 11,
                color: Colors.grey,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The VI-identity image strip shown above the block diagram: the VI's own icon
/// (richest available depth) and any embedded diagram PNGs (`MNGI`/`DSIM`), each
/// captioned with its source tag. Scope: this is *this* VI's icon (what a caller
/// renders on a subVI node); the icons of the subVIs this diagram *calls* are
/// stamped on their nodes instead when their files resolve (see
/// [ViDiagramView.subViIconLoader]).
class _ViImageStrip extends StatelessWidget {
  const _ViImageStrip(this.images);
  final ViImages images;

  /// The single richest-depth icon (icl8 → icl4 → ICON), or null.
  EmbeddedLegacyIcon? get _bestIcon {
    const order = {'icl8': 0, 'icl4': 1, 'ICON': 2};
    if (images.icons.isEmpty) return null;
    return ([
      ...images.icons,
    ]..sort((a, b) => (order[a.tag] ?? 9).compareTo(order[b.tag] ?? 9))).first;
  }

  @override
  Widget build(BuildContext context) {
    final icon = _bestIcon;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          if (icon != null)
            _tile(
              'VI icon (${icon.tag})',
              CustomPaint(
                size: const Size(36, 36),
                painter: LegacyIconPainter(icon.icon),
              ),
              tooltip:
                  "This VI's own 32×32 icon — what a caller's subVI node shows "
                  'for it.',
            ),
          for (final png in images.pngs.take(4))
            _tile(
              '${png.tag} ${png.width}×${png.height}',
              Image.memory(
                png.bytes,
                width: 36,
                height: 36,
                fit: BoxFit.contain,
                filterQuality: FilterQuality.none,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) =>
                    const Icon(Icons.broken_image_outlined, size: 20),
              ),
            ),
          const Expanded(
            child: Padding(
              padding: EdgeInsets.only(left: 8),
              child: Text(
                "The VI's own recovered images. A subVI-call node on the diagram "
                "shows the called VI's icon when that file resolves.",
                style: TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tile(String caption, Widget child, {String? tooltip}) {
    final tile = Padding(
      padding: const EdgeInsets.only(right: 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: const Color(0xFFFAFAFA),
              border: Border.all(color: const Color(0xFFBDBDBD)),
              borderRadius: BorderRadius.circular(3),
            ),
            child: child,
          ),
          const SizedBox(height: 2),
          Text(
            caption,
            style: const TextStyle(fontSize: 9, color: Colors.grey),
          ),
        ],
      ),
    );
    return tooltip == null ? tile : Tooltip(message: tooltip, child: tile);
  }
}

class _LegendChip extends StatelessWidget {
  const _LegendChip({required this.color, required this.label});
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 11,
        height: 11,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
      const SizedBox(width: 4),
      Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
    ],
  );
}
