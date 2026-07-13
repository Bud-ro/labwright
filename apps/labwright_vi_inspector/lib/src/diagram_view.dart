import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart' show AssetManifest, rootBundle;

import 'package:flutter/foundation.dart' show setEquals;
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
  Map<int, PrimIconArt> _primIcons = const {};
  late final List<ViHeapObject> _drawable = _diagram == null
      ? const []
      : bdDrawableObjects(_diagram);
  late final List<ViHeapObject> _ordered = bdPaintOrder(_drawable, _byId);
  // Decoded dataflow wires (empty on a front-panel heap). Drawn under the nodes.
  late final List<ViWire> _wires = switch (_diagram) {
    null => const [],
    final diagram => bdVisibleWires(diagram),
  };
  late final Set<int> _disabledOids = switch (_diagram) {
    null => const {},
    final diagram => bdDisabledObjectOids(diagram),
  };
  late final Map<HeapRect, ({int kind, bool hollow, bool disabled})>
  _borderTerminalKinds = switch (_diagram) {
    null => const {},
    final diagram => bdBorderTerminalKinds(diagram),
  };
  late final Map<int, List<({HeapRect box, int bmp})>> _structureTerminals =
      switch (_diagram) {
        null => const {},
        final diagram => bdStructureTerminals(diagram),
      };
  late final Map<int, String> _constValues = switch (_diagram) {
    null => const {},
    final diagram => bdConstValueTexts(diagram),
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
    if (_disabledOids.isNotEmpty) {
      ensurePrimIconsGrey().then((grey) {
        if (mounted && grey.isNotEmpty) setState(() {});
      });
    }
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
                              primIconsGrey: primIconsGreyLoaded(),
                              disabledOids: _disabledOids,
                              borderTerminalKinds: _borderTerminalKinds,
                              iconFilterQuality: FilterQuality.low,
                              canvasScale: _anchorScale,
                              structureTerminals: _structureTerminals,
                              constValues: _constValues,
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
      // Icon art can overhang its model box (a measured placement like
      // prim1162's dy: -5), so the coarse gate is the box UNION the stamp;
      // the alpha mask then decides precisely.
      var left = bounds.left.toDouble(), top = bounds.top.toDouble();
      var right = bounds.right.toDouble(), bottom = bounds.bottom.toDouble();
      final key = primIconKeyOf(object);
      final art = key == null ? null : _primIconsSync[key];
      if (art != null) {
        final stamp = primIconStampRect(
          Rect.fromLTRB(left, top, right, bottom),
          art.base.width,
          art.base.height,
          key: key,
        );
        left = math.min(left, stamp.left);
        top = math.min(top, stamp.top);
        right = math.max(right, stamp.right);
        bottom = math.max(bottom, stamp.bottom);
      }
      if (x >= left && x <= right && y >= top && y <= bottom) {
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
  // green (0,102,0) is sampled from crc8's boolean WIRE dots and selector
  // border at decoded rects (the decoded constant FOREGROUND is a
  // different green, 0x007F00 — constants are not wires).
  ViTypeKind.numericInt => const Color(0xFF0000FF),
  ViTypeKind.enumRing => const Color(0xFF0000FF),
  ViTypeKind.string => const Color(0xFFFF00FF),
  ViTypeKind.boolean => const Color(0xFF006600),
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

/// The 1 px border LabVIEW draws around a structure tunnel square (sampled
/// from the crc8 snippet reference at a decoded tunnel rect; the fill is the
/// wire's own colour).
const Color kBdTunnelBorder = Color(0xFF444444);

/// The cream fill inside shift-register and selector border terminals
/// (sampled (255,255,204) from the crc8 reference at decoded rects — the
/// same cream as primitive icon bodies).
const Color kBdTerminalFill = Color(0xFFFFFFCC);

/// The uniform grey a disabled frame renders dark NEUTRAL chrome in — the
/// same (170,170,170) line-work grey as the disabled icon palette
/// ([_greyDisabledPalette]). Measured on crc8's disabled tunnel at
/// (405,220): all 32 pixels of its [kBdTunnelBorder] ring read
/// (170,170,170), while the wire-derived colours on the same tunnel follow
/// [dimDisabledFrameRgb] (the wire formula predicts (187,187,187) for this
/// ring and is refuted by that measurement — neutral chrome takes the icon
/// mapping, wire colours take the formula).
const Color kBdDisabledChromeGrey = Color(0xFFAAAAAA);

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

/// [color] rendered through the measured disabled-frame palette transform
/// ([dimDisabledFrameRgb], per channel `c' = min(255, 153 + c ~/ 2)`) —
/// how LabVIEW draws every colour inside a disable structure's displayed
/// Disabled frame. Alpha stays opaque.
Color bdDimDisabled(Color color) =>
    Color(0xFF000000 | dimDisabledFrameRgb(color.toARGB32() & 0xFFFFFF));

/// The measured HORIZONTAL column cycles of the patterned wire strokes,
/// transcribed from the [ViWireRenderStyle] catalogue: per style, the
/// repeating per-column 5-bit ink masks where bit `b` inks row
/// `cross + (b - 2)` (bit 2 = the route row; higher bits are rows BELOW it,
/// y growing downward). The cycle SHAPES are census measurements; the
/// census canonicalises each cycle by rotation, so the absolute phase is
/// NOT measured — the painter anchors a cycle at `column mod period`
/// (TODO: census the phases). The dotted styles are not here: their
/// measured checkerboard phase law is applied directly (see [_drawWires]).
///
/// Only the solid styles ([ViWireRenderStyle.solid1px] / `solid2px` /
/// `hollowDouble`) and the dotted pair have vertical treatments in the
/// painter; every style in this map is drawn patterned on horizontal runs
/// alone.
const Map<ViWireRenderStyle, List<int>> kBdWireStrokeCycles = {
  ViWireRenderStyle.zigzag: [0x02, 0x06, 0x04, 0x06],
  ViWireRenderStyle.chainLink: [0x04, 0x0e, 0x0a, 0x0e],
  ViWireRenderStyle.chainLinkWide: [0x05, 0x0f, 0x0a, 0x0f],
  ViWireRenderStyle.braid: [0x0a, 0x0a, 0x0e, 0x0e],
  ViWireRenderStyle.braidWide: [0x09, 0x0d, 0x0f, 0x0b],
  ViWireRenderStyle.braidDense: [0x0a, 0x0e],
  ViWireRenderStyle.braidDenseWide: [0x0b, 0x0d],
  ViWireRenderStyle.weave: [0x02, 0x0a, 0x02, 0x0e, 0x08, 0x0a, 0x08, 0x0e],
};

/// The cross-axis ink band of a stroke [style] around its route row/column,
/// as inclusive offsets — the rows a horizontal run of the style inks.
/// Solid/dotted bands are measured (corpus render census: a 2 px wire
/// straddles `cross-1..cross`, 16 clean runs with zero counterexamples of
/// the alternative placement; crc8's routed 2 px wires confirm the same
/// transposed on vertical runs); patterned bands are the union of their
/// catalogued cycle masks.
(int, int) bdWireStrokeBand(ViWireRenderStyle style) => switch (style) {
  ViWireRenderStyle.solid1px || ViWireRenderStyle.dotted => (0, 0),
  ViWireRenderStyle.solid2px ||
  ViWireRenderStyle.dottedAlternating ||
  ViWireRenderStyle.zigzag => (-1, 0),
  ViWireRenderStyle.hollowDouble ||
  ViWireRenderStyle.chainLink ||
  ViWireRenderStyle.braid ||
  ViWireRenderStyle.braidDense ||
  ViWireRenderStyle.weave => (-1, 1),
  ViWireRenderStyle.chainLinkWide ||
  ViWireRenderStyle.braidWide ||
  ViWireRenderStyle.braidDenseWide => (-2, 1),
};

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

/// The colour a [wire] is drawn in: [kBdWireColor] unless one of its endpoint
/// anchors exactly matches a terminal whose datatype was recovered, in which
/// case that terminal's [labviewTypeColor] is used. [typedTerminalColors] maps a
/// packed endpoint-anchor rectangle (`t,l,b,r`) to that terminal's colour. The
/// wire's own datatype is not decoded, so no colour is ever guessed from the
/// signal itself. Pure + public for testing.
Color bdWireColor(
  ViWire wire,
  Map<int, Color> typedTerminalColors, {
  Map<int, Color> sourceOutputColors = const {},
}) {
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
  // No typed terminal on the wire: if its FIRST endpoint (the route source)
  // is a primitive whose catalogued op fixes its output type, the wire
  // carries that output — [PrimOp.output], asserted only from documented
  // semantics, never guessed from the signal.
  final source = wire.endpointAnchors.firstWhere(
    (a) => a != null,
    orElse: () => null,
  );
  if (source != null) {
    final color =
        sourceOutputColors[_packRect(
          source.top,
          source.left,
          source.bottom,
          source.right,
        )];
    if (color != null) return color;
  }
  // Last: the signal's own decoded type word — an ESTIMATE (89.9% family
  // agreement corpus-wide; see [ViSignalType]), which is why every
  // terminal-derived source above outranks it. Arrays colour by ELEMENT
  // kind, as LabVIEW does.
  final wordKind = wire.elementTypeKind;
  if (wordKind != null && wordKind != ViTypeKind.unknown) {
    return labviewTypeColor(wordKind);
  }
  return kBdWireColor;
}

/// Per data-view terminal oid, the **numeric literal** its block-diagram
/// constant displays: the decoded value ([ViHeapObject.constNumeric]) lives on
/// the `0x13` bdConstDCO record, and the drawn box is that record's bounded
/// terminal child (crc8's oid 3033 shows `256` from its 0x13 parent's
/// record). Only decoded values map — a constant whose flattened value was
/// not recovered renders no text (never guessed). A whole-valued double
/// formats without the trailing `.0`, matching the integer rendering LabVIEW
/// gives whole values; stored per-constant display format specifiers are not
/// yet decoded (TODO).
Map<int, String> bdConstValueTexts(ViDiagram diagram) {
  final byId = diagram.byId;
  final out = <int, String>{};
  for (final object in diagram.objects) {
    if (object.category != ViObjectKind.terminal) continue;
    final bounds = object.absBounds;
    if (bounds == null || bounds.width <= 0 || bounds.height <= 0) continue;
    final parent = byId[object.parentOid ?? -1];
    final value = parent?.kind == 0x13 ? parent!.constNumeric : null;
    if (value == null) continue;
    out[object.oid] = value is double && value == value.roundToDouble()
        ? value.toInt().toString()
        : value.toString();
  }
  return out;
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
/// `bDConstDCO` or `0x15` structural record ancestor) and (b) carries a named,
/// **visible** `0x0a` caption child (the subVI control's drawn data name, e.g.
/// `Requirement ID`, `Label (VI Title)`). LabVIEW draws the subVI as a single
/// icon node, not its inlined internal controls, so these are not part of *this*
/// VI's top-level block diagram and are excluded from the drawn/fit set.
///
/// The caption child must be *visible* ([ViHeapObject.isLabelHidden] false): a
/// diagram constant carries its own `0x0a` name child too, but that name is
/// hidden by default (bit `0x08`), so LabVIEW paints only the constant box —
/// the constant stays in the drawn set. A bare unnamed constant terminal has no
/// caption child at all and is likewise kept. [childrenByOid] is the positional
/// child index.
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
    (c) =>
        c.kind == 0x0a &&
        !c.isLabelHidden &&
        (c.label?.trim().isNotEmpty ?? false),
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
/// decoded bounds) is re-anchored to its decoded attach rectangle when one
/// exists (the exact terminal square, [ViWire.endpointAttachRects]), else to
/// the endpoint's nearest drawable bounded ancestor, so the run reaches the
/// structure's border the way LabVIEW's tunnel wires do. A leg that only
/// resolves to the diagram root stays unanchored (drawing to the canvas edge
/// would be wrong), and a wire whose remaining anchors collapse onto one
/// identical box is dropped as degenerate.
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
      final attach = i < wire.endpointAttachRects.length
          ? wire.endpointAttachRects[i]
          : null;
      final resolved = (attach != null && attach.width > 0 && attach.height > 0)
          ? attach
          : reanchor(wire.endpointOids[i]);
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
              endpointAttachRects: wire.endpointAttachRects,
              // The stored route replays from endpoint 0's connection point:
              // it survives a re-anchored SINK (the route already targets the
              // border the sink was re-anchored to) but not a re-anchored
              // source, whose original connection point is what the lengths
              // measure from. The proven absolute polyline and the decoded
              // type word are independent of the anchor patch and ride along.
              route: sourcePatched ? null : wire.route,
              routePoints: wire.routePoints,
              routeTree: wire.routeTree,
              signalType: wire.signalType,
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
/// without a decoded box are omitted (nothing is placed by guesswork), and a
/// terminal LabVIEW hides is dropped via the file's own per-terminal flag
/// ([ViDiagram.terminalGlyphHidden]: [kTerminalGlyphHiddenFlag] on the
/// terminal's DCO, render-verified on crc8's four loops — two drawn and two
/// hidden `i` glyphs, all four `N` glyphs drawn).
Map<int, List<({HeapRect box, int bmp})>> bdStructureTerminals(
  ViDiagram diagram,
) {
  final byId = diagram.byId;
  final out = <int, List<({HeapRect box, int bmp})>>{};
  for (final object in diagram.objects) {
    final box = object.termBounds;
    final bmp = object.termBmp;
    if (box == null || bmp == null) continue;
    if (box.width <= 0 || box.height <= 0) continue;
    if (diagram.terminalGlyphHidden(object.oid)) continue;
    // The owning structure: the nearest structure-category ancestor.
    var cur = byId[object.parentOid ?? -1];
    var depth = 0;
    while (cur != null &&
        cur.category != ViObjectKind.structure &&
        depth++ < 8) {
      cur = byId[cur.parentOid ?? -1];
    }
    if (cur == null || cur.category != ViObjectKind.structure) continue;
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
          // structure frame is likewise suppressed — evidence so far is
          // crc8's single case (a 12x12 at (224,669) under a loop frame,
          // absent from the reference render); TODO: revisit if a corpus
          // reference ever shows a structure-nested 0x177 drawn. Top-level
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
const kSingleOpPrimClasses = {0x3a, 0x34, 0x3e, 0x44, 0x6c, 0x93, 0x172, 0xb9};

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
  final name = key >= 0 ? 'prim$key' : 'class${-key}';
  final status = kPrimIconStatus[name];
  return status == null ? '' : ' · icon ${status.name}';
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

/// A bundled icon at both resolutions: [base] is the asset's own pixels —
/// the ONLY image nearest sampling may touch (nearest at any integer device
/// scale replicates it uniformly; nearest on the prescale at a mismatched
/// scale, e.g. 4x art on a 3x canvas, doubles some columns and drops others).
/// [sharp] is the [kPrimIconPrescale]x nearest prescale for the
/// sharp-bilinear interactive path.
typedef PrimIconArt = ({ui.Image base, ui.Image sharp});

Future<Map<int, PrimIconArt>> loadPrimIcons() => _primIcons ??= () async {
  final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
  final icons = <int, PrimIconArt>{};
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
      // The art-space ink (opaque-pixel) bounding box — the measured art
      // edge the wire fallback router anchors icon-stamped endpoints to.
      var minX = image.width, minY = image.height, maxX = -1, maxY = -1;
      for (var y = 0; y < image.height; y++) {
        for (var x = 0; x < image.width; x++) {
          if (alpha[y * image.width + x] == 0) continue;
          if (x < minX) minX = x;
          if (y < minY) minY = y;
          if (x > maxX) maxX = x;
          if (y > maxY) maxY = y;
        }
      }
      if (maxX >= minX && maxY >= minY) {
        _primIconInkBounds[id] = ui.Rect.fromLTRB(
          minX.toDouble(),
          minY.toDouble(),
          maxX + 1.0,
          maxY + 1.0,
        );
      }
    }
    icons[id] = await _prescaledArt(image);
  }
  return _primIconsSync = icons;
}();

/// Pairs [image] with its sharp-bilinear prescale (see [kPrimIconPrescale]).
Future<PrimIconArt> _prescaledArt(ui.Image image) async {
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
  return (
    base: image,
    sharp: await recorder.endRecording().toImage(
      image.width * kPrimIconPrescale,
      image.height * kPrimIconPrescale,
    ),
  );
}

Future<Map<int, PrimIconArt>>? _primIcons;
Map<int, PrimIconArt> _primIconsSync = const {};
Map<int, PrimIconArt> _primIconsGreySync = const {};

/// The disabled-diagram rendering of [rgba] in place: LabVIEW draws a
/// disabled frame's icons as grey line-work on white. Evidence — crc8's
/// disabled-frame `Reverse 1D Array` against the normal asset maps
/// (255,255,204)→(255,255,255) and (76,76,61)→(170,170,170) on every one of
/// its 736 opaque pixels, and its `Number To Boolean Array` shows the same
/// two output colours. Light fills go white, everything else goes the
/// uniform grey; the 204-average threshold between them is the one
/// assumption (no corpus pair exercises a mid tone yet — TODO: recheck when
/// one appears). Alpha is preserved.
void _greyDisabledPalette(Uint8List rgba) {
  for (var i = 0; i < rgba.length; i += 4) {
    if (rgba[i + 3] == 0) continue;
    final light = (rgba[i] + rgba[i + 1] + rgba[i + 2]) >= 3 * 204;
    final v = light ? 255 : 170;
    rgba[i] = rgba[i + 1] = rgba[i + 2] = v;
  }
}

/// The already-decoded disabled-palette icon variants (see
/// [_greyDisabledPalette]), keyed like [primIconsLoaded]. Empty until
/// [ensurePrimIconsGrey] runs — the variants are built only when a diagram
/// actually contains a disabled frame, not for every icon at startup.
Map<int, PrimIconArt> primIconsGreyLoaded() => _primIconsGreySync;

/// Builds the disabled-palette variants of every loaded icon, once, on
/// first demand (a diagram with a non-empty [bdDisabledObjectOids] set).
Future<Map<int, PrimIconArt>> ensurePrimIconsGrey() =>
    _primIconsGrey ??= () async {
      final icons = await loadPrimIcons();
      final grey = <int, PrimIconArt>{};
      for (final e in icons.entries) {
        final rgba = await e.value.base.toByteData();
        if (rgba == null) continue;
        final greyPx = Uint8List.fromList(rgba.buffer.asUint8List());
        _greyDisabledPalette(greyPx);
        final completer = Completer<ui.Image>();
        ui.decodeImageFromPixels(
          greyPx,
          e.value.base.width,
          e.value.base.height,
          ui.PixelFormat.rgba8888,
          completer.complete,
        );
        grey[e.key] = await _prescaledArt(await completer.future);
      }
      return _primIconsGreySync = grey;
    }();
Future<Map<int, PrimIconArt>>? _primIconsGrey;

/// Recolours a primitive icon by exact palette substitution: every pixel
/// whose RGB appears in [rgbMapping] (0xRRGGBB → 0xRRGGBB) is replaced,
/// alpha preserved; pixels outside the mapping keep their colour
/// (hand-finished assets carry reference-sampled tones beyond the
/// extraction pipeline's master palette). The disabled-frame rendering
/// uses the value-based [_greyDisabledPalette] instead — this exact-match
/// remap serves themed recolouring where the target colours are known.
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

/// Art-space opaque-pixel bounding boxes of the loaded icons (filled by
/// [loadPrimIcons] from the same alpha masks that back hit testing).
final Map<int, ui.Rect> _primIconInkBounds = {};

/// The art-space ink (opaque-pixel) bounding box of the icon keyed [key], or
/// null while the icons are still loading / for keys without art. The wire
/// fallback router anchors an icon-stamped endpoint at this measured art
/// edge instead of the (larger) node box.
ui.Rect? primIconInkBounds(int key) => _primIconInkBounds[key];

/// Whether the diagram-space point ([x],[y]) lands on an opaque pixel of the
/// primitive icon stamped on [object] (natural size, centred in its bounds).
/// True when no icon is stamped — the plain bounds hit stands. Pixel-precise
/// so an icon's transparent surround does not swallow clicks.
/// Where icon art lands within a node's box. Placement is a fixed
/// per-primitive property measured against LabVIEW's own renders
/// ([kPrimIconPlacement]) — no centring rule reproduces it. Unmeasured keys
/// centre with the half-pixel floored; the offsets stay whole logical
/// pixels either way (a fractional stamp splits border ink across resample
/// boundaries and shifts glyphs into their neighbours). The stamp, the
/// selection outline, and the alpha hitbox all share this rect.
Rect primIconStampRect(Rect nodeRect, int artW, int artH, {int? key}) {
  final placed = key == null
      ? null
      : kPrimIconPlacement[key >= 0 ? 'prim$key' : 'class${-key}'];
  if (placed != null) {
    return Rect.fromLTWH(
      nodeRect.left + placed.dx,
      nodeRect.top + placed.dy,
      artW.toDouble(),
      artH.toDouble(),
    );
  }
  return Rect.fromLTWH(
    (nodeRect.center.dx - artW / 2).floorToDouble(),
    (nodeRect.center.dy - artH / 2).floorToDouble(),
    artW.toDouble(),
    artH.toDouble(),
  );
}

bool primIconHit(ViHeapObject object, double x, double y) {
  final id = primIconKeyOf(object);
  final mask = id == null ? null : _primIconMasks[id];
  if (mask == null || _primIconsSync[id] == null) return true;
  final b = object.absBounds!;
  final stamp = primIconStampRect(
    Rect.fromLTRB(
      b.left.toDouble(),
      b.top.toDouble(),
      b.right.toDouble(),
      b.bottom.toDouble(),
    ),
    mask.w,
    mask.h,
    key: id,
  );
  final left = stamp.left;
  final top = stamp.top;
  final ix = (x - left).floor();
  final iy = (y - top).floor();
  if (ix < 0 || iy < 0 || ix >= mask.w || iy >= mask.h) return false;
  return mask.alpha[iy * mask.w + ix] > 0;
}

/// The absolute diagram coordinate of [object]'s stamped-art opaque EDGE along
/// one axis, on the line a wire's implied closing run arrives on — where the
/// run visibly meets the icon. For a horizontal run ([horizontal] true) the
/// scan is across art row [cross] (an absolute y) and [sign] is the run's x
/// direction: `+1` returns the LEFTMOST opaque column (the near edge a
/// rightward run meets), `-1` the column just past the RIGHTMOST. A vertical
/// run scans column [cross] (an absolute x) for the top/bottom opaque row.
/// Returns null when the object stamps no masked art or that row/column holds
/// no opaque pixel — the art is transparent there, which the per-art ink
/// bounding box ([primIconInkBounds]) cannot report. Absolute so the painter
/// and tests agree on the meeting point.
int? primIconInkEdge(
  ViHeapObject object, {
  required bool horizontal,
  required int cross,
  required int sign,
}) {
  final id = primIconKeyOf(object);
  final mask = id == null ? null : _primIconMasks[id];
  final b = object.absBounds;
  if (mask == null || b == null) return null;
  final stamp = primIconStampRect(
    Rect.fromLTRB(
      b.left.toDouble(),
      b.top.toDouble(),
      b.right.toDouble(),
      b.bottom.toDouble(),
    ),
    mask.w,
    mask.h,
    key: id,
  );
  if (horizontal) {
    final iy = (cross - stamp.top).floor();
    if (iy < 0 || iy >= mask.h) return null;
    final base = iy * mask.w;
    if (sign >= 0) {
      for (var ix = 0; ix < mask.w; ix++) {
        if (mask.alpha[base + ix] > 0) return stamp.left.floor() + ix;
      }
    } else {
      for (var ix = mask.w - 1; ix >= 0; ix--) {
        if (mask.alpha[base + ix] > 0) return stamp.left.floor() + ix + 1;
      }
    }
    return null;
  }
  final ix = (cross - stamp.left).floor();
  if (ix < 0 || ix >= mask.w) return null;
  if (sign >= 0) {
    for (var iy = 0; iy < mask.h; iy++) {
      if (mask.alpha[iy * mask.w + ix] > 0) return stamp.top.floor() + iy;
    }
  } else {
    for (var iy = mask.h - 1; iy >= 0; iy--) {
      if (mask.alpha[iy * mask.w + ix] > 0) return stamp.top.floor() + iy + 1;
    }
  }
  return null;
}

/// The already-decoded primitive icons, or empty while [loadPrimIcons] is
/// still in flight — for callers that must not block (the oracle's first
/// build under the test framework's fake async).
Map<int, PrimIconArt> primIconsLoaded() => _primIconsSync;

/// Terminal class codes whose border chrome is REFERENCE-VERIFIED (each
/// spec below was read from crc8/crc16/crc32 reference pixels at decoded
/// attach rects): plain loop tunnel `0x22` and select tunnel `0x2d` (a
/// wire-colour-filled square under a 1 px [kBdTunnelBorder] ring), left /
/// right shift registers `0x27`/`0x28` (2 px wire-colour border, cream
/// fill, wire-colour down-/up-arrow glyph), selector terminal `0x2e`
/// (1 px wire-colour border, cream fill, wire-colour `?` glyph). Other
/// border-terminal kinds stay undrawn until reference-verified.
const Set<int> kVerifiedBorderTerminalKinds = {0x22, 0x2d, 0x27, 0x28, 0x2e};

/// The terminal [ViHeapObject.objFlags] bit marking a HOLLOW tunnel square
/// (cream interior with a wire-colour ring — LabVIEW's use-default look)
/// instead of the solid wire-colour fill. Corpus census over both snippet
/// repos, classifying each 0x22/0x2d's reference interior: bit set → 71/72
/// hollow; bit clear → 289/296 solid. The 8 outliers (7 cream-dominant
/// without the bit — a bracket-style look whose trigger is not yet
/// decoded — and 1 set-but-solid) are drawn by the flag until that third
/// look is decoded (TODO).
const int kTunnelHollowFlag = 0x1000000;

/// Per decoded attach rect, its resolving terminal's class code, hollow
/// bit, and whether the terminal sits inside a disable structure's
/// displayed Disabled frame ([bdDisabledObjectOids] — its chrome then draws
/// through [dimDisabledFrameRgb]) — for the border-terminal chrome pass
/// (only [kVerifiedBorderTerminalKinds] draw).
Map<HeapRect, ({int kind, bool hollow, bool disabled})> bdBorderTerminalKinds(
  ViDiagram diagram,
) {
  final disabledOids = bdDisabledObjectOids(diagram);
  final out = <HeapRect, ({int kind, bool hollow, bool disabled})>{};
  for (final wire in bdVisibleWires(diagram)) {
    for (var e = 0; e < wire.endpointOids.length; e++) {
      final attach = e < wire.endpointAttachRects.length
          ? wire.endpointAttachRects[e]
          : null;
      if (attach == null) continue;
      final terminal = diagram.endpointTerminal(wire.endpointOids[e]);
      if (terminal != null &&
          kVerifiedBorderTerminalKinds.contains(terminal.kind)) {
        out[attach] = (
          kind: terminal.kind,
          hollow: ((terminal.objFlags ?? 0) & kTunnelHollowFlag) != 0,
          disabled: disabledOids.contains(terminal.oid),
        );
      }
    }
  }
  return out;
}

/// The oids of drawable objects sitting under a disable structure's
/// DISPLAYED frame when that frame is a disabled one — LabVIEW renders their
/// icons as grey line-work on white (see [_greyDisabledPalette]). The
/// disabled-ness signal is the structure's own `0x95` selector label (the
/// displayed frame's name, e.g. " Disabled"): the label is drawn from the
/// file, never inferred from frame order.
Set<int> bdDisabledObjectOids(ViDiagram diagram) {
  final out = <int>{};
  for (final o in diagram.objects) {
    if (o.kind != 0xcd) continue;
    final kids = diagram.children(o.oid).toList();
    final selector = kids.firstWhere((k) => k.kind == 0x95, orElse: () => o);
    if (identical(selector, o) ||
        selector.label?.trim().toLowerCase() != 'disabled') {
      continue;
    }
    final frames = kids.where((k) => k.kind == 0x1b).toList();
    final shown = o.visibleFrameIndex;
    if (shown >= frames.length) continue;
    final stack = [frames[shown].oid];
    while (stack.isNotEmpty) {
      final oid = stack.removeLast();
      for (final kid in diagram.children(oid)) {
        if (out.add(kid.oid)) stack.add(kid.oid);
      }
    }
  }
  return out;
}

/// One drawn wire segment in integer pixel space, kept for the crossing
/// rule: orientation, along-axis extent `lo..hi` (inclusive), and the
/// stroke's cross-axis ink band `bandLo..bandHi` (inclusive).
typedef _BdWireSeg = ({
  bool horizontal,
  int lo,
  int hi,
  int bandLo,
  int bandHi,
});

class BdDiagramPainter extends CustomPainter {
  BdDiagramPainter({
    required this.objects,
    required this.origin,
    this.wires = const [],
    this.subViIcons = const {},
    this.primIcons = const {},
    this.primIconsGrey = const {},
    this.disabledOids = const {},
    this.borderTerminalKinds = const {},
    this.structureTerminals = const {},
    this.constValues = const {},
    this.iconFilterQuality = FilterQuality.none,
    this.canvasScale = 1,
    this.drawDotGrid = true,
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
  final Map<int, PrimIconArt> primIcons;

  /// Disabled-palette variants of [primIcons] (see [primIconsGreyLoaded]),
  /// stamped for nodes in [disabledOids].
  final Map<int, PrimIconArt> primIconsGrey;

  /// Objects under a disabled displayed frame ([bdDisabledObjectOids]).
  final Set<int> disabledOids;

  /// Attach rect → terminal class for reference-verified border-terminal
  /// chrome ([bdBorderTerminalKinds]).
  final Map<HeapRect, ({int kind, bool hollow, bool disabled})>
  borderTerminalKinds;

  /// Per terminal oid, the numeric literal its constant box displays
  /// ([bdConstValueTexts]). A mapped box drops the generic terminal's inner
  /// ring (the reference draws constants with the 2 px outer border only)
  /// and centres the value text.
  final Map<int, String> constValues;

  /// [color] through the measured disabled-frame palette transform when the
  /// object [oid] sits under a disabled displayed frame ([disabledOids]),
  /// alpha preserved ([dimDisabledFrameRgb] is measured on opaque ink).
  Color _dimFor(int oid, Color color) => disabledOids.contains(oid)
      ? bdDimDisabled(color).withValues(alpha: color.a)
      : color;

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

  /// Whether the faint canvas alignment-dot grid draws. An interactive-view
  /// affordance only: the oracle raster omits it (LabVIEW's reference
  /// renders have a plain white canvas, and the grid's near-white dots
  /// break byte-exact wire comparisons).
  final bool drawDotGrid;

  @override
  void paint(Canvas canvas, Size size) {
    // The layer rasterises at [canvasScale]; everything below draws in
    // logical diagram units under one canvas scale, so strokes, text, and
    // icons all render at the zoom's real resolution.
    canvas.scale(canvasScale);
    size = Size(size.width / canvasScale, size.height / canvasScale);
    canvas.drawRect(Offset.zero & size, Paint()..color = kBdCanvas);
    if (drawDotGrid) _drawDotGrid(canvas, size);

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
        canvas.drawRect(rect, Paint()..color = _dimFor(object.oid, decoded));
      } else if (!isBackdrop(object)) {
        canvas.drawRect(
          rect,
          Paint()..color = _dimFor(object.oid, const Color(0xFFF4F4F4)),
        );
        canvas.drawRect(
          rect,
          Paint()
            ..color = _dimFor(object.oid, Colors.black.withValues(alpha: 0.45))
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
    final tunnelLandings = <(Offset, Color)>[];
    final tunnelSquares =
        <(Rect, ({int kind, bool hollow, bool disabled}), Color)>[];
    // Rects owned by the reference-verified border-terminal chrome pass
    // (shift registers, selectors, tunnels). A modeled structure terminal at
    // the same rect must not also draw: its anti-aliased ring strokes bleed
    // a ring of blended pixels just OUTSIDE the rect that the byte-exact
    // chrome cannot cover.
    final chromeOwnedRects = <Rect>{
      for (final attach in borderTerminalKinds.keys)
        Rect.fromLTRB(
          attach.left - origin.dx,
          attach.top - origin.dy,
          attach.right - origin.dx,
          attach.bottom - origin.dy,
        ),
    };
    _drawWires(canvas, tunnelSquares: tunnelSquares);
    for (final object in structures) {
      // Class-accurate structure chrome (no badge text — LabVIEW names a
      // construct by its border furniture, not a label). Loops get the thick
      // rounded grey band with the iteration / conditional corner terminals;
      // case structures get their band plus selector chrome (drawn at the
      // decoded 0x95 label, see the label pass). A decoded structColor tints
      // the band (the pale sequence/timed tint); other structure kinds keep
      // the neutral double-line frame.
      final rect = rectOf(object);
      final structDisabled = disabledOids.contains(object.oid);
      final structColor = switch (bdDecodedColor(object.structRgb)) {
        null => null,
        final c => _dimFor(object.oid, c),
      };
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
        case 0x20: // For loop: crisp 1px black border + stacked pages.
          _drawForLoopBorder(canvas, rect, disabled: structDisabled);
          _drawStructureTerminals(
            canvas,
            rect,
            terminals,
            tunnelLandings,
            chromeOwnedRects: chromeOwnedRects,
            disabled: structDisabled,
          );
        case 0x21: // While loop: crisp rounded grey band + terminals.
          _drawWhileLoopBand(
            canvas,
            rect,
            structColor,
            disabled: structDisabled,
          );
          _drawStructureTerminals(
            canvas,
            rect,
            terminals,
            tunnelLandings,
            chromeOwnedRects: chromeOwnedRects,
            disabled: structDisabled,
          );
        case 0x2c: // Case structure: solid 1px border + global hatch band.
          _drawStructureHatchBorder(
            canvas,
            rect,
            object.absBounds!.left,
            object.absBounds!.top,
            disabled: structDisabled,
          );
          _drawStructureTerminals(
            canvas,
            rect,
            terminals,
            tunnelLandings,
            chromeOwnedRects: chromeOwnedRects,
            disabled: structDisabled,
          );
        default:
          final frame =
              structColor ??
              _dimFor(object.oid, _kindColor(ViObjectKind.structure));
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
    // Overlapping border terminals stack: the reference draws a selector
    // OVER the select tunnel sharing its edge (crc8's 0x2e/0x2d pair
    // overlaps by two rows), so squares first, registers, then selectors.
    tunnelSquares.sort(
      (a, b) => _chromeZOrder(a.$2.kind).compareTo(_chromeZOrder(b.$2.kind)),
    );
    for (final (rect, info, color) in tunnelSquares) {
      _drawBorderTerminalChrome(canvas, rect, info, color);
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
          canvas.drawRect(rect, Paint()..color = _dimFor(object.oid, backing));
          canvas.drawRect(
            rect,
            Paint()
              ..color = _dimFor(object.oid, Colors.black).withValues(alpha: 0.6)
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
          final tint = _dimFor(
            object.oid,
            object.typeKind != ViTypeKind.unknown
                ? labviewTypeColor(object.typeKind)
                : (bdDecodedColor(object.fgRgb) ?? kBdUnknownTerminalFill),
          );
          // An unknown-type terminal keeps a dark neutral border — the light
          // "unknown" grey as a border is invisible to the eye and the edge
          // masks alike.
          final border = typed
              ? tint
              : _dimFor(object.oid, const Color(0xFF5A5A5A));
          // A constant box ([constValues]) carries the 2 px outer border
          // only — the reference draws no inner ring around crc8's oid 3033
          // (its whole 160 px perimeter reads the plain dim-blue border) —
          // and shows its decoded literal centred instead of a type glyph.
          final constValue = constValues[object.oid];
          canvas.drawRect(rect, Paint()..color = Colors.white);
          canvas.drawRect(
            rect.deflate(1),
            Paint()
              ..color = border
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2.0,
          );
          if (constValue == null && rect.width > 10 && rect.height > 10) {
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
            canvas.drawPath(
              tri,
              Paint()
                ..color = _dimFor(
                  object.oid,
                  Colors.black,
                ).withValues(alpha: 0.87),
            );
          }
          // A constant's decoded literal, centred in its box the way
          // LabVIEW shows the value (crc8's oid 3033 renders `256`); inked
          // black through the disabled transform (the reference's disabled
          // digits read as the (153,153,153) dim of black).
          if (constValue != null && rect.width >= 12 && rect.height >= 12) {
            final tp = TextPainter(
              text: TextSpan(
                text: constValue,
                style: TextStyle(
                  color: _dimFor(object.oid, Colors.black),
                  fontSize: 10,
                  fontFamily: 'Roboto',
                ),
              ),
              maxLines: 1,
              ellipsis: '…',
              textDirection: TextDirection.ltr,
            )..layout(maxWidth: math.max(8, rect.width - 6));
            tp.paint(canvas, rect.center - Offset(tp.width / 2, tp.height / 2));
          }
          // The resolved data type's short label (DBL / I32 / TF / abc),
          // as LabVIEW stamps on the terminal — sized to sit inside the
          // double border even on a 16 px terminal. A constant box shows
          // its value instead, never the type.
          final glyph = constValue != null || object.dataType == null
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
          final disabled = disabledOids.contains(object.oid);
          final primIcon = iconKey == null
              ? null
              : (disabled ? primIconsGrey[iconKey] : null) ??
                    primIcons[iconKey];
          if (primIcon != null) {
            // The harvested art carries its own borders and transparency —
            // no plate, backing, or extra frame around it. Exactness paths
            // (NEAREST) sample the asset's own pixels: at any integer device
            // scale that replicates uniformly, where nearest on the 4x
            // prescale at a mismatched scale (a 3x supersampled raster)
            // doubled some columns and dropped others. The sharp-bilinear
            // interactive path samples the prescale with LINEAR.
            final filter =
                iconFilterQuality == FilterQuality.none ||
                    canvasScale >= kPrimIconPrescale
                ? FilterQuality.none
                : iconFilterQuality;
            final art = filter == FilterQuality.none
                ? primIcon.base
                : primIcon.sharp;
            final dst = primIconStampRect(
              rect,
              primIcon.base.width,
              primIcon.base.height,
              key: iconKey,
            );
            canvas.drawImageRect(
              art,
              Rect.fromLTWH(0, 0, art.width.toDouble(), art.height.toDouble()),
              dst,
              Paint()..filterQuality = filter,
            );
          } else if (icon != null) {
            paintLegacyIcon(canvas, icon, rect);
          } else {
            final fill = _dimFor(
              object.oid,
              isSubVi ? kBdSubViNodeFill : kBdPrimitiveNodeFill,
            );
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
                ..color = _dimFor(object.oid, Colors.black)
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
                  color: _dimFor(
                    object.oid,
                    Colors.black,
                  ).withValues(alpha: 0.75),
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
          final fill = _dimFor(
            object.oid,
            bdFillColor(object) ?? _objectColor(object),
          );
          canvas.drawRRect(rr, Paint()..color = fill.withValues(alpha: 0.92));
          canvas.drawRRect(
            rr,
            Paint()
              ..color = _dimFor(object.oid, Colors.black).withValues(alpha: 0.5)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 0.8,
          );
      }
    }
    // Wire landings on structure borders feed ONLY the structure-terminal
    // recolour above (the case selector [?] takes its wire's colour).
    // Tunnel squares are drawn in [_drawWires] at the DECODED attach rects
    // ([ViWire.endpointAttachRects]), never guessed from a landing point.
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
              color: _dimFor(
                object.oid,
                bdDecodedColor(object.fgRgb) ??
                    Colors.black.withValues(alpha: 0.85),
              ),
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
      final textColor = _dimFor(
        object.oid,
        bdDecodedColor(object.fgRgb) ?? Colors.black.withValues(alpha: 0.75),
      );
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

  /// Draws each decoded [ViWire], in HEAP SERIALIZATION ORDER of the `0x17`
  /// signals ([ViDiagram.wires] order, preserved by [bdVisibleWires]) — the
  /// draw order LabVIEW uses, which the crossing rule keys off (see
  /// `wire_render.dart`: where two wires cross, the LATER-serialized signal
  /// breaks with a 1 px gap either side of the earlier wire's ink band).
  ///
  /// Geometry: a wire with a proven absolute polyline
  /// ([ViWire.routePoints]) or branch tree ([ViWire.routeTree]) draws it exactly
  /// as stored — no extension, no clipping — except that a terminal segment
  /// ending on an icon-stamped node is extended under the art (to the box
  /// centre, or, for a one-anchored walk that enters the node off-centre,
  /// [ViWire.routeClosingStep] carries the run direction and the segment
  /// reaches the art's near ink edge on the arrival row). A wire with NO decoded
  /// route is not drawn: there is no synthesized Manhattan guess (until an
  /// editor exists), so an undecoded wire body simply does not appear.
  ///
  /// Stroke: driven by the wire-type word's measured render style
  /// ([ViSignalTypeRenderStyle.renderStyle]); the estimate tier
  /// ([renderStyleEstimate]) stands in ONLY for the simple solid/dotted
  /// styles (a patterned cycle is never drawn from an extrapolation), and
  /// wires with neither keep the pre-catalogue simple laws (array ⇒ 2 px,
  /// scalar boolean ⇒ dotted, else 1 px). Colour precedence is
  /// [bdWireColor]'s (typed terminal > catalogued source op > word element
  /// kind > neutral); a wire whose signal sits under a disabled displayed
  /// frame draws through [bdDimDisabled].
  void _drawWires(
    Canvas canvas, {
    List<(Rect, ({int kind, bool hollow, bool disabled}), Color)>?
    tunnelSquares,
  }) {
    if (wires.isEmpty) return;
    // Endpoint-anchor rectangle → recovered terminal colour, for honest
    // tinting; the icon-stamped node rects (wires route under them, to the
    // box centre, so the art's own ink decides the visible meeting point);
    // and each node's catalogued output colour ([PrimOp.output]).
    final typedTerminalColors = <int, Color>{};
    final sourceOutputColors = <int, Color>{};
    final iconNodeRects = <Rect>{};
    // Node box → the stamped art's ink bounding box (canvas coords): the
    // measured art edge a fallback-routed endpoint anchors to instead of
    // the node box, so a leg meets the icon where its ink actually is
    // (crc8's gates: the reference wires run at the art's edge-centre row,
    // not the 32x32 box's).
    final iconInkRects = <Rect, Rect>{};
    // Node box (canvas coords) → its object, so a wire's into-node closing run
    // can query the art's opaque EDGE on the exact arrival row.
    final iconNodeObjects = <Rect, ViHeapObject>{};
    for (final object in objects) {
      final bounds = object.absBounds;
      if (bounds == null) continue;
      final packed = _packRect(
        bounds.top,
        bounds.left,
        bounds.bottom,
        bounds.right,
      );
      if (object.category == ViObjectKind.terminal &&
          object.typeKind != ViTypeKind.unknown) {
        typedTerminalColors[packed] = labviewTypeColor(object.typeKind);
      }
      final iconKey = primIconKeyOf(object);
      if (iconKey != null) {
        final boxRect = Rect.fromLTRB(
          bounds.left - origin.dx,
          bounds.top - origin.dy,
          bounds.right - origin.dx,
          bounds.bottom - origin.dy,
        );
        iconNodeRects.add(boxRect);
        iconNodeObjects[boxRect] = object;
        final art = primIcons[iconKey]?.base;
        final ink = primIconInkBounds(iconKey);
        if (art != null && ink != null) {
          final stamp = primIconStampRect(
            boxRect,
            art.width,
            art.height,
            key: iconKey,
          );
          iconInkRects[boxRect] = ink.shift(stamp.topLeft);
        }
      }
      final output = object.primResId == null
          ? null
          : PrimOp.fromId(object.primResId!)?.output;
      if (output != null) {
        sourceOutputColors[packed] = labviewTypeColor(output);
      }
    }
    // Segments already drawn by EARLIER wires (heap serialization order),
    // in integer pixel space — the crossing rule cuts later wires around
    // them.
    final drawn = <_BdWireSeg>[];
    for (final wire in wires) {
      // Endpoints with a DECODED attach rect get their border-terminal
      // chrome drawn at it (kind-specific, reference-verified only). A wire's
      // BODY comes from its decoded route ([ViWire.routePoints] /
      // [ViWire.routeTree]); an endpoint's owner box no longer routes a leg.
      final tunnels = <(Rect, ({int kind, bool hollow, bool disabled}))>[];
      for (var e = 0; e < wire.endpointAnchors.length; e++) {
        final anchor = wire.endpointAnchors[e];
        if (anchor == null) continue;
        // A zero-area anchor is an endpoint whose nearest bounded owner is a
        // degenerate wire-segment stub — no chrome to place there.
        if (anchor.width <= 0 && anchor.height <= 0) continue;
        // The decoded terminal attach rect pins the endpoint exactly (the
        // tunnel on a structure border, a growable node's terminal).
        final attach = e < wire.endpointAttachRects.length
            ? wire.endpointAttachRects[e]
            : null;
        if (attach == null) continue;
        final attachRect = Rect.fromLTRB(
          attach.left - origin.dx,
          attach.top - origin.dy,
          attach.right - origin.dx,
          attach.bottom - origin.dy,
        );
        final info = borderTerminalKinds[attach];
        if (info != null) tunnels.add((attachRect, info));
      }
      var color = bdWireColor(
        wire,
        typedTerminalColors,
        sourceOutputColors: sourceOutputColors,
      );
      final wireDisabled = disabledOids.contains(wire.signalOid);
      if (wireDisabled) color = bdDimDisabled(color);
      // Chrome is collected whenever its position is decoded — even when
      // the wire's OTHER endpoint is unresolvable and no route can be
      // drawn — and painted AFTER the structure chrome (LabVIEW draws the
      // terminal over the band). A terminal inside a disabled frame draws
      // its chrome dimmed even when the wire's own signal is outside it.
      tunnelSquares?.addAll([
        for (final (t, info) in tunnels)
          (
            t,
            info,
            info.disabled && !wireDisabled ? bdDimDisabled(color) : color,
          ),
      ]);
      // Leg polylines: the proven absolute polyline when the parse shipped
      // one (exact at both ends — drawn as-is, no extension or clipping),
      // else synthesized Manhattan legs from the first anchor to each other
      // anchor.
      final routePoints = wire.routePoints;
      final routeTree = wire.routeTree;
      final legs = <List<Offset>>[];
      final junctions = <Offset>[];
      if (routeTree != null) {
        // A proven branching tree ([ViWire.routeTree]): every run drawn
        // exactly (origin-relative, no extension or clipping) and a branch
        // dot stamped at each junction. The runs feed the same stroke and
        // crossing-gap machinery as any other leg, so a branch wire obeys the
        // measured render laws. Its endpoints are decoded attach points (the
        // closure gate requires them), so — like a routePoints leg — the
        // attach-rect pass owns their chrome and no tunnel landing is added.
        for (final run in routeTree.polylines) {
          legs.add([
            for (final p in run) Offset(p.x - origin.dx, p.y - origin.dy),
          ]);
        }
        for (final j in routeTree.junctions) {
          junctions.add(Offset(j.x - origin.dx, j.y - origin.dy));
        }
      } else if (routePoints != null) {
        final points = [
          for (final p in routePoints) Offset(p.x - origin.dx, p.y - origin.dy),
        ];
        // A proven polyline connects at its DECODED attach point on the
        // endpoint's own border. Where that endpoint is an icon-stamped node,
        // LabVIEW draws the wire UNDER the art — the art's opaque pixels decide
        // the visible meeting point — so the terminal segment is extended into
        // the icon; the covered interior is masked by the art itself.
        if (points.length >= 2 && wire.endpointAnchors.length >= 2) {
          Rect? iconBox(int e) {
            final a = wire.endpointAnchors[e];
            if (a == null) return null;
            final box = Rect.fromLTRB(
              a.left - origin.dx,
              a.top - origin.dy,
              a.right - origin.dx,
              a.bottom - origin.dy,
            );
            return iconNodeRects.contains(box) ? box : null;
          }

          final sourceBox = iconBox(0);
          if (sourceBox != null) {
            final c = (iconInkRects[sourceBox] ?? sourceBox).center;
            final p0 = points.first, p1 = points[1];
            points[0] = p0.dy == p1.dy
                ? Offset(c.dx, p0.dy)
                : Offset(p0.dx, c.dy);
          }
          final sinkBox = iconBox(wire.endpointAnchors.length - 1);
          if (sinkBox != null) {
            final ink = iconInkRects[sinkBox] ?? sinkBox;
            final closing = wire.routeClosingStep;
            if (closing != null) {
              // The polyline ends at the last DECODED bend INSIDE the node;
              // the implied closing run enters along [ViWire.routeClosingStep]
              // at the wire's own input row (not the box centre). Extend a
              // segment from that bend along the closing axis to where the art
              // becomes OPAQUE on the arrival row ([primIconInkEdge]) — the ink
              // bounding box is per-art, so it can be transparent on this row
              // where a protruding feature elsewhere set its edge. The art then
              // overdraws the covered stub. Falls back to the ink-box edge when
              // the row carries no masked art.
              final last = points.last;
              final farObj = iconNodeObjects[sinkBox];
              if (closing.dx != 0) {
                final edge = farObj == null
                    ? null
                    : primIconInkEdge(
                        farObj,
                        horizontal: true,
                        cross: (last.dy + origin.dy).round(),
                        sign: closing.dx,
                      );
                points.add(
                  Offset(
                    edge != null
                        ? edge - origin.dx
                        : (closing.dx > 0 ? ink.left : ink.right - 1),
                    last.dy,
                  ),
                );
              } else {
                final edge = farObj == null
                    ? null
                    : primIconInkEdge(
                        farObj,
                        horizontal: false,
                        cross: (last.dx + origin.dx).round(),
                        sign: closing.dy,
                      );
                points.add(
                  Offset(
                    last.dx,
                    edge != null
                        ? edge - origin.dy
                        : (closing.dy > 0 ? ink.top : ink.bottom - 1),
                  ),
                );
              }
            } else {
              // The closing run reached the box edge: run on under the art to
              // the icon centre (the art masks the covered interior).
              final c = ink.center;
              final pn = points.last, pm = points[points.length - 2];
              points[points.length - 1] = pn.dy == pm.dy
                  ? Offset(c.dx, pn.dy)
                  : Offset(pn.dx, c.dy);
            }
          }
        }
        legs.add(points);
      }
      // A wire with NO decoded route (neither a proven [ViWire.routePoints]
      // polyline nor a branch [ViWire.routeTree]) is not drawn: the app renders
      // decoded geometry only, never a synthesized Manhattan guess (there is no
      // built-in routing until an editor exists). Its endpoint chrome is still
      // collected above; the wire body simply does not appear.
      // Stroke style: measured tier first; the estimate tier stands in for
      // the simple solid/dotted styles only (never a patterned cycle); the
      // pre-catalogue simple laws cover the remainder (array ⇒ 2 px, scalar
      // boolean ⇒ dotted, else 1 px).
      final st = wire.signalType;
      var style = st?.renderStyle;
      if (style == null) {
        final estimate = st?.renderStyleEstimate;
        if (estimate == ViWireRenderStyle.solid1px ||
            estimate == ViWireRenderStyle.solid2px ||
            estimate == ViWireRenderStyle.dotted) {
          style = estimate;
        }
      }
      style ??=
          (wire.elementTypeKind == ViTypeKind.boolean &&
              (st?.arrayDims ?? 0) == 0)
          ? ViWireRenderStyle.dotted
          : ((st?.arrayDims ?? 0) >= 1
                ? ViWireRenderStyle.solid2px
                : ViWireRenderStyle.solid1px);

      final fill = Paint()
        ..color = color
        ..isAntiAlias = false;
      final (bandLo, bandHi) = bdWireStrokeBand(style);
      // Segments this wire draws — appended to [drawn] only after the whole
      // wire, so a wire never gaps against its own bends.
      final mine = <_BdWireSeg>[];
      for (final leg in legs) {
        for (var j = 1; j < leg.length; j++) {
          final a = leg[j - 1], b = leg[j];
          if (a == b) continue;
          final horizontal = a.dy == b.dy;
          var lo = (horizontal ? math.min(a.dx, b.dx) : math.min(a.dy, b.dy))
              .floor();
          var hi = (horizontal ? math.max(a.dx, b.dx) : math.max(a.dy, b.dy))
              .floor();
          final cross = (horizontal ? a.dy : a.dx).floor();
          // Bend continuity for the 2 px solid stroke: at a shared vertex
          // the segment also covers the perpendicular partner's ink band, so
          // the corner fills its full 2x2 square (measured on crc8's routed
          // 2 px elbows).
          if (style == ViWireRenderStyle.solid2px) {
            for (final neighbour in [
              if (j >= 2) leg[j - 2],
              if (j + 1 < leg.length) leg[j + 1],
            ]) {
              final nCross = (horizontal ? neighbour.dx : neighbour.dy).floor();
              if (nCross + bandLo < lo) lo = nCross + bandLo;
              if (nCross + bandHi > hi) hi = nCross + bandHi;
            }
          }
          // Crossing gaps (the measured rule, see wire_render.dart): where
          // this later-drawn segment properly crosses an EARLIER wire's
          // perpendicular segment, it skips a 1 px gap either side of the
          // earlier stroke's ink band; the earlier ink survives. Endpoint
          // touches (T-junctions) are not crossings.
          final gaps = <(int, int)>[];
          for (final e in drawn) {
            if (e.horizontal == horizontal) continue;
            if (e.bandLo > lo &&
                e.bandHi < hi &&
                cross + bandLo > e.lo &&
                cross + bandHi < e.hi) {
              gaps.add((e.bandLo - 1, e.bandHi + 1));
            }
          }
          _strokeSegment(canvas, fill, style, horizontal, lo, hi, cross, gaps);
          mine.add((
            horizontal: horizontal,
            lo: lo,
            hi: hi,
            bandLo: cross + bandLo,
            bandHi: cross + bandHi,
          ));
        }
      }
      drawn.addAll(mine);
      // Branch dots sit on top of the wire's own runs (same colour); they are
      // terminal features, not crossing segments, so they are not recorded in
      // [drawn].
      for (final junction in junctions) {
        _drawWireJunctionDot(canvas, junction, fill);
      }
    }
  }

  /// The branch-junction dot LabVIEW stamps where a wire forks — a filled
  /// 5x5 disc with the four corner pixels clipped (row widths 3/5/5/5/3),
  /// centred on the junction pixel, in the wire's colour ([fill]). Measured
  /// from reference snippets (Excel_Read_XLSX, Read VI Blocks, large,
  /// ProjectItems) on 1 px scalar wires; the thick-wire dot size is not
  /// separately sampled (TODO: measure a thick-wire junction).
  void _drawWireJunctionDot(Canvas canvas, Offset center, Paint fill) {
    final cx = center.dx.floorToDouble();
    final cy = center.dy.floorToDouble();
    for (var dy = -2; dy <= 2; dy++) {
      for (var dx = -2; dx <= 2; dx++) {
        if (dx.abs() == 2 && dy.abs() == 2) continue;
        canvas.drawRect(Rect.fromLTWH(cx + dx, cy + dy, 1, 1), fill);
      }
    }
  }

  /// Draws one Manhattan wire segment in [style]: the along-axis pixel range
  /// [lo]..[hi] (inclusive) at route row/column [cross], skipping the
  /// crossing-gap ranges [gaps] (inclusive, along the same axis).
  void _strokeSegment(
    Canvas canvas,
    Paint fill,
    ViWireRenderStyle style,
    bool horizontal,
    int lo,
    int hi,
    int cross,
    List<(int, int)> gaps,
  ) {
    gaps.sort((x, y) => x.$1.compareTo(y.$1));
    var v = lo;
    for (final (gLo, gHi) in [...gaps, (hi + 1, hi + 1)]) {
      final end = math.min(hi, gLo - 1);
      if (v <= end) _strokeRun(canvas, fill, style, horizontal, v, end, cross);
      if (gHi + 1 > v) v = gHi + 1;
    }
  }

  /// Draws one gap-free run of a wire stroke, pixels [lo]..[hi] inclusive.
  ///
  /// Horizontal runs follow the measured catalogue: the solid bands, the
  /// dotted checkerboard (ink exactly where `x + y` is even — measured on
  /// 20 clean corpus dotted runs and both crc8 orientations, zero
  /// counterexamples), and the patterned column cycles
  /// ([kBdWireStrokeCycles]). VERTICAL runs of the multi-row patterned
  /// styles draw a plain 1 px line in the wire colour instead: the vertical
  /// renditions of those cycles are not yet measured (the census pinned
  /// them orientation-DEPENDENT — e.g. vertical string wires compress to a
  /// period-2 cycle), so nothing is guessed. TODO: catalogue the vertical
  /// cycles and draw them.
  void _strokeRun(
    Canvas canvas,
    Paint fill,
    ViWireRenderStyle style,
    bool horizontal,
    int lo,
    int hi,
    int cross,
  ) {
    Rect px(int along, int band) => horizontal
        ? Rect.fromLTWH(along.toDouble(), band.toDouble(), 1, 1)
        : Rect.fromLTWH(band.toDouble(), along.toDouble(), 1, 1);
    Rect span(int bandLo, int bandHi) => horizontal
        ? Rect.fromLTRB(
            lo.toDouble(),
            (cross + bandLo).toDouble(),
            hi + 1.0,
            cross + bandHi + 1.0,
          )
        : Rect.fromLTRB(
            (cross + bandLo).toDouble(),
            lo.toDouble(),
            cross + bandHi + 1.0,
            hi + 1.0,
          );
    switch (style) {
      case ViWireRenderStyle.solid1px:
        canvas.drawRect(span(0, 0), fill);
      case ViWireRenderStyle.solid2px:
        canvas.drawRect(span(-1, 0), fill);
      case ViWireRenderStyle.hollowDouble:
        // Period-1 and hence orientation-symmetric (see the catalogue).
        canvas.drawRect(span(-1, -1), fill);
        canvas.drawRect(span(1, 1), fill);
      case ViWireRenderStyle.dotted:
        for (var v = lo; v <= hi; v++) {
          if ((v + cross).isEven) canvas.drawRect(px(v, cross), fill);
        }
      case ViWireRenderStyle.dottedAlternating when horizontal:
        // Catalogued period-2 cycle: single dots alternating between the
        // route row and the row above. The absolute phase is unmeasured;
        // anchored so the route-row dot sits on even x+y, matching the
        // dotted family's measured checkerboard (TODO: measure the phase).
        for (var v = lo; v <= hi; v++) {
          canvas.drawRect(px(v, (v + cross).isEven ? cross : cross - 1), fill);
        }
      default:
        final cycle = horizontal ? kBdWireStrokeCycles[style] : null;
        if (cycle == null) {
          // Vertical run of a patterned style: the vertical cycles are not
          // yet measured, so the honest fallback is a plain 1 px line in
          // the wire colour (TODO above).
          canvas.drawRect(span(0, 0), fill);
          return;
        }
        for (var v = lo; v <= hi; v++) {
          final mask = cycle[v % cycle.length];
          for (var bit = 0; bit < 5; bit++) {
            if ((mask >> bit) & 1 != 0) {
              canvas.drawRect(px(v, cross + bit - 2), fill);
            }
          }
        }
    }
  }

  /// The stacking order for overlapping border-terminal chrome (see the
  /// paint site): tunnels/select squares under registers under selectors.
  static int _chromeZOrder(int kind) => switch (kind) {
    0x22 || 0x2d => 0,
    0x27 || 0x28 => 1,
    _ => 2,
  };

  /// Border-terminal chrome at a DECODED attach rect, per terminal class —
  /// every spec read from reference pixels (crc8/crc16/crc32):
  ///
  /// - tunnel `0x22` / select `0x2d`: the rect filled with the wire's
  ///   colour under a 1 px [kBdTunnelBorder] ring, over the structure band
  ///   (crc8's loop tunnel at (158,499)-(167,508)).
  /// - shift registers `0x27`/`0x28` (16x12): a 2 px wire-colour border,
  ///   cream fill, and a wire-colour 5-row triangle glyph — down (10,8,6,
  ///   4,2 wide) on the left register, up on the right.
  /// - selector `0x2e` (8x12): a 1 px wire-colour border, cream fill, and
  ///   the 6x10 `?` glyph.
  ///
  /// A register/selector whose rect differs from the measured size draws
  /// border + fill only (the glyph layout is pinned to the measured
  /// geometry, never scaled by guesswork).
  ///
  /// A terminal inside a disable structure's displayed Disabled frame
  /// (`info.disabled`) draws its wire-derived colours through the measured
  /// wire transform ([bdDimDisabled], applied by the wire pass) and its
  /// neutral chrome through the measured disabled mappings: the dark ring
  /// goes to the icon line-work grey ([kBdDisabledChromeGrey]) and the
  /// cream fill goes white (both measured mappings agree on the cream —
  /// [bdDimDisabled] clamps it to white too). Nothing is hand-tuned.
  void _drawBorderTerminalChrome(
    Canvas canvas,
    Rect t,
    ({int kind, bool hollow, bool disabled}) info,
    Color wireColor,
  ) {
    final kind = info.kind;
    final ringColor = info.disabled ? kBdDisabledChromeGrey : kBdTunnelBorder;
    final creamColor = info.disabled
        ? bdDimDisabled(kBdTerminalFill)
        : kBdTerminalFill;
    final noAa = Paint()
      ..color = wireColor
      ..isAntiAlias = false;
    switch (kind) {
      case 0x22 || 0x2d:
        // Hollow ([kTunnelHollowFlag]): cream interior with a 5x5
        // wire-colour ring (open at the middle of its top/bottom edges),
        // read from crc8's reference at (520,276). Solid: wire-colour fill.
        if (info.hollow) {
          canvas.drawRect(
            t,
            Paint()
              ..color = creamColor
              ..isAntiAlias = false,
          );
          if (t.width == 9 && t.height == 9) {
            const ring = ['xx.xx', 'x...x', 'x...x', 'x...x', 'xx.xx'];
            for (var y = 0; y < 5; y++) {
              for (var x = 0; x < 5; x++) {
                if (ring[y][x] != 'x') continue;
                canvas.drawRect(
                  Rect.fromLTWH(t.left + 2 + x, t.top + 2 + y, 1, 1),
                  noAa,
                );
              }
            }
          }
        } else {
          canvas.drawRect(t, noAa);
        }
        canvas.drawRect(
          Rect.fromLTRB(
            t.left + 0.5,
            t.top + 0.5,
            t.right - 0.5,
            t.bottom - 0.5,
          ),
          Paint()
            ..color = ringColor
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..isAntiAlias = false,
        );
      case 0x27 || 0x28:
        canvas.drawRect(t, noAa);
        canvas.drawRect(
          t.deflate(2),
          Paint()
            ..color = creamColor
            ..isAntiAlias = false,
        );
        if (t.width == 16 && t.height == 12) {
          // Triangle rows within the 12x8 interior: row index 2..6 for the
          // down arrow, 1..5 for the up arrow, widths 10/8/6/4/2 centred.
          final down = kind == 0x27;
          for (var i = 0; i < 5; i++) {
            final width = down ? 10 - 2 * i : 2 + 2 * i;
            final row = (down ? 2 + i : 1 + i).toDouble();
            canvas.drawRect(
              Rect.fromLTWH(
                t.left + 2 + (12 - width) / 2,
                t.top + 2 + row,
                width.toDouble(),
                1,
              ),
              noAa,
            );
          }
        }
      case 0x2e:
        canvas.drawRect(t, noAa);
        canvas.drawRect(
          t.deflate(1),
          Paint()
            ..color = creamColor
            ..isAntiAlias = false,
        );
        if (t.width == 8 && t.height == 12) {
          const glyph = [
            '......',
            '..xx..',
            '.x..x.',
            '....x.',
            '...x..',
            '..x...',
            '..x...',
            '......',
            '..x...',
            '......',
          ];
          for (var y = 0; y < glyph.length; y++) {
            for (var x = 0; x < 6; x++) {
              if (glyph[y][x] != 'x') continue;
              canvas.drawRect(
                Rect.fromLTWH(t.left + 1 + x, t.top + 1 + y, 1, 1),
                noAa,
              );
            }
          }
        }
    }
  }

  /// The while-loop's rounded corners, measured per-corner from LabVIEW's
  /// raster (its rounding is NOT symmetric — the right and bottom edges round a
  /// pixel fuller than the left and top). `#` = grey band pixel, indexed
  /// `[distance-from-cap-edge][distance-from-side-edge]` from the outer corner.
  /// The bottom-right corner is the arrow ([_kWhileArrow]).
  static const _kWhileCornerTL = [
    '.....#',
    '..####',
    '.#####',
    '.#####',
    '.#####',
    '######',
  ];
  static const _kWhileCornerTR = [
    '....##',
    '...###',
    '.#####',
    '.#####',
    '.#####',
    '######',
  ];
  static const _kWhileCornerBL = [
    '.....#',
    '..####',
    '..####',
    '.#####',
    '######',
    '######',
  ];

  /// The rotational arrow LabVIEW draws into a while-loop's bottom-right corner
  /// (the gap-and-arrowhead is what marks the frame a *while* loop), measured
  /// from the raster. Rows run top→bottom, the last at the band's bottom row;
  /// columns run left→right ending at the frame's right edge. `#` grey.
  static const _kWhileArrow = [
    '.........',
    '.........',
    '.########',
    '..#######',
    '#########',
    '#########',
    '#########',
    '#########',
    '#########',
    '#####...#',
  ];

  /// The while-loop border LabVIEW draws: a crisp [_kWhileBand]-px mid-grey
  /// (0xFF777777) band, hard-edged (no anti-aliasing) so its outer edge is a
  /// line the oracle registration locks onto, with rounded corners
  /// ([_kWhileCorner]) and the rotational arrow ([_kWhileArrow]) in the
  /// bottom-right. The interior stays clear — LabVIEW washes no colour inside a
  /// plain while loop. A decoded [tint] only recolours the band.
  void _drawWhileLoopBand(
    Canvas canvas,
    Rect rect,
    Color? tint, {
    bool disabled = false,
  }) {
    Color dim(Color c) => disabled ? bdDimDisabled(c) : c;
    final grey = tint ?? dim(const Color(0xFF777777));
    // The band's drawn box runs 1px right of the stored bounds: a 1px gutter on
    // the left, flush on the right (top flush, bottom inset 1). [l,r) × [t,b).
    final l = rect.left.round() + 1, t = rect.top.round();
    final r = rect.right.round() + 1, b = rect.bottom.round();
    const band = _kWhileBand;
    // Bottom-right arrow footprint (columns then rows), anchored to the frame's
    // right/bottom edge; excluded from the ring loop so the arrow alone fills
    // it. Its last row is the band's bottom row.
    final aw = _kWhileArrow.first.length, ah = _kWhileArrow.length;
    final ax0 = r - aw, ay0 = b - ah;

    final path = Path();
    void add(int x, int y) =>
        path.addRect(Rect.fromLTWH(x.toDouble(), y.toDouble(), 1, 1));

    for (var y = t; y < b; y++) {
      final dt = y - t, db = b - 1 - y;
      for (var x = l; x < r; x++) {
        final dl = x - l, dr = r - 1 - x;
        final edge = dl < band || dr < band || dt < band || db < band;
        if (!edge) continue;
        if (x >= ax0 && y >= ay0) continue; // arrow owns this cell
        bool grey1;
        if (dt < band && dl < band) {
          grey1 = _kWhileCornerTL[dt][dl] == '#';
        } else if (dt < band && dr < band) {
          grey1 = _kWhileCornerTR[dt][dr] == '#';
        } else if (db < band && dl < band) {
          grey1 = _kWhileCornerBL[db][dl] == '#';
        } else {
          grey1 = true; // straight run (bottom-right handled by the arrow)
        }
        if (grey1) add(x, y);
      }
    }
    // Stamp the arrow (its last row sits one pixel below the band bottom).
    for (var ry = 0; ry < ah; ry++) {
      for (var rx = 0; rx < aw; rx++) {
        if (_kWhileArrow[ry][rx] == '#') add(ax0 + rx, ay0 + ry);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = grey
        ..isAntiAlias = false,
    );
  }

  static const _kWhileBand = 6;

  /// Draws a for-loop's border pixel-exact to LabVIEW's own render: crisp
  /// 1px-black chrome shaped as a stack of three pages, the top page's
  /// bottom-right corner turned up in a dog-ear. No anti-aliasing, no
  /// translucent interior wash. The stack is fixed decoration — its geometry
  /// does not vary with the loop's `N`.
  ///
  /// Measured from LabVIEW's raster (crc8's for loops). The BACK page is the
  /// full rectangle `[left, top]..[right-5, bottom-5]`, but its bottom-right
  /// corner is folded: the right and bottom edges stop [_kForLoopFold] px
  /// short and an 8×8 triangular flap (top + left + diagonal hypotenuse)
  /// stands in for the square corner. Two more pages peek out below-and-right
  /// at +2 and +4 px, each contributing only its bottom edge, right edge, and
  /// the short corner steps that tie it to the page behind — a 3px horizontal
  /// at the top-right and a 1px vertical at the bottom-left.
  void _drawForLoopBorder(Canvas canvas, Rect rect, {bool disabled = false}) {
    final ink = disabled
        ? bdDimDisabled(const Color(0xFF000000))
        : const Color(0xFF000000);
    final paint = Paint()
      ..color = ink
      ..isAntiAlias = false;
    final l = rect.left.roundToDouble();
    final t = rect.top.roundToDouble();
    final r = rect.right.roundToDouble();
    final b = rect.bottom.roundToDouble();
    // 1px fills spanning inclusive integer pixel endpoints.
    void px(double x, double y) =>
        canvas.drawRect(Rect.fromLTRB(x, y, x + 1, y + 1), paint);
    void hline(double x0, double x1, double y) =>
        canvas.drawRect(Rect.fromLTRB(x0, y, x1 + 1, y + 1), paint);
    void vline(double x, double y0, double y1) =>
        canvas.drawRect(Rect.fromLTRB(x, y0, x + 1, y1 + 1), paint);

    const fold = _kForLoopFold;
    final backRight = r - 5, backBottom = b - 5; // back page's corner
    // Back page: top and left run full; right and bottom stop short of the
    // dog-ear that replaces the bottom-right corner.
    hline(l, backRight, t);
    vline(l, t, backBottom);
    vline(backRight, t, backBottom - fold);
    hline(l, backRight - fold, backBottom);
    // Dog-ear flap: top edge, left edge, and the diagonal hypotenuse joining
    // the shortened right and bottom edges.
    hline(backRight - fold, backRight, backBottom - fold);
    vline(backRight - fold, backBottom - fold, backBottom);
    for (var i = 1; i < fold; i++) {
      px(backRight - i, backBottom - fold + i);
    }
    // Middle (+2) and front (+4) pages: bottom edge, right edge, and the two
    // corner steps connecting each to the page behind it.
    for (final o in const [2.0, 4.0]) {
      hline(l + o, backRight + o, backBottom + o);
      vline(backRight + o, t + o, backBottom + o);
      hline(backRight + o - 2, backRight + o, t + o); // top-right step
      px(l + o, backBottom + o - 1); // bottom-left step
    }
  }

  /// Draws a case/sequence frame's border exactly as LabVIEW does: a solid 1px
  /// black outer rectangle wrapping a [_kHatchBand]-px band of the global
  /// [_kStructureHatch] lattice. The hatch phase is keyed on ABSOLUTE diagram
  /// coordinates ([absLeft]/[absTop] give the frame's top-left in that space),
  /// so the pattern is continuous across the diagram — the frame is a window
  /// onto it, not a source of it. Drawn before the tunnel chrome pass, which
  /// paints over it where border terminals land.
  void _drawStructureHatchBorder(
    Canvas canvas,
    Rect rect,
    int absLeft,
    int absTop, {
    bool disabled = false,
  }) {
    final ink = disabled
        ? bdDimDisabled(const Color(0xFF000000))
        : const Color(0xFF000000);
    final paint = Paint()
      ..color = ink
      ..isAntiAlias = false;
    final l = rect.left.round(), t = rect.top.round();
    final w = rect.width.round(), h = rect.height.round();
    if (w < 2 || h < 2) return;
    // Solid 1px outer border.
    canvas.drawRect(
      Rect.fromLTWH(l.toDouble(), t.toDouble(), w.toDouble(), 1),
      paint,
    );
    canvas.drawRect(
      Rect.fromLTWH(l.toDouble(), (t + h - 1).toDouble(), w.toDouble(), 1),
      paint,
    );
    canvas.drawRect(
      Rect.fromLTWH(l.toDouble(), t.toDouble(), 1, h.toDouble()),
      paint,
    );
    canvas.drawRect(
      Rect.fromLTWH((l + w - 1).toDouble(), t.toDouble(), 1, h.toDouble()),
      paint,
    );
    // Hatch band: only the black cells, batched into one path. Iterate the
    // perimeter ring (skip the interior columns of the middle rows).
    final band = Path();
    for (var j = 0; j < h; j++) {
      final nearTopBottom = j <= _kHatchBand || j >= h - 1 - _kHatchBand;
      for (var i = 0; i < w; i++) {
        if (!nearTopBottom && i > _kHatchBand && i < w - 1 - _kHatchBand) {
          continue; // interior — no border here
        }
        final d = math.min(math.min(i, j), math.min(w - 1 - i, h - 1 - j));
        if (d < 1 || d > _kHatchBand) continue; // 0 = solid, >5 = interior
        if (_kStructureHatch[(absTop + j) & 3][(absLeft + i) & 3] != '#') {
          continue;
        }
        band.addRect(
          Rect.fromLTWH((l + i).toDouble(), (t + j).toDouble(), 1, 1),
        );
      }
    }
    canvas.drawPath(band, paint);
  }

  /// Side length (px) of the for-loop's dog-ear corner fold — fixed chrome,
  /// measured from LabVIEW's raster.
  static const _kForLoopFold = 8.0;

  /// The diagonal hatch LabVIEW fills a structure (case / sequence) frame with,
  /// indexed `[absY % 4][absX % 4]` — a single lattice anchored to absolute
  /// diagram coordinates, NOT to each frame, so neighbouring structures and
  /// the four corners of one frame show different phases. Measured from crc8's
  /// case frames (716 and 1861 fit this tile identically). `#` = black.
  static const _kStructureHatch = ['.#.#', '#.#.', '##..', '..##'];

  /// Width (px) of the hatch band inside a case/sequence frame's solid 1px
  /// outer border.
  static const _kHatchBand = 5;

  static const _loopBlue = Color(0xFF0033CC);

  /// `termBMPs` glyph selectors (corpus pairing, see the package's
  /// [HeapAttribute.termBMPs] doc).
  static const _bmpIteration = 1; // the loop `i`
  static const _bmpCount = 2; // the for-loop `N`
  static const _bmpLeftShiftRegister = 3; // ▼ delivers
  static const _bmpRightShiftRegister = 4; // ▲ stores
  static const _bmpCaseSelector = 5; // the case `?` tunnel
  static const _bmpConditional = 192; // the while-loop stop

  /// The for-loop count `N` and iteration `i` glyphs exactly as LabVIEW
  /// rasters them inside a 16×16 border terminal — 1px cells at box-relative
  /// (col,row) from [origin]. Blue ink on a cream field with a 2px blue
  /// border, reproduced pixel-for-pixel like the selector/tunnel chrome
  /// rather than approximated with a font.
  static const _forLoopNGlyph = (
    origin: (4, 3),
    rows: [
      '#.....#',
      '##....#',
      '###...#',
      '####..#',
      '#.###.#',
      '#..####',
      '#...###',
      '#....##',
      '#.....#',
    ],
  );
  static const _forLoopIGlyph = (
    origin: (7, 4),
    rows: ['##', '..', '##', '##', '##', '##', '##', '##', '##'],
  );

  /// Draws a 16×16 loop count/iteration terminal pixel-exact: cream field,
  /// 2px blue border, and the [glyph] bitmap in blue. Colours route through
  /// the measured disabled-frame transform when [disabled].
  void _drawLoopGlyphTerminal(
    Canvas canvas,
    Rect box,
    ({(int, int) origin, List<String> rows}) glyph, {
    bool disabled = false,
  }) {
    Color dim(Color c) => disabled ? bdDimDisabled(c) : c;
    final ink = Paint()
      ..color = dim(const Color(0xFF0000FF))
      ..isAntiAlias = false;
    final l = box.left.roundToDouble(), t = box.top.roundToDouble();
    canvas.drawRect(
      box,
      Paint()
        ..color = dim(kBdTerminalFill)
        ..isAntiAlias = false,
    );
    // 2px blue border as four bands.
    canvas.drawRect(Rect.fromLTWH(l, t, 16, 2), ink);
    canvas.drawRect(Rect.fromLTWH(l, t + 14, 16, 2), ink);
    canvas.drawRect(Rect.fromLTWH(l, t, 2, 16), ink);
    canvas.drawRect(Rect.fromLTWH(l + 14, t, 2, 16), ink);
    final (ox, oy) = glyph.origin;
    for (var gy = 0; gy < glyph.rows.length; gy++) {
      final row = glyph.rows[gy];
      for (var gx = 0; gx < row.length; gx++) {
        if (row[gx] != '#') continue;
        canvas.drawRect(Rect.fromLTWH(l + ox + gx, t + oy + gy, 1, 1), ink);
      }
    }
  }

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
  ///
  /// A terminal whose box the reference-verified chrome pass owns
  /// ([chromeOwnedRects] — shift registers, selectors, tunnels reached by a
  /// decoded wire attach rect) is skipped: the chrome reproduces the
  /// reference byte-for-byte inside the rect, and this pass's anti-aliased
  /// ring would bleed blended pixels just outside it. [disabled] routes the
  /// glyph/border colours through the measured disabled-frame transform.
  void _drawStructureTerminals(
    Canvas canvas,
    Rect frame,
    List<({HeapRect box, int bmp})> terminals,
    List<(Offset, Color)>? tunnelLandings, {
    Set<Rect> chromeOwnedRects = const {},
    bool disabled = false,
  }) {
    Color dim(Color c) => disabled ? bdDimDisabled(c) : c;
    for (final t in terminals) {
      final box = Rect.fromLTWH(
        frame.left + t.box.left,
        frame.top + t.box.top,
        t.box.width.toDouble(),
        t.box.height.toDouble(),
      );
      if (chromeOwnedRects.contains(box)) continue;
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
      // Count `N` / iteration `i` terminals: LabVIEW draws a 16×16 blue box
      // with a cream field and a bitmap glyph — reproduced pixel-exact, the
      // same reference-verified chrome treatment as the selector and tunnels.
      if (box.width == 16 &&
          box.height == 16 &&
          (t.bmp == _bmpCount || t.bmp == _bmpIteration)) {
        _drawLoopGlyphTerminal(
          canvas,
          box,
          t.bmp == _bmpCount ? _forLoopNGlyph : _forLoopIGlyph,
          disabled: disabled,
        );
        continue;
      }
      final border = switch (t.bmp) {
        _bmpConditional => dim(const Color(0xFF007F00)),
        _ => wireColor ?? dim(_loopBlue),
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
          _drawGlyphText(canvas, box, 'i', dim(_loopBlue));
        case _bmpCount:
          _drawGlyphText(canvas, box, 'N', dim(_loopBlue));
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
          canvas.drawPath(
            tri,
            Paint()..color = dim(Colors.black).withValues(alpha: 0.87),
          );
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
          canvas.drawPath(path, Paint()..color = dim(const Color(0xFFCC0000)));
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
      !identical(old.primIconsGrey, primIconsGrey) ||
      !setEquals(old.disabledOids, disabledOids) ||
      old.iconFilterQuality != iconFilterQuality ||
      old.canvasScale != canvasScale ||
      old.drawDotGrid != drawDotGrid ||
      !identical(old.structureTerminals, structureTerminals) ||
      !identical(old.constValues, constValues) ||
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
    final rect = Rect.fromLTRB(
      bounds.left - origin.dx,
      bounds.top - origin.dy,
      bounds.right - origin.dx,
      bounds.bottom - origin.dy,
    );
    // Icon-stamped nodes outline the stamped art, not the (often square)
    // model box — matching what is drawn and what the alpha hitbox accepts.
    final key = primIconKeyOf(o);
    final art = key == null ? null : primIconsLoaded()[key];
    return art == null
        ? rect
        : primIconStampRect(rect, art.base.width, art.base.height, key: key);
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
          // to blank canvases) belong to the Images tab; this row stays a
          // single fixed-size icon so it can never overflow.
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
