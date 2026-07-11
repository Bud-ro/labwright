import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart' show AssetManifest, rootBundle;

import 'package:flutter/material.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import 'images_view.dart';
import 'prim_icon_catalog.dart';
import 'span_annotations.dart';

/// A read-only **layout view** of a decoded VI block diagram, rendered to a
/// faithful, LabVIEW-like canvas: every recovered object drawn at its absolute
/// coordinates, with nesting-aware z-order, type-faithful terminal colors,
/// structure frames, labels, click-to-inspect, pan/zoom and auto-fit.
///
/// Backed entirely by the clean-room `labwright_rsrc_parse` decode
/// (`buildViModel` → `blockDiagrams`/`frontPanelDiagrams`). Honest by
/// construction: only objects with recovered absolute bounds are drawn.
/// Dataflow wires are drawn from the decoded signal (`0x17`) endpoint binding
/// ([ViDiagram.wires]) — routed as synthesized right-angle runs between each
/// endpoint's anchor (the nearest bounded owner of the endpoint; LabVIEW does
/// not persist wire path geometry) — but the wire **datatype is not decoded**, so
/// runs are a
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
    this.subViIconResolver,
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
  /// targets' icons when a [subViIconResolver] resolves the called VIs.)
  /// Empty by default.
  final ViImages viImages;

  /// Optional icon resolver used to stamp each **subVI-call node** with the
  /// icon of the VI it targets: given the set of `.vi`/`.vim` filenames this
  /// diagram calls ([subViWantedNames]), it returns a `filename → icon` map
  /// (see `resolveSubViIconsFor` — linker-path resolution, so it completes in
  /// moments). Only meaningful for the block diagram (subVI nodes live there);
  /// a node whose target is not found keeps the neutral connector-pane plate.
  /// Null (the default) draws no on-node icons.
  final Future<Map<String, ViLegacyIcon>> Function(Set<String> wantedNames)?
  subViIconResolver;

  @override
  State<ViDiagramView> createState() => _ViDiagramViewState();
}

class _ViDiagramViewState extends State<ViDiagramView> {
  final _transform = TransformationController();

  /// The zoom the diagram layer is currently rasterised at. Pan/zoom scales
  /// the cached layer (cheap, transiently soft); when a gesture settles at a
  /// meaningfully different zoom the layer re-rasterises crisp at it.
  double _anchorScale = 1;

  void _reanchor() {
    final scale = _transform.value.getMaxScaleOnAxis();
    if (scale / _anchorScale > 1.25 || scale / _anchorScale < 0.8) {
      setState(() => _anchorScale = scale.clamp(0.02, 16.0));
    }
  }

  ViHeapObject? _selected;
  Set<ViHeapObject> _members = const {};
  Size? _lastViewport;
  Rect? _lastContent;
  bool _fitted = false;

  /// Whether the recovery-detail shelf (images / legend / outline) is shown
  /// beside the diagram.
  bool _shelfOpen = true;

  late final ViDiagram? _diagram = _largestDiagram(widget.diagrams);
  late final Map<int, ViHeapObject> _byId = _diagram?.byId ?? const {};
  // SubVI-call node icons resolved from the called VIs' own files (block diagram
  // only). Populated asynchronously once the project-index loader resolves (see
  // [_resolveIcons]); empty until then, and when no loader is supplied.
  Map<int, ViLegacyIcon> _subViIcons = const {};
  Map<int, ui.Image> _primIcons = const {};
  late final List<ViHeapObject> _drawable = _diagram == null
      ? const []
      : bdDrawableObjects(_diagram);
  late final List<ViHeapObject> _ordered = bdPaintOrder(_drawable, _byId);
  // Decoded dataflow wires (empty on a front-panel heap). Drawn under the nodes.
  late final List<ViWire> _wires = switch (_diagram) {
    null => const [],
    final diagram => bdVisibleWires(diagram),
  };
  late final Map<int, List<({HeapRect box, int bmp})>> _structureTerminals =
      switch (_diagram) {
        null => const {},
        final diagram => bdStructureTerminals(diagram),
      };
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
  void initState() {
    super.initState();
    _resolveIcons();
    loadPrimIcons().then((icons) {
      if (mounted && icons.isNotEmpty) setState(() => _primIcons = icons);
    });
  }

  /// Resolves the subVI-call node icons (one fast await — linker-path
  /// resolution needs no searching) and repaints once. A no-op on the front
  /// panel, without a resolver, or when the diagram calls no subVIs.
  Future<void> _resolveIcons() async {
    final diagram = _diagram;
    final resolver = widget.subViIconResolver;
    if (diagram == null || widget.isFrontPanel || resolver == null) return;
    final wanted = subViWantedNames(diagram);
    if (wanted.isEmpty) return;
    final byName = await resolver(wanted);
    if (!mounted || byName.isEmpty) return;
    final icons = <int, ViLegacyIcon>{};
    for (final object in diagram.objects) {
      if (!kSubViCallNodeCodes.contains(object.kind)) continue;
      final icon = byName[object.label?.trim()];
      if (icon != null) icons[object.oid] = icon;
    }
    if (icons.isNotEmpty) setState(() => _subViIcons = icons);
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
        _toolbar(_drawable.length),
        const SizedBox(height: 4),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _diagramStack(content, ordered)),
              if (_shelfOpen) _shelf(),
            ],
          ),
        ),
      ],
    );
  }

  /// The recovery-detail shelf beside the diagram: the VI's own images, the
  /// object-kind legend, and the outline summaries (control flow / recovered
  /// features / class confidence / linked subVIs) — off the diagram's vertical
  /// space so the canvas gets the room.
  Widget _shelf() => SizedBox(
    width: 250,
    child: ListView(
      padding: const EdgeInsets.only(left: 8),
      children: [
        if (!widget.isFrontPanel && !widget.viImages.isEmpty) ...[
          _ViImageStrip(widget.viImages),
          const SizedBox(height: 8),
        ],
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final entry in _counts.entries)
              _LegendChip(
                color: _kindColor(entry.key),
                label: '${entry.key.name} ${entry.value}',
              ),
          ],
        ),
        const SizedBox(height: 8),
        _BdOutline(
          outline: computeBdOutline(_drawable),
          linkedSubVis: widget.subViNames,
        ),
      ],
    ),
  );

  Widget _diagramStack(Rect content, List<ViHeapObject> ordered) {
    return Stack(
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
                WidgetsBinding.instance.addPostFrameCallback((_) => _fit());
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
                    onInteractionEnd: (_) => _reanchor(),
                    // The boundary isolates the diagram into its own
                    // layer, so pan/zoom only re-composites the cached
                    // painting instead of re-running the whole painter
                    // (per-label text layout included) every frame. The
                    // layer rasterises at the SETTLED zoom (_anchorScale,
                    // via _reanchor) and the Transform.scale cancels that
                    // factor, so at rest the compositor shows the layer 1:1
                    // — vector-crisp at any zoom — and only mid-gesture
                    // scaling stretches a stale raster.
                    child: Transform.scale(
                      scale: 1 / _anchorScale,
                      alignment: Alignment.topLeft,
                      child: RepaintBoundary(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTapDown: (d) => _selectAt(
                            d.localPosition / _anchorScale,
                            ordered,
                            content,
                          ),
                          child: CustomPaint(
                            size: Size(
                              content.width * _anchorScale,
                              content.height * _anchorScale,
                            ),
                            painter: BdDiagramPainter(
                              objects: ordered,
                              origin: content.topLeft,
                              wires: _wires,
                              subViIcons: _subViIcons,
                              primIcons: _primIcons,
                              iconFilterQuality: FilterQuality.low,
                              canvasScale: _anchorScale,
                              structureTerminals: _structureTerminals,
                            ),
                            foregroundPainter: _OverlayPainter(
                              origin: content.topLeft,
                              selected: _selected,
                              members: _members,
                              canvasScale: _anchorScale,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        if (_selected != null)
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
      ],
    );
  }

  Widget _toolbar(int objectCount) => Wrap(
    spacing: 12,
    runSpacing: 4,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      Text(
        '$objectCount objects',
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
      IconButton(
        tooltip: 'Fit to view',
        onPressed: _fit,
        icon: const Icon(Icons.fit_screen),
      ),
      IconButton(
        // The shelf is the right-hand panel; the icon reads as that panel being
        // filled (open) or empty (hidden).
        tooltip: _shelfOpen ? 'Hide details panel' : 'Show details panel',
        onPressed: () => setState(() => _shelfOpen = !_shelfOpen),
        icon: Icon(
          _shelfOpen ? Icons.view_sidebar : Icons.view_sidebar_outlined,
        ),
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
        if (!primIconHit(object, x, y)) continue;
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
    // The layer rasterises at the fitted zoom from the first frame.
    setState(() => _anchorScale = scale.clamp(0.02, 16.0));
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
  ViTypeKind.string => const Color(0xFFDD00DD),
  ViTypeKind.boolean => const Color(0xFF2A8A2A),
  ViTypeKind.cluster => const Color(0xFF8A6B3A),
  ViTypeKind.array => const Color(0xFF4A6BB0),
  ViTypeKind.refnum => const Color(0xFF3A8A8A),
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
  // Integer/enum blue and string magenta are sampled from LabVIEW's own
  // snippet renders (terminal borders (0,0,255) and (255,0,255)); boolean
  // green matches the decoded constant foreground (0x007F00).
  ViTypeKind.numericInt => const Color(0xFF0000FF),
  ViTypeKind.enumRing => const Color(0xFF0000FF),
  ViTypeKind.string => const Color(0xFFFF00FF),
  ViTypeKind.boolean => const Color(0xFF007F00),
  ViTypeKind.path => const Color(0xFF669900),
  ViTypeKind.clnNode => const Color(0xFFE8C547),
  // Cluster/array/refnum borders are not yet colour-sampled from a
  // reference; they keep the neutral grey rather than a guessed hue.
  ViTypeKind.cluster ||
  ViTypeKind.array ||
  ViTypeKind.refnum => const Color(0xFF8A8A8A),
  ViTypeKind.unknown => const Color(0xFF8A8A8A),
};

/// The block-diagram canvas fill — pure white. The render and the oracle
/// letterbox/registration share it so the empty margin matches a white reference
/// screenshot instead of reading as a grey plate.
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

/// Fill for a non-subVI node plate — a pale gold. A generic default for every
/// node that is not a recognised subVI call (the specific primitive is not
/// decoded, so one neutral plate colour is used rather than a per-function one).
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

/// The signal's **stored** route (its decoded `0x1e7` table) as absolute
/// points from [source] to [sink]: segments alternate axes starting
/// horizontal from the source connection point (anchor centre), the first
/// segment aims toward the sink, interior-joint signs come from the table,
/// and the trailing segment(s) close on the sink connection point (the
/// stored route lands within the destination anchor for nearly all
/// two-endpoint signals — census on [ViWireRoute]; the square-in below
/// covers the miss tail). The first point is clipped to the source edge so
/// the stroke does not cross the source icon. Null when the table's
/// segments are empty or a sign byte is missing for an interior joint.
/// Pure + public for testing.
List<Offset>? bdStoredWireRoute(Rect source, Rect sink, ViWireRoute route) {
  final lengths = route.segmentLengths;
  final signs = route.jointSigns;
  if (lengths.isEmpty) return null;
  var x = source.center.dx;
  var y = source.center.dy;
  final points = <Offset>[Offset(x, y)];
  var horiz = true;
  for (var i = 0; i < lengths.length; i++) {
    final double sign;
    if (i == 0) {
      sign = sink.center.dx >= source.center.dx ? 1 : -1;
    } else {
      if (i - 1 >= signs.length) return null;
      sign = signs[i - 1].toDouble();
    }
    if (horiz) {
      x += sign * lengths[i];
    } else {
      y += sign * lengths[i];
    }
    points.add(Offset(x, y));
    horiz = !horiz;
  }
  // Close along the alternated axis: the stored route already fixed the
  // perpendicular coordinate (that IS the sink connection row/column), so
  // the trailing segment just runs to the sink. Square in with one extra
  // elbow only when the landing misses the sink rect entirely (the rare
  // fit-miss tail keeps an orthogonal path rather than a diagonal).
  if (horiz) {
    if ((sink.center.dx - x).abs() > 0.5) points.add(Offset(sink.center.dx, y));
    if (y < sink.top || y > sink.bottom) {
      points.add(Offset(sink.center.dx, sink.center.dy));
    }
  } else {
    if ((sink.center.dy - y).abs() > 0.5) points.add(Offset(x, sink.center.dy));
    if (x < sink.left || x > sink.right) {
      points.add(Offset(sink.center.dx, sink.center.dy));
    }
  }
  // Clip the leading run to the source box edge (LabVIEW stops the stroke at
  // the icon; the stored length still measures from the connection point).
  if (points.length >= 2 && points[1].dy == points[0].dy) {
    final rightward = points[1].dx >= points[0].dx;
    final edge = rightward ? source.right : source.left;
    if ((rightward && points[1].dx > edge) ||
        (!rightward && points[1].dx < edge)) {
      points[0] = Offset(edge, points[0].dy);
    }
  }
  return points;
}

/// The short operator glyph drawn on a primitive node's plate for a decoded
/// [PrimOp] — the recognisable core of LabVIEW's icon art (the `+` of Add,
/// the type name of a conversion). Null for ops whose icon has no natural
/// short reading; the plate then stays blank rather than guessing art.
String? primOpGlyph(PrimOp? op) => switch (op) {
  PrimOp.add => '+',
  PrimOp.subtract => '−',
  PrimOp.multiply => '×',
  PrimOp.divide => '÷',
  PrimOp.increment => '+1',
  PrimOp.decrement => '−1',
  PrimOp.squareRoot => 'sqrt',
  PrimOp.and => '&',
  PrimOp.or => 'or',
  PrimOp.exclusiveOr => 'xor',
  PrimOp.not => '!',
  PrimOp.equal => '=',
  PrimOp.notEqual => '≠',
  PrimOp.greater => '>',
  PrimOp.less => '<',
  PrimOp.equalToZero => '=0',
  PrimOp.notEqualToZero => '≠0',
  PrimOp.greaterThanZero => '>0',
  PrimOp.lessThanZero => '<0',
  PrimOp.greaterOrEqualToZero => '≥0',
  PrimOp.lessOrEqualToZero => '≤0',
  PrimOp.select => 'sel',
  PrimOp.toByteInteger => 'I8',
  PrimOp.toWordInteger => 'I16',
  PrimOp.toLongInteger => 'I32',
  PrimOp.toUnsignedByteInteger => 'U8',
  PrimOp.toUnsignedWordInteger => 'U16',
  PrimOp.toUnsignedLongInteger => 'U32',
  PrimOp.toSinglePrecisionFloat => 'SGL',
  PrimOp.toDoublePrecisionFloat => 'DBL',
  PrimOp.typeCast => 'cast',
  PrimOp.logicalShift => 'shl',
  PrimOp.rotateLeftWithCarry => 'rlc',
  PrimOp.rotateRightWithCarry => 'rrc',
  PrimOp.arraySize => 'siz',
  PrimOp.buildPath => 'pth',
  PrimOp.stringLength => 'len',
  _ => null,
};

/// A synthesized Manhattan (right-angle) route between two endpoint-anchor
/// rectangles, as an ordered polyline in the anchors' own coordinate space —
/// the fallback for wires whose stored `0x1e7` route is not decoded
/// (branching junction tables) or absent.
///
/// When one endpoint's horizontal centre-line crosses the other's vertical
/// span, the run is a single **straight horizontal** at that centre-line,
/// entering the partner's facing edge at that y — the common LabVIEW shape of
/// a terminal wired level into a structure border or an aligned partner
/// (routing to the partner's own midpoint instead dove a level wire to the
/// centre of a tall loop frame). When both centre-lines cross (nested or
/// overlapping spans), the smaller endpoint — the terminal-like one whose
/// centre a LabVIEW wire actually leaves from — sets the y. Otherwise the
/// route leaves [source] on the side facing [sink], turns at the mid-x column,
/// and enters [sink] on its facing side (an H–V–H elbow). Pure + public so
/// the routing is unit-testable independent of the canvas.
List<Offset> bdWireRoute(Rect source, Rect sink) {
  final sinkRight = sink.center.dx >= source.center.dx;
  final startX = sinkRight ? source.right : source.left;
  final endX = sinkRight ? sink.left : sink.right;
  final sourceLevel =
      source.center.dy > sink.top && source.center.dy < sink.bottom;
  final sinkLevel =
      sink.center.dy > source.top && sink.center.dy < source.bottom;
  if (sourceLevel || sinkLevel) {
    final double y;
    if (sourceLevel && sinkLevel) {
      y = (source.height <= sink.height ? source : sink).center.dy;
    } else {
      y = sourceLevel ? source.center.dy : sink.center.dy;
    }
    return [Offset(startX, y), Offset(endX, y)];
  }
  final start = Offset(startX, source.center.dy);
  final end = Offset(endX, sink.center.dy);
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

/// Class codes LabVIEW draws as **free text** on the canvas: the control
/// caption / free-label (`0x0a`) and the case-selector label (`0x95`). The
/// painter renders their recovered caption text within the label's own bounds,
/// backed by a bordered fill only when the label's background colour was
/// decoded (a comment's yellow backing) — never a guessed box.
const Set<int> kBdTextLabelCodes = {0x0a, 0x95};

/// The text to show on a node box: its recovered name when present (e.g. a subVI
/// filename), otherwise an honest class HINT derived from its classification
/// (`primitive`, `growable`, `Call Library node`) so the box isn't blank.
/// `isHint` is true for the class-derived fallback so it can be styled apart from
/// a real name. Pure + public for testing.
({String text, bool isHint}) nodeDisplayLabel(ViHeapObject object) {
  final label = object.label?.trim();
  if (label != null && label.isNotEmpty) return (text: label, isHint: false);
  final cls = object.objectClass.label;
  final match = RegExp(r'^Node \((.+)\)$').firstMatch(cls);
  return (text: match != null ? match.group(1)! : cls, isHint: true);
}

/// The badge text for a structure object — taken from the videcode CLASS CATALOG
/// ([HeapObjectClass.label]) rather than a hand-maintained table, so the inspector
/// can't drift from / contradict the catalog's honest, hedged names (e.g. 0x53 =
/// "Loop (BD) / container (FP)", 0x2c = "Case structure", 0x20 = "For loop").
/// Falls back to "Structure" only when the class is uncatalogued. Public for
/// testing + shared with the wireframe annotation.
String structureBadge(ViHeapObject object) =>
    object.objectClass == HeapObjectClass.unknown
    ? 'Structure'
    : object.objectClass.label;

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
/// the total node count. A text summary of the diagram's control-flow shape; it
/// lists no dataflow edges (those are drawn on the canvas from the decoded
/// signal endpoints, see [ViDiagramView]). Pure + public so it is unit-testable.
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

/// The oids of every object inside a **hidden frame** of a stacked
/// multi-frame structure (a case/event structure holds one `0x1b` frame per
/// case, all at overlapping coordinates, but LabVIEW draws only the visible
/// one — drawing them all stacks every case's contents on top of each other).
///
/// For the stacked structure kinds ([kMultiFrameStructureKinds]) the decoded
/// [ViHeapObject.visibleFrameIndex] decides which frame draws. Elsewhere —
/// and for the rare out-of-range index — the content heuristic remains: the
/// frame with the most content positioned inside the structure's own box is
/// kept (the frames LabVIEW is not showing compose partly outside it or
/// hold less in-box content), and structures whose frames' in-box contents
/// are pairwise disjoint (a flat sequence tiling its frames side by side)
/// keep every frame. Pure + public for testing; shared by
/// [bdDrawableObjects] and [bdVisibleWires].
Set<int> bdHiddenFrameOids(ViDiagram diagram) {
  final childrenByOid = bdChildrenByOid(diagram);
  final hidden = <int>{};

  void hideSubtree(ViHeapObject root) {
    hidden.add(root.oid);
    for (final child in childrenByOid[root.oid] ?? const <ViHeapObject>[]) {
      hideSubtree(child);
    }
  }

  for (final structure in diagram.objects) {
    if (structure.category != ViObjectKind.structure) continue;
    final box = structure.absBounds;
    if (box == null || box.width <= 0 || box.height <= 0) continue;
    final frames = (childrenByOid[structure.oid] ?? const <ViHeapObject>[])
        .where((c) => c.kind == 0x1b)
        .toList();
    if (frames.length < 2) continue;

    // The stored display index decides outright for the stacked structure
    // kinds — including an absent record, which is render-verified to mean
    // frame 0. Out-of-range (one corpus outlier) falls through to the
    // content heuristic below. Flat sequences never reach here: they are a
    // different class (0xca) whose 0x121 subframes fail the 0x1b filter.
    if (kMultiFrameStructureKinds.contains(structure.kind)) {
      final visible = structure.visibleFrameIndex;
      if (visible < frames.length) {
        for (var i = 0; i < frames.length; i++) {
          if (i != visible) hideSubtree(frames[i]);
        }
        continue;
      }
    }

    // Per frame: how much positioned content sits inside the structure's box
    // (slack for tunnels/labels on the border), and that content's bbox.
    final inBoxCounts = <int>[];
    final inBoxBoxes = <Rect?>[];
    for (final frame in frames) {
      var count = 0;
      var l = 1 << 30, t = 1 << 30, r = -(1 << 30), b = -(1 << 30);
      void visit(ViHeapObject o) {
        final bb = o.absBounds;
        if (bb != null && bb.width > 0 && bb.height > 0) {
          final cx = (bb.left + bb.right) / 2, cy = (bb.top + bb.bottom) / 2;
          if (cx >= box.left - 8 &&
              cx <= box.right + 8 &&
              cy >= box.top - 8 &&
              cy <= box.bottom + 8) {
            count++;
            if (bb.left < l) l = bb.left;
            if (bb.top < t) t = bb.top;
            if (bb.right > r) r = bb.right;
            if (bb.bottom > b) b = bb.bottom;
          }
        }
        for (final child in childrenByOid[o.oid] ?? const <ViHeapObject>[]) {
          visit(child);
        }
      }

      visit(frame);
      inBoxCounts.add(count);
      inBoxBoxes.add(
        count == 0
            ? null
            : Rect.fromLTRB(
                l.toDouble(),
                t.toDouble(),
                r.toDouble(),
                b.toDouble(),
              ),
      );
    }
    final candidates = [
      for (var i = 0; i < frames.length; i++)
        if (inBoxCounts[i] > 0) i,
    ];
    if (candidates.length < 2) {
      // One (or no) frame holds in-box content: LabVIEW shows exactly one
      // frame, so any other frame's content is not on this canvas.
      for (var i = 0; i < frames.length; i++) {
        if (candidates.isEmpty ? i > 0 : i != candidates.single) {
          hideSubtree(frames[i]);
        }
      }
      continue;
    }
    // Disjoint in-box contents = side-by-side frames (flat sequence): keep all.
    var overlapping = false;
    for (var i = 0; i < candidates.length && !overlapping; i++) {
      for (var j = i + 1; j < candidates.length; j++) {
        final a = inBoxBoxes[candidates[i]]!, b = inBoxBoxes[candidates[j]]!;
        final inter = a.intersect(b);
        if (inter.width <= 0 || inter.height <= 0) continue;
        final minArea = math.min(a.width * a.height, b.width * b.height);
        if (minArea > 0 && inter.width * inter.height / minArea > 0.2) {
          overlapping = true;
          break;
        }
      }
    }
    if (!overlapping) continue;
    var visible = candidates.first;
    for (final i in candidates) {
      if (inBoxCounts[i] > inBoxCounts[visible]) visible = i;
    }
    for (var i = 0; i < frames.length; i++) {
      if (i != visible) hideSubtree(frames[i]);
    }
  }
  return hidden;
}

/// [diagram]'s dataflow wires prepared for drawing: signals living in a
/// hidden frame of a stacked multi-frame structure are dropped (a hidden
/// case's wires must not draw across the visible one, see
/// [bdHiddenFrameOids]), and an endpoint whose anchor did not resolve to a
/// positioned box (a structure tunnel — its border-crossing point carries no
/// decoded bounds) is re-anchored to the endpoint's nearest drawable bounded
/// ancestor, so the run reaches the structure's border the way LabVIEW's
/// tunnel wires do. A leg that only resolves to the diagram root stays
/// unanchored (drawing to the canvas edge would be wrong), and a wire whose
/// remaining anchors collapse onto one identical box is dropped as
/// degenerate.
List<ViWire> bdVisibleWires(ViDiagram diagram) {
  final hidden = bdHiddenFrameOids(diagram)
    ..addAll(bdInlinedInstanceOids(diagram));
  final byId = diagram.byId;

  HeapRect? reanchor(int endpointOid) {
    var cur = byId[endpointOid];
    var depth = 0;
    while (cur != null && depth++ < 64) {
      final b = cur.absBounds;
      if (!hidden.contains(cur.oid) &&
          b != null &&
          b.width > 0 &&
          b.height > 0) {
        // The diagram root's box is the whole canvas — not an anchor.
        return cur.parentOid == null ? null : b;
      }
      cur = cur.parentOid == null ? null : byId[cur.parentOid!];
    }
    return null;
  }

  final out = <ViWire>[];
  for (final wire in diagram.wires) {
    if (hidden.contains(wire.signalOid)) continue;
    var patched = false;
    var sourcePatched = false;
    final anchors = <HeapRect?>[];
    for (var i = 0; i < wire.endpointAnchors.length; i++) {
      final anchor = wire.endpointAnchors[i];
      if (anchor != null && anchor.width > 0 && anchor.height > 0) {
        anchors.add(anchor);
        continue;
      }
      final resolved = reanchor(wire.endpointOids[i]);
      anchors.add(resolved);
      if (resolved != null) {
        patched = true;
        if (i == 0) sourcePatched = true;
      }
    }
    final boxes = anchors.whereType<HeapRect>().toList();
    if (boxes.length < 2) continue;
    // All legs on one identical box: nothing to route. (HeapRect has no
    // operator==, so compare edges.)
    final first = boxes.first;
    if (boxes.every(
      (b) =>
          b.left == first.left &&
          b.top == first.top &&
          b.right == first.right &&
          b.bottom == first.bottom,
    )) {
      continue;
    }
    out.add(
      patched
          ? ViWire(
              signalOid: wire.signalOid,
              endpointOids: wire.endpointOids,
              endpointAnchors: anchors,
              // The stored route replays from endpoint 0's connection point:
              // it survives a re-anchored SINK (the route already targets the
              // border the sink was re-anchored to) but not a re-anchored
              // source, whose original connection point is what the lengths
              // measure from.
              route: sourcePatched ? null : wire.route,
            )
          : wire,
    );
  }
  return out;
}

/// [diagram]'s parent-oid → children map — the walk index every grouping
/// helper below shares.
Map<int, List<ViHeapObject>> bdChildrenByOid(ViDiagram diagram) {
  final childrenByOid = <int, List<ViHeapObject>>{};
  for (final object in diagram.objects) {
    if (object.parentOid != null) {
      (childrenByOid[object.parentOid!] ??= <ViHeapObject>[]).add(object);
    }
  }
  return childrenByOid;
}

/// The oids of every object inside an **inlined sub-VI instance** (`0x105`):
/// an express/inlined call splices the called VI's whole internal diagram
/// into this heap under the instance node, in the sub-VI's own coordinate
/// space (its subtree re-bases toward the diagram origin). LabVIEW draws
/// only the instance node — which carries proper caller-space bounds — never
/// the internals, so the subtree is excluded from the drawable set and the
/// wire list.
Set<int> bdInlinedInstanceOids(ViDiagram diagram) {
  final childrenByOid = bdChildrenByOid(diagram);
  final out = <int>{};
  void collect(ViHeapObject root) {
    for (final child in childrenByOid[root.oid] ?? const <ViHeapObject>[]) {
      if (out.add(child.oid)) collect(child);
    }
  }

  for (final object in diagram.objects) {
    if (object.kind == 0x105) collect(object);
  }
  return out;
}

/// Per structure oid, the **modeled structure terminals** of [diagram]: a
/// loop's iteration/count/conditional terminals, its shift registers, and a
/// case's selector tunnel — each with its decoded frame-relative box
/// ([ViHeapObject.termBounds]) and glyph selector ([ViHeapObject.termBmp]:
/// `i`→1, `N`→2, stop→192, shift registers→3/4, case selector→5). Terminals
/// without a decoded box are omitted (nothing is placed by guesswork).
Map<int, List<({HeapRect box, int bmp})>> bdStructureTerminals(
  ViDiagram diagram,
) {
  final byId = diagram.byId;
  final out = <int, List<({HeapRect box, int bmp})>>{};
  // A for loop's N part (the 0x15 parent of the bmp-2 carrier) hides the
  // N/i corner pair when its objFlags clear bit 0x8000 — render-verified
  // both ways on crc8's four loops (571 hides both with the bit clear;
  // 86/164/3042 show both with it set).
  final hiddenCountLoops = <int>{};
  for (final object in diagram.objects) {
    if (object.termBmp != 2) continue;
    final part = byId[object.parentOid ?? -1];
    if (part == null || part.kind != 0x15) continue;
    if (((part.objFlags ?? 0) & 0x8000) != 0) continue;
    var cur = byId[part.parentOid ?? -1];
    var depth = 0;
    while (cur != null &&
        cur.category != ViObjectKind.structure &&
        depth++ < 8) {
      cur = byId[cur.parentOid ?? -1];
    }
    if (cur != null) hiddenCountLoops.add(cur.oid);
  }
  for (final object in diagram.objects) {
    final box = object.termBounds;
    final bmp = object.termBmp;
    if (box == null || bmp == null) continue;
    if (box.width <= 0 || box.height <= 0) continue;
    // The owning structure: the nearest structure-category ancestor.
    var cur = byId[object.parentOid ?? -1];
    var depth = 0;
    while (cur != null &&
        cur.category != ViObjectKind.structure &&
        depth++ < 8) {
      cur = byId[cur.parentOid ?? -1];
    }
    if (cur == null || cur.category != ViObjectKind.structure) continue;
    if ((bmp == 1 || bmp == 2) && hiddenCountLoops.contains(cur.oid)) continue;
    (out[cur.oid] ??= []).add((box: box, bmp: bmp));
  }
  return out;
}

/// Whether [object]'s positional ancestry crosses a structure — node-glyph
/// art belongs to a node, and inside a structure frame it is never canvas
/// content.
bool _nestedInStructure(ViHeapObject object, Map<int, ViHeapObject> byId) {
  var cur = byId[object.parentOid ?? -1];
  var depth = 0;
  while (cur != null && depth++ < 16) {
    // The diagram root (0x7e, no parent) is not a structure for this test —
    // top-level glyphs are exactly the ones LabVIEW draws.
    if (cur.category == ViObjectKind.structure && cur.parentOid != null) {
      return true;
    }
    cur = byId[cur.parentOid ?? -1];
  }
  return false;
}

/// The **drawable** objects of [diagram] — the layout layer the BD/FP view and
/// the [BdOracle] both paint: objects with a valid absolute rectangle, excluding
/// the scaffolding parts ([_isScaffolding]), implausibly large boxes, and the
/// hidden frames of stacked multi-frame structures ([bdHiddenFrameOids]). Wires
/// (degenerate zero-area Manhattan runs) are kept via the wire exemption. Single
/// source of truth so the on-screen view and the off-screen oracle render the
/// same object set. Pure + public for the oracle and tests.
List<ViHeapObject> bdDrawableObjects(ViDiagram diagram) {
  final byId = diagram.byId;
  final hidden = bdHiddenFrameOids(diagram)
    ..addAll(bdInlinedInstanceOids(diagram));
  final childrenByOid = bdChildrenByOid(diagram);
  return [
    for (final object in diagram.objects)
      if (object.absBounds != null &&
          object.absBounds!.isValid &&
          (object.category == ViObjectKind.wire ||
              (object.absBounds!.width > 0 && object.absBounds!.height > 0)) &&
          object.absBounds!.width < 8000 &&
          object.absBounds!.height < 8000 &&
          !hidden.contains(object.oid) &&
          // A node-glyph part (0x177) composed at negative coordinates is a
          // node's icon art in glyph space, not canvas space (crc8's floats
          // at (-8,-13) parented to the root frame) — drawing it stamps a
          // stray box and stretches the content extent. One nested inside a
          // structure frame is likewise node-icon art LabVIEW's canvas never
          // shows (crc8's 12x12 at (224,669) under a loop frame). Top-level
          // positive-positioned 0x177s are real drawn glyphs (VI Tree's icon
          // row) and stay.
          !(object.kind == 0x177 &&
              (object.absBounds!.left < 0 ||
                  object.absBounds!.top < 0 ||
                  _nestedInStructure(object, byId))) &&
          !_escapesConstantBox(object, byId) &&
          !_escapesStructureBox(object, byId) &&
          // An owned name-label whose position was not composed lands glued to
          // the origin, extending upward (left == 0, bottom == 0) — 13 of the
          // snippet corpus's 1849 label parts, every one duplicating text that
          // belongs elsewhere. Drawing it stamps mislocated text AND inflates
          // the content rect above the diagram; labels anywhere else
          // (including legitimately negative coordinates) are kept.
          !(kBdTextLabelCodes.contains(object.kind) &&
              object.absBounds!.left == 0 &&
              object.absBounds!.bottom == 0) &&
          // An inlined/malleable subVI splices its own connector-pane controls
          // into this heap; LabVIEW draws the subVI as one icon node, not those
          // internal controls, so they are not this diagram's top-level content.
          !_isInlinedSubViControl(object, byId, childrenByOid) &&
          !_isScaffolding(object, byId))
        object,
  ];
}

/// Whether [object] is a constant's internal part composed **entirely outside
/// the constant's own box** — undrawable either way: LabVIEW clips a
/// constant's data view strictly to its box, so a part outside it is a
/// scrolled-out element or one whose coordinate frame the composition does
/// not yet decode (observed on cluster-in-cluster constants, whose whole
/// inner subtree re-bases near the diagram origin and wrecks the content
/// extent). The constant's box is the outermost bounded shell below the
/// `0x13` const-DCO record on [object]'s parent chain; the test is
/// **subtree-wide** — a part is undrawable when it, or ANY ancestor between
/// it and that shell, lies entirely outside the box (a part "inside" an
/// escaped ancestor is junk at a junk location). A free-text label is exempt
/// only when no ancestor escaped — a constant's own name label legitimately
/// hangs outside the box.
bool _escapesConstantBox(ViHeapObject object, Map<int, ViHeapObject> byId) {
  // Parent chain from [object] up to (exclusive) the 0x13 const-DCO record.
  final chain = <ViHeapObject>[];
  var cur = object;
  var depth = 0;
  var underConst = false;
  while (cur.parentOid != null && depth++ < 64) {
    final parent = byId[cur.parentOid];
    if (parent == null) break;
    if (parent.kind == 0x13) {
      underConst = true;
      break;
    }
    chain.add(parent);
    cur = parent;
  }
  if (!underConst) return false;
  // Anchor: the outermost bounded shell just below the const record.
  HeapRect? anchor;
  for (final shell in chain.reversed) {
    final b = shell.absBounds;
    if (b != null && b.width > 0 && b.height > 0) {
      anchor = b;
      break;
    }
  }
  final box = anchor;
  if (box == null) return false;
  bool outside(HeapRect b) =>
      b.right <= box.left ||
      b.left >= box.right ||
      b.bottom <= box.top ||
      b.top >= box.bottom;
  for (final ancestor in chain) {
    final b = ancestor.absBounds;
    if (b == null || b.width <= 0 || b.height <= 0) continue;
    if (identical(b, box)) continue;
    if (outside(b)) return true;
  }
  if (kBdTextLabelCodes.contains(object.kind)) return false;
  final b = object.absBounds;
  return b != null && b.width > 0 && b.height > 0 && outside(b);
}

/// Whether [object] is composed **entirely outside** its nearest bounded
/// structure ancestor's box (inflated by [slack] px, so tunnels and owned
/// labels overhanging a border stay) — with **no wire (0x1d) on the chain**
/// between them: a wire-parented subtree legitimately escapes its heap
/// container (heap-nesting ≠ visual containment for wires), but a directly
/// nested part outside its frame is mis-composed (a coordinate frame the
/// origin composition does not yet decode) and drawing it stamps content at
/// junk positions and stretches the content extent. Free-text labels are
/// exempt.
bool _escapesStructureBox(
  ViHeapObject object,
  Map<int, ViHeapObject> byId, {
  int slack = 32,
}) {
  if (kBdTextLabelCodes.contains(object.kind)) return false;
  if (object.category == ViObjectKind.wire) return false;
  final bounds = object.absBounds;
  if (bounds == null || bounds.width <= 0 || bounds.height <= 0) return false;
  var cur = object;
  var depth = 0;
  while (cur.parentOid != null && depth++ < 64) {
    final parent = byId[cur.parentOid];
    if (parent == null) return false;
    if (parent.kind == 0x1d) return false;
    final box = parent.absBounds;
    if (parent.category == ViObjectKind.structure &&
        box != null &&
        box.width > 0 &&
        box.height > 0) {
      return bounds.right <= box.left - slack ||
          bounds.left >= box.right + slack ||
          bounds.bottom <= box.top - slack ||
          bounds.top >= box.bottom + slack;
    }
    cur = parent;
  }
  return false;
}

/// The `.vi`/`.vim` filenames [diagram]'s subVI-call nodes target — the wanted
/// set an icon resolver receives (see [ViDiagramView.subViIconResolver]).
Set<String> subViWantedNames(ViDiagram diagram) => {
  for (final object in diagram.objects)
    if (kSubViCallNodeCodes.contains(object.kind))
      if (object.label?.trim() case final name?
          when name.isNotEmpty && _isViFileName(name))
        name,
};

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
/// The bundled primitive icon assets (assets/prim_icons/prim<id>.png —
/// LabVIEW's icon art harvested from the snippet references, transparent
/// exterior, hand-editable), decoded once and keyed by primResID. Empty when
/// the bundle carries none.
/// The primitive classes that ARE a single operation (no primResID record —
/// the class code is the identity); their icons are keyed as `-code`.
const kSingleOpPrimClasses = {0x3a, 0x34, 0x3e, 0x44, 0x6c, 0x93, 0x172};

/// The detail-card row describing a primitive's decoded identity: the
/// primResID and its evidence-based name (with the evidence kind), or the
/// class-identity for the single-op classes, plus the icon asset key and its
/// review status. Null for non-primitive objects. Two nodes of the same
/// single-op class that look different in LabVIEW mean that class carries a
/// further identity the model has not decoded yet — the card says exactly
/// what IS known.
String? _primDetail(ViHeapObject object) {
  final key = primIconKeyOf(object);
  if (key == null) return null;
  final name = key >= 0 ? 'prim$key' : 'class${-key}';
  final status = kPrimIconStatus[name];
  final iconPart =
      'icon $name${status == null ? ' (no asset)' : ' ${status.name}'}';
  if (object.primResId != null) {
    final op = PrimOp.fromId(object.primResId!);
    final opPart = op == null
        ? 'primResID ${object.primResId} (uncatalogued — numeric id only)'
        : 'primResID ${object.primResId} = ${op.opName} (${op.basis == PrimNameBasis.corpusLabel ? 'corpus-labelled' : 'adjacency-inferred'})';
    return '$opPart · $iconPart';
  }
  return 'class 0x${object.kind.toRadixString(16)} single-op identity '
      '(no primResID record — nodes of this class share one operation; a '
      'visible difference between two of them is undecoded state) · $iconPart';
}

/// The detail-card suffix naming a primitive icon's review status
/// ([kPrimIconStatus]) — empty for objects that stamp no icon.
String _iconStatusSuffix(ViHeapObject object) {
  final key = primIconKeyOf(object);
  if (key == null) return '';
  final name = key >= 0 ? 'prim\$key' : 'class\${-key}';
  final status = kPrimIconStatus[name];
  return status == null ? '' : ' · icon \${status.name}';
}

/// The icon-map key for [object]: its primResID when present, else the
/// negated class code for the single-op primitive classes, else null.
int? primIconKeyOf(ViHeapObject object) =>
    object.primResId ??
    (kSingleOpPrimClasses.contains(object.kind) ? -object.kind : null);

/// Integer prescale applied to every bundled icon at load: the stored image
/// is the asset replicated [kPrimIconPrescale]x with nearest sampling —
/// bit-exact blocks. Drawing it back at logical size with NEAREST recovers
/// the original pixels exactly (each destination pixel's centre lands inside
/// its own source block), so the 1:1 oracle raster stays bit-perfect;
/// drawing it with LINEAR is "sharp bilinear": crisp pixel edges at any
/// non-integer zoom, because the interpolation band is only
/// 1/[kPrimIconPrescale] of a source pixel wide.
const kPrimIconPrescale = 4;

Future<Map<int, ui.Image>> loadPrimIcons() => _primIcons ??= () async {
  final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
  final icons = <int, ui.Image>{};
  for (final asset in manifest.listAssets()) {
    final m = RegExp(
      r'assets/prim_icons/(prim|class)(\d+)(?:_[a-z0-9-]+)?\.png$',
    ).firstMatch(asset);
    if (m == null) continue;
    // A rejected icon never stamps — the node falls back to the plate +
    // operator glyph until a better extraction or hand-drawn art lands.
    if (kPrimIconStatus['${m.group(1)}${m.group(2)}'] ==
        PrimIconStatus.rejected) {
      continue;
    }
    final bytes = await rootBundle.load(asset);
    final codec = await ui.instantiateImageCodec(bytes.buffer.asUint8List());
    final image = (await codec.getNextFrame()).image;
    final id = m.group(1) == 'prim'
        ? int.parse(m.group(2)!)
        : -int.parse(m.group(2)!);
    // The alpha mask backs pixel-precise hit testing at LOGICAL resolution:
    // a stamped icon's transparent surround must not swallow clicks meant
    // for the wire or canvas behind it.
    final rgba = await image.toByteData();
    if (rgba != null) {
      final alpha = Uint8List(image.width * image.height);
      for (var i = 0; i < alpha.length; i++) {
        alpha[i] = rgba.getUint8(i * 4 + 3);
      }
      _primIconMasks[id] = (w: image.width, h: image.height, alpha: alpha);
    }
    // Sharp-bilinear prescale (see [kPrimIconPrescale]).
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawImageRect(
      image,
      ui.Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      ui.Rect.fromLTWH(
        0,
        0,
        (image.width * kPrimIconPrescale).toDouble(),
        (image.height * kPrimIconPrescale).toDouble(),
      ),
      ui.Paint()..filterQuality = ui.FilterQuality.none,
    );
    icons[id] = await recorder.endRecording().toImage(
      image.width * kPrimIconPrescale,
      image.height * kPrimIconPrescale,
    );
  }
  return _primIconsSync = icons;
}();
Future<Map<int, ui.Image>>? _primIcons;
Map<int, ui.Image> _primIconsSync = const {};

/// Recolours a primitive icon by exact palette substitution: every pixel
/// whose RGB appears in [rgbMapping] (0xRRGGBB → 0xRRGGBB) is replaced,
/// alpha preserved. The bundled icons are quantised to a closed master
/// palette (listed in assets/prim_icons/MANIFEST.md), so a full-palette
/// mapping recolours the art losslessly — the hook for an inactive/greyed
/// rendering of nodes inside disable structures.
Future<ui.Image> remapPrimIcon(ui.Image icon, Map<int, int> rgbMapping) async {
  final data = await icon.toByteData();
  if (data == null) return icon;
  final rgba = Uint8List.fromList(data.buffer.asUint8List());
  for (var i = 0; i + 3 < rgba.length; i += 4) {
    if (rgba[i + 3] == 0) continue;
    final mapped =
        rgbMapping[(rgba[i] << 16) | (rgba[i + 1] << 8) | rgba[i + 2]];
    if (mapped == null) continue;
    rgba[i] = (mapped >> 16) & 0xff;
    rgba[i + 1] = (mapped >> 8) & 0xff;
    rgba[i + 2] = mapped & 0xff;
  }
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    rgba,
    icon.width,
    icon.height,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}

final Map<int, ({int w, int h, Uint8List alpha})> _primIconMasks = {};

/// Whether the diagram-space point ([x],[y]) lands on an opaque pixel of the
/// primitive icon stamped on [object] (natural size, centred in its bounds).
/// True when no icon is stamped — the plain bounds hit stands. Pixel-precise
/// so an icon's transparent surround does not swallow clicks.
bool primIconHit(ViHeapObject object, double x, double y) {
  final id = primIconKeyOf(object);
  final mask = id == null ? null : _primIconMasks[id];
  if (mask == null || _primIconsSync[id] == null) return true;
  final b = object.absBounds!;
  final left = (b.left + b.right - mask.w) / 2;
  final top = (b.top + b.bottom - mask.h) / 2;
  final ix = (x - left).floor();
  final iy = (y - top).floor();
  if (ix < 0 || iy < 0 || ix >= mask.w || iy >= mask.h) return false;
  return mask.alpha[iy * mask.w + ix] > 0;
}

/// The already-decoded primitive icons, or empty while [loadPrimIcons] is
/// still in flight — for callers that must not block (the oracle's first
/// build under the test framework's fake async).
Map<int, ui.Image> primIconsLoaded() => _primIconsSync;

class BdDiagramPainter extends CustomPainter {
  BdDiagramPainter({
    required this.objects,
    required this.origin,
    this.wires = const [],
    this.subViIcons = const {},
    this.primIcons = const {},
    this.structureTerminals = const {},
    this.iconFilterQuality = FilterQuality.none,
    this.canvasScale = 1,
  });

  final List<ViHeapObject> objects;
  final Offset origin;

  /// Per structure oid, its modeled terminals (frame-relative box + glyph
  /// selector; see [bdStructureTerminals]).
  final Map<int, List<({HeapRect box, int bmp})>> structureTerminals;

  /// The decoded dataflow wires ([ViDiagram.wires], one per `0x17` signal),
  /// routed under the nodes/structures between their endpoint anchors. Empty
  /// leaves the diagram wire-free. See [_drawWires].
  final List<ViWire> wires;

  /// Resolved subVI-call node icons, keyed by [ViHeapObject.oid] — the 32×32
  /// icon of the VI a subVI-call node targets, loaded from that VI's own file
  /// (resolved by `resolveSubViIconsFor`). A node with an entry here stamps the
  /// real icon on its plate; a node without one keeps the neutral
  /// connector-pane plate (the icon is never guessed).
  final Map<int, ViLegacyIcon> subViIcons;

  /// Bundled primitive icon art keyed by primResID (see [loadPrimIcons]);
  /// stamped at natural size on primitive plates. A node without an entry
  /// keeps the plate + operator glyph.
  final Map<int, ui.Image> primIcons;

  /// Sampling for stamped icons: nearest (the default) is pixel-exact in the
  /// 1:1 oracle raster; the interactive view passes [FilterQuality.low]
  /// because its zoom is arbitrary and nearest minification drops pixels.
  final FilterQuality iconFilterQuality;

  /// The zoom this layer rasterises at. The interactive view re-anchors the
  /// layer to the settled zoom after each gesture, so the cached raster the
  /// compositor scales is already crisp at the zoom being viewed — vector
  /// content re-renders sharp at ANY zoom, and only the transient gesture
  /// magnifies a stale raster.
  final double canvasScale;

  @override
  void paint(Canvas canvas, Size size) {
    // The layer rasterises at [canvasScale]; everything below draws in
    // logical diagram units under one canvas scale, so strokes, text, and
    // icons all render at the zoom's real resolution.
    canvas.scale(canvasScale);
    size = Size(size.width / canvasScale, size.height / canvasScale);
    canvas.drawRect(Offset.zero & size, Paint()..color = kBdCanvas);
    _drawDotGrid(canvas, size);

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

    // Decorations are the backmost layer (a coloured free-label backing, box or
    // separator sits behind the logic), so they paint before the dataflow wires
    // and every node — a decoration drawn opaque in its decoded colour must not
    // occlude the wires routed across it.
    // Whether a decoration encloses other drawn logic — then it is a backdrop
    // (a structure interior, a user grouping box) whose interior LabVIEW shows
    // as plain canvas, not a plated leaf box.
    final backdropCandidates = [
      for (final other in objects)
        if (other.category == ViObjectKind.node ||
            other.category == ViObjectKind.structure ||
            other.category == ViObjectKind.terminal)
          other,
    ];
    bool isBackdrop(ViHeapObject deco) {
      final bounds = deco.absBounds!;
      for (final other in backdropCandidates) {
        if (identical(other, deco)) continue;
        final b = other.absBounds!;
        if (b.left >= bounds.left &&
            b.top >= bounds.top &&
            b.right <= bounds.right &&
            b.bottom <= bounds.bottom) {
          return true;
        }
      }
      return false;
    }

    for (final object in decorations) {
      // Drawn in its own decoded LabVIEW colour when one was recovered. An
      // undecoded decoration is still a visible drawn element (a box,
      // separator or backing with an outline), so it gets a thin border and —
      // when it is a leaf box, not a backdrop enclosing other logic — a
      // neutral near-canvas plate, the same honest treatment as an unresolved
      // node's plate (LabVIEW shows a backdrop's
      // interior as plain canvas, and a barely-visible tint would hide a
      // decoration-only diagram entirely).
      final rect = rectOf(object);
      final decoded =
          bdDecodedColor(object.bgRgb) ?? bdDecodedColor(object.contentRgb);
      if (decoded != null) {
        canvas.drawRect(rect, Paint()..color = decoded);
      } else if (!isBackdrop(object)) {
        canvas.drawRect(rect, Paint()..color = const Color(0xFFF4F4F4));
        canvas.drawRect(
          rect,
          Paint()
            ..color = Colors.black.withValues(alpha: 0.45)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 0.8,
        );
      }
    }
    // Dataflow wires paint over the canvas/decorations but under every
    // structure/node, so nodes and terminals always sit on top of the runs that
    // reach them.
    final arrayShellOids = {
      for (final o in objects)
        if (o.kind == 0x50 && o.parentOid != null) o.parentOid!,
    };
    final structureRects = {for (final o in structures) rectOf(o)};
    final tunnelLandings = <(Offset, Color)>[];
    _drawWires(
      canvas,
      structureRects: structureRects,
      tunnelLandings: tunnelLandings,
    );
    for (final object in structures) {
      // Class-accurate structure chrome (no badge text — LabVIEW names a
      // construct by its border furniture, not a label). Loops get the thick
      // rounded grey band with the iteration / conditional corner terminals;
      // case structures get their band plus selector chrome (drawn at the
      // decoded 0x95 label, see the label pass). A decoded structColor tints
      // the band (the pale sequence/timed tint); other structure kinds keep
      // the neutral double-line frame.
      final rect = rectOf(object);
      final structColor = bdDecodedColor(object.structRgb);
      // Structure terminals (iteration/count/conditional, shift registers,
      // case selector tunnel) draw at their MODELED frame-relative positions
      // with their MODELED glyph (see [bdStructureTerminals]); a terminal
      // without a decoded box is not placed.
      final terminals =
          structureTerminals[object.oid] ?? const <({HeapRect box, int bmp})>[];
      // An array constant shell (a 0x52 container holding a 0x50 index box)
      // is not a drawn frame — LabVIEW shows only its parts (the index box,
      // the element, the label); crc8's LUT constant renders frameless. A
      // 0x52 without an index box keeps its generic frame (decorations_only
      // scores on one).
      if (object.kind == 0x52 && arrayShellOids.contains(object.oid)) {
        continue;
      }
      switch (object.kind) {
        case 0x21 || 0x20: // While / for loop: rounded band + terminals.
          _drawLoopBand(canvas, rect, structColor);
          _drawStructureTerminals(canvas, rect, terminals, tunnelLandings);
        case 0x2c: // Case structure: the same band, un-rounded.
          _drawLoopBand(canvas, rect, structColor, rounded: false);
          _drawStructureTerminals(canvas, rect, terminals, tunnelLandings);
        default:
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
    }
    // Wires: each 0x1d object is one stored Manhattan run, drawn exactly as
    // its own segment. Runs of the same wire already meet at their bend
    // corners (corpus: 79% of consecutive segment pairs share an exact
    // endpoint), so a bent wire connects by geometry alone; no connector is
    // synthesized between runs that do not touch — a gap is a different wire,
    // and bridging it drew false strokes across the diagram.
    final wirePaint = Paint()
      ..color = _kindColor(ViObjectKind.wire)
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.square;
    for (final object in wires) {
      final rect = rectOf(object);
      // A zero-area segment is an unanchored stub (often at the diagram
      // origin) — a point, not a run, so there is nothing to draw.
      if (rect.width == 0 && rect.height == 0) continue;
      canvas.drawLine(rect.topLeft, rect.bottomRight, wirePaint);
    }

    for (final object in solids) {
      final rect = rectOf(object);
      // Free-text label parts (control caption 0x0a, case selector 0x95) are
      // drawn by LabVIEW as text, backed by a bordered fill only when the
      // label has its own colour (a comment's yellow backing). So: a decoded
      // background colour paints that backing; no colour paints no box (never
      // guessed). The text pass below renders any recovered caption.
      if (kBdTextLabelCodes.contains(object.kind)) {
        if (object.kind == 0x95) {
          // Case selector chrome: the label ring on the case's top border —
          // white value box with a ▼, flanked by ◄/► pager boxes.
          _drawCaseSelector(canvas, rect);
          continue;
        }
        // A hidden label paints nothing — neither backing nor (below) text.
        final backing = object.isLabelHidden
            ? null
            : bdDecodedColor(object.bgRgb);
        if (backing != null) {
          canvas.drawRect(rect, Paint()..color = backing);
          canvas.drawRect(
            rect,
            Paint()
              ..color = Colors.black.withValues(alpha: 0.6)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 0.8,
          );
        }
        continue;
      }
      switch (object.category) {
        case ViObjectKind.terminal:
          // LabVIEW terminal: datatype-coloured double border — a 2 px outer
          // border, a 1 px white gap, a 1 px inner border — over a plate
          // shaded only around the dataflow arrow. A recovered datatype (or
          // a decoded foreground colour, e.g. a boolean constant's green)
          // drives the colour; an unrecovered one stays a neutral grey
          // rather than guessing. NI draws indicators with a thinner 1 px
          // outer border; both directions unify on the control weights here
          // (deliberate divergence — the reference-measured indicator border
          // reads as an engraving artefact, not a meaningful distinction).
          final typed =
              object.typeKind != ViTypeKind.unknown || object.fgRgb != null;
          final tint = object.typeKind != ViTypeKind.unknown
              ? labviewTypeColor(object.typeKind)
              : (bdDecodedColor(object.fgRgb) ?? kBdUnknownTerminalFill);
          // An unknown-type terminal keeps a dark neutral border — the light
          // "unknown" grey as a border is invisible to the eye and the edge
          // masks alike.
          final border = typed ? tint : const Color(0xFF5A5A5A);
          canvas.drawRect(rect, Paint()..color = Colors.white);
          canvas.drawRect(
            rect.deflate(1),
            Paint()
              ..color = border
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2.0,
          );
          if (rect.width > 10 && rect.height > 10) {
            canvas.drawRect(
              rect.deflate(3.5),
              Paint()
                ..color = border
                ..style = PaintingStyle.stroke
                ..strokeWidth = 1.0,
            );
          }
          // The dataflow arrow lives INSIDE the box (reference-measured on
          // the snippet renders): a right-pointing triangle 3 px deep and
          // ~7 px tall. Data leaving (a control): the tip touches the 2 px
          // outer border, the base intrudes 1 px past the inner border.
          // Data arriving (an indicator): the base sits on the inner border.
          // The plate shading hugs the arrow region only, leaving the 1 px
          // whitespace gap beside the borders — same size both directions.
          if (object.isIndicator != null &&
              rect.height >= 12 &&
              rect.width >= 12) {
            final indicator = object.isIndicator == true;
            final cy = rect.center.dy;
            final double tipX;
            if (indicator) {
              // Wire enters at the left: base on the inner border.
              tipX = rect.left + 7;
            } else {
              // Data leaves at the right: tip touching the outer border.
              tipX = rect.right - 3;
            }
            final shade = Rect.fromLTRB(
              indicator ? rect.left + 3 : rect.right - 10,
              rect.top + 4,
              indicator ? rect.left + 10 : rect.right - 3,
              rect.bottom - 4,
            );
            canvas.drawRect(
              shade,
              Paint()..color = tint.withValues(alpha: 0.25),
            );
            final tri = Path()
              ..moveTo(tipX - 3, cy - 3.5)
              ..lineTo(tipX, cy)
              ..lineTo(tipX - 3, cy + 3.5)
              ..close();
            canvas.drawPath(tri, Paint()..color = Colors.black87);
          }
          // The resolved data type's short label (DBL / I32 / TF / abc),
          // as LabVIEW stamps on the terminal — sized to sit inside the
          // double border even on a 16 px terminal.
          final glyph = object.dataType == null
              ? null
              : dataTypeGlyph(object.dataType!);
          if (glyph != null &&
              rect.width >= 6.0 * glyph.length + 10 &&
              rect.height >= 13) {
            final tp = TextPainter(
              text: TextSpan(
                text: glyph,
                style: TextStyle(
                  color: border,
                  fontSize: 8.5,
                  fontWeight: FontWeight.w700,
                  fontFamily: 'Roboto',
                ),
              ),
              textDirection: TextDirection.ltr,
            )..layout();
            tp.paint(canvas, rect.center - Offset(tp.width / 2, tp.height / 2));
          }
        case ViObjectKind.node:
          // LabVIEW node icon plate: a verified primitive icon (the bundled
          // art harvested from LabVIEW's own renders) stamps at natural
          // size; a subVI call stamps the icon resolved from its own file
          // ([subViIcons]). Without either, subVI calls get a light-grey
          // connector-pane plate and primitive/function nodes the pale-gold
          // numeric-palette plate with the operator glyph — an icon is never
          // guessed. Everything gets the 1 px pure-black border LabVIEW
          // draws around node icons.
          final isSubVi = kSubViCallNodeCodes.contains(object.kind);
          final icon = subViIcons[object.oid];
          final iconKey = primIconKeyOf(object);
          final primIcon = iconKey == null ? null : primIcons[iconKey];
          if (primIcon != null) {
            // The harvested art carries its own borders and transparency —
            // no plate, backing, or extra frame around it. The image is the
            // asset prescaled [kPrimIconPrescale]x (see there); the dst rect
            // is the LOGICAL size.
            final w = primIcon.width / kPrimIconPrescale;
            final h = primIcon.height / kPrimIconPrescale;
            final dst = Rect.fromCenter(
              center: rect.center,
              width: w,
              height: h,
            );
            // Sampling by the layer's rasterisation scale: once it
            // magnifies the prescaled bitmap itself (canvasScale >=
            // kPrimIconPrescale), LINEAR's interpolation band spans a whole
            // display pixel and reads as fuzz — NEAREST gives the crisp
            // blocks; below that the band stays sub-pixel and LINEAR is the
            // sharp-bilinear that kills minification aliasing. NEAREST also
            // stays exact for the 1:1 oracle raster.
            final filter =
                iconFilterQuality == FilterQuality.none ||
                    canvasScale >= kPrimIconPrescale
                ? FilterQuality.none
                : iconFilterQuality;
            canvas.drawImageRect(
              primIcon,
              Rect.fromLTWH(
                0,
                0,
                primIcon.width.toDouble(),
                primIcon.height.toDouble(),
              ),
              dst,
              Paint()..filterQuality = filter,
            );
          } else if (icon != null) {
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
          if (primIcon == null) {
            canvas.drawRect(
              rect.deflate(0.5),
              Paint()
                ..color = Colors.black
                ..style = PaintingStyle.stroke
                ..strokeWidth = 1.0,
            );
          }
          // A decoded primitive identity draws its operator glyph on the
          // plate when no icon asset exists (LabVIEW draws icon art; the
          // glyph is the recognisable core of that art). Nothing is drawn
          // for uncatalogued ids or when no glyph reads naturally.
          final glyph =
              icon == null && primIcon == null && object.primResId != null
              ? primOpGlyph(PrimOp.fromId(object.primResId!))
              : null;
          if (glyph != null && rect.width >= 14 && rect.height >= 12) {
            final tp = TextPainter(
              text: TextSpan(
                text: glyph,
                style: TextStyle(
                  color: Colors.black.withValues(alpha: 0.75),
                  fontSize: glyph.length > 2 ? 8.0 : 12,
                  fontFamily: 'Roboto',
                ),
              ),
              maxLines: 1,
              textDirection: TextDirection.ltr,
            )..layout();
            tp.paint(canvas, rect.center - Offset(tp.width / 2, tp.height / 2));
          }
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
    // Wire landings on structure borders feed ONLY the structure-terminal
    // recolour above (the case selector [?] takes its wire's colour);
    // free-standing tunnel squares at every landing looked wrong — the real
    // tunnel positions are not yet decoded, so none are guessed.
    // The drawn-object index for owner lookups in the text pass.
    final byOid = {for (final o in objects) o.oid: o};
    // Text pass: LabVIEW shows a structure's construct name on its frame and a
    // control/subVI's own caption, but not per-terminal datatype annotations.
    // Only a structure badge or a genuine recovered caption is drawn (the
    // wireframe's debug "name · type" suffix is omitted so the render stays as
    // close to LabVIEW's sparse on-canvas text as the decode allows).
    for (final object in objects) {
      // Standalone label parts (0x0a free label / control caption, 0x95 case
      // selector) draw their recovered caption as multi-line text within their
      // own bounds — across the snippet corpus 1819/1849 such labels carry a
      // plausible non-origin box, so the text lands where LabVIEW put it.
      // Degenerate boxes (origin-pinned or sub-glyph-sized) are skipped.
      if (kBdTextLabelCodes.contains(object.kind)) {
        // LabVIEW hides a label whose part sets objFlags bit 0x08 (see
        // [ViHeapObject.isLabelHidden]; false for 0x95 by its class gate —
        // the case selector's value text is structure furniture and never
        // hides). Drawing hidden text would add ink the reference lacks.
        if (object.isLabelHidden) continue;
        var text = object.label?.trim();
        if (text == null || text.isEmpty) {
          // An owned label with no recovered caption shows its owner's
          // resolved data-space name (the VCTP type name, e.g. `data in`) —
          // the identifier LabVIEW displays in that label.
          text = byOid[object.parentOid]?.typeName;
        }
        if (text == null || text.isEmpty) continue;
        final rect0 = rectOf(object);
        if (rect0.width < 8 || rect0.height < 8) continue;
        // The case selector's value text sits between the inset pager boxes
        // (see [_drawCaseSelector]) and is centred like LabVIEW's.
        final selector = object.kind == 0x95;
        final rect = selector
            ? Rect.fromLTRB(
                rect0.left + 9,
                rect0.top,
                rect0.right - 9,
                rect0.bottom,
              )
            : rect0;
        final tp = TextPainter(
          text: TextSpan(
            text: text,
            style: TextStyle(
              color:
                  bdDecodedColor(object.fgRgb) ??
                  Colors.black.withValues(alpha: 0.85),
              fontSize: selector ? 9.5 : 10.5,
              fontFamily: 'Roboto',
            ),
          ),
          maxLines: math.max(1, rect.height ~/ 12),
          ellipsis: '…',
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: math.max(8, rect.width - (selector ? 1 : 4)));
        tp.paint(
          canvas,
          selector
              ? Offset(
                  rect.center.dx - tp.width / 2,
                  rect.center.dy - tp.height / 2,
                )
              : rect0.topLeft + const Offset(2, 1),
        );
        continue;
      }
      // A structure is identified by its border chrome (LabVIEW draws no
      // construct name); a node's identity is carried by its icon plate (and
      // a separate free label), never by stamping its subVI-filename/function
      // label inside the icon box. A constant/terminal shows the recovered
      // literal value ([ViHeapObject.constText]) when one exists — e.g. a
      // string constant's `"report.txt"` — falling back to its recovered
      // label; a value that was not decoded renders no text (never guessed).
      final String? text;
      if (object.category == ViObjectKind.structure ||
          object.category == ViObjectKind.node) {
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
      // when one was recovered (fgColor is the LabVIEW text/line colour), else
      // a neutral near-black.
      final textColor =
          bdDecodedColor(object.fgRgb) ?? Colors.black.withValues(alpha: 0.75);
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
  void _drawWires(
    Canvas canvas, {
    Set<Rect>? structureRects,
    List<(Offset, Color)>? tunnelLandings,
  }) {
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
        // A zero-area anchor is an endpoint whose nearest bounded owner is a
        // degenerate wire-segment stub (often at the diagram origin or a
        // far-off point) — its real location is not decoded, and routing to it
        // draws strokes into empty space. Such a leg is skipped rather than
        // drawn wrong.
        if (anchor.width <= 0 && anchor.height <= 0) continue;
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
      final route = wire.route;
      final storedApplies =
          route != null && anchors.length == 2 && wire.endpointOids.length == 2;
      for (var i = 1; i < anchors.length; i++) {
        final points =
            (storedApplies
                ? bdStoredWireRoute(source, anchors[i], route)
                : null) ??
            bdWireRoute(source, anchors[i]);
        final path = Path()..moveTo(points.first.dx, points.first.dy);
        for (final point in points.skip(1)) {
          path.lineTo(point.dx, point.dy);
        }
        canvas.drawPath(path, paint);
        // A leg whose anchor is a structure's own box is a border crossing —
        // the landing point is where LabVIEW draws the tunnel square.
        if (structureRects != null && tunnelLandings != null) {
          if (structureRects.contains(source)) {
            tunnelLandings.add((points.first, paint.color));
          }
          if (structureRects.contains(anchors[i])) {
            tunnelLandings.add((points.last, paint.color));
          }
        }
      }
    }
  }

  /// The thick grey structure band LabVIEW draws for loops and cases: a
  /// ~3.5 px mid-grey band with a 1 px darker outline, rounded on loops.
  /// [tint] (a decoded structColor, e.g. the pale sequence colour) replaces
  /// the band grey when present.
  void _drawLoopBand(
    Canvas canvas,
    Rect rect,
    Color? tint, {
    bool rounded = true,
  }) {
    final band = tint ?? const Color(0xFF9C9C9C);
    final radius = rounded ? const Radius.circular(4) : Radius.zero;
    // A decoded structure colour (the pale sequence/timed tint) also washes
    // the interior, as LabVIEW's coloured structures do.
    if (tint != null) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, radius),
        Paint()..color = tint.withValues(alpha: 0.12),
      );
    }
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect.deflate(1.75), radius),
      Paint()
        ..color = band
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.5,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, radius),
      Paint()
        ..color = const Color(0xFF606060)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0,
    );
  }

  static const _loopBlue = Color(0xFF0033CC);

  /// `termBMPs` glyph selectors (corpus pairing, see the package's
  /// [HeapAttribute.termBMPs] doc).
  static const _bmpIteration = 1; // the loop `i`
  static const _bmpCount = 2; // the for-loop `N`
  static const _bmpLeftShiftRegister = 3; // ▼ delivers
  static const _bmpRightShiftRegister = 4; // ▲ stores
  static const _bmpCaseSelector = 5; // the case `?` tunnel
  static const _bmpConditional = 192; // the while-loop stop

  void _drawGlyphText(Canvas canvas, Rect box, String glyph, Color color) {
    final tp = TextPainter(
      text: TextSpan(
        text: glyph,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          fontStyle: FontStyle.italic,
          fontFamily: 'Roboto',
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, box.center - Offset(tp.width / 2, tp.height / 2));
  }

  /// Draws a structure's modeled terminals at their frame-relative boxes,
  /// each with its modeled glyph (`termBMPs`): `i`→1, `N`→2, conditional
  /// stop→192, shift registers→3 (left ▼) / 4 (right ▲), case selector→5.
  void _drawStructureTerminals(
    Canvas canvas,
    Rect frame,
    List<({HeapRect box, int bmp})> terminals, [
    List<(Offset, Color)>? tunnelLandings,
  ]) {
    for (final t in terminals) {
      final box = Rect.fromLTWH(
        frame.left + t.box.left,
        frame.top + t.box.top,
        t.box.width.toDouble(),
        t.box.height.toDouble(),
      );
      // A wire landing inside this terminal's box takes over its colour —
      // LabVIEW paints the case selector [?] in the selector wire's datatype
      // colour (green for a boolean selector). The landing is consumed so no
      // separate tunnel square draws over the terminal.
      Color? wireColor;
      if (tunnelLandings != null) {
        final inflated = box.inflate(3);
        for (var i = tunnelLandings.length - 1; i >= 0; i--) {
          if (inflated.contains(tunnelLandings[i].$1)) {
            wireColor = tunnelLandings.removeAt(i).$2;
          }
        }
      }
      final border = switch (t.bmp) {
        _bmpConditional => const Color(0xFF007F00),
        _ => wireColor ?? _loopBlue,
      };
      canvas.drawRect(box, Paint()..color = Colors.white);
      canvas.drawRect(
        box,
        Paint()
          ..color = border
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4,
      );
      switch (t.bmp) {
        case _bmpIteration:
          _drawGlyphText(canvas, box, 'i', _loopBlue);
        case _bmpCount:
          _drawGlyphText(canvas, box, 'N', _loopBlue);
        case _bmpCaseSelector:
          _drawGlyphText(canvas, box, '?', border);
        case _bmpLeftShiftRegister || _bmpRightShiftRegister:
          // Shift register: ▼ delivers on the left border, ▲ stores on
          // the right.
          final c = box.center;
          final tri = t.bmp == _bmpLeftShiftRegister
              ? (Path()
                  ..moveTo(c.dx - 4, c.dy - 3)
                  ..lineTo(c.dx + 4, c.dy - 3)
                  ..lineTo(c.dx, c.dy + 4)
                  ..close())
              : (Path()
                  ..moveTo(c.dx - 4, c.dy + 3)
                  ..lineTo(c.dx + 4, c.dy + 3)
                  ..lineTo(c.dx, c.dy - 4)
                  ..close());
          canvas.drawPath(tri, Paint()..color = Colors.black87);
        case _bmpConditional:
          // Red stop octagon.
          final c = box.center;
          const r = 5.0;
          final path = Path();
          for (var k = 0; k < 8; k++) {
            final a = (k * 45 + 22.5) * math.pi / 180;
            final p = Offset(c.dx + r * math.cos(a), c.dy + r * math.sin(a));
            if (k == 0) {
              path.moveTo(p.dx, p.dy);
            } else {
              path.lineTo(p.dx, p.dy);
            }
          }
          path.close();
          canvas.drawPath(path, Paint()..color = const Color(0xFFCC0000));
      }
    }
  }

  /// Case-selector chrome at the decoded `0x95` label [rect]: a white value
  /// box with a black border and ▼, flanked by the ◄/► case-pager boxes that
  /// sit on the case's top border. The selector STRING is drawn by the text
  /// pass; only the furniture is drawn here.
  void _drawCaseSelector(Canvas canvas, Rect rect) {
    // Reference-measured chrome (the snippet renders): the selector strip is
    // the modeled 0x95 label bounds; the pager boxes sit INSIDE its two ends
    // at full height, 9 px wide, sharing the strip's border; the pager
    // triangles are 4 px deep and 7 px tall; the dropdown is 7 px wide and
    // 4 px tall against the value box's right edge.
    final border = Paint()
      ..color = Colors.black.withValues(alpha: 0.8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    canvas.drawRect(rect, Paint()..color = Colors.white);
    canvas.drawRect(rect.deflate(0.5), border);
    final cy = rect.center.dy;
    void pager(Rect box, bool left) {
      canvas.drawRect(box.deflate(0.5), border);
      final tipX = left ? box.center.dx - 2 : box.center.dx + 2;
      final baseX = left ? box.center.dx + 2 : box.center.dx - 2;
      final tri = Path()
        ..moveTo(baseX, cy - 3.5)
        ..lineTo(baseX, cy + 3.5)
        ..lineTo(tipX, cy)
        ..close();
      canvas.drawPath(tri, Paint()..color = Colors.black87);
    }

    pager(Rect.fromLTWH(rect.left, rect.top, 9, rect.height), true);
    pager(Rect.fromLTWH(rect.right - 9, rect.top, 9, rect.height), false);
    final dx = rect.right - 15;
    final down = Path()
      ..moveTo(dx - 3.5, cy - 2)
      ..lineTo(dx + 3.5, cy - 2)
      ..lineTo(dx, cy + 2)
      ..close();
    canvas.drawPath(down, Paint()..color = Colors.black87);
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
      !identical(old.subViIcons, subViIcons) ||
      !identical(old.primIcons, primIcons) ||
      old.iconFilterQuality != iconFilterQuality ||
      old.canvasScale != canvasScale ||
      !identical(old.structureTerminals, structureTerminals) ||
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
    this.canvasScale = 1,
  });

  final Offset origin;
  final ViHeapObject? selected;
  final Set<ViHeapObject> members;

  /// Matches [BdDiagramPainter.canvasScale] — the overlay shares the layer.
  final double canvasScale;

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
    canvas.scale(canvasScale);
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
      !old.members.containsAll(members) ||
      old.canvasScale != canvasScale;
}

/// A "label: value" detail row for the selected-object card (decoded semantics).
Widget _detail(String label, String value) => Padding(
  padding: const EdgeInsets.only(top: 3),
  // Text.rich (not RichText) so the body inherits the ambient theme colour —
  // a fixed dark grey was unreadable on the dark theme; the label blue reads
  // on both.
  child: Text.rich(
    maxLines: 3,
    overflow: TextOverflow.ellipsis,
    TextSpan(
      style: const TextStyle(fontSize: 12),
      children: [
        TextSpan(
          text: '$label: ',
          style: const TextStyle(
            fontWeight: FontWeight.w600,
            color: Color(0xFF5B9BD5),
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
                    '${object.isLabelHidden ? ' · hidden' : ''}'
                    '${kMultiFrameStructureKinds.contains(object.kind) ? ' · shows frame ${object.visibleFrameIndex + 1}' : ''}'
                    '${_iconStatusSuffix(object)}'
                    '${object.typeKind != ViTypeKind.unknown ? ' · type ${object.typeKind.name}' : ''}'
                    '${bounds != null ? ' · ${bounds.width}×${bounds.height} @(${bounds.left},${bounds.top})' : ''}'
                    '${object.parentOid != null ? ' · parent ${object.parentOid}' : ''}',
                    style: const TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                  if (_primDetail(object) case final prim?)
                    _detail('primitive', prim),
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
/// [ViDiagramView.subViIconResolver]).
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
          // Only the VI icon shows here: the other recovered image resources
          // (e.g. Excel_Read_XLSX carries a stack of DSIM entries that decode
          // to blank canvases) belong to the Images tab, and a strip of them
          // overflowed this row.
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text(
                "The VI's own icon — what a caller's subVI node shows for it."
                '${images.pngs.isEmpty ? '' : ' ${images.pngs.length} more recovered image(s) in the Images tab.'}',
                style: const TextStyle(fontSize: 11, color: Colors.grey),
                overflow: TextOverflow.ellipsis,
                maxLines: 2,
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
