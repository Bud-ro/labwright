import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart' show AssetManifest, rootBundle;

import 'package:flutter/material.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import 'bd_text_font.dart';
import 'prim_terminal_catalog.dart';
import 'terminal_bitmaps.dart';

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
    this.sections = const [],
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

  /// The VI's decoded sections, used to recover XNode facade images (`DSIM`
  /// PNGs stamped over `0x105` nodes — see [xnodeFacadesFromSections]). Only
  /// meaningful for the block diagram; empty (the default) draws XNodes as
  /// plain boxes.
  final List<DecodedSection> sections;

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
  Map<int, ui.Image> _xnodeFacades = const {};

  /// The diagram-derived render inputs, computed once (see [BdScene]).
  late final BdScene? _scene = switch (_diagram) {
    null => null,
    final diagram => BdScene(diagram),
  };
  List<ViHeapObject> get _drawable => _scene?.drawable ?? const [];
  Rect get _content => _scene?.content ?? Rect.zero;
  late final Map<ViObjectKind, int> _counts = _computeCounts();

  /// The control-flow outline, derived once — rebuilding it on every
  /// selection tap / zoom re-anchor re-walked the whole object list.
  late final _outline = computeBdOutline(_drawable);

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
    if (_diagram != null && widget.sections.isNotEmpty) {
      xnodeFacadesFromSections(widget.sections, _diagram).then((facades) {
        if (!mounted) {
          for (final image in facades.values) {
            image.dispose();
          }
          return;
        }
        if (facades.isNotEmpty) setState(() => _xnodeFacades = facades);
      });
    }
    if (_scene?.disabledOids.isNotEmpty ?? false) {
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
    _scene?.dispose();
    for (final image in _xnodeFacades.values) {
      image.dispose();
    }
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _toolbar(_drawable.length),
        const SizedBox(height: 4),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _diagramStack(content, _scene!.ordered)),
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
        _BdOutline(outline: _outline, linkedSubVis: widget.subViNames),
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
                          onTapDown: (details) => _selectAt(
                            details.localPosition / _anchorScale,
                            ordered,
                            content,
                          ),
                          child: CustomPaint(
                            size: Size(
                              content.width * _anchorScale,
                              content.height * _anchorScale,
                            ),
                            painter: BdDiagramPainter(
                              scene: _scene!,
                              origin: content.topLeft,
                              subViIcons: _subViIcons,
                              xnodeFacades: _xnodeFacades,
                              primIcons: _primIcons,
                              primIconsGrey: primIconsGreyLoaded(),
                              iconFilterQuality: FilterQuality.low,
                              canvasScale: _anchorScale,
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
    // ARRAY GRID CELLS ARE PAINTED, NOT REAL: an array constant stores ONE
    // element prototype (`0x50`) plus the index spinners — every other grid
    // cell is furniture the shell painter tiles from that prototype,
    // enumerating [ViHeapObject.constArray]. There is no heap object per
    // cell to select, and the wrap/window `0x9` parts are scaffolding
    // ([_isScaffolding]) outside the hit list, so a click on a painted cell
    // lands on no real child at all. It still resolves usefully with no
    // special case: the `0x52` shell itself is in the hit list and contains
    // the point, so the smallest-area rule selects the array container —
    // the object that actually owns the pixels — while clicks on the
    // prototype or spinners keep selecting those real children. (The `0x13`
    // const holder carrying the decoded values would be the other candidate,
    // but it has no bounds — no selection outline could be drawn for it and
    // the details card would show a bare record.)
    setState(() {
      _selected = hit;
      _members = hit != null && hit.category == ViObjectKind.structure
          ? nodesWithin(hit, _drawable)
          : membersOf(hit, _byId);
    });
  }

  void _fit() {
    final viewport = _lastViewport;
    final content = _lastContent;
    if (viewport == null ||
        content == null ||
        content.width <= 0 ||
        content.height <= 0)
      return;
    final scale =
        math.min(
          viewport.width / content.width,
          viewport.height / content.height,
        ) *
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
Color _typeColor(ViTypeKind kind) => switch (kind) {
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

Color _kindColor(ViObjectKind kind) => switch (kind) {
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
  // Float orange is (255,102,0): the snippet corpus references contain
  // 1,000 px of 0xFF6600 and ZERO of 0xFF8000 (exact-colour census over
  // every reference PNG), and Excel_Read_XLSX's DBL wires/stubs all read
  // 0xFF6600.
  ViTypeKind.numericFloat => const Color(0xFFFF6600),
  // Integer/enum blue and string magenta are sampled from LabVIEW's own
  // snippet renders (terminal borders (0,0,255) and (255,0,255)); boolean
  // green (0,102,0) is sampled from crc8's boolean WIRE dots and selector
  // border at decoded rects (the decoded constant FOREGROUND is a
  // different green, 0x007F00 — constants are not wires).
  ViTypeKind.numericInt => const Color(0xFF0000FF),
  ViTypeKind.enumRing => const Color(0xFF0000FF),
  ViTypeKind.string => const Color(0xFFFF00FF),
  ViTypeKind.boolean => const Color(0xFF006600),
  // Path teal sampled from Excel_Read_XLSX's path-constant borders
  // ((0,102,102) across both constants' 2px rings).
  ViTypeKind.path => const Color(0xFF006666),
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

/// The representative [ViDataType] for a terminal that resolved only a
/// coarse [ViTypeKind] (no VCTP-backed [ViHeapObject.dataType]) — enough to
/// pick its measured art for the kinds whose art does not vary within the
/// kind. Numeric kinds return null: the glyph depends on the exact width.
ViDataType? _dataTypeOfTypeKind(ViTypeKind kind) => switch (kind) {
  ViTypeKind.boolean => ViDataType.boolean,
  ViTypeKind.string => ViDataType.string,
  ViTypeKind.cluster => ViDataType.cluster,
  ViTypeKind.path => ViDataType.path,
  ViTypeKind.enumRing => ViDataType.enumU8,
  _ => null,
};

/// Whether a VCTP [ViDataType] is one of LabVIEW's numeric families
/// (integer / float / complex / enum) for the cluster-tint rule.
bool _isNumericDataType(ViDataType type) => switch (type) {
  ViDataType.i8 ||
  ViDataType.i16 ||
  ViDataType.i32 ||
  ViDataType.i64 ||
  ViDataType.u8 ||
  ViDataType.u16 ||
  ViDataType.u32 ||
  ViDataType.u64 ||
  ViDataType.sgl ||
  ViDataType.dbl ||
  ViDataType.ext ||
  ViDataType.complexSgl ||
  ViDataType.complexDbl ||
  ViDataType.complexExt ||
  ViDataType.enumU8 ||
  ViDataType.enumU16 ||
  ViDataType.enumU32 => true,
  _ => false,
};

/// The ERROR cluster's member fingerprint — exactly
/// `[boolean, i32, string]` (status/code/source), the resolved members of
/// every corpus `error in/out` terminal sampled. Error wires draw LabVIEW's
/// dedicated dark-yellow braid palette instead of the member tint.
bool _isErrorClusterMembers(List<ViType> members) =>
    members.length == 3 &&
    members[0].kind == ViDataType.boolean &&
    members[1].kind == ViDataType.i32 &&
    members[2].kind == ViDataType.string;

/// A cluster's ink follows its member make-up: any non-numeric member draws
/// the magenta family (Excel_Read_XLSX's `Worksheets` array-of-cluster wire,
/// terminal and label, and its `StateData` shift-register wires —
/// reference-measured); the ERROR cluster draws the braid's dark yellow;
/// LabVIEW's all-numeric cluster brown has no reference pin yet, so that
/// case keeps the neutral grey.
Color _clusterTint(List<ViType> members) => _isErrorClusterMembers(members)
    ? const Color(0xFF666600)
    : members.any((m) => !_isNumericDataType(m.kind))
    ? const Color(0xFFFF00FF)
    : labviewTypeColor(ViTypeKind.cluster);

/// The type colour of a terminal, resolving arrays to their ELEMENT ink and
/// clusters to their member-make-up tint ([_clusterTint]) the way LabVIEW
/// colours them; scalars fall through to [labviewTypeColor].
Color bdTerminalTypeColor(ViHeapObject object) {
  if (object.typeKind == ViTypeKind.array) {
    final element = object.resolvedElementType;
    if (element != null) {
      if (element.kind == ViDataType.cluster &&
          object.resolvedElementMembers.isNotEmpty) {
        return _clusterTint(object.resolvedElementMembers);
      }
      return labviewTypeColor(_typeKindOfDataType(element.kind));
    }
  }
  if (object.typeKind == ViTypeKind.cluster &&
      object.resolvedMembers.isNotEmpty) {
    return _clusterTint(object.resolvedMembers);
  }
  return labviewTypeColor(object.typeKind);
}

/// The coarse [ViTypeKind] a VCTP [ViDataType] colours as — the inverse of
/// [_dataTypeOfTypeKind] widened over the numeric families. Feeds
/// [labviewTypeColor] for element-typed ink (array rows / brackets).
ViTypeKind _typeKindOfDataType(ViDataType type) => switch (type) {
  ViDataType.i8 ||
  ViDataType.i16 ||
  ViDataType.i32 ||
  ViDataType.i64 ||
  ViDataType.u8 ||
  ViDataType.u16 ||
  ViDataType.u32 ||
  ViDataType.u64 => ViTypeKind.numericInt,
  ViDataType.sgl ||
  ViDataType.dbl ||
  ViDataType.ext ||
  ViDataType.complexSgl ||
  ViDataType.complexDbl ||
  ViDataType.complexExt => ViTypeKind.numericFloat,
  ViDataType.enumU8 ||
  ViDataType.enumU16 ||
  ViDataType.enumU32 => ViTypeKind.enumRing,
  ViDataType.boolean => ViTypeKind.boolean,
  ViDataType.string => ViTypeKind.string,
  ViDataType.path => ViTypeKind.path,
  ViDataType.cluster => ViTypeKind.cluster,
  ViDataType.array => ViTypeKind.array,
  _ => ViTypeKind.unknown,
};

/// LabVIEW's default structure colour (mid-grey). A frame carrying it has no
/// user-chosen tint, so it draws in its standard chrome rather than washing
/// this nominal value over the border.
const int kDefaultStructureRgb = 0x7F7F7F;

/// Phase of the global structure-hatch lattice, in pixels added to absolute
/// diagram coordinates before indexing the 4×4 tile (both components 0..3).
typedef GlobalHatchOffset = ({int x, int y});

/// The neutral hatch phase: the lattice indexed by absolute diagram
/// coordinates directly.
const GlobalHatchOffset kNoHatchOffset = (x: 0, y: 0);

/// The diagonal hatch LabVIEW fills a structure (case / sequence) frame with,
/// indexed `[absY % 4][absX % 4]` — one infinite lattice shared by every frame
/// in a render, so neighbouring structures and the four corners of one frame
/// show different phases. Measured from crc8's case frames (716 and 1861 fit
/// this tile identically). `#` = black.
const kBdStructureHatch = ['.#.#', '#.#.', '##..', '..##'];

/// Width (px) of the hatch band inside a case/sequence frame's solid 1px
/// outer border.
const kBdHatchBand = 5;

/// The single-diagonal stripe lattice of an error case's border band
/// ([bdErrorCaseOids]), indexed like [kBdStructureHatch] — grey ink on the
/// green band where `(absX + absY) % 4 == 0`. Its per-capture phase is
/// INDEPENDENT of the black hatch's (measured: one capture carries different
/// phases for the two lattices), so it takes its own derived offset.
const kBdErrorHatch = ['#...', '...#', '..#.', '.#..'];

/// The block-diagram render style: every user-tunable / capture-varying piece
/// of the structure chrome in one object, so the painter and rasteriser take a
/// single parameter instead of one per knob.
///
/// The colours are the values LabVIEW resolves from the CAPTURE ENVIRONMENT's
/// system palette, not from the .vi: same-version captures measure different
/// values (greys 119/127/119, greens 153/178/153 across three 19.0 captures).
/// The defaults are the corpus-dominant readings; a capture from another
/// environment may sit a few shades off, which is the reference's variance,
/// not a render error. The hatch offsets are likewise per-capture (brush
/// phases; see [GlobalHatchOffset]) — the oracle derives those because a
/// mis-phased lattice reads as structural noise, while an 8-shade band delta
/// does not.
class BdRenderStyle {
  const BdRenderStyle({
    this.whileBandGrey = const Color(0xFF777777),
    this.errorCaseGreen = const Color(0xFF99FF99),
    this.booleanGreen = const Color(0xFF006600),
    this.hatchOffset = kNoHatchOffset,
    this.errorHatchOffset = kNoHatchOffset,
    this.wireCycleOffset = kNoHatchOffset,
  });

  /// The while-loop band and error-stripe grey — corpus-dominant (119,119,119).
  /// (Some captures render LabVIEW's stored default 0x7F7F7F literally.)
  final Color whileBandGrey;

  /// The error case's green band field — corpus-dominant (153,255,153).
  final Color errorCaseGreen;

  /// The boolean-datatype green: T/F constant blocks and the while-loop stop
  /// terminal's ring — corpus-dominant (0,102,0). (Some captures render it
  /// as (0,127,0), the same palette family as [whileBandGrey]'s variance.)
  final Color booleanGreen;

  /// Phase of the black case-hatch lattice ([kBdStructureHatch]).
  final GlobalHatchOffset hatchOffset;

  /// Phase of the error-stripe lattice ([kBdErrorHatch]) — independent of
  /// [hatchOffset] within one capture.
  final GlobalHatchOffset errorHatchOffset;

  /// Phase of the patterned wire-stroke cycles ([kBdWireCyclePhase]): `x` is
  /// the mod-4 column shift, `y` the row-parity flip, both from the capture
  /// viewport's pan. Derived per reference by the oracle
  /// (`deriveWireCycleOffset`); the viewer keeps (0,0).
  final GlobalHatchOffset wireCycleOffset;
}

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

/// The rendered fill for a free label's backing given its stored background
/// colour. The stored default token `0xFFFFD7` renders as `0xFFFFCC`
/// (98/98 visible corpus bubbles; none renders the raw stored value); a
/// non-default stored colour renders verbatim (measured: `0x333333`).
/// TODO: one corpus sample renders stored `0x7F7F7F` as `0x777777` —
/// possibly nearest-palette snapping; needs more samples to decide.
int bdLabelBackingRgb(int rgb) => rgb == 0xFFFFD7 ? 0xFFFFCC : rgb;

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
/// census canonicalises each cycle by rotation — the on-screen phase is
/// measured separately ([kBdWireCyclePhase]). The dotted styles are not
/// here: their measured checkerboard phase law is applied directly (see
/// [_drawWires]).
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

/// The measured RELATIVE PHASE of each horizontal stroke cycle: LabVIEW
/// indexes a cycle by `x + 2·(y & 1) + stylePhase + captureShift` — the
/// pattern slides two columns between even and odd route rows, each style
/// carries a fixed rotation relative to the others, and the whole family
/// shifts by the capture viewport's pan (the same per-capture screen
/// anchoring as the hatch lattice — [BdRenderStyle.wireCycleOffset], derived
/// per reference by the oracle and (0,0) in the viewer). Phase census over
/// every clean horizontal run of Excel_Read_XLSX's reference (39 legs, zero
/// counterexamples, capture shift 1): zigzag legs measure absolute shift 3
/// on odd rows / 1 on even rows, chainLink 1/3, braid 1 and braidWide 2 at
/// even rows — rebased here so the zigzag entry is 0 (crc8's capture pins
/// the zero shift). Styles absent keep phase 0 (TODO: census
/// chainLinkWide/weave/dense phases when a clean reference run appears).
const Map<ViWireRenderStyle, int> kBdWireCyclePhase = {
  ViWireRenderStyle.zigzag: 0,
  ViWireRenderStyle.chainLink: 2,
  ViWireRenderStyle.braid: 0,
  ViWireRenderStyle.braidWide: 1,
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

/// The measured radix-marker glyphs LabVIEW draws before a non-decimal
/// constant's digits, inside the constant's `0xb` radix part: `#` rows at
/// the glyph's offset from the part's top-left corner, inked in the type
/// colour. Byte-measured on MD5's `%08x` initials (the 4×4 `x`) and its
/// `%08b` feeders (the 4×6 `b`); both share the baseline at part top+9.
/// The octal marker is not yet reference-measured, so `o` draws nothing
/// (TODO).
const Map<String, (int, int, List<String>)> kBdRadixMarkerGlyphs = {
  'x': (1, 5, ['#..#', '.##.', '.##.', '#..#']),
  'X': (1, 5, ['#..#', '.##.', '.##.', '#..#']),
  'b': (1, 3, ['#...', '#...', '###.', '#..#', '#..#', '###.']),
  'B': (1, 3, ['#...', '#...', '###.', '#..#', '#..#', '###.']),
};

/// Packs a rectangle's four `s16` edges into one int key for anchor↔terminal
/// matching (each edge is offset into a non-negative 16-bit lane).
int _packRect(int top, int left, int bottom, int right) =>
    ((top + 0x8000) << 48) |
    ((left + 0x8000) << 32) |
    ((bottom + 0x8000) << 16) |
    (right + 0x8000);

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

/// Resolves [object]'s prim icon: a primResID key directly; a class key
/// first per terminal count ([classVariantIconKey], the `0x15` DCO
/// children), then the legacy single-art class asset gated on an EXACT
/// box-size match (class art varies per arity — Excel_Read_XLSX's 0x44 at
/// 32x35 must not wear crc8's 32x27 art).
PrimIconArt? primIconArtFor(
  ViHeapObject object,
  ViDiagram diagram,
  Map<int, PrimIconArt> icons,
) {
  final key = primIconKeyOf(object);
  if (key == null) return null;
  if (key >= 0) return icons[key];
  final terms = diagram
      .children(object.oid)
      .where((c) => c.kind == 0x15)
      .length;
  final variant = icons[classVariantIconKey(object.kind, terms)];
  if (variant != null) {
    final b = object.absBounds;
    // The stamp is only exact when the art fills the box it was cut from.
    if (b != null &&
        variant.base.width == b.width &&
        variant.base.height == b.height) {
      return variant;
    }
  }
  final legacy = icons[key];
  final b = object.absBounds;
  if (legacy == null || b == null) return legacy;
  return legacy.base.width == b.width && legacy.base.height == b.height
      ? legacy
      : null;
}

/// Builtin prim terminal positions, keyed by (icon key, terminal index
/// among the prim's `0x15` DCO children, box width, box height) with the
/// offset relative to the prim box's top-left. LabVIEW measures a route's
/// stored segment lengths from the node TERMINAL, which for a primitive is
/// environment-builtin geometry the file does not carry — a route departing
/// a prim therefore ships with [ViWire.routeHeadSlack] and resolves here.
///
/// Derivation: the corpus route census — a reverse walk with stored bends
/// pins the origin's coordinate perpendicular to its closing axis, so
/// wires of both closing parities assemble a terminal's full position
/// (every slack head corpus-wide is a prim `0x15` DCO; the
/// `oa2_slack_head_dco` census law pins that identity). An axis stays null
/// until pinned. Entries and their basis:
///  * prim 1063 t0: dy=16 corpus-unanimous; dx=22 measured once from the
///    crc8 reference bend column (the byte-exact `slack-271` oracle pin is
///    that same render, so it regression-locks rather than independently
///    corroborates) and matching the corpus-pinned dx=22 of prims
///    1061/1062.
///  * class 0x44 at 32x27 t1: (24, 22) — corpus-unanimous on both axes
///    (11 x-wires, 70 y-wires) and independently equal to the crc8
///    reference measurement.
///  * prim 1142 t0: dy=16 corpus-unanimous (20 wires); dx not yet pinned.
///  * prim 1171 t0: dy=16 corpus-unanimous (8 wires); dx=20 corpus-pinned
///    (1 wire) and independently equal to the crc32 reference bend column.
///  * prim 1900 t0: dy=16 corpus-unanimous (8 wires); dx=24 corpus-pinned
///    (1 wire).
///  * prims 1143 / 1814 / 1815 t0: dy=16 measured from the crc8 reference
///    (the disabled LUT chain's seam ink sits on the row t+16 at every
///    abutment); no corpus route pins them yet, dx unpinned.
///  * prim 8083 t3 dx=28 / prim 1908 t0 dx=24: measured from the
///    Excel_Read_XLSX reference bend columns of their slack wires (the
///    walked route slides onto the terminal; the reference's vertical run
///    pins the slide); the dy of both is corpus-unanimous in the census
///    table and agrees with the same reference rows.
///  * MD5-reference entries (each pinned by a stored route whose bend
///    column/row is visible ink, dy corpus-unanimous where the census has
///    one): prim 1050 t0 dx=21 (bend column x=1418 = box.left + 21 + the
///    stored 14); 1050 t1 dy=21 (riser tops at box.top + 21); 1082 t0
///    (22, 16) (riser bottom row box.top + 16, bend column box.left + 22 +
///    12); 1142 t0 dx=22 (bend column x=642); 1502 t0 (24, 15) (a branch
///    trunk column x=345 = box.left + 24 + 13, its leaf rows pinning
///    dy=15); 1056 t3 (10, 10) (that same ref-pinned trunk's walked leaf,
///    corroborated by an independent arrival row box.top + 10); 1166 t2
///    dx=26 (a slack wire's drawn column pins the slide at -5); 1900 t1
///    dy=16 (an arrival seam's stroke rows); 1051 t2 (11, 11) / 1155 t1
///    (10, 16) / 1156 t1 (10, 16) — the walked leaves of the branch route
///    whose trunk column and leaf rows are the ref-pinned 1502-t0 ink
///    (the stored edge lengths are exact, so a pinned origin pins every
///    leaf).
/// Growable classes move terminals with the box, hence the size key.
const Map<(int, int, int, int), ({int? dx, int? dy})> _kBdPrimTerminals = {
  // Multiply's triangle: inputs at art rows top+5 / top+15 (art top =
  // box.top+6), output mid-height — Excel_Read_XLSX rows 1146/1156 on the
  // (1135,477) node.
  (1050, 0, 32, 32): (dx: 21, dy: 16),
  (1050, 1, 32, 32): (dx: null, dy: 21),
  (1051, 2, 32, 32): (dx: 11, dy: 11),
  (1052, 1, 32, 32): (dx: null, dy: 21),
  (1052, 2, 32, 32): (dx: null, dy: 11),
  (1056, 3, 32, 32): (dx: 10, dy: 10),
  (1063, 0, 32, 32): (dx: 22, dy: 16),
  // Logical Shift's output rides the tag-art apex row — MD5's inter-prim
  // gap ink at row box.top+16 (agreeing with the far conversion prim's
  // dco-child candidate row on the same wire).
  (1081, 0, 32, 32): (dx: null, dy: 16),
  // Random Number's output rides its dice-art middle row — Excel_Read_XLSX
  // row 1146 on the (1131,443) node.
  (1070, 0, 32, 32): (dx: null, dy: 15),
  (1082, 0, 32, 32): (dx: 22, dy: 16),
  (-0x44, 1, 32, 27): (dx: 24, dy: 22),
  (1142, 0, 32, 32): (dx: 22, dy: 16),
  (1143, 0, 32, 32): (dx: null, dy: 16),
  (1155, 1, 32, 32): (dx: 10, dy: 16),
  (1156, 1, 32, 32): (dx: 10, dy: 16),
  (1166, 2, 32, 32): (dx: 26, dy: 16),
  (1171, 0, 32, 32): (dx: 20, dy: 16),
  (1502, 0, 32, 32): (dx: 24, dy: 15),
  (1814, 0, 32, 32): (dx: null, dy: 16),
  (1815, 0, 32, 32): (dx: null, dy: 16),
  (1900, 0, 32, 32): (dx: 24, dy: 16),
  (1900, 1, 32, 32): (dx: null, dy: 16),
  (1908, 0, 32, 32): (dx: 24, dy: 24),
  (8083, 3, 32, 32): (dx: 28, dy: 4),
};

/// The catalogued builtin-terminal position of [endpointOid]'s prim
/// ([_kBdPrimTerminals]) in absolute diagram coordinates — either axis
/// null while unpinned — or null when the endpoint is not a prim `0x15`
/// DCO or its terminal is uncatalogued.
({int? x, int? y})? bdPrimTerminalOf(ViDiagram diagram, int endpointOid) {
  final head = diagram.byId[endpointOid];
  final parentOid = head?.parentOid;
  if (head == null || head.kind != 0x15 || parentOid == null) return null;
  final parent = diagram.byId[parentOid];
  final box = parent?.absBounds;
  if (parent == null || box == null) return null;
  final key = primIconKeyOf(parent);
  if (key == null) return null;
  var termIdx = -1;
  var at = 0;
  for (final c in diagram.childrenByOid[parentOid] ?? const <ViHeapObject>[]) {
    if (c.kind != 0x15) continue;
    if (c.oid == head.oid) {
      termIdx = at;
      break;
    }
    at++;
  }
  if (termIdx < 0) return null;
  // Reference-measured entries take precedence; the corpus-census table
  // ([kBdPrimTerminalCensus]) supplies the long tail.
  final sizedKey = (key, termIdx, box.right - box.left, box.bottom - box.top);
  final offset = _kBdPrimTerminals[sizedKey] ?? kBdPrimTerminalCensus[sizedKey];
  if (offset == null) return null;
  return (
    x: offset.dx == null ? null : box.left + offset.dx!,
    y: offset.dy == null ? null : box.top + offset.dy!,
  );
}

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

/// The bundled primitive icon assets (assets/prim_icons/prim<id>.png —
/// LabVIEW's icon art harvested from the snippet references, transparent
/// exterior, hand-editable), decoded once and keyed by primResID. Empty when
/// the bundle carries none.
Future<Map<int, PrimIconArt>> loadPrimIcons() => _primIcons ??= () async {
  final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
  final icons = <int, PrimIconArt>{};
  for (final asset in manifest.listAssets()) {
    final match = RegExp(
      r'assets/prim_icons/(prim|class)(\d+)(?:_t(\d+))?(?:_[a-z0-9-]+)?\.png$',
    ).firstMatch(asset);
    if (match == null) continue;
    final sized = match.group(3) != null;
    final statusKey =
        '${match.group(1)}${match.group(2)}'
        '${sized ? '_t${match.group(3)}' : ''}';
    // A rejected icon never stamps — the node falls back to the plate +
    // operator glyph until a better extraction or hand-drawn art lands.
    if (kPrimIconStatus[statusKey] == PrimIconStatus.rejected) {
      continue;
    }
    final bytes = await rootBundle.load(asset);
    final image = await decodeImage(bytes.buffer.asUint8List());
    final id = match.group(1) == 'prim'
        ? int.parse(match.group(2)!)
        : (sized
              ? classVariantIconKey(
                  int.parse(match.group(2)!),
                  int.parse(match.group(3)!),
                )
              : -int.parse(match.group(2)!));
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
      _primIconRgba[id] = Uint8List.fromList(
        rgba.buffer.asUint8List(rgba.offsetInBytes, rgba.lengthInBytes),
      );
      // Plate corner-AA pixels: an opaque `dddddd` on the art's ink
      // boundary (a transparent or outside 4-neighbour) is the rounded
      // plate corner's anti-aliasing baked against the white canvas — see
      // [_primIconCornerAa].
      final corners = <int>{};
      for (var y = 0; y < image.height; y++) {
        for (var x = 0; x < image.width; x++) {
          final artIndex = y * image.width + x;
          if (alpha[artIndex] != 255) continue;
          final byteIndex = artIndex * 4;
          if (_primIconRgba[id]![byteIndex] != 0xdd ||
              _primIconRgba[id]![byteIndex + 1] != 0xdd ||
              _primIconRgba[id]![byteIndex + 2] != 0xdd) {
            continue;
          }
          final onEdge =
              x == 0 ||
              y == 0 ||
              x == image.width - 1 ||
              y == image.height - 1 ||
              alpha[artIndex - 1] == 0 ||
              alpha[artIndex + 1] == 0 ||
              alpha[artIndex - image.width] == 0 ||
              alpha[artIndex + image.width] == 0;
          if (onEdge) corners.add(artIndex);
        }
      }
      if (corners.isNotEmpty) _primIconCornerAa[id] = corners;
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
/// Decodes PNG/other-encoded image [bytes] to a [ui.Image].
Future<ui.Image> decodeImage(Uint8List bytes) {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromList(bytes, completer.complete);
  return completer.future;
}

/// Builds a [ui.Image] from a raw RGBA buffer ([width]×[height]×4 bytes).
/// XNode facade images: the k-th `0x105` object in heap order pairs with
/// the k-th `DSIM` section, gated on exact geometry (corpus-verified — the
/// per-snippet DSIM/0x105 counts and dimensions match, and the facades'
/// error-code text matches the `C6 5D` configs under the same objects).
/// A `DSIM` is a 46-byte geometry header followed by a PNG whose alpha is
/// INVERTED (0 = opaque) with magenta (255,0,255) as a transparency key.
Future<Map<int, ui.Image>> xnodeFacadesFromSections(
  List<DecodedSection> sections,
  ViDiagram diagram,
) async {
  final xnodes = [
    for (final o in diagram.objects)
      if (o.kind == 0x105 && o.absBounds != null) o,
  ];
  if (xnodes.isEmpty) return const {};
  final dsims = [
    for (final s in sections)
      if (s.tag == 'DSIM') s,
  ];
  final out = <int, ui.Image>{};
  for (var k = 0; k < xnodes.length && k < dsims.length; k++) {
    final payload = dsims[k].bytes;
    if (payload.length < 54) continue;
    final png = decodePngEnvelope(payload, 46);
    if (png == null || 46 + png.byteLength > payload.length) continue;
    final b = xnodes[k].absBounds!;
    if (png.width != b.right - b.left || png.height != b.bottom - b.top) {
      continue;
    }
    final codec = await ui.instantiateImageCodec(
      payload.sublist(46, 46 + png.byteLength),
    );
    final frame = await codec.getNextFrame();
    final data = await frame.image.toByteData();
    frame.image.dispose();
    if (data == null) continue;
    final px = Uint8List.fromList(data.buffer.asUint8List());
    for (var i = 0; i < px.length; i += 4) {
      final magenta = px[i] == 255 && px[i + 1] == 0 && px[i + 2] == 255;
      px[i + 3] = magenta ? 0 : 255 - px[i + 3];
    }
    out[xnodes[k].oid] = await imageFromRgba(px, png.width, png.height);
  }
  return out;
}

/// [xnodeFacadesFromSections] over a raw VI: decodes the sections first
/// (skipped entirely when the diagram has no `0x105` objects).
Future<Map<int, ui.Image>> loadXnodeFacades(
  Uint8List viBytes,
  ViDiagram diagram,
) async {
  if (!diagram.objects.any((o) => o.kind == 0x105 && o.absBounds != null)) {
    return const {};
  }
  List<DecodedSection> sections;
  try {
    sections = decodeSections(viBytes);
  } catch (_) {
    return const {};
  }
  return xnodeFacadesFromSections(sections, diagram);
}

Future<ui.Image> imageFromRgba(Uint8List rgba, int width, int height) {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    rgba,
    width,
    height,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}

Future<Map<int, PrimIconArt>> ensurePrimIconsGrey() =>
    _primIconsGrey ??= () async {
      final icons = await loadPrimIcons();
      final grey = <int, PrimIconArt>{};
      for (final e in icons.entries) {
        final rgba = await e.value.base.toByteData();
        if (rgba == null) continue;
        final greyPx = Uint8List.fromList(rgba.buffer.asUint8List());
        _greyDisabledPalette(greyPx);
        grey[e.key] = await _prescaledArt(
          await imageFromRgba(greyPx, e.value.base.width, e.value.base.height),
        );
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
  return imageFromRgba(rgba, icon.width, icon.height);
}

final Map<int, ({int w, int h, Uint8List alpha})> _primIconMasks = {};

/// Raw RGBA of each loaded icon (filled by [loadPrimIcons]) — the pixel
/// source the plate corner-AA ladder reads when an overlap must restore the
/// art a corner pixel yields to.
final Map<int, Uint8List> _primIconRgba = {};

/// Per icon, the art positions (`y * w + x`) of its plate CORNER-AA pixels:
/// the `dddddd` blends baked where a prim plate's rounded outline corner
/// anti-aliased against the white canvas (the triangle plates carry one at
/// each left corner). These pixels are canvas artefacts, not opaque plate
/// art — when prim boxes overlap they compose by the measured ladder in the
/// icon stamping pass, not by plain source-over.
final Map<int, Set<int>> _primIconCornerAa = {};

/// The corner-AA ladder's second rung: the measured screen value where TWO
/// plate corner-AA pixels coincide on bare canvas (MD5's stacked Adds, the
/// 465/485 pair whose 20 px pitch lands one plate's bottom corner exactly on
/// the next plate's top corner).
const _kCornerAaRung2 = Color(0xFFAAAAAA);

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

/// Resolves the LOADED icon id for [object]: a primResID directly; a
/// class key by probing its per-arity variants ([classVariantIconKey])
/// for one whose art matches the node box (variant art is always the full
/// box rect), else the legacy plain class id gated on an exact box-size
/// match. Same-size arities (0x44 t4/t5) alias here — harmless for masks
/// and ink edges, which only read the fully-opaque rect; the STAMP path
/// ([primIconArtFor]) resolves by the true terminal count.
int? loadedPrimIconIdOf(ViHeapObject object) {
  final key = primIconKeyOf(object);
  if (key == null || key >= 0) return key;
  final b = object.absBounds;
  if (b == null) return key;
  for (var t = 0; t <= 15; t++) {
    final id = classVariantIconKey(object.kind, t);
    final m = _primIconMasks[id];
    if (m != null && m.w == b.width && m.h == b.height) return id;
  }
  final legacy = _primIconMasks[key];
  if (legacy != null && (legacy.w != b.width || legacy.h != b.height)) {
    return null;
  }
  return key;
}

bool primIconHit(ViHeapObject object, double x, double y) {
  final id = loadedPrimIconIdOf(object);
  final mask = id == null ? null : _primIconMasks[id];
  if (mask == null || _primIconsSync[id] == null) return true;
  final bounds = object.absBounds!;
  final stamp = primIconStampRect(
    Rect.fromLTRB(
      bounds.left.toDouble(),
      bounds.top.toDouble(),
      bounds.right.toDouble(),
      bounds.bottom.toDouble(),
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
  final id = loadedPrimIconIdOf(object);
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

/// Everything the block-diagram painter needs that derives from one
/// [ViDiagram] — computed once here and passed as a unit, instead of each
/// caller re-deriving and threading a parameter per piece. The decode-only
/// half is [ViDiagramSemantics] (shared with every non-rendering consumer of
/// the same diagram); this adds the canvas-space extent and the painter's
/// text caches. Members are lazy, so a caller that never paints wires (say)
/// never pays for their analysis.
class BdScene {
  BdScene(
    ViDiagram diagram, {
    List<ViWire>? wires,
    List<ViHeapObject>? drawable,
  }) : semantics = ViDiagramSemantics(
         diagram,
         wires: wires,
         drawable: drawable,
       );

  /// The diagram's decoded block-diagram semantics — the object set, the
  /// wires, and everything derived from them that carries no pixel geometry.
  final ViDiagramSemantics semantics;

  ViDiagram get diagram => semantics.diagram;

  /// The drawn object set ([bdDrawableObjects]); callers may override (e.g.
  /// a probe rendering a subset).
  List<ViHeapObject> get drawable => semantics.drawable;

  /// The decoded dataflow wires ([bdVisibleWires], one per `0x17` signal),
  /// routed under the nodes/structures between their endpoint anchors; pass
  /// `const []` for a wire-free render.
  List<ViWire> get wires => semantics.wires;

  /// [drawable] in painting order ([bdPaintOrder]).
  List<ViHeapObject> get ordered => semantics.ordered;

  /// Objects under a disabled displayed frame ([bdDisabledObjectOids]).
  Set<int> get disabledOids => semantics.disabledOids;

  /// Case structures displaying their "No Error" frame ([bdErrorCaseOids]).
  Set<int> get errorCaseOids => semantics.errorCaseOids;

  /// Attach rect → terminal class for reference-verified border-terminal
  /// chrome ([bdBorderTerminalKinds]).
  Map<HeapRect, ({int kind, bool hollow, bool centreDot, bool disabled})>
  get borderTerminalKinds => semantics.borderTerminalKinds;

  /// Per structure oid, its modeled terminals ([bdStructureTerminals]).
  Map<int, List<({HeapRect box, int bmp})>> get structureTerminals =>
      semantics.structureTerminals;

  /// Per terminal oid, the numeric literal its constant box displays
  /// ([bdConstValueTexts]).
  Map<int, String> get constValues => semantics.constValues;

  /// The display-part furniture boxes the into-DCO wire trim stops on
  /// ([ViDiagramSemantics.furnitureBounds]).
  List<HeapRect> get furnitureBounds => semantics.furnitureBounds;

  /// The ink envelope of [drawable] (wires excluded: their absolute anchoring
  /// is not yet verified, and a misanchored run must not blow up the fit).
  late final Rect content = drawable.isEmpty
      ? Rect.zero
      : bdContentRect(drawable, includeWires: false);

  /// Scale-independent text layouts, cached for the painter across repaints
  /// and zoom re-anchors (the canvas itself is scaled, so a layout never
  /// depends on [BdDiagramPainter.canvasScale]). Laying out hundreds of
  /// labels per frame dominated interactive paint time. Keyed by the text +
  /// full style ([BdRunKey], a record: value equality with no key string to
  /// build or parse).
  final Map<BdRunKey, BdTextRun> textLayoutCache = {};

  /// Per-glyph layout/paint slots backing [textLayoutCache] (see [BdGlyph]),
  /// keyed by glyph + full style: a glyph's painters, integer advance, and
  /// baseline are computed once and shared by every run that uses it.
  final Map<BdGlyphKey, BdGlyph> textGlyphCache = {};

  /// Whether [paintedText] is recorded. Off by default: the record and rect
  /// cost an allocation per run per paint and only the text-metric tests and
  /// accuracy probes read them.
  bool recordPaintedText = false;

  /// Every text run the last paint drew (when [recordPaintedText]): its
  /// string, the canvas-space rect of its laid-out box, and the style size
  /// it was set in. Rebuilt each paint; the text-metric tests and accuracy
  /// probes read it to locate text ink without re-deriving the painter's
  /// placement rules.
  final List<({String text, Rect rect, double fontSize})> paintedText = [];

  /// Releases the native handles the text caches hold — every recorded run
  /// picture and every cached glyph's painters. Call it when the scene is
  /// discarded: a scene is built per rasterise, and a corpus sweep otherwise
  /// accumulates one picture per distinct run and two painters per distinct
  /// glyph for the whole sweep. The scene must not be painted afterwards.
  void dispose() {
    for (final run in textLayoutCache.values) {
      run.dispose();
    }
    textLayoutCache.clear();
    for (final glyph in textGlyphCache.values) {
      glyph.dispose();
    }
    textGlyphCache.clear();
    paintedText.clear();
  }
}

/// The layout cache key of one text run ([BdScene.textLayoutCache]): the
/// string, the full style, and the EFFECTIVE line count — two runs of the
/// same single-line text share a layout no matter how tall the boxes that
/// hold them are.
typedef BdRunKey = (
  String text,
  int color,
  double fontSize,
  FontWeight fontWeight,
  FontStyle? fontStyle,
  int lineCount,
  String fontFamily,
);

/// The cache key of one glyph slot ([BdScene.textGlyphCache]).
typedef BdGlyphKey = (
  String glyph,
  int color,
  double fontSize,
  FontWeight fontWeight,
  FontStyle? fontStyle,
  String fontFamily,
);

/// The block-diagram text size, in logical px per em, calibrated against
/// the snippet references' own text ink (the Windows UI face as rasterised
/// by the capturing machine; drawn here with the metric-compatible bundled
/// Selawik). Measured on the Excel_Read_XLSX/MD5/crc8 references:
///
///  * cap height 9 px, x-height 6 px, descender 3 px — every text class
///    (owned labels, free labels, comment blocks, case-selector values,
///    array/constant digits) shows the same 9 px caps;
///  * ink-bbox widths (lum<144, AA fringe cancelling between render and
///    reference): "Reflect Output?" 75, "Reflect Input? (F)" 80,
///    "U8 Bits Reversed LUT" 100, "Xor Out (0x00)" 71, "Truncate? (T)" 63,
///    "Worksheets" 58, "CRC-8" 32, "No Error" 41.
///
/// Laid out at 12.0 em on the whole-pixel glyph lattice ([BdTextRun]:
/// integer per-glyph advances, integer baseline), the run widths match the
/// reference ink within ±1 px on all but a handful of the ~200 painted runs
/// across the three VIs.
const double kBdTextSize = 12.0;

/// Line box height as a multiple of the em size: `ceil(fontSize * this)` is
/// both the reported line-box height and the multi-line baseline pitch —
/// 15 px at [kBdTextSize] (crc8's reference comment pens its three
/// baselines at rows 103/118/133, 15 px apart).
const double kBdTextLineHeight = 14.5 / kBdTextSize;

/// The line box (px) a run of em size [fontSize] sets on, and the pitch of
/// its baselines: the [kBdTextLineHeight] multiple taken up to a whole pixel
/// row, since the reference pens every baseline on a whole row.
double bdLineBox(double fontSize) =>
    (fontSize * kBdTextLineHeight).ceilToDouble();

/// Ink-weight overdraw alpha: every text run re-draws itself once at this
/// alpha under the full-strength pass (a zero-offset, zero-blur shadow in
/// the run's style — one layout, one paint call), darkening each AA fringe
/// pixel from coverage `a` to `1-(1-a)(1-0.75a)`. Calibrated against the
/// three snippet references' own glyph ink: the plain rasterisation
/// measures 0.78-0.81 of the reference's mean ink (the captures'
/// gamma-corrected, stem-darkened text), a full double-paint 1.07-1.09;
/// this alpha lands 1.00-1.02 and lifts thresholded text IoU on all three
/// calibration VIs (Excel .325→.362, MD5 .435→.472, crc8 .442→.475).
const double kBdTextOverdrawAlpha = 0.75;

/// The BOLD face's overdraw alpha: the regular calibration overshoots on
/// bold — its stems are already multi-pixel, so the same fringe lift lands
/// 1.14x the reference's mean ink (measured on MD5's `Calculate MD5`
/// heading). Recalibrated on that heading: this alpha lands 1.015.
///
/// EXTRAPOLATED beyond that measurement: the calibration is one 12 em bold
/// heading, and this alpha is applied to every bold glyph at every size (the
/// 8.5 em type letters, the 11 em bold-italic structure glyphs, the 16 em
/// headings). Those sizes have no ink-weight measurement of their own yet.
/// // TODO(labwright): calibrate the bold alpha per size.
const double kBdTextOverdrawAlphaBold = 0.15;

/// The anchor for a text run of [text] size CENTRED in [box] — both axes
/// truncate the half pixel, so a run one px narrower than an even gap sits
/// left/above of the symmetric centre.
///
/// Reference-measured over the 46-snippet corpus by registering each painted
/// run's ink onto its reference's ink (best whole-pixel shift by ink IoU,
/// runs scoring ≥0.5 with a decisive margin): 781 of 786 confidently
/// registered runs sit at shift 0 under this law, and the 41 growable-node
/// row texts whose cell−text gap is EVEN all move one px off the reference
/// under the label law below. The vertical half pixel is unmeasurable on
/// this corpus (flooring vs rounding moves no registered run) and is floored
/// to match the horizontal axis. Glyph stamps (type/operator/structure
/// letters) centre by the same law — no registered glyph run moves when they
/// switch from rounding to flooring.
Offset bdCentredTextAnchor(Rect box, Size text) => Offset(
  box.left + ((box.width - text.width) / 2).floorToDouble(),
  box.top + ((box.height - text.height) / 2).floorToDouble(),
);

/// The vertical half of [bdCentredTextAnchor], for runs whose horizontal
/// anchor is justified rather than centred.
double bdCentredTextTop(Rect box, double textHeight) =>
    box.top + ((box.height - textHeight) / 2).floorToDouble();

/// The LEFT anchor of a centre-justified label run
/// ([ViHeapObject.labelJustifyCenter]) of [textWidth] in its stored [bounds]:
/// centred over `width − 1`, so an even gap inks one px LEFT of the
/// symmetric centre — a different law from [bdCentredTextAnchor], measured
/// separately on the same registration probe. The four confidently
/// registered centred labels with an EVEN gap (ClassChildren's
/// `Find parents`, GenerateTree's `Index Ids` / `Recursively order children
/// sorted by weight` / `Append id if parent`) sit at shift 0 here and all
/// four move one px right of the reference under [bdCentredTextAnchor];
/// odd-gap labels read the same under either law.
double bdCentredLabelLeft(Rect bounds, double textWidth) =>
    bounds.left + ((bounds.width - textWidth - 1) / 2).floorToDouble();

/// One cached glyph of the diagram text face at a full style+colour: the
/// full-ink and [kBdTextOverdrawAlpha] companion painters, the pen advance
/// snapped to whole pixels, and the painter's own (fractional) alphabetic
/// baseline distance, used to land the glyph outline on an integer
/// baseline row.
///
/// The capture rasterizer (classic GDI text output) pens each glyph a
/// whole number of pixels after the last and sets every baseline on a
/// whole pixel row; the face's fractional advances (Selawik digits
/// 6.469 px, `e` 6.275 px) would otherwise accumulate a drift of several
/// px over long runs (MD5's hex windows ran 2–4 px long; the references
/// space value digits on an exact 6 px pitch).
class BdGlyph {
  BdGlyph({
    required this.main,
    required this.dim,
    required this.advance,
    required this.baseline,
  });

  /// The full-strength single-glyph painter.
  final TextPainter main;

  /// The ink-weight overdraw companion ([kBdTextOverdrawAlpha]).
  final TextPainter dim;

  /// The whole-pixel pen advance: the face's hinted 12 ppem advance where
  /// the reference rasterizer's own metrics differ from rounding
  /// ([bdHintedAdvance]), else the fractional advance rounded.
  final int advance;

  /// [main]'s alphabetic-baseline distance from its paint origin.
  final double baseline;

  /// Releases both painters' native layout resources.
  void dispose() {
    main.dispose();
    dim.dispose();
  }
}

/// A laid-out text run on the whole-pixel glyph lattice: every glyph pens
/// at an integer x, every line's baseline on an integer row at the
/// [kBdTextLineHeight] pitch, with the overdraw pass recorded under the
/// full-strength pass at identical origins. The run is laid out once and
/// replayed from a recorded picture — the replay still issues the recorded
/// draw per glyph per pass, so what a repaint saves is the layout, not the
/// draw count.
class BdTextRun {
  BdTextRun({
    required this.text,
    required this.width,
    required this.height,
    required this.fontSize,
    required ui.Picture picture,
  }) : _picture = picture;

  /// The string the run lays out (the text-metric tests and accuracy probes
  /// read it back off [BdScene.paintedText]).
  final String text;

  /// The widest line's advance sum — an exact whole number of pixels.
  final double width;

  /// `lineHeight * lineCount` (the same 15 px line boxes the reference
  /// pens at 12 em).
  final double height;

  /// The em size the run was set in (mirrored onto
  /// [BdScene.paintedText]).
  final double fontSize;

  final ui.Picture _picture;

  Size get size => Size(width, height);

  void paint(Canvas canvas, Offset at) {
    canvas
      ..save()
      ..translate(at.dx, at.dy)
      ..drawPicture(_picture)
      ..restore();
  }

  /// Releases the recorded picture's native handle.
  void dispose() => _picture.dispose();
}

/// The **static** diagram layer: grid, objects, and labels. Depends only on the
/// (memoized, stable) object list + origin, so a selection tap never repaints it
/// — the cheap [_OverlayPainter] handles highlights instead. Public so the
/// off-screen [BdOracle] rasterises with the exact same drawing as the view.
class BdDiagramPainter extends CustomPainter {
  BdDiagramPainter({
    required this.scene,
    required this.origin,
    this.subViIcons = const {},
    this.xnodeFacades = const {},
    this.primIcons = const {},
    this.primIconsGrey = const {},
    this.iconFilterQuality = FilterQuality.none,
    this.canvasScale = 1,
    this.drawDotGrid = true,
    this.style = const BdRenderStyle(),
  });

  /// The diagram-derived render inputs (paint order, wires, chrome indexes).
  final BdScene scene;

  /// One cached [BdGlyph] (see [BdScene.textGlyphCache]).
  BdGlyph _glyph(
    String glyph,
    Color color,
    double fontSize,
    FontWeight fontWeight,
    FontStyle? fontStyle,
  ) {
    final key = (
      glyph,
      color.toARGB32(),
      fontSize,
      fontWeight,
      fontStyle,
      bdTextFontFamily,
    );
    final cached = scene.textGlyphCache[key];
    if (cached != null) return cached;
    TextPainter build(Color inkColor) => TextPainter(
      text: TextSpan(
        text: glyph,
        style: TextStyle(
          color: inkColor,
          fontSize: fontSize,
          height: kBdTextLineHeight,
          fontWeight: fontWeight,
          fontStyle: fontStyle,
          fontFamily: bdTextFontFamily,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final main = build(color);
    // GDI pens by the face's HINTED per-ppem advance (`hdmx`), not the
    // rounded linear one; at the reference's 12 ppem the two differ on a
    // handful of glyphs ([bdHintedAdvance]). Other em sizes keep the
    // rounded engine width.
    final hinted = fontSize == kBdTextSize && glyph.length == 1
        ? bdHintedAdvance(
            glyph.codeUnitAt(0),
            bold: fontWeight.value >= FontWeight.w700.value,
          )
        : null;
    final overdraw = fontWeight.value >= FontWeight.w700.value
        ? kBdTextOverdrawAlphaBold
        : kBdTextOverdrawAlpha;
    final slot = BdGlyph(
      main: main,
      dim: build(color.withValues(alpha: color.a * overdraw)),
      advance: hinted ?? main.width.round(),
      baseline: main.computeDistanceToActualBaseline(TextBaseline.alphabetic),
    );
    scene.textGlyphCache[key] = slot;
    return slot;
  }

  /// A laid-out [BdTextRun] from the scene's scale-independent layout
  /// cache ([BdScene.textLayoutCache]) — label text re-lays-out only when
  /// its content or style changes, not on every repaint or zoom re-anchor.
  /// Lines are the text's own newlines, truncated to [maxLines]; each
  /// glyph pens at the integer advance sum, each line's baseline on the
  /// integer row nearest the face's own (12 at 12 em).
  BdTextRun _layoutText(
    String text, {
    required Color color,
    double fontSize = kBdTextSize,
    FontWeight fontWeight = FontWeight.w400,
    FontStyle? fontStyle,
    int? maxLines,
  }) {
    // The EFFECTIVE line count keys the cache: a taller box that truncates
    // nothing is the same layout.
    var lineCount = 1;
    for (var i = 0; i < text.length; i++) {
      if (text.codeUnitAt(i) == 0x0a) lineCount++;
    }
    if (maxLines != null && maxLines < lineCount) lineCount = maxLines;
    final key = (
      text,
      color.toARGB32(),
      fontSize,
      fontWeight,
      fontStyle,
      lineCount,
      bdTextFontFamily,
    );
    final cached = scene.textLayoutCache[key];
    if (cached != null) return cached;

    final lineHeight = bdLineBox(fontSize);
    final lines = text.split('\n');
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    var width = 0.0;
    // The overdraw pass first ([kBdTextOverdrawAlpha]), the full-strength
    // pass over it — identical integer origins by construction.
    for (final dimPass in [true, false]) {
      var lineTop = 0.0;
      for (var line = 0; line < lineCount; line++) {
        var x = 0.0;
        for (final rune in lines[line].runes) {
          final slot = _glyph(
            String.fromCharCode(rune),
            color,
            fontSize,
            fontWeight,
            fontStyle,
          );
          final pen = Offset(
            x,
            lineTop + slot.baseline.roundToDouble() - slot.baseline,
          );
          (dimPass ? slot.dim : slot.main).paint(canvas, pen);
          x += slot.advance;
        }
        width = math.max(width, x);
        lineTop += lineHeight;
      }
    }
    final run = BdTextRun(
      text: text,
      width: width,
      height: lineHeight * lineCount,
      fontSize: fontSize,
      picture: recorder.endRecording(),
    );
    scene.textLayoutCache[key] = run;
    return run;
  }

  /// Paints [run] at [at] — snapped to whole pixels: the references pen
  /// every run at integer device coordinates, and a fractional anchor
  /// would smear each glyph's AA and drop baseline fringes one row low —
  /// and records the run's canvas rect on [BdScene.paintedText] for
  /// text-metric tests and accuracy probes. [clip] bounds overlong text
  /// the way LabVIEW crops a value display to its box — a hard pixel
  /// clip, never an ellipsis (the references show cut glyphs, not `…`).
  void _paintText(Canvas canvas, BdTextRun run, Offset at, {Rect? clip}) {
    at = Offset(at.dx.roundToDouble(), at.dy.roundToDouble());
    if (clip != null) {
      canvas
        ..save()
        ..clipRect(clip);
    }
    run.paint(canvas, at);
    if (clip != null) canvas.restore();
    if (!scene.recordPaintedText) return;
    scene.paintedText.add((
      text: run.text,
      rect: clip == null ? at & run.size : (at & run.size).intersect(clip),
      fontSize: run.fontSize,
    ));
  }

  final Offset origin;

  List<ViHeapObject> get objects => scene.ordered;
  List<ViWire> get wires => scene.wires;
  Set<int> get disabledOids => scene.disabledOids;
  Set<int> get errorCaseOids => scene.errorCaseOids;
  Map<HeapRect, ({int kind, bool hollow, bool centreDot, bool disabled})>
  get borderTerminalKinds => scene.borderTerminalKinds;
  Map<int, List<({HeapRect box, int bmp})>> get structureTerminals =>
      scene.structureTerminals;
  Map<int, String> get constValues => scene.constValues;

  /// Resolved subVI-call node icons, keyed by [ViHeapObject.oid] — the 32×32
  /// icon of the VI a subVI-call node targets, loaded from that VI's own file
  /// (resolved by `resolveSubViIconsFor`). A node with an entry here stamps the
  /// real icon on its plate; a node without one keeps the neutral
  /// connector-pane plate (the icon is never guessed).
  final Map<int, ViLegacyIcon> subViIcons;

  /// XNode facade images decoded from the VI's `DSIM` sections
  /// ([loadXnodeFacades] in bd_oracle.dart), keyed by the `0x105` oid.
  final Map<int, ui.Image> xnodeFacades;

  /// Bundled primitive icon art keyed by primResID (see [loadPrimIcons]);
  /// stamped at natural size on primitive plates. A node without an entry
  /// keeps the plate + operator glyph.
  final Map<int, PrimIconArt> primIcons;

  /// Disabled-palette variants of [primIcons] (see [primIconsGreyLoaded]),
  /// stamped for nodes in [disabledOids].
  final Map<int, PrimIconArt> primIconsGrey;

  /// The structure-chrome style: band/field colours and per-capture hatch
  /// phases. See [BdRenderStyle].
  final BdRenderStyle style;

  /// [rect] (absolute diagram coordinates) mapped into this painter's canvas
  /// frame (the content origin subtracted).
  Rect _toCanvas(HeapRect rect) => Rect.fromLTRB(
    rect.left - origin.dx,
    rect.top - origin.dy,
    rect.right - origin.dx,
    rect.bottom - origin.dy,
  );

  /// Whether every pixel of the axis-aligned polyline [points] lies under
  /// some box in [cover] (canvas coords; a box covers `[left, right-1] ×
  /// [top, bottom-1]`, its drawn extent). Interval-merges the covering
  /// boxes along each run, bridging a 1 px seam between ABUTTING boxes (a
  /// stacked prim chain's divider row carries no wire ink either —
  /// measured on the crc32 LUT stack); any wider gap is visible ink and
  /// reads false.
  static bool _polylineUnderNodes(List<Offset> points, List<Rect> cover) {
    for (var j = 1; j < points.length; j++) {
      final a = points[j - 1], b = points[j];
      final horizontal = a.dy == b.dy;
      final lo = horizontal ? math.min(a.dx, b.dx) : math.min(a.dy, b.dy);
      final hi = horizontal ? math.max(a.dx, b.dx) : math.max(a.dy, b.dy);
      var at = lo;
      var progressed = true;
      while (at <= hi && progressed) {
        progressed = false;
        for (final r in cover) {
          final crossOk = horizontal
              ? (a.dy >= r.top && a.dy < r.bottom)
              : (a.dx >= r.left && a.dx < r.right);
          if (!crossOk) continue;
          final (s, e) = horizontal ? (r.left, r.right) : (r.top, r.bottom);
          if (s <= at + 1 && e > at) {
            at = e;
            progressed = true;
          }
        }
      }
      if (at <= hi) return false;
    }
    return points.isNotEmpty;
  }

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
    scene.paintedText.clear();
    // The layer rasterises at [canvasScale]; everything below draws in
    // logical diagram units under one canvas scale, so strokes, text, and
    // icons all render at the zoom's real resolution.
    canvas.scale(canvasScale);
    size = Size(size.width / canvasScale, size.height / canvasScale);
    canvas.drawRect(Offset.zero & size, Paint()..color = kBdCanvas);
    if (drawDotGrid) _drawDotGrid(canvas, size);

    Rect rectOf(ViHeapObject o) => _toCanvas(o.absBounds!);

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
    final tunnelSquares =
        <
          (
            Rect,
            ({int kind, bool hollow, bool centreDot, bool disabled}),
            Color,
          )
        >[];
    // Rects owned by the reference-verified border-terminal chrome pass
    // (shift registers, selectors, tunnels). A modeled structure terminal at
    // the same rect must not also draw: its anti-aliased ring strokes bleed
    // a ring of blended pixels just OUTSIDE the rect that the byte-exact
    // chrome cannot cover.
    final chromeOwnedRects = <Rect>{
      for (final attach in borderTerminalKinds.keys) _toCanvas(attach),
    };
    _drawWires(canvas, tunnelSquares: tunnelSquares);
    for (final object in structures) {
      // A small 0x53 CLUSTER container is a single drawn box, not a frame —
      // routed to the same chrome as the solids pass (and drawn HERE, after
      // the wire pass: the reference covers a wire crossing the box's
      // interior — Excel_Read_XLSX's braid under the (316,826) constant).
      if (object.kind == 0x53) {
        final rect = rectOf(object);
        if (rect.width <= 40 && rect.height <= 24) {
          _drawSmallClusterBox(canvas, object, rect);
          continue;
        }
      }
      // Class-accurate structure chrome (no badge text — LabVIEW names a
      // construct by its border furniture, not a label). Loops get the thick
      // rounded grey band with the iteration / conditional corner terminals;
      // case structures get their band plus selector chrome (drawn at the
      // decoded 0x95 label, see the label pass). A decoded structColor tints
      // the band (the pale sequence/timed tint); other structure kinds keep
      // the neutral double-line frame.
      final rect = rectOf(object);
      final structDisabled = disabledOids.contains(object.oid);
      // A structure whose colour is LabVIEW's default grey (0x7F7F7F) carries
      // no user tint — the frame draws in its standard chrome (a while loop's
      // 119 grey band, not this nominal 127). Only a non-default colour tints.
      final structColor = switch (object.structRgb == kDefaultStructureRgb
          ? null
          : bdDecodedColor(object.structRgb)) {
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
        _drawArrayConstantShell(canvas, object);
        continue;
      }
      switch (object.kind) {
        case 0x20: // For loop: crisp 1px black border + stacked pages.
          _drawForLoopBorder(canvas, rect, disabled: structDisabled);
        case 0x21: // While loop: crisp rounded grey band + terminals.
          _drawWhileLoopBand(
            canvas,
            rect,
            structColor,
            disabled: structDisabled,
          );
        case 0x2c: // Case structure: solid 1px border + global hatch band.
          _drawStructureHatchBorder(
            canvas,
            rect,
            object.absBounds!.left,
            object.absBounds!.top,
            disabled: structDisabled,
            error: errorCaseOids.contains(object.oid),
          );
          // Case-insensitive string match (objFlags bit 0x1000000): the
          // magenta `A=a` badge on a white plate at the frame's bottom-left
          // corner, over the hatch band. Reference-measured on
          // Excel_Read_XLSX oid2480 (the corpus' one visible flagged case;
          // its two other flagged cases sit in hidden frames).
          if (((object.objFlags ?? 0) & 0x1000000) != 0) {
            _drawCaseInsensitiveBadge(
              canvas,
              rect,
              disabled: structDisabled,
              oid: object.oid,
            );
          }
        case 0xca: // Flat sequence: the film-strip border.
          _drawFlatSequenceBorder(canvas, rect, object);
        case 0x121: // A flat-sequence frame: the parent 0xca owns the strip
          // chrome and the inter-frame dividers; the frame draws nothing.
          break;
        case 0xcd: // Diagram-disable structure. Displaying its Disabled
          // frame: a single 1px grey rectangle (153,153,153), measured on
          // crc8 — no double line, no tint. Displaying an ENABLED frame: a
          // 3px (119,119,119) crosshatch band on the left/right/bottom
          // edges (the case-hatch lattice, anchored to the structure's own
          // rect with a +1 row phase) and a plain 1px black top row between
          // the hatch corners — measured on Excel_Read_XLSX oid 2228.
          final showsDisabled = scene.diagram
              .children(object.oid)
              .any(
                (k) =>
                    k.kind == 0x95 &&
                    k.label?.trim().toLowerCase() == 'disabled',
              );
          if (showsDisabled) {
            final grey = _solidNoAa(
              _dimFor(object.oid, const Color(0xFF999999)),
            );
            canvas.drawRect(
              Rect.fromLTWH(rect.left, rect.top, rect.width, 1),
              grey,
            );
            canvas.drawRect(
              Rect.fromLTWH(rect.left, rect.bottom - 1, rect.width, 1),
              grey,
            );
            canvas.drawRect(
              Rect.fromLTWH(rect.left, rect.top, 1, rect.height),
              grey,
            );
            canvas.drawRect(
              Rect.fromLTWH(rect.right - 1, rect.top, 1, rect.height),
              grey,
            );
          } else {
            final black = _solidNoAa(_dimFor(object.oid, Colors.black));
            final hatchPts = <double>[];
            void hatchCell(double x, double y) {
              final rx = (x - rect.left).round() & 3;
              final ry = ((y - rect.top).round() + 1) & 3;
              if (kBdStructureHatch[ry][rx] == '#') {
                hatchPts
                  ..add(x + 0.5)
                  ..add(y + 0.5);
              }
            }

            for (var y = rect.top; y < rect.bottom; y++) {
              for (var k = 0; k < 3; k++) {
                hatchCell(rect.left + k, y);
                hatchCell(rect.right - 3 + k, y);
              }
            }
            for (var y = rect.bottom - 3; y < rect.bottom; y++) {
              for (var x = rect.left + 3; x < rect.right - 3; x++) {
                hatchCell(x, y);
              }
            }
            _drawCellPoints(
              canvas,
              hatchPts,
              _dimFor(object.oid, const Color(0xFF777777)),
            );
            canvas.drawRect(
              Rect.fromLTRB(
                rect.left + 3,
                rect.top,
                rect.right - 3,
                rect.top + 1,
              ),
              black,
            );
          }
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
          continue; // Generic frames draw no corner terminals.
      }
      _drawStructureTerminals(
        canvas,
        rect,
        terminals,
        chromeOwnedRects: chromeOwnedRects,
        disabled: structDisabled,
      );
    }
    // The case-selector strips draw UNDER the border-terminal chrome: the
    // reference draws a case's ? tunnel (and its wire) over the strip's
    // bottom-left corner where they overlap.
    for (final object in solids) {
      if (object.kind == 0x95) _drawCaseSelector(canvas, rectOf(object));
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

    final labelBackings = <(int, Rect, Color)>[];
    // Prim icon stamps already painted in THIS pass, in paint order — the
    // lookup behind the plate corner-AA ladder (see the stamping branch).
    final stampedPrimIcons = <({Rect dst, int id})>[];
    for (final object in solids) {
      final rect = rectOf(object);
      // Free-text label parts (control caption 0x0a, case selector 0x95) are
      // drawn by LabVIEW as text; a backed label shows an opaque bordered
      // fill. Two backed classes, censused across the snippet corpus's
      // references (812 drawn `0x0a` labels): a FREE label (held by a
      // `0x1b` free-label holder — a diagram comment) with a decoded
      // background colour, and an ARRAY-DOCKED label (held by a `0x52`
      // array shell) with a decoded background and without the
      // value-window flag bit — MD5's `Indices`/`S`/`T` labels, 3/3 boxed,
      // while every other owned label (no decoded background, the `0x800`
      // value-window flag, or hidden) shows none. The text pass below
      // renders any recovered caption.
      if (kBdTextLabelCodes.contains(object.kind)) {
        // The case selector's chrome already drew in the pre-chrome pass; its
        // value text draws in the text pass.
        if (object.kind == 0x95) continue;
        // A hidden label paints nothing — neither backing nor (below) text.
        final holderKind = scene.diagram.byId[object.parentOid ?? -1]?.kind;
        final backed =
            holderKind == 0x1b ||
            (holderKind == 0x52 && ((object.objFlags ?? 0) & 0x800) == 0);
        final backing = object.isLabelHidden || !backed || object.bgRgb == null
            ? null
            : bdDecodedColor(bdLabelBackingRgb(object.bgRgb!));
        // Free labels float ABOVE nodes in LabVIEW's z-order (a comment's
        // backing covers an overlapping node icon), so the backing is
        // deferred past this pass and painted after it.
        if (backing != null) labelBackings.add((object.oid, rect, backing));
        continue;
      }
      if (object.kind == 0x53 && rect.width <= 40 && rect.height <= 24) {
        _drawSmallClusterBox(canvas, object, rect);
        continue;
      }
      switch (object.category) {
        case ViObjectKind.terminal:
          // A named constant draws its box around the VALUE part only (the
          // `0x9` child window): LabVIEW places the visible caption beside
          // the box, inside the same terminal bounds (crc8's `bytes` /
          // `8-bits` feeders). An unnamed constant's whole bounds ARE the
          // value box (crc8's oid 3033).
          var box = rect;
          if (constValues[object.oid] != null) {
            final kids =
                scene.diagram.childrenByOid[object.oid] ??
                const <ViHeapObject>[];
            final named = kids.any(
              (c) =>
                  c.kind == 0x0a &&
                  !c.isLabelHidden &&
                  (c.label?.trim().isNotEmpty ?? false),
            );
            if (named) {
              for (final c in kids) {
                final b = c.absBounds;
                if (c.kind == 0x9 && b != null && b.right > b.left) {
                  box = _toCanvas(b);
                  break;
                }
              }
            }
          }
          // A boolean constant's shell draws LabVIEW's exact T/F block — the
          // decoded [ViHeapObject.constBool] picks the bitmap.
          final constHolder = scene.diagram.byId[object.parentOid ?? -1];
          final boolValue = constHolder?.kind == 0x13
              ? constHolder!.constBool
              : null;
          if (boolValue != null && box.width == 16 && box.height == 14) {
            _drawBoolConstant(
              canvas,
              box,
              boolValue,
              disabled: disabledOids.contains(object.oid),
            );
            continue;
          }
          // A terminal whose (datatype, direction) has reference-measured
          // art at the standard 32×16 box draws it pixel-exact
          // ([kBdTerminalArt]); unmeasured types keep the generic frame.
          final artType =
              object.dataType ?? _dataTypeOfTypeKind(object.typeKind);
          if (artType != null &&
              object.isIndicator != null &&
              box.width == 32 &&
              box.height == 16) {
            // An array terminal draws the element-typed bracket art
            // ([kBdArrayTerminalArt]); a scalar draws its own table entry.
            final elementKind = artType == ViDataType.array
                ? object.resolvedElementType?.kind
                : null;
            final art = elementKind != null
                ? bdArrayTerminalArtFor(
                    elementKind,
                    indicator: object.isIndicator == true,
                  )
                : bdTerminalArtFor(
                    artType,
                    indicator: object.isIndicator == true,
                  );
            if (art != null) {
              _drawTerminalArt(
                canvas,
                box,
                art,
                disabled: disabledOids.contains(object.oid),
              );
              continue;
            }
          }
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
          // An ARRAY constant's element box draws LabVIEW's measured chrome
          // instead of the generic stroked frame: a crisp 3 px ring whose
          // outer edge sits 1 px outside the part bounds on the left/top and
          // ON the bounds' right/bottom edges (crc8's Polynomial + LUT
          // arrays, byte-verified), value digits in the element colour.
          final shellParent = scene.diagram.byId[object.parentOid ?? -1];
          if (object.kind == 0x50 && shellParent?.kind == 0x52) {
            // Both the INDEX box (window, spinner boxes, arrows) and the
            // ELEMENT cells (the grid of value boxes) are the array shell's
            // furniture ([_drawArrayConstantShell]); the generic stroked
            // frame would double them.
            continue;
          }
          // Indicators wear LabVIEW's thin 1px single border (measured on
          // Excel_Read_XLSX's path and array indicator terminals; matches
          // the art table's indicator rasters); controls keep the 2px
          // double-border weight.
          if (object.isIndicator == true) {
            canvas.drawRect(
              box,
              Paint()
                ..color = border
                ..isAntiAlias = false,
            );
            canvas.drawRect(
              box.deflate(1),
              Paint()
                ..color = Colors.white
                ..isAntiAlias = false,
            );
          } else {
            canvas.drawRect(box, Paint()..color = Colors.white);
            canvas.drawRect(
              box.deflate(1),
              Paint()
                ..color = border
                ..style = PaintingStyle.stroke
                ..strokeWidth = 2.0,
            );
            // A STRING shell's LEFT border is 4 px (measured on
            // Excel_Read_XLSX's `INIT` constant: rows read 4 border px on
            // the left against 2 on the other three sides).
            if (object.kind == 0x51 && box.width > 8) {
              canvas.drawRect(
                Rect.fromLTWH(box.left, box.top, 4, box.height),
                _solidNoAa(border),
              );
            }
            // A PATH shell carries the small path glyph inside its left
            // border: two linked 4x4 squares in the border teal, the lower
            // square 2 px right of the upper, anchored at (+3,+4) — measured
            // on Excel_Read_XLSX's three path control shells (byte-identical
            // at all three).
            if (object.kind == 0x5b && box.width > 14 && box.height >= 17) {
              const glyphRows = [
                '####..',
                '#..#..',
                '#..#..',
                '####..',
                '...#..',
                '...#..',
                '..####',
                '..#..#',
                '..#..#',
                '..####',
              ];
              final ink = _solidNoAa(border);
              for (var r = 0; r < glyphRows.length; r++) {
                for (var c = 0; c < glyphRows[r].length; c++) {
                  if (glyphRows[r].codeUnitAt(c) != 0x23) continue;
                  canvas.drawRect(
                    Rect.fromLTWH(box.left + 3 + c, box.top + 4 + r, 1, 1),
                    ink,
                  );
                }
              }
            }
          }
          // Any constant skips the inner ring — including one whose VALUE
          // is not decoded (a `0x13` holder marks it): Excel_Read_XLSX's
          // path constants read the plain 2px border in the reference,
          // same as crc8's decoded oid 3033.
          final isConstant = constValue != null || shellParent?.kind == 0x13;
          if (object.isIndicator != true &&
              !isConstant &&
              box.width > 10 &&
              box.height > 10) {
            canvas.drawRect(
              box.deflate(3.5),
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
              box.height >= 12 &&
              box.width >= 12) {
            final indicator = object.isIndicator == true;
            final cy = box.center.dy;
            final double tipX;
            if (indicator) {
              // Wire enters at the left: base on the inner border.
              tipX = box.left + 7;
            } else {
              // Data leaves at the right: tip touching the outer border.
              tipX = box.right - 3;
            }
            final shade = Rect.fromLTRB(
              indicator ? box.left + 3 : box.right - 10,
              box.top + 4,
              indicator ? box.left + 10 : box.right - 3,
              box.bottom - 4,
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
          // A non-decimal constant's radix marker: the measured pixel glyph
          // ([kBdRadixMarkerGlyphs]) at the constant's 0xb radix part, in
          // the type colour; decimal constants draw nothing there
          // (byte-measured on MD5's %08x initials and %08b feeders).
          var hasRadixMarker = false;
          if (constValue != null) {
            final marker =
                kBdRadixMarkerGlyphs[bdFormatConversion(
                  bdDisplayFormatOf(scene.diagram, object.oid),
                )];
            final radixPart = marker == null
                ? null
                : scene.diagram
                      .children(object.oid)
                      .where(
                        (part) => part.kind == 0xb && part.absBounds != null,
                      )
                      .firstOrNull;
            if (marker != null && radixPart != null) {
              final (dx, dy, rows) = marker;
              final corner = _toCanvas(radixPart.absBounds!).topLeft;
              hasRadixMarker = true;
              final ink = _solidNoAa(tint);
              for (var r = 0; r < rows.length; r++) {
                for (var c = 0; c < rows[r].length; c++) {
                  if (rows[r].codeUnitAt(c) != 0x23) continue;
                  canvas.drawRect(
                    Rect.fromLTWH(corner.dx + dx + c, corner.dy + dy + r, 1, 1),
                    ink,
                  );
                }
              }
            }
          }
          // A constant's decoded literal, RIGHT-aligned in its value
          // window the way LabVIEW justifies numeric displays: the text
          // advance ends 4 px inside the window's right edge. Measured on
          // MD5's fixed-format windows, where the box is wider than the
          // digits and the alignment shows: the `%08b` pair oids 516/540
          // ("10000000"/"00000000") share one right edge with different
          // left starts, and the `%08x` spinner constants (oid 811 family)
          // end 4 px short of the window at every digit mix. A snug
          // autosized box (crc8's `256`) reads the same under any anchor.
          // Inked black through the disabled transform (the reference's
          // disabled digits read as the (153,153,153) dim of black).
          if (constValue != null && box.width >= 12 && box.height >= 12) {
            final run = _layoutText(
              constValue,
              color: _dimFor(object.oid, Colors.black),
              maxLines: 1,
            );
            _paintText(
              canvas,
              run,
              Offset(
                box.right - 4 - run.width,
                bdCentredTextTop(box, run.height),
              ),
              clip: box.deflate(hasRadixMarker ? 2 : 1),
            );
          }
          // The resolved data type's short label (DBL / I32 / TF / abc),
          // as LabVIEW stamps on the terminal — sized to sit inside the
          // double border even on a 16 px terminal. A constant box shows
          // its value instead, never the type: a decoded TEXT value on the
          // `0x13` holder is drawn by its value-label part in the text pass
          // (Excel's `INIT` / `sheet%d.xml`), so the glyph stays off those
          // boxes too.
          final glyph =
              constValue != null ||
                  object.dataType == null ||
                  (shellParent?.kind == 0x13 && shellParent?.constText != null)
              ? null
              : dataTypeGlyph(object.dataType!);
          if (glyph != null &&
              box.width >= 6.0 * glyph.length + 10 &&
              box.height >= 13) {
            final run = _layoutText(
              glyph,
              color: border,
              fontSize: 8.5,
              fontWeight: FontWeight.w700,
            );
            _paintText(canvas, run, bdCentredTextAnchor(box, run.size));
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
          // An XNode facade is the node's own stored image — drawn verbatim
          // at its bounds (the DSIM geometry matches them exactly).
          final facade = xnodeFacades[object.oid];
          if (facade != null) {
            canvas.drawImageRect(
              facade,
              Rect.fromLTWH(
                0,
                0,
                facade.width.toDouble(),
                facade.height.toDouble(),
              ),
              rect,
              Paint()..filterQuality = FilterQuality.none,
            );
            continue;
          }
          // A growable node (0x63): (68,68,68) ring, white field, and its
          // `0x62` terminal strips laid out from their node-local termBounds
          // (measured on Excel_Read_XLSX 3233 / 3179 / 2486):
          // - FULL-HEIGHT cells are terminals: (255,255,204) fill with a 1px
          //   black separator on the edge facing the node's interior; a LEFT
          //   terminal cell carries the solid black input arrow, RIGHT
          //   column cells the ridged output arrow.
          // - Partial-height cells are text rows: the resolved data-space
          //   name in the type colour (arrays by element), with 1px black
          //   dividers at shared row boundaries.
          // (objFlags bit 0x10000 marks the input-side flavour; both share
          // the ring/field chrome.)
          if (object.kind == 0x63) {
            canvas.drawRect(
              rect,
              Paint()..color = _dimFor(object.oid, const Color(0xFF444444)),
            );
            canvas.drawRect(
              rect.deflate(1),
              Paint()..color = _dimFor(object.oid, Colors.white),
            );
            final rows = <HeapRect>[];
            final rowTerms = <(ViHeapObject, HeapRect)>[];
            final cells = <HeapRect>[];
            final nodeH = object.absBounds!.bottom - object.absBounds!.top;
            final nodeW = object.absBounds!.right - object.absBounds!.left;
            for (final dco in scene.diagram.children(object.oid)) {
              if (dco.kind != 0x15) continue;
              for (final t in scene.diagram.children(dco.oid)) {
                final tb = t.termBounds;
                if (t.kind != 0x62 || tb == null) continue;
                if (tb.height >= nodeH) {
                  cells.add(tb);
                } else {
                  rows.add(tb);
                  rowTerms.add((t, tb));
                }
              }
            }
            final black = Paint()
              ..color = _dimFor(object.oid, Colors.black)
              ..isAntiAlias = false;
            final cream = Paint()
              ..color = _dimFor(object.oid, const Color(0xFFFFFFCC))
              ..isAntiAlias = false;
            rows.sort((a, b) => a.top.compareTo(b.top));
            // Interior dividers at shared row boundaries.
            for (var i = 0; i + 1 < rows.length; i++) {
              if (rows[i].bottom != rows[i + 1].top) continue;
              canvas.drawRect(
                Rect.fromLTWH(
                  rect.left + rows[i].left + 1,
                  rect.top + rows[i].bottom,
                  (rows[i].right - rows[i].left - 2).toDouble(),
                  1,
                ),
                black,
              );
            }
            for (final cell in cells) {
              final leftSide = cell.left < nodeW - cell.right;
              if (leftSide) {
                // Input terminal cell: cream to the interior separator, the
                // solid black arrow pointing INTO the node (measured on
                // 2486: a 6x3 shaft and a 4-column head, centred).
                canvas.drawRect(
                  Rect.fromLTRB(
                    rect.left + 1,
                    rect.top + 1,
                    rect.left + cell.right,
                    rect.bottom - 1,
                  ),
                  cream,
                );
                canvas.drawRect(
                  Rect.fromLTWH(
                    rect.left + cell.right,
                    rect.top + 1,
                    1,
                    rect.height - 2,
                  ),
                  black,
                );
                final cy = rect.top + (nodeH ~/ 2);
                canvas.drawRect(
                  Rect.fromLTWH(rect.left + 1, cy - 1.0, 6, 3),
                  black,
                );
                for (var i = 0; i < 4; i++) {
                  canvas.drawRect(
                    Rect.fromLTWH(
                      rect.left + 7 + i,
                      cy - 3.0 + i,
                      1,
                      (7 - 2 * i).toDouble(),
                    ),
                    black,
                  );
                }
              } else {
                // Output column: cream from the rows' right edge through the
                // cell, separators at the rows' edge and the cell's left.
                final rowsRight = rows.isEmpty ? cell.left : rows.first.right;
                final top = rect.top + 1;
                final h = rect.height - 2;
                canvas.drawRect(
                  Rect.fromLTRB(
                    rect.left + rowsRight,
                    top,
                    rect.left + cell.right - 1,
                    top + h,
                  ),
                  cream,
                );
                canvas.drawRect(
                  Rect.fromLTWH(rect.left + rowsRight - 1, top, 1, h),
                  black,
                );
                canvas.drawRect(
                  Rect.fromLTWH(rect.left + cell.left - 1, top, 1, h),
                  black,
                );
                // The ridged output arrow through the columns, centred on
                // the node's middle row (measured on 3233; 3179 reads the
                // same bitmap).
                const arrowRows = [
                  '...........#...',
                  '.#####.....##..',
                  '#.############.',
                  '#.#############',
                  '#.############.',
                  '.#####.....##..',
                  '...........#...',
                ];
                final cy = rect.top + (nodeH ~/ 2);
                final x0 = rect.left + rowsRight;
                for (var r = 0; r < arrowRows.length; r++) {
                  final y = cy - 3 + r;
                  final mask = arrowRows[r];
                  for (var c = 0; c < mask.length; c++) {
                    if (mask.codeUnitAt(c) != 0x23) continue;
                    canvas.drawRect(
                      Rect.fromLTWH(x0 + c.toDouble(), y.toDouble(), 1, 1),
                      black,
                    );
                  }
                }
              }
            }
            // Row text: the terminal's resolved data-space name, centred
            // in the row cell with the half pixel truncated (reference-
            // measured across the corpus's growable strips: every odd
            // cell−text gap inks at the floor — Excel 3233's 27 px
            // `worksheet.xml` gap, Export/Pages/ProjectItems rows — never
            // the rounded-up centre), in the type colour (array rows
            // colour by element).
            for (final (term, tb) in rowTerms) {
              final name = term.typeName?.trim();
              if (name == null || name.isEmpty) continue;
              final elementKind = term.typeKind == ViTypeKind.array
                  ? term.resolvedElementType?.kind
                  : null;
              final rowColor = elementKind != null
                  ? labviewTypeColor(_typeKindOfDataType(elementKind))
                  : labviewTypeColor(term.typeKind);
              final cell = Rect.fromLTRB(
                rect.left + tb.left + 1,
                rect.top + tb.top,
                rect.left + tb.right - 1,
                rect.top + tb.bottom,
              );
              final run = _layoutText(
                name,
                color: _dimFor(object.oid, rowColor),
                maxLines: 1,
              );
              _paintText(
                canvas,
                run,
                bdCentredTextAnchor(cell, run.size),
                clip: cell,
              );
            }
            continue;
          }
          final icon = subViIcons[object.oid];
          final iconKey = primIconKeyOf(object);
          final disabled = disabledOids.contains(object.oid);
          final primIcon =
              (disabled
                  ? primIconArtFor(object, scene.diagram, primIconsGrey)
                  : null) ??
              primIconArtFor(object, scene.diagram, primIcons);
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
            // Plate corner-AA ladder: a corner pixel ([_primIconCornerAa])
            // is the plate outline's anti-aliasing baked against the WHITE
            // canvas, not opaque art, so over an earlier stamp it composes
            // by the measured reference ladder (MD5's stacked Adds, tops
            // 446/465/485/504):
            //  * over another stamp's OPAQUE art the corner deposits
            //    NOTHING — the art beneath shows through byte-exactly;
            //  * two corner pixels coinciding on bare canvas deepen the
            //    blend one rung, `dddddd` -> `aaaaaa`;
            //  * on bare canvas alone the baked `dddddd` stands.
            // The compositor rule producing the second rung is not yet
            // decoded — no pixel-local source-over/coverage model yields
            // 255->221 and 221->170 from the same stamp (TODO: revisit
            // when the corpus grows another corner-corner collision).
            final ladderId = disabled ? null : loadedPrimIconIdOf(object);
            final corners = ladderId == null
                ? null
                : _primIconCornerAa[ladderId];
            for (final artIndex in corners ?? const <int>{}) {
              final artWidth = primIcon.base.width;
              final cornerX = dst.left + artIndex % artWidth;
              final cornerY = dst.top + artIndex ~/ artWidth;
              var beneathCorner = false;
              Color? restore;
              for (final prior in stampedPrimIcons.reversed) {
                final localX = (cornerX - prior.dst.left).round();
                final localY = (cornerY - prior.dst.top).round();
                final mask = _primIconMasks[prior.id];
                if (mask == null ||
                    localX < 0 ||
                    localY < 0 ||
                    localX >= mask.w ||
                    localY >= mask.h) {
                  continue;
                }
                final priorIndex = localY * mask.w + localX;
                if (mask.alpha[priorIndex] == 0) continue;
                if (_primIconCornerAa[prior.id]?.contains(priorIndex) ??
                    false) {
                  beneathCorner = true;
                  continue;
                }
                final rgba = _primIconRgba[prior.id]!;
                restore = Color.fromARGB(
                  0xff,
                  rgba[priorIndex * 4],
                  rgba[priorIndex * 4 + 1],
                  rgba[priorIndex * 4 + 2],
                );
                break;
              }
              final rung = restore ?? (beneathCorner ? _kCornerAaRung2 : null);
              if (rung != null) {
                canvas.drawRect(
                  Rect.fromLTWH(cornerX, cornerY, 1, 1),
                  _solidNoAa(rung),
                );
              }
            }
            if (ladderId != null) {
              stampedPrimIcons.add((dst: dst, id: ladderId));
            }
          } else if (icon != null) {
            paintLegacyIcon(canvas, icon, rect);
          } else {
            final fill = _dimFor(
              object.oid,
              isSubVi ? kBdSubViNodeFill : kBdPrimitiveNodeFill,
            );
            canvas.drawRect(rect, Paint()..color = fill);
          }
          if (primIcon == null) {
            // A node without icon art is a CLEAN crisp rectangle: 1 px black
            // ring on the exact bounds, no anti-aliasing (the old half-pixel
            // stroke read as a faint translucent outline).
            final ring = _solidNoAa(_dimFor(object.oid, Colors.black));
            canvas.drawRect(
              Rect.fromLTWH(rect.left, rect.top, rect.width, 1),
              ring,
            );
            canvas.drawRect(
              Rect.fromLTWH(rect.left, rect.bottom - 1, rect.width, 1),
              ring,
            );
            canvas.drawRect(
              Rect.fromLTWH(rect.left, rect.top, 1, rect.height),
              ring,
            );
            canvas.drawRect(
              Rect.fromLTWH(rect.right - 1, rect.top, 1, rect.height),
              ring,
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
            final run = _layoutText(
              glyph,
              color: _dimFor(object.oid, Colors.black).withValues(alpha: 0.75),
              fontSize: glyph.length > 2 ? 8.0 : 12,
              maxLines: 1,
            );
            _paintText(canvas, run, bdCentredTextAnchor(rect, run.size));
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
    // Free-label backings, above every node/icon they overlap: a 1px black
    // border on the outermost pixel ring of the label bounds, filled with
    // the decoded colour inside (reference-measured on Excel_Read_XLSX's
    // comment). Caption text lands on top in the text pass below.
    for (final (oid, rect, backing) in labelBackings) {
      canvas.drawRect(rect, Paint()..color = _dimFor(oid, Colors.black));
      canvas.drawRect(rect.deflate(1), Paint()..color = _dimFor(oid, backing));
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
        // The selector's stored value text keeps its own padding spaces
        // (" 3 ", " 0, Default ") — LabVIEW's left inset — so it is not
        // trimmed.
        var text = object.kind == 0x95
            ? (object.label?.trim().isEmpty ?? true ? null : object.label)
            : object.label?.trim();
        if (text == null || text.isEmpty) {
          // An owned label with no recovered caption is the owner's VALUE
          // display when a constant value decoded on the const holder above
          // it (`0x13` → shell → label: Excel's `xl\workbook.xml` path and
          // `INIT` string constants); otherwise it shows the owner's resolved
          // data-space name (the VCTP type name, e.g. `data in`) — the
          // identifier LabVIEW displays in that label.
          final diagramById = scene.diagram.byId;
          String? constValue;
          var ancestorOid = object.parentOid;
          for (var hop = 0; hop < 4 && ancestorOid != null; hop++) {
            final ancestor = diagramById[ancestorOid];
            if (ancestor == null) break;
            final decoded = ancestor.constText?.trim();
            if (decoded != null && decoded.isNotEmpty) {
              constValue = decoded;
              break;
            }
            ancestorOid = ancestor.parentOid;
          }
          text = constValue ?? byOid[object.parentOid]?.typeName;
        }
        if (text == null || text.isEmpty) continue;
        final rect = rectOf(object);
        if (rect.width < 8 || rect.height < 8) continue;
        // The case selector's value text fills its decoded label bounds — the
        // pager boxes and dropdown sit OUTSIDE them (see [_drawCaseSelector])
        // — LEFT-justified like LabVIEW's (the recovered label carries the
        // reference's own leading space: MD5's " 3 " strip shows the glyph
        // at bounds.left+4, the space's width past a 1 px inset).
        final selector = object.kind == 0x95;
        // The label's decoded face: its first font run resolved against the
        // VI's FTAB ([ViHeapObject.labelFont]) — weight 1000 draws the bold
        // face; a non-default table size (its cell height in px, 15 = the
        // default UI font whose em is [kBdTextSize]) scales the em by
        // size/15 (crc32_lookup_table's 21 px heading, Read VI Blocks'
        // 20 px numbering). MD5's bold headings keep the regular face's
        // 9 px caps and land within the stored label bounds only at the
        // bold face's own advances (reference-measured). A non-default
        // family (Courier New) is not yet rendered — the default face
        // stands in. // TODO(labwright): render FTAB face names.
        final labelFont = object.labelFont;
        final fontSize = labelFont == null
            ? kBdTextSize
            : bdEmForCellHeight(labelFont.resolvedSize);
        final run = _layoutText(
          text,
          color: _dimFor(
            object.oid,
            bdDecodedColor(object.fgRgb) ?? Colors.black,
          ),
          fontSize: fontSize,
          fontWeight: object.labelIsBold ? FontWeight.w700 : FontWeight.w400,
          // Label text is never truncated or auto-wrapped: LabVIEW sizes a
          // label's bounds to its text (multi-line captions carry their own
          // newlines), so the render lets the metric-matched layout run its
          // full width rather than ellipsising a few px of slack.
          maxLines: math.max(1, (rect.height / bdLineBox(fontSize)).round()),
        );
        // A selector's value text HARD-clips 4 px inside its label part's
        // right bound — cut glyphs, no ellipsis (MD5's oid 6039 strip:
        // ` 0, Default ` shows exactly ` 0, De`; the following `f` stem,
        // which a bounds-edge clip would keep, is absent in the reference,
        // pinning the clip edge to bounds.right-4/-5). A wide-enough strip
        // (its sibling selectors) shows the whole run unchanged.
        // A CENTRE-justified label ([ViHeapObject.labelJustifyCenter], the
        // 0x021 word's 0x20 bit) centres its run by [bdCentredLabelLeft] —
        // a different half-pixel law from the cell centring of
        // [bdCentredTextAnchor], measured separately.
        // A LEFT-justified label pens at [ViHeapObject.labelTextInset]
        // (the 0x021 word's 0x800000 bit: 2 px, else 1 px) inside its
        // bounds — corpus-measured across holder classes.
        final centered = !selector && object.labelJustifyCenter;
        _paintText(
          canvas,
          run,
          selector
              ? Offset(rect.left + 1, bdCentredTextTop(rect, run.height))
              : centered
              ? Offset(bdCentredLabelLeft(rect, run.width), rect.top + 1)
              : rect.topLeft + Offset(object.labelTextInset.toDouble(), 1),
          clip: selector
              ? Rect.fromLTRB(rect.left, rect.top, rect.right - 4, rect.bottom)
              : null,
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
      // a neutral near-black, and pens at the same decoded text inset a label
      // does ([ViHeapObject.labelTextInset]). No run this fallback draws
      // registers confidently against a snippet reference (the ink-registration
      // census leaves it unmeasured either way), so it follows the measured
      // label law rather than an inset of its own.
      final textColor = _dimFor(
        object.oid,
        bdDecodedColor(object.fgRgb) ?? Colors.black,
      );
      final run = _layoutText(text, color: textColor, maxLines: 1);
      _paintText(
        canvas,
        run,
        rect.topLeft + Offset(object.labelTextInset.toDouble(), 1),
        clip: rect.deflate(1),
      );
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
    List<
      (Rect, ({int kind, bool hollow, bool centreDot, bool disabled}), Color)
    >?
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
    // Node-category boxes (canvas coords): the cover set for the
    // fully-under-nodes withhold below (LabVIEW paints nodes OVER wires, so
    // a polyline every pixel of which lies under node boxes has no visible
    // ink — drawing it would ink pixels LabVIEW leaves to the node art;
    // measured on the crc-family LUT chains, whose abutting conversion
    // prims carry stored routes threaded entirely under the chain).
    final nodeCoverRects = <Rect>[];
    for (final object in objects) {
      final bounds = object.absBounds;
      if (bounds == null) continue;
      if (object.category == ViObjectKind.node &&
          bounds.width > 0 &&
          bounds.height > 0) {
        nodeCoverRects.add(_toCanvas(bounds));
      }
      final packed = _packRect(
        bounds.top,
        bounds.left,
        bounds.bottom,
        bounds.right,
      );
      if (object.category == ViObjectKind.terminal &&
          object.typeKind != ViTypeKind.unknown) {
        typedTerminalColors[packed] = bdTerminalTypeColor(object);
      }
      final iconKey = loadedPrimIconIdOf(object);
      if (iconKey != null) {
        final boxRect = _toCanvas(bounds);
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
    // ---- Wire-NET colour resolution ----
    // LabVIEW draws one dataflow wire as a chain of 0x17 signals joined end
    // to end (through tunnels and junction stubs); every segment of the
    // chain inks in the same type colour. The authoritative tint lives on
    // whichever signal touches a resolved terminal — the others' endpoints
    // are unbounded `0x1d`/`0x15` stubs — so signals are UNIONED into nets
    // by shared route endpoints/junctions and each takes its net's
    // best-resolved colour. Resolution tiers per signal (lowest wins):
    //   0 typed endpoint-anchor rect ([typedTerminalColors]),
    //   1 resolved endpoint OBJECT ([bdTerminalTypeColor] — carries the
    //     cluster member tint the anchor map cannot),
    //   2 a source primitive's documented output ([sourceOutputColors]),
    //   3 the signal word's element family (the 89.9% estimate tier).
    // The neutral grey means "unresolved" at every tier (nothing colours
    // 0x8A8A8A legitimately) and never propagates.
    const unresolvedGrey = Color(0xFF8A8A8A);
    final netParent = <int, int>{
      for (final w in wires) w.signalOid: w.signalOid,
    };
    int netFind(int a) {
      var root = a;
      while (netParent[root] != root) {
        root = netParent[root]!;
      }
      var cursor = a;
      while (netParent[cursor] != root) {
        final next = netParent[cursor]!;
        netParent[cursor] = root;
        cursor = next;
      }
      return root;
    }

    void netUnion(int a, int b) => netParent[netFind(a)] = netFind(b);
    final pointOwner = <int, int>{};
    List<ViPoint> netPointsOf(ViWire wire) => [
      for (final run in [
        if (wire.routePoints case final p? when p.isNotEmpty) p,
        ...?wire.routeTree?.polylines,
      ]) ...[run.first, run.last],
      ...?wire.routeTree?.junctions,
    ];
    for (final wire in wires) {
      // Signals join a net where route endpoints/junctions coincide AND
      // where they share a decoded attach rect (the two signals either
      // side of one tunnel).
      final keys = [
        for (final p in netPointsOf(wire))
          ((p.x + 0x8000) << 17) | (p.y + 0x8000),
        for (final attach in wire.endpointAttachRects)
          if (attach != null && attach.width > 0 && attach.height > 0)
            _packRect(attach.top, attach.left, attach.bottom, attach.right),
      ];
      for (final key in keys) {
        final owner = pointOwner[key];
        if (owner == null) {
          pointOwner[key] = wire.signalOid;
        } else {
          netUnion(wire.signalOid, owner);
        }
      }
    }
    final netBest = <int, (int, Color)>{};
    final netError = <int, bool>{};
    for (final wire in wires) {
      final root = netFind(wire.signalOid);
      void consider(int tier, Color? color) {
        if (color == null || color == unresolvedGrey) return;
        final best = netBest[root];
        if (best == null || tier < best.$1) netBest[root] = (tier, color);
      }

      for (final anchor in wire.endpointAnchors) {
        if (anchor == null) continue;
        consider(
          0,
          typedTerminalColors[_packRect(
            anchor.top,
            anchor.left,
            anchor.bottom,
            anchor.right,
          )],
        );
      }
      for (final oid in wire.endpointOids) {
        final endpoint = scene.diagram.byId[oid];
        if (endpoint == null) continue;
        if (_isErrorClusterMembers(endpoint.resolvedMembers)) {
          netError[root] = true;
        }
        if (endpoint.resolvedMembers.isNotEmpty ||
            endpoint.resolvedElementMembers.isNotEmpty ||
            endpoint.typeKind != ViTypeKind.unknown) {
          consider(1, bdTerminalTypeColor(endpoint));
        }
      }
      final source = wire.endpointAnchors.firstWhere(
        (a) => a != null,
        orElse: () => null,
      );
      if (source != null) {
        consider(
          2,
          sourceOutputColors[_packRect(
            source.top,
            source.left,
            source.bottom,
            source.right,
          )],
        );
      }
      final wordKind = wire.elementTypeKind;
      if (wordKind != null && wordKind != ViTypeKind.unknown) {
        // Refnum WIRES ink the same teal as paths — reference-measured on
        // ProjectItems' six refnum runs (0x006666 against white, solid1px
        // and solid2px alike). [labviewTypeColor] keeps refnum TERMINAL
        // borders neutral: no reference has pinned those yet.
        consider(
          3,
          wordKind == ViTypeKind.refnum
              ? const Color(0xFF006666)
              : labviewTypeColor(wordKind),
        );
      }
    }
    // The scene's furniture boxes ([BdScene.furnitureBounds]) in canvas
    // space, for the into-DCO leg trim below.
    final furnitureRects = <Rect>[
      for (final bounds in scene.furnitureBounds) _toCanvas(bounds),
    ];
    // Segments already drawn by EARLIER wires (heap serialization order),
    // in integer pixel space — the crossing rule cuts later wires around
    // them.
    final drawn = <_BdWireSeg>[];
    for (final wire in wires) {
      // Endpoints with a DECODED attach rect get their border-terminal
      // chrome drawn at it (kind-specific, reference-verified only). A wire's
      // BODY comes from its decoded route ([ViWire.routePoints] /
      // [ViWire.routeTree]); an endpoint's owner box no longer routes a leg.
      final tunnels =
          <(Rect, ({int kind, bool hollow, bool centreDot, bool disabled}))>[];
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
        final attachRect = _toCanvas(attach);
        final info = borderTerminalKinds[attach];
        if (info != null) tunnels.add((attachRect, info));
      }
      // The signal takes its NET's best-resolved colour (see the prepass
      // above); an unresolved net keeps the neutral wire dark. The braid
      // (depth-3 cluster) special case: an error net — or a braid net with
      // no resolution at all (the corpus' unresolved braids are the error
      // chains) — draws LabVIEW's dedicated dark-yellow error palette
      // (olive flanks + yellow/black weave, measured on Excel_Read_XLSX;
      // its tunnels fill the flank olive); a resolved non-error cluster
      // braid draws the catalogued cycle in its member tint (Excel's pink
      // `StateData` shift-register net; the census' braid runs are
      // pink-dominant).
      final netRoot = netFind(wire.signalOid);
      var color = netBest[netRoot]?.$2 ?? kBdWireColor;
      var errorBraid = false;
      if (wire.signalType?.renderStyle == ViWireRenderStyle.braid) {
        errorBraid =
            (netError[netRoot] ?? false) ||
            netBest[netRoot] == null ||
            color == const Color(0xFF666600);
        if (errorBraid) color = const Color(0xFF666600);
      }
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
      // Whether the straight-stub tier below may draw this wire: no decoded
      // route shipped, OR the shipped polyline was withheld as fully covered
      // by node boxes — its only visible ink is the seam between the
      // adjacent nodes' ART, exactly what the stub tier draws from the ink
      // edges (the crc8 disabled chain's abutment stubs).
      var stubEligible = routeTree == null && routePoints == null;
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

          final slack = wire.routeHeadSlack;
          if (slack != null) {
            // A slack-headed walk ([ViWire.routeHeadSlack]): the route's
            // stored lengths measure from the head prim's own terminal — a
            // builtin position the file does not carry — so the walk pinned
            // the head at the prim's border and left the slack-axis
            // coordinate one degree free. Resolve it from the terminal
            // catalog ([bdPrimTerminalOf]) by sliding every point but the
            // anchored tail (always an explicit trailing point on a slack
            // ship) so the head lands on the terminal; a wire whose
            // terminal is uncatalogued is not drawn (decoded geometry only,
            // never a guess).
            final terminal = bdPrimTerminalOf(
              scene.diagram,
              wire.endpointOids[0],
            );
            final tx = terminal?.x, ty = terminal?.y;
            final head = points.first;
            // The catalog entry must agree with the walk's pinned
            // perpendicular coordinate, and the slide must run along the
            // shipped interior-ward step (a contrary slide means the
            // resolved terminal is wrong, and would shorten or invert the
            // closing run).
            final slide = slack.dx != 0
                ? (tx == null ? null : tx - origin.dx - head.dx)
                : (ty == null ? null : ty - origin.dy - head.dy);
            final resolved =
                tx != null &&
                ty != null &&
                slide != null &&
                slide * (slack.dx + slack.dy) >= 0 &&
                (slack.dx != 0
                    ? (head.dy + origin.dy).round() == ty
                    : (head.dx + origin.dx).round() == tx);
            if (!resolved) {
              points.clear();
            } else {
              final delta = slack.dx != 0 ? Offset(slide, 0) : Offset(0, slide);
              for (var i = 0; i < points.length - 1; i++) {
                points[i] = points[i] + delta;
              }
            }
          } else {
            // A polyline closed onto a [ViDiagram.dcoChildTerminalAttach]
            // candidate whose prim terminal is CATALOGUED at both axes
            // ([bdPrimTerminalOf], reference-measured — it outranks the
            // candidate convention) re-anchors: the whole polyline
            // translates so that endpoint sits on the catalogued terminal
            // (the stored segments are exact; only the anchor convention
            // differed — measured on MD5, where every such wire's candidate
            // anchor misses the reference ink the catalogued terminal
            // lands on). Two catalogued ends demanding different
            // translations contradict, and the wire is withheld.
            Offset? reanchor;
            var reanchorConflict = false;
            if (wire.endpointOids.length == 2) {
              for (final (e, p) in [(0, points.first), (1, points.last)]) {
                final oid = wire.endpointOids[e];
                if (scene.diagram.wireAttachPoint(oid) != null) continue;
                final abs = (
                  x: (p.dx + origin.dx).round(),
                  y: (p.dy + origin.dy).round(),
                );
                final candidates = scene.diagram
                    .dcoChildTerminalAttach(oid)
                    ?.candidates;
                if (candidates == null || !candidates.contains(abs)) continue;
                final term = bdPrimTerminalOf(scene.diagram, oid);
                if (term?.x == null || term?.y == null) continue;
                final delta = Offset(
                  (term!.x! - abs.x).toDouble(),
                  (term.y! - abs.y).toDouble(),
                );
                if (delta == Offset.zero) continue;
                if (reanchor == null) {
                  reanchor = delta;
                } else if (reanchor != delta) {
                  reanchorConflict = true;
                }
              }
            }
            if (reanchorConflict) {
              points.clear();
            } else if (reanchor != null) {
              for (var i = 0; i < points.length; i++) {
                points[i] = points[i] + reanchor;
              }
            }
            final sourceBox = iconBox(0);
            if (points.length >= 2 && sourceBox != null) {
              final c = (iconInkRects[sourceBox] ?? sourceBox).center;
              final p0 = points.first, p1 = points[1];
              points[0] = p0.dy == p1.dy
                  ? Offset(c.dx, p0.dy)
                  : Offset(p0.dx, c.dy);
            }
          }
          final sinkBox = points.isEmpty
              ? null
              : iconBox(wire.endpointAnchors.length - 1);
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
              final Offset target;
              if (closing.dx != 0) {
                final edge = farObj == null
                    ? null
                    : primIconInkEdge(
                        farObj,
                        horizontal: true,
                        cross: (last.dy + origin.dy).round(),
                        sign: closing.dx,
                      );
                target = Offset(
                  edge != null
                      ? edge - origin.dx
                      : (closing.dx > 0 ? ink.left : ink.right - 1),
                  last.dy,
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
                target = Offset(
                  last.dx,
                  edge != null
                      ? edge - origin.dy
                      : (closing.dy > 0 ? ink.top : ink.bottom - 1),
                );
              }
              // The closing run steps FROM the bend IN the closing
              // direction; an edge behind the bend means the run is
              // entirely under opaque art (the bend already sits past the
              // arrival edge) and adds no visible ink — extending to it
              // would drag a stroke backwards across the art and out the
              // far side (measured on MD5's Multiply lower input, where
              // the up-closing run's opposite edge sat below the box art).
              final along =
                  (target.dx - last.dx) * closing.dx +
                  (target.dy - last.dy) * closing.dy;
              if (along > 0) points.add(target);
            } else {
              // The closing run reached the box edge: run on under the art
              // to where it becomes OPAQUE on the arrival row/column
              // ([primIconInkEdge], same law as the decoded-bend arrivals
              // above) — never past it: the reference leaves the art's
              // TRANSPARENT cells white, so overrunning to the icon centre
              // paints ink LabVIEW never shows (measured on MD5's Select
              // top/bottom inputs, whose triangle corners are transparent
              // on the arrival rows). Falls back to the icon-ink centre
              // when the arrival line carries no masked art.
              final c = ink.center;
              final pn = points.last, pm = points[points.length - 2];
              final farObj = iconNodeObjects[sinkBox];
              if (pn.dy == pm.dy) {
                final edge = farObj == null
                    ? null
                    : primIconInkEdge(
                        farObj,
                        horizontal: true,
                        cross: (pn.dy + origin.dy).round(),
                        sign: pn.dx >= pm.dx ? 1 : -1,
                      );
                points[points.length - 1] = Offset(
                  edge != null ? edge - origin.dx : c.dx,
                  pn.dy,
                );
              } else {
                final edge = farObj == null
                    ? null
                    : primIconInkEdge(
                        farObj,
                        horizontal: false,
                        cross: (pn.dx + origin.dx).round(),
                        sign: pn.dy >= pm.dy ? 1 : -1,
                      );
                points[points.length - 1] = Offset(
                  pn.dx,
                  edge != null ? edge - origin.dy : c.dy,
                );
              }
            }
          }
        }
        // A leg end attached INSIDE a value-display endpoint (a numeric/
        // array constant) shows no ink before the display's opaque window
        // chrome: the stored attach point sits under the control's
        // transparent label gap, where the reference is white (measured on
        // crc8's `8-bits`/`bytes` constants — their reference runs begin
        // at the window ring's outer column, 10 px past the stored attach).
        // The end point slides forward along its own segment to the first
        // furniture (`0x9`/`0xe0`) rect edge inside the endpoint's anchor;
        // a point already under furniture keeps the chrome's own cover, and
        // an anchor with no furniture on the segment is left exact.
        if (points.length >= 2 && wire.endpointAnchors.length >= 2) {
          void trimToFurniture({required bool head}) {
            final index = head ? 0 : wire.endpointAnchors.length - 1;
            final anchor = wire.endpointAnchors[index];
            if (anchor == null || anchor.width <= 0 || anchor.height <= 0) {
              return;
            }
            final anchorRect = _toCanvas(anchor);
            if (iconNodeRects.contains(anchorRect)) return;
            final end = head ? points.first : points.last;
            final next = head ? points[1] : points[points.length - 2];
            if (!anchorRect.contains(end)) return;
            final horizontal = end.dy == next.dy;
            if (!horizontal && end.dx != next.dx) return;
            final sign = horizontal
                ? (next.dx - end.dx).sign
                : (next.dy - end.dy).sign;
            if (sign == 0) return;
            double? best;
            for (final furniture in furnitureRects) {
              if (furniture.left < anchorRect.left ||
                  furniture.top < anchorRect.top ||
                  furniture.right > anchorRect.right ||
                  furniture.bottom > anchorRect.bottom) {
                continue;
              }
              if (horizontal
                  ? end.dy < furniture.top || end.dy >= furniture.bottom
                  : end.dx < furniture.left || end.dx >= furniture.right) {
                continue;
              }
              if (furniture.contains(end)) return;
              final near = horizontal
                  ? (sign > 0 ? furniture.left : furniture.right - 1)
                  : (sign > 0 ? furniture.top : furniture.bottom - 1);
              final along = (near - (horizontal ? end.dx : end.dy)) * sign;
              final limit =
                  ((horizontal ? next.dx : next.dy) -
                      (horizontal ? end.dx : end.dy)) *
                  sign;
              if (along <= 0 || along > limit) continue;
              if (best == null ||
                  along < (best - (horizontal ? end.dx : end.dy)) * sign) {
                best = near;
              }
            }
            if (best == null) return;
            final trimmed = horizontal
                ? Offset(best, end.dy)
                : Offset(end.dx, best);
            if (head) {
              points[0] = trimmed;
            } else {
              points[points.length - 1] = trimmed;
            }
          }

          trimToFurniture(head: true);
          trimToFurniture(head: false);
        }
        // Withhold a polyline with NO visible box-level ink: every pixel
        // under a node box ([nodeCoverRects]) is painted over by node
        // art/chrome in LabVIEW's draw order (the crc-family LUT chains'
        // abutting conversion prims store exactly such routes). A withheld
        // 2-point wire falls through to the straight-stub tier, which draws
        // the seam ink between the adjacent nodes' ART edges — the one part
        // LabVIEW shows.
        if (points.length >= 2) {
          if (!_polylineUnderNodes(points, nodeCoverRects)) {
            legs.add(points);
          } else {
            stubEligible = true;
          }
        }
      } else if (wire.branchRoute != null && wire.endpointOids.length >= 3) {
        // A branching table whose ORIGIN is a catalogued prim terminal
        // ([bdPrimTerminalOf], both axes) and no endpoint resolves a
        // standard attach (the parse gates all declined): the stored tree
        // is fully decoded off the catalogued origin, and it ships only
        // when EVERY walked leaf lands exactly on its own endpoint's
        // catalogued terminal or [ViDiagram.dcoChildTerminalAttach]
        // candidate — zero-slack closure at every endpoint, never a guess.
        // Leaves sit under their nodes' art, which overdraws the covered
        // interior (the same law as every routeTree leaf).
        final headTerminal = bdPrimTerminalOf(
          scene.diagram,
          wire.endpointOids[0],
        );
        if (headTerminal?.x != null && headTerminal?.y != null) {
          final tree = walkWireBranchRoute(wire.branchRoute!, (
            x: headTerminal!.x!,
            y: headTerminal.y!,
          ));
          final leaves = tree.leaves;
          var closed = leaves.length == wire.endpointOids.length - 1;
          if (closed) {
            final remaining = <ViPoint, int>{};
            for (final leaf in leaves) {
              remaining.update(leaf, (c) => c + 1, ifAbsent: () => 1);
            }
            for (var e = 1; e < wire.endpointOids.length; e++) {
              final oid = wire.endpointOids[e];
              final term = bdPrimTerminalOf(scene.diagram, oid);
              ViPoint? match;
              for (final candidate in [
                if (term?.x != null && term?.y != null)
                  (x: term!.x!, y: term.y!),
                ...?scene.diagram.dcoChildTerminalAttach(oid)?.candidates,
              ]) {
                if (remaining.containsKey(candidate)) {
                  match = candidate;
                  break;
                }
              }
              if (match == null) {
                closed = false;
                break;
              }
              final count = remaining[match]!;
              if (count == 1) {
                remaining.remove(match);
              } else {
                remaining[match] = count - 1;
              }
            }
          }
          if (closed) {
            for (final run in tree.polylines) {
              legs.add([
                for (final p in run) Offset(p.x - origin.dx, p.y - origin.dy),
              ]);
            }
            for (final j in tree.junctions) {
              junctions.add(Offset(j.x - origin.dx, j.y - origin.dy));
            }
          }
        }
      }
      if (stubEligible &&
          legs.isEmpty &&
          wire.route?.pointCount == 2 &&
          wire.route?.direction != null &&
          wire.endpointOids.length == 2 &&
          wire.endpointAttachRects.length >= 2) {
        // A straight 2-point route between undecoded attach points: one
        // implied segment at the endpoints' shared terminal row/column
        // (LabVIEW measures it terminal-to-terminal; a prim's terminal
        // hides under its own icon art, so only the gap between the two
        // nodes' ink is visible). The cross coordinate comes from a decoded
        // attach rect or a catalogued builtin terminal
        // ([bdPrimTerminalOf]) — every determinable end must agree — and
        // each visible bound comes from the adjacent node's art ink edge on
        // that row ([primIconInkEdge], the closing-run arrival rule) or the
        // attach rect's border. A wire an end of which resolves neither way
        // is not drawn (decoded geometry only, never a guess).
        final dir = wire.route!.direction!;
        final horizontal = dir.dy == 0;
        final crossCandidates = <int>{};
        for (var e = 0; e < 2; e++) {
          final attach = wire.endpointAttachRects[e];
          if (attach != null &&
              attach.right > attach.left &&
              attach.bottom > attach.top) {
            crossCandidates.add(
              horizontal
                  ? attach.top + (attach.bottom - attach.top) ~/ 2
                  : attach.left + (attach.right - attach.left) ~/ 2,
            );
          } else {
            final terminal = bdPrimTerminalOf(
              scene.diagram,
              wire.endpointOids[e],
            );
            final coord = horizontal ? terminal?.y : terminal?.x;
            if (coord != null) crossCandidates.add(coord);
          }
        }
        if (crossCandidates.length == 1) {
          final cross = crossCandidates.single;
          // The endpoint at the run's low-coordinate side: [dir] steps from
          // endpoint 0 toward endpoint 1.
          final lowEnd = dir.dx > 0 || dir.dy > 0 ? 0 : 1;
          int? visibleBound(int e, {required bool lowSide}) {
            final attach = wire.endpointAttachRects[e];
            if (attach != null &&
                attach.right > attach.left &&
                attach.bottom > attach.top) {
              return horizontal
                  ? (lowSide ? attach.right : attach.left - 1)
                  : (lowSide ? attach.bottom : attach.top - 1);
            }
            final dco = scene.diagram.byId[wire.endpointOids[e]];
            final owner = dco?.parentOid == null
                ? null
                : scene.diagram.byId[dco!.parentOid!];
            if (owner == null) return null;
            final edge = primIconInkEdge(
              owner,
              horizontal: horizontal,
              cross: cross,
              sign: lowSide ? -1 : 1,
            );
            if (edge != null) return lowSide ? edge : edge - 1;
            // A node drawn as a PLAIN BOX (no icon art resolved) covers its
            // interior with the box chrome, so the wire's visible ink ends
            // at the 1 px border — reference-measured on Excel_Read_XLSX's
            // F → zip-node dotted stub (ink runs to box.left - 1). Gated on
            // the arrival row lying inside the box.
            final bounds = owner.absBounds;
            if (bounds == null) return null;
            final inSpan = horizontal
                ? cross >= bounds.top && cross < bounds.bottom
                : cross >= bounds.left && cross < bounds.right;
            if (!inSpan) return null;
            return horizontal
                ? (lowSide ? bounds.right : bounds.left - 1)
                : (lowSide ? bounds.bottom : bounds.top - 1);
          }

          final lo = visibleBound(lowEnd, lowSide: true);
          final hi = visibleBound(1 - lowEnd, lowSide: false);
          if (lo != null && hi != null && lo <= hi) {
            legs.add(
              horizontal
                  ? [
                      Offset(lo - origin.dx, cross - origin.dy),
                      Offset(hi - origin.dx, cross - origin.dy),
                    ]
                  : [
                      Offset(cross - origin.dx, lo - origin.dy),
                      Offset(cross - origin.dx, hi - origin.dy),
                    ],
            );
          }
        }
      }
      if (stubEligible &&
          legs.isEmpty &&
          wire.route?.pointCount == 3 &&
          wire.route?.direction != null &&
          wire.route!.segmentLengths.length == 1 &&
          wire.endpointOids.length == 2 &&
          wire.endpointAttachRects.length >= 2) {
        // A 3-point route table anchored at ONE decoded attach rect, with a
        // plain prim DCO at the other end. Three decoded resolutions, tried
        // in order (each gated on arrival equality or containment — never a
        // guess):
        //
        //  1. ATTACH-ORIGIN onto a catalogued terminal: the walk starts at
        //     the attach centre and its closing run's arrival coordinate
        //     must EQUAL the far prim's catalogued cross coordinate
        //     ([bdPrimTerminalOf]); visible from the anchor border to the
        //     far node's art ink edge (measured on Excel_Read_XLSX's
        //     numeric-constant → Multiply lower-input wire).
        //  2. PRIM-ORIGIN onto the attach: the table is stored from the
        //     prim's terminal instead — the catalogued coordinate walked
        //     through the first segment must EQUAL the attach's centre
        //     cross, and the closing sign must point from the prim's box
        //     toward the attach; visible from the prim's art ink edge to
        //     the attach border, the origin jog under the art (measured on
        //     MD5's comparison prim → case-selector '?' wire).
        //  3. ATTACH-ORIGIN with the far terminal uncatalogued but the
        //     walked bend landing INSIDE the far node's box: the closing
        //     run and terminal sit under the node, whose art overdraws the
        //     covered interior — the first segment is decoded geometry and
        //     its visible ink ends at the node's art edge (measured on
        //     MD5's index-spinner → conversion prim wire).
        final route = wire.route!;
        final dir = route.direction!;
        for (final (tail, head) in [(0, 1), (1, 0)]) {
          final attach = wire.endpointAttachRects[tail];
          if (attach == null ||
              attach.right <= attach.left ||
              attach.bottom <= attach.top) {
            continue;
          }
          if (wire.endpointAttachRects[head] != null) continue;
          final terminal = bdPrimTerminalOf(
            scene.diagram,
            wire.endpointOids[head],
          );
          final headObj = scene.diagram.byId[wire.endpointOids[head]];
          final headOwner = headObj?.parentOid == null
              ? null
              : scene.diagram.byId[headObj!.parentOid!];
          final headBox = headOwner?.absBounds;
          final closingSign = route.jointSigns.isNotEmpty
              ? route.jointSigns.last
              : null;
          if (headOwner == null || headBox == null || closingSign == null) {
            break;
          }
          final start = (
            x: attach.left + (attach.right - attach.left) ~/ 2,
            y: attach.top + (attach.bottom - attach.top) ~/ 2,
          );
          final bend = (
            x: start.x + dir.dx * route.segmentLengths[0],
            y: start.y + dir.dy * route.segmentLengths[0],
          );
          final closingHorizontal = dir.dx == 0;
          final arrivalCross = closingHorizontal ? bend.y : bend.x;
          final catalogued = closingHorizontal ? terminal?.y : terminal?.x;
          // The first segment's visible ink starts just outside the anchor
          // rect's border on the walk side.
          final visStart = (
            x: dir.dx == 0
                ? start.x
                : (dir.dx > 0 ? attach.right : attach.left - 1),
            y: dir.dy == 0
                ? start.y
                : (dir.dy > 0 ? attach.bottom : attach.top - 1),
          );
          if (catalogued != null && catalogued == arrivalCross) {
            final edge = primIconInkEdge(
              headOwner,
              horizontal: closingHorizontal,
              cross: arrivalCross,
              sign: closingSign,
            );
            if (edge == null) break;
            final far = edge - closingSign;
            legs.add([
              Offset(visStart.x - origin.dx, visStart.y - origin.dy),
              Offset(bend.x - origin.dx, bend.y - origin.dy),
              closingHorizontal
                  ? Offset(far - origin.dx, bend.y - origin.dy)
                  : Offset(bend.x - origin.dx, far - origin.dy),
            ]);
            break;
          }
          // Prim-origin: the first segment departs the prim's terminal, so
          // its axis coordinate is the catalogued one walked by the stored
          // length; the closing run arrives at the attach.
          final primCoord = dir.dx == 0 ? terminal?.y : terminal?.x;
          if (primCoord != null) {
            final closingCross =
                primCoord + (dir.dx + dir.dy) * route.segmentLengths[0];
            final attachCross = dir.dx == 0 ? start.y : start.x;
            // The closing sign must carry the run OFF the prim's box toward
            // the attach side.
            final signToAttach = dir.dx == 0
                ? (start.x >= headBox.right
                      ? 1
                      : start.x < headBox.left
                      ? -1
                      : 0)
                : (start.y >= headBox.bottom
                      ? 1
                      : start.y < headBox.top
                      ? -1
                      : 0);
            if (closingCross == attachCross && closingSign == signToAttach) {
              final edge = primIconInkEdge(
                headOwner,
                horizontal: dir.dx == 0,
                cross: closingCross,
                sign: -closingSign,
              );
              if (edge == null) break;
              final nearAttach = dir.dx == 0
                  ? (closingSign > 0 ? attach.left - 1 : attach.right)
                  : (closingSign > 0 ? attach.top - 1 : attach.bottom);
              legs.add([
                dir.dx == 0
                    ? Offset(edge - origin.dx, closingCross - origin.dy)
                    : Offset(closingCross - origin.dx, edge - origin.dy),
                dir.dx == 0
                    ? Offset(nearAttach - origin.dx, closingCross - origin.dy)
                    : Offset(closingCross - origin.dx, nearAttach - origin.dy),
              ]);
              break;
            }
          }
          // Uncatalogued far terminal: decoded first segment whose bend
          // lands inside the far node's box.
          if (terminal == null &&
              bend.x > headBox.left &&
              bend.x < headBox.right &&
              bend.y > headBox.top &&
              bend.y < headBox.bottom) {
            legs.add([
              Offset(visStart.x - origin.dx, visStart.y - origin.dy),
              Offset(bend.x - origin.dx, bend.y - origin.dy),
            ]);
            break;
          }
          break;
        }
      }
      if (stubEligible &&
          legs.isEmpty &&
          wire.routePoints == null &&
          (wire.route?.pointCount ?? 0) >= 3 &&
          wire.route?.direction != null &&
          wire.route!.segmentLengths.length == wire.route!.pointCount - 2 &&
          wire.endpointOids.length == 2) {
        // A full stored route departing a CATALOGUED prim terminal
        // ([bdPrimTerminalOf], both axes pinned) with no decoded attach at
        // that end: every stored segment is decoded geometry off the
        // catalogued origin, and the implied closing run's arrival
        // coordinate must EQUAL the far end's independently known cross
        // coordinate — a decoded attach rect's centre row/column, the far
        // prim's catalogued terminal, or its [dcoChildTerminalAttach]
        // candidate — never a guess. The closing run ends at the far
        // attach rect's border, or at the far node's art ink edge
        // ([primIconInkEdge], plain box border when no art resolves); the
        // origin sits under the head node's own art, which overdraws the
        // covered interior (measured on MD5's arithmetic-chain wires).
        final route = wire.route!;
        final headTerminal = bdPrimTerminalOf(
          scene.diagram,
          wire.endpointOids[0],
        );
        final headAttach = wire.endpointAttachRects[0];
        if (headTerminal?.x != null &&
            headTerminal?.y != null &&
            (headAttach == null ||
                headAttach.right <= headAttach.left ||
                headAttach.bottom <= headAttach.top)) {
          final dir = route.direction!;
          var horizontal = dir.isHorizontal;
          var sign = dir.dx + dir.dy;
          var walkX = headTerminal!.x!, walkY = headTerminal.y!;
          final walk = <(int, int)>[(walkX, walkY)];
          for (var k = 0; k < route.segmentLengths.length; k++) {
            if (k > 0) sign = route.jointSigns[k - 1];
            if (horizontal) {
              walkX += route.segmentLengths[k] * sign;
            } else {
              walkY += route.segmentLengths[k] * sign;
            }
            walk.add((walkX, walkY));
            horizontal = !horizontal;
          }
          final closingHorizontal = horizontal;
          final closingSign = route.jointSigns.last;
          final arrivalCross = closingHorizontal ? walkY : walkX;
          int? terminus;
          final farAttach = wire.endpointAttachRects[1];
          if (farAttach != null &&
              farAttach.right > farAttach.left &&
              farAttach.bottom > farAttach.top) {
            final cross = closingHorizontal
                ? farAttach.top + (farAttach.bottom - farAttach.top) ~/ 2
                : farAttach.left + (farAttach.right - farAttach.left) ~/ 2;
            if (cross == arrivalCross) {
              terminus = closingHorizontal
                  ? (closingSign > 0 ? farAttach.left - 1 : farAttach.right)
                  : (closingSign > 0 ? farAttach.top - 1 : farAttach.bottom);
            }
          } else {
            final farTerminal = bdPrimTerminalOf(
              scene.diagram,
              wire.endpointOids[1],
            );
            var farCross = closingHorizontal ? farTerminal?.y : farTerminal?.x;
            if (farCross == null) {
              for (final c
                  in scene.diagram
                          .dcoChildTerminalAttach(wire.endpointOids[1])
                          ?.candidates ??
                      const <ViPoint>[]) {
                final cross = closingHorizontal ? c.y : c.x;
                if (cross == arrivalCross) {
                  farCross = cross;
                  break;
                }
              }
            }
            final farObj = scene.diagram.byId[wire.endpointOids[1]];
            final farOwner = farObj?.parentOid == null
                ? null
                : scene.diagram.byId[farObj!.parentOid!];
            final farBox = farOwner?.absBounds;
            if (farCross == arrivalCross && farBox != null) {
              final edge = primIconInkEdge(
                farOwner!,
                horizontal: closingHorizontal,
                cross: arrivalCross,
                sign: closingSign,
              );
              terminus = edge != null
                  ? edge - closingSign
                  : (closingSign > 0
                        ? (closingHorizontal ? farBox.left : farBox.top) - 1
                        : (closingHorizontal ? farBox.right : farBox.bottom));
            }
          }
          // The closing run must extend beyond the last bend in its stored
          // direction; a double-back means the resolved geometry is wrong.
          if (terminus != null &&
              (terminus - (closingHorizontal ? walkX : walkY)) * closingSign >=
                  0) {
            legs.add([
              for (final (px, py) in walk)
                Offset(px - origin.dx, py - origin.dy),
              closingHorizontal
                  ? Offset(terminus - origin.dx, walkY - origin.dy)
                  : Offset(walkX - origin.dx, terminus - origin.dy),
            ]);
          }
        }
      }
      if (stubEligible &&
          legs.isEmpty &&
          wire.routePoints == null &&
          (wire.route?.pointCount ?? 0) >= 4 &&
          wire.route?.direction != null &&
          wire.route!.segmentLengths.length == wire.route!.pointCount - 2 &&
          wire.endpointOids.length == 2 &&
          wire.endpointAttachRects.length >= 2) {
        // ATTACH-ORIGIN COVERED WALK: the full stored table departs a decoded
        // attach rect toward a far prim with NO decoded attach, and every
        // walked bend stays INSIDE that rect — the origin jogs under the
        // terminal's own drawn chrome, so the only visible ink is the closing
        // run's tail. Ships when the closing run's arrival coordinate EQUALS
        // the far prim's catalogued terminal cross coordinate
        // ([bdPrimTerminalOf]) and the run exits the rect toward the far
        // node; visible from the attach rect's border to the far node's art
        // ink edge ([primIconInkEdge], the into-icon arrival law). Measured
        // on MD5's index-terminal → Multiply upper-input wire (the 4-point
        // left/down/right jog under the 13x19 terminal box, closing on the
        // catalogued input row).
        final route = wire.route!;
        for (final (tail, head) in [(0, 1), (1, 0)]) {
          final attach = wire.endpointAttachRects[tail];
          if (attach == null ||
              attach.right <= attach.left ||
              attach.bottom <= attach.top) {
            continue;
          }
          if (wire.endpointAttachRects[head] != null) continue;
          final dir = route.direction!;
          var horizontal = dir.isHorizontal;
          var sign = dir.dx + dir.dy;
          var walkX = attach.left + (attach.right - attach.left) ~/ 2;
          var walkY = attach.top + (attach.bottom - attach.top) ~/ 2;
          var covered = true;
          for (var k = 0; k < route.segmentLengths.length; k++) {
            if (k > 0) sign = route.jointSigns[k - 1];
            if (horizontal) {
              walkX += route.segmentLengths[k] * sign;
            } else {
              walkY += route.segmentLengths[k] * sign;
            }
            covered =
                covered &&
                walkX >= attach.left &&
                walkX < attach.right &&
                walkY >= attach.top &&
                walkY < attach.bottom;
            horizontal = !horizontal;
          }
          if (!covered) break;
          final closingHorizontal = horizontal;
          final closingSign = route.jointSigns.last;
          final arrivalCross = closingHorizontal ? walkY : walkX;
          final terminal = bdPrimTerminalOf(
            scene.diagram,
            wire.endpointOids[head],
          );
          final catalogued = closingHorizontal ? terminal?.y : terminal?.x;
          if (catalogued == null || catalogued != arrivalCross) break;
          final headObj = scene.diagram.byId[wire.endpointOids[head]];
          final headOwner = headObj?.parentOid == null
              ? null
              : scene.diagram.byId[headObj!.parentOid!];
          if (headOwner == null) break;
          final edge = primIconInkEdge(
            headOwner,
            horizontal: closingHorizontal,
            cross: arrivalCross,
            sign: closingSign,
          );
          if (edge == null) break;
          final terminus = edge - closingSign;
          // Visible ink starts at the attach rect's border on the exit side;
          // the run must truly leave the rect toward the far node.
          final border = closingHorizontal
              ? (closingSign > 0 ? attach.right : attach.left - 1)
              : (closingSign > 0 ? attach.bottom : attach.top - 1);
          if ((terminus - border) * closingSign < 0) break;
          legs.add(
            closingHorizontal
                ? [
                    Offset(border - origin.dx, arrivalCross - origin.dy),
                    Offset(terminus - origin.dx, arrivalCross - origin.dy),
                  ]
                : [
                    Offset(arrivalCross - origin.dx, border - origin.dy),
                    Offset(arrivalCross - origin.dx, terminus - origin.dy),
                  ],
          );
          break;
        }
      }
      if (stubEligible &&
          legs.isEmpty &&
          wire.route?.direction != null &&
          wire.endpointOids.length == 2 &&
          wire.endpointAttachRects.length >= 2) {
        // CONTAINER-FACE run: one endpoint resolves an exact border-terminal
        // attach (a tunnel-family rect; every catalogued kind fits 16 px),
        // the other a large CONTAINER face (an array-block value rect, tens
        // of px a side). The stored route closes onto the exact attach, so
        // the closing run's cross coordinate is that attach's own — the
        // container's centre is NOT its connection point. Ships when the
        // cross lies within the container's span, the rects are disjoint
        // along the closing axis, and the closing sign carries the run from
        // the container to the attach; a longer table's interior bends jog
        // on the container's side (its chrome covers them — the stored
        // first segment must point INTO the container). Visible ink: the
        // run between the container face and the attach border (measured
        // on MD5's Indices-array ↔ loop-tunnel wires, both directions).
        const exactMax = 16, containerMin = 17;
        final route = wire.route!;
        final dir = route.direction!;
        final closingHorizontal = route.pointCount == 2
            ? dir.isHorizontal
            : (route.pointCount.isEven ? dir.isHorizontal : !dir.isHorizontal);
        final closingSign = route.pointCount == 2
            ? (dir.dx + dir.dy)
            : (route.jointSigns.isEmpty ? 0 : route.jointSigns.last);
        final dirTowardContainer =
            route.pointCount == 2 ||
            (dir.isHorizontal == closingHorizontal &&
                (dir.dx + dir.dy) == -closingSign);
        for (final (exactEnd, containerEnd) in [(0, 1), (1, 0)]) {
          if (closingSign == 0 || !dirTowardContainer) break;
          final exact = wire.endpointAttachRects[exactEnd];
          final container = wire.endpointAttachRects[containerEnd];
          if (exact == null || container == null) continue;
          if (exact.width <= 0 ||
              exact.width > exactMax ||
              exact.height <= 0 ||
              exact.height > exactMax) {
            continue;
          }
          if (container.width < containerMin ||
              container.height < containerMin) {
            continue;
          }
          final wap = scene.diagram.wireAttachPoint(
            wire.endpointOids[exactEnd],
          );
          if (wap == null) continue;
          // Travel sign from the container face to the exact attach along
          // the closing axis, from the rects' disjoint order.
          final int toExact, cross, lo, hi;
          if (closingHorizontal) {
            cross = wap.y;
            if (cross <= container.top || cross >= container.bottom) continue;
            if (container.right <= exact.left) {
              toExact = 1;
              lo = container.right;
              hi = exact.left - 1;
            } else if (exact.right <= container.left) {
              toExact = -1;
              lo = exact.right;
              hi = container.left - 1;
            } else {
              continue;
            }
          } else {
            cross = wap.x;
            if (cross <= container.left || cross >= container.right) continue;
            if (container.bottom <= exact.top) {
              toExact = 1;
              lo = container.bottom;
              hi = exact.top - 1;
            } else if (exact.bottom <= container.top) {
              toExact = -1;
              lo = exact.bottom;
              hi = container.top - 1;
            } else {
              continue;
            }
          }
          // An n==2 table's sign runs endpoint 0 -> 1; a longer table's
          // closing sign runs container -> exact (its origin jogs on the
          // container side).
          final wantSign = route.pointCount == 2
              ? (exactEnd == 0 ? -toExact : toExact)
              : toExact;
          if (closingSign != wantSign || lo > hi) continue;
          // An ARRAY-SHELL container's box edge is NOT chrome: the shell
          // draws only its wrap frames ([bdArrayShellWrapRects]) plus the
          // index/label furniture, so the run's ink continues past the box
          // edge until it TOUCHES the wrap spanning its cross coordinate
          // (measured on MD5's S-grid feed — the shell's label band is bare
          // canvas and the reference ink reaches the element wrap's frame).
          // Containers that are not drawn array shells keep their box face.
          var runLo = lo, runHi = hi;
          for (final o in scene.drawable) {
            final b = o.absBounds;
            if (o.kind != 0x52 ||
                b == null ||
                b.left != container.left ||
                b.top != container.top ||
                b.right != container.right ||
                b.bottom != container.bottom) {
              continue;
            }
            // The nearest wrap face along the run (the first opaque chrome
            // the ink meets travelling from the exact attach): the outermost
            // candidate wins, so a nested frame never stops the run early.
            int? face;
            for (final wrap in bdArrayShellWrapRects(scene.diagram, o.oid)) {
              final int wrapLo, wrapHi, wrapFace;
              if (closingHorizontal) {
                wrapLo = wrap.top;
                wrapHi = wrap.bottom;
                wrapFace = toExact == 1 ? wrap.right : wrap.left;
              } else {
                wrapLo = wrap.left;
                wrapHi = wrap.right;
                wrapFace = toExact == 1 ? wrap.bottom : wrap.top;
              }
              if (cross <= wrapLo || cross >= wrapHi) continue;
              face = face == null
                  ? wrapFace
                  : (toExact == 1
                        ? math.max(face, wrapFace)
                        : math.min(face, wrapFace));
            }
            if (face != null) {
              if (toExact == 1) {
                runLo = face;
              } else {
                runHi = face - 1;
              }
            }
            break;
          }
          if (runLo > runHi) continue;
          legs.add(
            closingHorizontal
                ? [
                    Offset(runLo - origin.dx, cross - origin.dy),
                    Offset(runHi - origin.dx, cross - origin.dy),
                  ]
                : [
                    Offset(cross - origin.dx, runLo - origin.dy),
                    Offset(cross - origin.dx, runHi - origin.dy),
                  ],
          );
          break;
        }
      }
      // A wire with NO decoded route (neither a proven [ViWire.routePoints]
      // polyline nor a branch [ViWire.routeTree]) is not drawn: the app renders
      // decoded geometry only, never a synthesized Manhattan guess (there is no
      // built-in routing until an editor exists). Its endpoint chrome is still
      // collected above; the wire body simply does not appear. A straight
      // 2-point route is the one exception above: its geometry IS decoded
      // (one implied segment), only its endpoints resolve through the
      // terminal catalog / ink-edge arrival.
      // Stroke style: measured tier first; the estimate tier stands in for
      // the simple solid/dotted styles only (never a patterned cycle); the
      // pre-catalogue simple laws cover the remainder (array ⇒ 2 px, scalar
      // boolean ⇒ dotted, else 1 px).
      final sigType = wire.signalType;
      var style = sigType?.renderStyle;
      if (style == null) {
        final estimate = sigType?.renderStyleEstimate;
        if (estimate == ViWireRenderStyle.solid1px ||
            estimate == ViWireRenderStyle.solid2px ||
            estimate == ViWireRenderStyle.dotted) {
          style = estimate;
        }
      }
      style ??=
          (wire.elementTypeKind == ViTypeKind.boolean &&
              (sigType?.arrayDims ?? 0) == 0)
          ? ViWireRenderStyle.dotted
          : ((sigType?.arrayDims ?? 0) >= 1
                ? ViWireRenderStyle.solid2px
                : ViWireRenderStyle.solid1px);

      final fill = _solidNoAa(color);
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
          // Bend continuity: at a shared vertex the segment also covers the
          // perpendicular partner's ink band, so the two bands fully overlap
          // and the texture masks the whole corner square (measured on crc8's
          // routed 2 px elbows and on Excel's string-family bend corners —
          // e.g. the zigzag corner pixel at (1186,893) and the chainLink
          // corner at (1077,970), both plain texture continuations). The
          // braid is the one exception: its HORIZONTAL run owns the corner —
          // flanks and core texture extend over the vertical's band — while
          // the vertical run starts BELOW the horizontal band (the reference
          // braid verticals begin at band+1 — Excel (1505,808)/(1513,808)).
          if (const {
                ViWireRenderStyle.solid1px,
                ViWireRenderStyle.solid2px,
                ViWireRenderStyle.dotted,
                ViWireRenderStyle.zigzag,
                ViWireRenderStyle.chainLink,
                ViWireRenderStyle.chainLinkWide,
              }.contains(style) ||
              (style == ViWireRenderStyle.braid && horizontal)) {
            for (final neighbour in [
              if (j >= 2) leg[j - 2],
              if (j + 1 < leg.length) leg[j + 1],
            ]) {
              final nCross = (horizontal ? neighbour.dx : neighbour.dy).floor();
              if (nCross + bandLo < lo) lo = nCross + bandLo;
              if (nCross + bandHi > hi) hi = nCross + bandHi;
            }
          }
          if (style == ViWireRenderStyle.braid && !horizontal) {
            for (final neighbour in [
              if (j >= 2) leg[j - 2],
              if (j + 1 < leg.length) leg[j + 1],
            ]) {
              final nCross = (horizontal ? neighbour.dx : neighbour.dy).floor();
              if ((nCross - lo).abs() <= 1) lo = nCross + 2;
              if ((hi - nCross).abs() <= 1) hi = nCross - 2;
            }
          }
          // A braid elbow's OUTER WALL is continuous: the cell where the
          // vertical's far flank column (away from the horizontal run) meets
          // the route row inks even where the core texture holes it — Excel
          // (1512,808) inks (texture idx would hole it) while the mirrored
          // near-side cell (1504,808) at the (1505,808) elbow stays a texture
          // hole. Junction blobs own their measured art instead.
          if (style == ViWireRenderStyle.braid && horizontal) {
            for (final (vertex, other) in [
              if (j >= 2) (a, b),
              if (j + 1 < leg.length) (b, a),
            ]) {
              final bendX = vertex.dx.floor();
              final farX = bendX - (other.dx > vertex.dx ? 1 : -1);
              final isJunction = junctions.any(
                (junction) =>
                    junction.dx.floor() == bendX &&
                    junction.dy.floor() == cross,
              );
              if (!isJunction) {
                canvas.drawRect(
                  Rect.fromLTWH(farX * 1.0, cross * 1.0, 1, 1),
                  fill,
                );
              }
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
          _strokeSegment(
            canvas,
            fill,
            style,
            horizontal,
            lo,
            hi,
            cross,
            gaps,
            errorBraid: errorBraid,
          );
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
        _drawWireJunctionDot(
          canvas,
          junction,
          fill,
          bdWireStrokeBand(style),
          style: style,
          errorBraid: errorBraid,
        );
      }
    }
  }

  /// A flat sequence's film-strip border (measured byte-for-byte on
  /// Excel_Read_XLSX's sequence): 10 px top/bottom bands — 1 px black
  /// outer edge, (221,221,221) grey, a 6-row sprocket strip of 6 px-wide
  /// black-outlined WHITE holes on a 12 px period starting at left+9, grey,
  /// 1 px black inner edge — 6 px side bands whose outer two columns weave
  /// a 2×2 black/grey checker on absolute row pairs, and a 7 px
  /// black/grey/black divider ending at each inter-frame boundary (the
  /// cumulative 0x121 frame widths).
  void _drawFlatSequenceBorder(Canvas canvas, Rect rect, ViHeapObject seq) {
    final black = _dimFor(seq.oid, Colors.black);
    final grey = _dimFor(seq.oid, const Color(0xFFDDDDDD));
    final blackFill = _solidNoAa(black);
    final greyFill = _solidNoAa(grey);
    final whiteFill = _solidNoAa(Colors.white);
    void px(Paint paint, double x, double y, [double w = 1, double h = 1]) {
      canvas.drawRect(Rect.fromLTWH(x, y, w, h), paint);
    }

    final l = rect.left, t = rect.top, r = rect.right, b = rect.bottom;
    final w = rect.width;
    for (final top in [true, false]) {
      final y0 = top ? t : b - 10;
      // Row offsets within the band, outer edge first.
      final rows = top
          ? [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
          : [9, 8, 7, 6, 5, 4, 3, 2, 1, 0];
      px(blackFill, l, y0 + rows[0], w);
      px(greyFill, l, y0 + rows[1], w);
      px(greyFill, l, y0 + rows[8], w);
      px(blackFill, l, y0 + rows[9], w);
      for (final holeRow in [rows[2], rows[7]]) {
        px(greyFill, l, y0 + holeRow, w);
      }
      for (final sideRow in [rows[3], rows[4], rows[5], rows[6]]) {
        px(greyFill, l, y0 + sideRow, w);
      }
      for (var hx = 9.0; hx + 6 <= w; hx += 12) {
        for (final holeRow in [rows[2], rows[7]]) {
          px(blackFill, l + hx, y0 + holeRow, 6);
        }
        for (final sideRow in [rows[3], rows[4], rows[5], rows[6]]) {
          px(blackFill, l + hx, y0 + sideRow);
          px(whiteFill, l + hx + 1, y0 + sideRow, 4);
          px(blackFill, l + hx + 5, y0 + sideRow);
        }
      }
    }
    // Side bands between the horizontal bands. The woven checker columns
    // and the grey mid columns run the FULL height (t+1 .. b-1): through
    // the corner rows and over the bands' inner border rows, so the
    // corners join seamlessly and the border reads interrupted where the
    // side band crosses it (reference-measured at all four corners). Only
    // the 1px black edge columns stay between the inner borders.
    final innerTop = t + 10, innerBottom = b - 10;
    final sideH = innerBottom - innerTop;
    if (sideH > 0) {
      px(greyFill, l + 2, t + 1, 3, b - t - 2);
      px(blackFill, l + 5, innerTop, 1, sideH);
      px(blackFill, r - 6, innerTop, 1, sideH);
      px(greyFill, r - 5, t + 1, 3, b - t - 2);
      for (var y = t + 1; y < b - 1; y++) {
        // Absolute-row pair parity: odd pair index reads grey-first on the
        // outer column (measured phase).
        final greyFirst = (((y + origin.dy).round() + 1) ~/ 2).isOdd;
        px(greyFirst ? greyFill : blackFill, l, y.toDouble());
        px(greyFirst ? blackFill : greyFill, l + 1, y.toDouble());
        px(greyFirst ? blackFill : greyFill, r - 2, y.toDouble());
        px(greyFirst ? greyFill : blackFill, r - 1, y.toDouble());
      }
      // Corner sprocket holes: the bands' hole run continues into every
      // corner, clipped by the woven columns — a white sliver with its
      // black border, stamped over the checker (byte-measured, all four
      // corners of Excel_Read_XLSX's sequence).
      for (final top in [true, false]) {
        final holeTop = top ? t + 3 : b - 7;
        final capTop = top ? t + 2 : b - 8;
        px(whiteFill, l + 1, holeTop, 1, 4);
        px(blackFill, l + 2, capTop, 1, 6);
        px(blackFill, l + 1, capTop, 2);
        px(blackFill, l + 1, capTop + 5, 2);
        px(whiteFill, r - 4, holeTop, 3, 4);
        px(blackFill, r - 5, capTop, 1, 6);
        px(blackFill, r - 5, capTop, 4);
        px(blackFill, r - 5, capTop + 5, 4);
      }
      // Inter-frame dividers at cumulative frame widths. The grey interior
      // pokes 1px through each band's inner border row (the divider's
      // black edges carry the border's line across — the visible seam).
      var cum = 0.0;
      final frames = scene.diagram
          .children(seq.oid)
          .where((c) => c.kind == 0x121 && c.absBounds != null)
          .toList();
      for (var i = 0; i + 1 < frames.length; i++) {
        cum += frames[i].absBounds!.right - frames[i].absBounds!.left;
        px(blackFill, l + cum - 6, innerTop, 1, sideH);
        px(greyFill, l + cum - 5, innerTop - 1, 5, sideH + 2);
        px(blackFill, l + cum, innerTop, 1, sideH);
      }
    }
  }

  /// An array constant's drawn furniture (measured on crc8's Polynomial /
  /// U8-LUT arrays and MD5's Indices / S / T grids). Wrap selection lives in
  /// [bdArrayShellWrapRects], shared with the wire container-face law:
  ///
  ///  * a 1 px border in the ELEMENT type's colour + opaque white fill at
  ///    each OUTERMOST bounded `0x9` wrap part (the index-side and
  ///    element-side frames) — except one demoted to a grid window /
  ///    overlay zone by containing a `0x50` without being its largest
  ///    container. A `0x9` nested inside a sibling `0x9` draws nothing of
  ///    its own — its edges are covered by the cell rings, and LabVIEW
  ///    paints no line at the overlays' interior edges;
  ///  * the index `0x50`'s value window and its two `0xb` spinner boxes;
  ///  * the ELEMENT `0x50` tiled as a CELL GRID: the element's bounds give
  ///    the cell pitch, the smallest `0x9` containing it is the grid
  ///    window, and every cell draws the measured constant-cell chrome
  ///    ([_drawArrayCell]) — adjacent 3 px rings union into the observed
  ///    4 px double walls. Cells beyond the decoded element count (an
  ///    empty array's prototype) draw the dimmed style.
  void _drawArrayConstantShell(Canvas canvas, ViHeapObject shell) {
    final children = scene.diagram.children(shell.oid).toList();
    ViTypeKind elementType = ViTypeKind.unknown;
    ViHeapObject? element;
    for (final c in children) {
      if (c.kind != 0x50) continue;
      if (c.typeKind != ViTypeKind.unknown) elementType = c.typeKind;
      if (c.absBounds != null &&
          (element == null || c.absBounds!.right > element.absBounds!.right)) {
        element = c;
      }
    }
    final tint = _dimFor(shell.oid, labviewTypeColor(elementType));
    final fill = _solidNoAa(tint);
    void border(HeapRect b) {
      final l = (b.left - origin.dx).toDouble();
      final t = (b.top - origin.dy).toDouble();
      final w = (b.right - b.left).toDouble();
      final h = (b.bottom - b.top).toDouble();
      if (w <= 0 || h <= 0) return;
      canvas.drawRect(Rect.fromLTWH(l, t, w, 1), fill);
      canvas.drawRect(Rect.fromLTWH(l, t + h - 1, w, 1), fill);
      canvas.drawRect(Rect.fromLTWH(l, t, 1, h), fill);
      canvas.drawRect(Rect.fromLTWH(l + w - 1, t, 1, h), fill);
    }

    bool contains(HeapRect outer, HeapRect inner) =>
        outer.left <= inner.left &&
        outer.top <= inner.top &&
        outer.right >= inner.right &&
        outer.bottom >= inner.bottom;
    final white = _solidNoAa(Colors.white);
    // Outermost wrap fills+borders first: the index/element furniture
    // paints OVER the opaque wrap, whatever the heap child order. The wrap
    // is opaque: it masks the covered run of a wire that attaches under
    // the array (the visible run starts at the wrap border, byte-verified
    // on the Polynomial feed).
    for (final b in bdArrayShellWrapRects(scene.diagram, shell.oid)) {
      canvas.drawRect(
        Rect.fromLTWH(
          (b.left - origin.dx).toDouble(),
          (b.top - origin.dy).toDouble(),
          (b.right - b.left).toDouble(),
          (b.bottom - b.top).toDouble(),
        ),
        white,
      );
      border(b);
    }
    for (final c in children) {
      final b = c.absBounds;
      if (c.kind == 0x50 && b != null && !identical(c, element)) {
        for (final part in scene.diagram.children(c.oid)) {
          final pb = part.absBounds;
          if (pb == null) continue;
          if (part.kind == 0xb || part.kind == 0x9) border(pb);
          // The index window shows the array's DISPLAYED index
          // ([ViHeapObject.arrayIndex], the tag-`0x15` group value) — the
          // same base the cell grid below enumerates its values from —
          // drawn in the cells' digit style at the window's text inset
          // (MD5's small 1D array: the `0` at window.left+2, the cell
          // digit rows; crc8's LUT arrays read `255` there).
          if (part.kind == 0x9 && pb.width >= 10 && pb.height >= 12) {
            final indexText = '${shell.arrayIndex ?? 0}';
            final run = _layoutText(
              indexText,
              color: _dimFor(shell.oid, Colors.black),
              maxLines: 1,
            );
            _paintText(
              canvas,
              run,
              Offset(
                (pb.left + 2 - origin.dx).toDouble(),
                bdCentredTextTop(_toCanvas(pb), run.height),
              ),
            );
          }
          // The spinner's fat triangle (measured on crc8's Polynomial
          // index): rows t+2..t+5 at widths 1/3/3/5 centred on l+3, the
          // up box's tip on top and the down box's mirrored.
          if (part.kind == 0xb) {
            final up = pb.top == b.top;
            final cx = (pb.left + 3 - origin.dx).toDouble();
            for (var i = 0; i < 4; i++) {
              final half = [0, 1, 1, 2][i];
              final row = up ? pb.top + 2 + i : pb.bottom - 4 - i;
              canvas.drawRect(
                Rect.fromLTWH(
                  cx - half,
                  (row - origin.dy).toDouble(),
                  2.0 * half + 1,
                  1,
                ),
                fill,
              );
            }
          }
        }
      }
    }
    if (element == null) return;
    final cell = element.absBounds!;
    final cellW = cell.width, cellH = cell.height;
    if (cellW <= 0 || cellH <= 0) return;
    // The grid window: the smallest 0x9 containing the element prototype
    // (crc8's 1D arrays store it at exactly the prototype's rect — one
    // cell; MD5's grids tile it 16x4 / 4x4 / 1x5).
    HeapRect grid = cell;
    var gridArea = 1 << 60;
    for (final c in children) {
      final b = c.absBounds;
      if (c.kind != 0x9 || b == null || !contains(b, cell)) continue;
      final area = b.width * b.height;
      if (area < gridArea) {
        grid = b;
        gridArea = area;
      }
    }
    final cols = math.max(1, grid.width ~/ cellW);
    final rows = math.max(1, grid.height ~/ cellH);
    final holder = scene.diagram.byId[shell.parentOid ?? -1];
    final values = holder?.kind == 0x13 ? holder!.constArray : null;
    final dims = holder?.kind == 0x13 ? holder!.constArrayDims : null;
    final format = bdDisplayFormatOf(scene.diagram, element.oid);
    final marker = kBdRadixMarkerGlyphs[bdFormatConversion(format)];
    // The radix part's offset inside its cell, from the prototype's own
    // 0xb child (MD5: +2,+3 in every array).
    var radixDx = 2, radixDy = 3;
    for (final part in scene.diagram.children(element.oid)) {
      if (part.kind == 0xb && part.absBounds != null) {
        radixDx = part.absBounds!.left - cell.left;
        radixDy = part.absBounds!.top - cell.top;
      }
    }
    // The visible window starts at the shell's DISPLAYED index (the
    // tag-`0x15` value; crc8's LUT cells read `array[255]`, MD5's grids
    // sit at 0). Multi-dimension index offsets are not yet decoded, so
    // only a 1D window shifts.
    final windowStart = dims != null && dims.length >= 2
        ? 0
        : (shell.arrayIndex ?? 0);
    for (var j = 0; j < rows; j++) {
      for (var i = 0; i < cols; i++) {
        // Storage order is row-major over the decoded dims; a 1D array is a
        // single visible row or column, so its index is i + j either way.
        final index = dims != null && dims.length >= 2
            ? j * dims.last + i
            : windowStart + i + j;
        final value =
            values != null &&
                index < values.length &&
                (dims == null || dims.length < 2 || i < dims.last)
            ? values[index]
            : null;
        _drawArrayCell(
          canvas,
          shellOid: shell.oid,
          cell: Rect.fromLTWH(
            (grid.left + i * cellW - origin.dx).toDouble(),
            (grid.top + j * cellH - origin.dy).toDouble(),
            cellW.toDouble(),
            cellH.toDouble(),
          ),
          tint: tint,
          value: value,
          empty: values != null && value == null,
          format: format,
          marker: marker,
          radixDx: radixDx,
          radixDy: radixDy,
        );
      }
    }
  }

  /// One array-constant element cell, byte-measured on crc8's arrays and
  /// MD5's grids: a 3 px ring in the element colour whose outer edge sits
  /// 1 px outside the cell rect on the left/top and ON its right/bottom
  /// edges, white field, the value digits in AA black, and the radix-marker
  /// glyph of a non-decimal display format at the cell's radix-part corner.
  /// A cell PAST the decoded element count (an empty array's prototype)
  /// dims the ring's inner 2 px and shows the dimmed default `0`
  /// ([bdDimDisabled]; MD5's two empty arrays read the pure ring edge over
  /// the (153,153,255) inner ring and a (153,153,153) digit).
  void _drawArrayCell(
    Canvas canvas, {
    required int shellOid,
    required Rect cell,
    required Color tint,
    required num? value,
    required bool empty,
    required String? format,
    required (int, int, List<String>)? marker,
    required int radixDx,
    required int radixDy,
  }) {
    final outer = Rect.fromLTRB(
      cell.left - 1,
      cell.top - 1,
      cell.right + 1,
      cell.bottom + 1,
    );
    canvas.drawRect(outer, Paint()..color = Colors.white);
    final ringFill = _solidNoAa(empty ? bdDimDisabled(tint) : tint);
    canvas.drawRect(
      Rect.fromLTWH(outer.left, outer.top, outer.width, 3),
      ringFill,
    );
    canvas.drawRect(
      Rect.fromLTWH(outer.left, outer.bottom - 3, outer.width, 3),
      ringFill,
    );
    canvas.drawRect(
      Rect.fromLTWH(outer.left, outer.top, 3, outer.height),
      ringFill,
    );
    canvas.drawRect(
      Rect.fromLTWH(outer.right - 3, outer.top, 3, outer.height),
      ringFill,
    );
    if (empty) {
      // The outermost 1 px of the ring stays the pure element colour.
      final pure = _solidNoAa(tint);
      canvas.drawRect(
        Rect.fromLTWH(outer.left, outer.top, outer.width, 1),
        pure,
      );
      canvas.drawRect(
        Rect.fromLTWH(outer.left, outer.bottom - 1, outer.width, 1),
        pure,
      );
      canvas.drawRect(
        Rect.fromLTWH(outer.left, outer.top, 1, outer.height),
        pure,
      );
      canvas.drawRect(
        Rect.fromLTWH(outer.right - 1, outer.top, 1, outer.height),
        pure,
      );
    }
    if (marker != null && (value != null || empty)) {
      final (gx, gy, glyphRows) = marker;
      final ink = _solidNoAa(empty ? bdDimDisabled(tint) : tint);
      for (var r = 0; r < glyphRows.length; r++) {
        for (var c = 0; c < glyphRows[r].length; c++) {
          if (glyphRows[r].codeUnitAt(c) != 0x23) continue;
          canvas.drawRect(
            Rect.fromLTWH(
              cell.left + radixDx + gx + c,
              cell.top + radixDy + gy + r,
              1,
              1,
            ),
            ink,
          );
        }
      }
    }
    final text = value != null
        ? bdFormatConstValue(value, format)
        : empty
        ? '0'
        : null;
    if (text == null || cell.width < 10 || cell.height < 12) return;
    final ink = _dimFor(
      shellOid,
      empty ? bdDimDisabled(Colors.black) : Colors.black,
    );
    final run = _layoutText(text, color: ink, maxLines: 1);
    // Digits sit left-aligned after the radix zone on the centred line box
    // (MD5: decimal digits at cell.left+3, hex digits at cell.left+9 past
    // the marker; cell-ink bboxes match the reference at dL/dT = 0 across
    // the Indices/S/T grids — the earlier `-1` row nudge and `+4` decimal
    // inset each sat one px up/right of the reference ink).
    _paintText(
      canvas,
      run,
      Offset(
        cell.left + (marker != null ? 9 : 3),
        bdCentredTextTop(cell, run.height),
      ),
      clip: cell,
    );
  }

  /// The branch-junction dot LabVIEW stamps where a wire forks, in the
  /// wire's colour ([fill]). Two measured shapes by stroke [band]:
  /// the solid 2 px band (−1..0) gets a diamond hugging the 2×2 crossing —
  /// rows band±2 relative to the junction with widths 2/4/6/6/4/2 anchored
  /// on the band columns (measured on crc8's thick LUT junction; the 6-wide
  /// middle rows lie under the wire's own runs) — and every other band gets
  /// the 5x5 disc with the corner pixels clipped (row widths 3/5/5/5/3,
  /// centred on the junction pixel; measured on Excel_Read_XLSX, Read VI
  /// Blocks, large, ProjectItems 1 px junctions, and unmeasured on the
  /// patterned multi-row bands, which keep the disc until a reference pins
  /// their shape).
  void _drawWireJunctionDot(
    Canvas canvas,
    Offset center,
    Paint fill,
    (int, int) band, {
    ViWireRenderStyle? style,
    bool errorBraid = false,
  }) {
    final cx = center.dx.floorToDouble();
    final cy = center.dy.floorToDouble();
    // All pattern lattices anchor to ABSOLUTE diagram coordinates (the
    // canvas origin is the interactive view's pan and must not slide them).
    final ox = origin.dx.round(), oy = origin.dy.round();
    final (bandLo, bandHi) = band;
    if (style == ViWireRenderStyle.braid) {
      // Braid junctions, byte-measured on Excel_Read_XLSX (each from its
      // one corpus junction — the vertical run joins from ABOVE for the
      // error braid at (1768,1071) and leaves BELOW for the pink braid at
      // (407,808); the mirrored topologies reuse the stamp flipped).
      if (errorBraid) {
        // The error wedge: weave-law colours through the 5-wide core
        // (yellow where (x+y+1) mod 4 < 2), black transition rows toward
        // the vertical, olive rim and taper away from it.
        final olive = _solidNoAa(const Color(0xFF666600));
        final yellow = _solidNoAa(const Color(0xFFFFFF00));
        final black = _solidNoAa(Colors.black);
        const rows = ['o###o', '###W#', 'WWWWW', 'WWWWW', 'o###o', '.ooo.'];
        for (var r = 0; r < rows.length; r++) {
          for (var c = 0; c < 5; c++) {
            final ch = rows[r][c];
            if (ch == '.') continue;
            final x = (cx + ox - 2 + c).toInt(), y = (cy + oy - 2 + r).toInt();
            final paint = ch == 'o'
                ? olive
                : ch == '#'
                ? black
                : ((x + y + 1) % 4 < 2 ? yellow : black);
            canvas.drawRect(Rect.fromLTWH(cx - 2 + c, cy - 2 + r, 1, 1), paint);
          }
        }
      } else {
        // The pink-braid blob (measured at Excel's (407,808)): solid taper
        // rows above and below; the weave row stays the wire's own
        // lattice; the FLANK rows show the weave's hole classes
        // ((x+y) mod 4 in {0,3}) within one column of the junction and
        // fill solid outside it — every cell of the measured junction
        // agrees with this lattice form.
        final white = _solidNoAa(Colors.white);
        const taper = [
          '...###...',
          '..#####..',
          '#########',
          '.........',
          '#########',
          '..#####..',
          '...###...',
        ];
        for (var r = 0; r < taper.length; r++) {
          final dy = r - 3;
          for (var c = 0; c < 9; c++) {
            if (taper[r][c] == '.') continue;
            final dx = c - 4;
            final x = (cx + ox + dx).toInt(), y = (cy + oy + dy).toInt();
            final flank = dy == -1 || dy == 1;
            final hole = flank && dx.abs() <= 1 && (x + y) % 4 % 3 == 0;
            canvas.drawRect(
              Rect.fromLTWH(cx + dx, cy + dy, 1, 1),
              hole ? white : fill,
            );
          }
        }
      }
      return;
    }
    // Whether a blob pixel is PUNCHED white by the wire's own global
    // pattern lattice: the reference keeps the stroke lattice through the
    // junction (measured on Excel's zigzag junctions — holes exactly at the
    // cycle's no-ink column — and dotted junction dots).
    final cycle = style == null ? null : kBdWireStrokeCycles[style];
    final phaseBase = style == null ? null : kBdWireCyclePhase[style];
    final capture = this.style.wireCycleOffset;
    bool punched(int cxp, int cyp) {
      final x = cxp + ox, y = cyp + oy;
      if (style == ViWireRenderStyle.dotted ||
          style == ViWireRenderStyle.dottedAlternating) {
        return (x + y).isOdd;
      }
      if (cycle == null || phaseBase == null || cycle.length != 4) {
        return false;
      }
      return (x + (((y + capture.y) & 1) << 1) + phaseBase + capture.x) % 4 ==
          0;
    }

    // Blob geometry: the diamond hugging the stroke band (rows band±2,
    // reach shrinking with distance) serves the solid 2 px thick wire
    // (measured on crc8) AND the patterned (-1,0)-band styles, whose
    // reference blobs read as the same diamond under their punch lattice
    // (Excel's zigzag junctions). The 1 px styles keep the corner-clipped
    // 5x5 disc (measured on Excel_Read_XLSX, Read VI Blocks, large,
    // ProjectItems).
    final diamond =
        style == ViWireRenderStyle.solid2px ||
        (bandLo == -1 && bandHi == 0 && cycle != null && cycle.length == 4);
    if (!diamond) {
      for (var dy = -2; dy <= 2; dy++) {
        for (var dx = -2; dx <= 2; dx++) {
          if (dx.abs() == 2 && dy.abs() == 2) continue;
          final x = (cx + dx).toInt(), y = (cy + dy).toInt();
          if (style != ViWireRenderStyle.solid1px && punched(x, y)) continue;
          canvas.drawRect(Rect.fromLTWH(cx + dx, cy + dy, 1, 1), fill);
        }
      }
      return;
    }
    for (var dy = bandLo - 2; dy <= bandHi + 2; dy++) {
      final outside = dy < bandLo
          ? bandLo - dy
          : dy > bandHi
          ? dy - bandHi
          : 0;
      final reach = 2 - outside;
      final left = cx + bandLo - reach;
      final width = bandHi - bandLo + 1 + 2 * reach;
      if (style == ViWireRenderStyle.solid2px) {
        canvas.drawRect(
          Rect.fromLTWH(left, cy + dy, width.toDouble(), 1),
          fill,
        );
        continue;
      }
      for (var i = 0; i < width; i++) {
        final x = (left + i).toInt(), y = (cy + dy).toInt();
        // Measured on all six Excel zigzag junctions and MD5's three
        // (annotated diff-cell census, zero counterexamples):
        //  * BAND rows hole the stroke lattice's no-ink column within the
        //    4-wide window dx in [-2, +1] of the junction — exactly one
        //    such column lands per row;
        //  * the FIRST row beyond the band, on BOTH sides, keeps the
        //    stroke lattice through the band columns — the vertical run's
        //    texture where a run continues, the same lattice where none
        //    does (MD5's junctions pin the no-run side);
        //  * everything else (the outermost taper rows and the reach
        //    columns) fills solid.
        final dx = x - cx.toInt();
        bool hole;
        if (dy >= bandLo && dy <= bandHi) {
          hole = dx >= -2 && dx <= 1 && punched(x, y);
        } else if (dy == bandLo - 1 || dy == bandHi + 1) {
          hole = dx >= bandLo && dx <= bandHi && punched(x, y);
        } else {
          hole = false;
        }
        if (hole) continue;
        canvas.drawRect(Rect.fromLTWH(left + i, cy + dy, 1, 1), fill);
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
    List<(int, int)> gaps, {
    bool errorBraid = false,
  }) {
    gaps.sort((x, y) => x.$1.compareTo(y.$1));
    var v = lo;
    for (final (gLo, gHi) in [...gaps, (hi + 1, hi + 1)]) {
      final end = math.min(hi, gLo - 1);
      if (v <= end) {
        _strokeRun(
          canvas,
          fill,
          style,
          horizontal,
          v,
          end,
          cross,
          errorBraid: errorBraid,
        );
      }
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
    int cross, {
    bool errorBraid = false,
  }) {
    // ONE MODEL FOR EVERY PATTERNED STROKE: a wire is a colour + a band
    // width + a GLOBAL TEXTURE that the band masks in. The texture anchors
    // to ABSOLUTE diagram coordinates (plus the capture's screen shift for
    // the string family), so runs, corners, and both orientations are the
    // same texture under different masks — the measured per-orientation
    // cycles, the vertical "compressed" forms and the bend behaviour all
    // fall out of the masking with no per-style phase constants.
    //
    // Textures (both reference-measured; see kBdWireStrokeCycles' history):
    //  * STRING family (zigzag / chainLink / chainLinkWide): hole where
    //    `x` is odd and `(x ~/ 2) + y` is odd — a 4-period weave whose
    //    2/3/4-row masks are exactly the measured cycles and whose 2/3-col
    //    masks are the measured vertical forms.
    //  * BRAID family (cluster braids): the diagonal 50% texture, ink
    //    where `(x + y) mod 4` is 1 or 2, between solid band-edge rows;
    //    the ERROR braid paints the texture's holes black and its ink
    //    yellow between olive edges (same lattice, its own palette).
    //  * DOTTED family: the `(x + y)`-even checkerboard (1-row mask; the
    //    2-row mask is the measured alternating-dot form).
    final ox = origin.dx.round(), oy = origin.dy.round();
    final captureX = this.style.wireCycleOffset.x;
    Rect px(int along, int band) => horizontal
        ? Rect.fromLTWH(along.toDouble(), (cross + band).toDouble(), 1, 1)
        : Rect.fromLTWH((cross + band).toDouble(), along.toDouble(), 1, 1);
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
    // Absolute diagram coords of a band cell: `along` runs along the wire,
    // `band` is the cross-axis offset from the route row/column.
    (int, int) abs(int along, int band) {
      final canvasX = horizontal ? along : cross + band;
      final canvasY = horizontal ? cross + band : along;
      return (canvasX + ox, canvasY + oy);
    }

    bool stringTextureInk(int x, int y) =>
        (x + ((y & 1) << 1) + captureX) % 4 != 0;

    bool braidTextureInk(int x, int y) {
      final m = (x + y) % 4;
      return m == 1 || m == 2;
    }

    switch (style) {
      case ViWireRenderStyle.solid1px:
        canvas.drawRect(span(0, 0), fill);
      case ViWireRenderStyle.solid2px:
        canvas.drawRect(span(-1, 0), fill);
      case ViWireRenderStyle.hollowDouble:
        canvas.drawRect(span(-1, -1), fill);
        canvas.drawRect(span(1, 1), fill);
      case ViWireRenderStyle.dotted:
        for (var v = lo; v <= hi; v++) {
          final (x, y) = abs(v, 0);
          if ((x + y).isEven) canvas.drawRect(px(v, 0), fill);
        }
      case ViWireRenderStyle.dottedAlternating:
        for (var v = lo; v <= hi; v++) {
          for (final band in const [-1, 0]) {
            final (x, y) = abs(v, band);
            if ((x + y).isEven) canvas.drawRect(px(v, band), fill);
          }
        }
      case ViWireRenderStyle.zigzag ||
          ViWireRenderStyle.chainLink ||
          ViWireRenderStyle.chainLinkWide:
        final (bandLo, bandHi) = switch (style) {
          ViWireRenderStyle.zigzag => (-1, 0),
          ViWireRenderStyle.chainLink => (-1, 1),
          _ => (-2, 1),
        };
        for (var v = lo; v <= hi; v++) {
          for (var band = bandLo; band <= bandHi; band++) {
            final (x, y) = abs(v, band);
            if (stringTextureInk(x, y)) canvas.drawRect(px(v, band), fill);
          }
        }
      case ViWireRenderStyle.braid when errorBraid:
        final olive = _solidNoAa(const Color(0xFF666600));
        final yellow = _solidNoAa(const Color(0xFFFFFF00));
        final black = _solidNoAa(Colors.black);
        canvas.drawRect(span(-1, -1), olive);
        canvas.drawRect(span(1, 1), olive);
        for (var v = lo; v <= hi; v++) {
          final (x, y) = abs(v, 0);
          canvas.drawRect(px(v, 0), braidTextureInk(x, y) ? black : yellow);
        }
      case ViWireRenderStyle.braid:
        canvas.drawRect(span(-1, -1), fill);
        canvas.drawRect(span(1, 1), fill);
        for (var v = lo; v <= hi; v++) {
          final (x, y) = abs(v, 0);
          final ink = horizontal
              ? (x + ((y & 1) << 1) + captureX) % 4 >= 2
              : braidTextureInk(x, y);
          if (ink) canvas.drawRect(px(v, 0), fill);
        }
      case ViWireRenderStyle.braidWide:
        canvas.drawRect(span(-2, -2), fill);
        canvas.drawRect(span(1, 1), fill);
        for (var v = lo; v <= hi; v++) {
          for (final band in const [-1, 0]) {
            final (x, y) = abs(v, band);
            if (braidTextureInk(x, y)) canvas.drawRect(px(v, band), fill);
          }
        }
      default:
        // The dense/weave cycles have no texture derivation yet — the
        // catalogued horizontal cycles stand in, and vertical runs draw the
        // honest 1 px line (TODO: measure and fold into the model).
        final cycle = horizontal ? kBdWireStrokeCycles[style] : null;
        if (cycle == null) {
          canvas.drawRect(span(0, 0), fill);
          return;
        }
        for (var v = lo; v <= hi; v++) {
          final (x, y) = abs(v, 0);
          final mask = cycle[(x + ((y & 1) << 1) + 1) % cycle.length];
          for (var bit = 0; bit < 5; bit++) {
            if ((mask >> bit) & 1 != 0) {
              canvas.drawRect(px(v, bit - 2), fill);
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
  /// A solid fill of [color] with anti-aliasing off — the pixel-exact chrome
  /// paint (hard edges the oracle byte-compares).
  static Paint _solidNoAa(Color color) => Paint()
    ..color = color
    ..isAntiAlias = false;

  /// Paints a batch of 1x1 cells (given as pixel-CENTRE coordinates,
  /// `x + 0.5, y + 0.5, …`) in ONE canvas call: width-1 square-cap points
  /// rasterise to exactly the pixels a per-cell 1x1 drawRect fill covers,
  /// without the per-cell engine call that made large structure bands the
  /// most expensive draw of a frame.
  static void _drawCellPoints(
    Canvas canvas,
    List<double> centres,
    Color color,
  ) {
    if (centres.isEmpty) return;
    canvas.drawRawPoints(
      ui.PointMode.points,
      Float32List.fromList(centres),
      Paint()
        ..color = color
        ..isAntiAlias = false
        ..strokeWidth = 1
        ..strokeCap = StrokeCap.square,
    );
  }

  /// Stamps a `List<String>` bitmap at 1px per cell marked [on], with the
  /// bitmap's (0,0) cell at ([left], [top]) — the shared form of every
  /// reference-measured chrome glyph.
  static void _stampBitmap(
    Canvas canvas,
    Paint paint,
    List<String> rows,
    double left,
    double top, {
    String on = '#',
  }) {
    for (var y = 0; y < rows.length; y++) {
      for (var x = 0; x < rows[y].length; x++) {
        if (rows[y][x] != on) continue;
        canvas.drawRect(Rect.fromLTWH(left + x, top + y, 1, 1), paint);
      }
    }
  }

  void _drawBorderTerminalChrome(
    Canvas canvas,
    Rect t,
    ({int kind, bool hollow, bool centreDot, bool disabled}) info,
    Color wireColor,
  ) {
    final kind = info.kind;
    final ringColor = info.disabled ? kBdDisabledChromeGrey : kBdTunnelBorder;
    final creamColor = info.disabled
        ? bdDimDisabled(kBdTerminalFill)
        : kBdTerminalFill;
    final noAa = _solidNoAa(wireColor);
    switch (kind) {
      case 0x22 || 0x2d || 0x2a || 0xcb || 0xce:
        // Hollow ([kTunnelHollowFlag]): cream interior with a 5x5
        // wire-colour ring (open at the middle of its top/bottom edges),
        // read from crc8's reference at (520,276). Solid: wire-colour fill.
        if (info.hollow) {
          canvas.drawRect(t, _solidNoAa(creamColor));
          if (t.width == 9 && t.height == 9) {
            const ring = ['xx.xx', 'x...x', 'x...x', 'x...x', 'xx.xx'];
            _stampBitmap(canvas, noAa, ring, t.left + 2, t.top + 2, on: 'x');
          }
        } else {
          canvas.drawRect(t, noAa);
          // The centre-dot variant ([kTunnelCentreDotFlags]): a 3×3 white
          // centre with a wire-colour dot, byte-measured on Excel's
          // `Worksheets` case output tunnels.
          if (info.centreDot && t.width >= 7 && t.height >= 7) {
            final cx = t.left + (t.width - 3) / 2;
            final cy = t.top + (t.height - 3) / 2;
            canvas.drawRect(
              Rect.fromLTWH(cx, cy, 3, 3),
              _solidNoAa(Colors.white),
            );
            canvas.drawRect(Rect.fromLTWH(cx + 1, cy + 1, 1, 1), noAa);
          }
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
        canvas.drawRect(t.deflate(2), _solidNoAa(creamColor));
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
        canvas.drawRect(t.deflate(1), _solidNoAa(creamColor));
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
          _stampBitmap(canvas, noAa, glyph, t.left + 1, t.top + 1, on: 'x');
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
    final grey = tint ?? dim(style.whileBandGrey);
    // The band fills the frame's stored bounds; [l,r) × [t,b).
    final l = rect.left.round(), t = rect.top.round();
    final r = rect.right.round(), b = rect.bottom.round();
    const band = _kWhileBand;
    // Bottom-right arrow footprint (columns then rows), anchored to the frame's
    // right/bottom edge; excluded from the ring loop so the arrow alone fills
    // it. Its last row is the band's bottom row.
    final aw = _kWhileArrow.first.length, ah = _kWhileArrow.length;
    final ax0 = r - aw, ay0 = b - ah;

    final pts = <double>[];
    void add(int x, int y) => pts
      ..add(x + 0.5)
      ..add(y + 0.5);

    // Only band cells are visited — full rows inside the top/bottom bands,
    // and just the left/right band columns of the middle rows — so the cost
    // is O(perimeter x band), never O(area) (a diagram-sized loop made this
    // the most expensive draw of the whole frame).
    void cell(int x, int y) {
      final dt = y - t, db = b - 1 - y;
      final dl = x - l, dr = r - 1 - x;
      if (x >= ax0 && y >= ay0) return; // arrow owns this cell
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

    final bandBottom = math.max(b - band, t + band);
    for (var y = t; y < math.min(t + band, b); y++) {
      for (var x = l; x < r; x++) {
        cell(x, y);
      }
    }
    for (var y = bandBottom; y < b; y++) {
      for (var x = l; x < r; x++) {
        cell(x, y);
      }
    }
    for (var y = t + band; y < bandBottom; y++) {
      for (var x = l; x < math.min(l + band, r); x++) {
        cell(x, y);
      }
      for (var x = math.max(r - band, l + band); x < r; x++) {
        cell(x, y);
      }
    }
    // Stamp the arrow (its last row sits one pixel below the band bottom).
    for (var ry = 0; ry < ah; ry++) {
      for (var rx = 0; rx < aw; rx++) {
        if (_kWhileArrow[ry][rx] == '#') add(ax0 + rx, ay0 + ry);
      }
    }
    _drawCellPoints(canvas, pts, grey);
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
    final paint = _solidNoAa(ink);
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
  /// black outer rectangle wrapping a [kBdHatchBand]-px band of the global
  /// [kBdStructureHatch] lattice — or, for an [error] case displaying its
  /// "No Error" frame, a green field striped with the [kBdErrorHatch]
  /// lattice. Each lattice is keyed on ABSOLUTE diagram coordinates
  /// ([absLeft]/[absTop] give the frame's top-left in that space) plus its own
  /// per-capture offset, so the pattern is continuous across the diagram — the
  /// frame is a window onto it, not a source of it. Drawn before the tunnel
  /// chrome pass, which paints over it where border terminals land.
  void _drawStructureHatchBorder(
    Canvas canvas,
    Rect rect,
    int absLeft,
    int absTop, {
    bool disabled = false,
    bool error = false,
  }) {
    Color dim(Color c) => disabled ? bdDimDisabled(c) : c;
    final paint = _solidNoAa(dim(const Color(0xFF000000)));
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
    // Hatch band, batched into ink/field paths. Only the perimeter ring's
    // cells are visited — full rows inside the top/bottom bands, just the
    // side-band columns of the middle rows — so the cost is
    // O(perimeter x band), never O(area).
    final tile = error ? kBdErrorHatch : kBdStructureHatch;
    final offset = error ? style.errorHatchOffset : style.hatchOffset;
    final band = <double>[];
    final field = error ? <double>[] : null;
    void cell(int i, int j) {
      final d = math.min(math.min(i, j), math.min(w - 1 - i, h - 1 - j));
      if (d < 1 || d > kBdHatchBand) return; // 0 = solid, >5 = interior
      if (tile[(absTop + j + offset.y) & 3][(absLeft + i + offset.x) & 3] ==
          '#') {
        band
          ..add(l + i + 0.5)
          ..add(t + j + 0.5);
      } else {
        field
          ?..add(l + i + 0.5)
          ..add(t + j + 0.5);
      }
    }

    final sideTop = math.min(kBdHatchBand + 1, h);
    final sideBottom = math.max(h - 1 - kBdHatchBand, sideTop);
    for (var j = 0; j < sideTop; j++) {
      for (var i = 0; i < w; i++) {
        cell(i, j);
      }
    }
    for (var j = sideBottom; j < h; j++) {
      for (var i = 0; i < w; i++) {
        cell(i, j);
      }
    }
    for (var j = sideTop; j < sideBottom; j++) {
      for (var i = 0; i < math.min(kBdHatchBand + 1, w); i++) {
        cell(i, j);
      }
      for (
        var i = math.max(w - 1 - kBdHatchBand, kBdHatchBand + 1);
        i < w;
        i++
      ) {
        cell(i, j);
      }
    }
    if (field != null) {
      _drawCellPoints(canvas, field, dim(style.errorCaseGreen));
    }
    _drawCellPoints(
      canvas,
      band,
      error ? dim(style.whileBandGrey) : dim(const Color(0xFF000000)),
    );
  }

  /// The magenta `A=a` glyph rows of the case-insensitive badge, 1px cells at
  /// (rect.left + 2 + col, rect.bottom - 9 + row). Measured pixel-for-pixel
  /// on Excel_Read_XLSX's oid2480.
  static const _kCaseInsensitiveGlyph = [
    '.####.............',
    '##..##............',
    '##..##.......###..',
    '######.####....##.',
    '##..##.......####.',
    '##..##.####.##.##.',
    '##..##.......#####',
  ];

  /// The `A=a` case-insensitive-match badge at a case frame's bottom-left
  /// corner: a white plate over the hatch band (21×9 px resting on the 1px
  /// bottom border) carrying the magenta glyph.
  void _drawCaseInsensitiveBadge(
    Canvas canvas,
    Rect rect, {
    required bool disabled,
    required int oid,
  }) {
    Color dim(Color c) => disabled ? bdDimDisabled(c) : _dimFor(oid, c);
    canvas.drawRect(
      Rect.fromLTWH(rect.left + 1, rect.bottom - 10, 21, 9),
      _solidNoAa(dim(Colors.white)),
    );
    final ink = _solidNoAa(dim(const Color(0xFFFF00FF)));
    for (var r = 0; r < _kCaseInsensitiveGlyph.length; r++) {
      final mask = _kCaseInsensitiveGlyph[r];
      for (var c = 0; c < mask.length; c++) {
        if (mask.codeUnitAt(c) != 0x23) continue;
        canvas.drawRect(
          Rect.fromLTWH(rect.left + 2 + c, rect.bottom - 9 + r, 1, 1),
          ink,
        );
      }
    }
  }

  /// Side length (px) of the for-loop's dog-ear corner fold — fixed chrome,
  /// measured from LabVIEW's raster.
  static const _kForLoopFold = 8.0;

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

  /// The while-loop conditional (stop) terminal exactly as LabVIEW rasters it
  /// in a 16×16 border box: a 1px [BdRenderStyle.booleanGreen] ring, cream
  /// field, black octagon outline, red fill. Measured identical on both
  /// capture palettes (fg.png and Tokenize URL.png) modulo the ring green.
  static const _stopTerminal = [
    'GGGGGGGGGGGGGGGG',
    'GccccccccccccccG',
    'GccccXXXXXXccccG',
    'GcccXccccccXcccG',
    'GccXccRRRRccXccG',
    'GcXccRRRRRRccXcG',
    'GcXcRRRRRRRRcXcG',
    'GcXcRRRRRRRRcXcG',
    'GcXcRRRRRRRRcXcG',
    'GcXcRRRRRRRRcXcG',
    'GcXccRRRRRRccXcG',
    'GccXccRRRRccXccG',
    'GcccXccccccXcccG',
    'GccccXXXXXXccccG',
    'GccccccccccccccG',
    'GGGGGGGGGGGGGGGG',
  ];

  /// Draws the 16×16 conditional stop terminal pixel-exact from
  /// [_stopTerminal], colours dimmed through the disabled transform.
  void _drawConditionalTerminal(
    Canvas canvas,
    Rect box, {
    bool disabled = false,
  }) {
    Color dim(Color c) => disabled ? bdDimDisabled(c) : c;
    final inks = {
      'G': _solidNoAa(dim(style.booleanGreen)),
      'c': _solidNoAa(dim(kBdTerminalFill)),
      'X': _solidNoAa(dim(const Color(0xFF000000))),
      'R': _solidNoAa(dim(const Color(0xFFFF0000))),
    };
    for (final e in inks.entries) {
      _stampBitmap(
        canvas,
        e.value,
        _stopTerminal,
        box.left,
        box.top,
        on: e.key,
      );
    }
  }

  /// Draws a terminal's measured 32×16 art ([BdTerminalArt]) pixel-exact,
  /// colours dimmed through the disabled transform.
  void _drawTerminalArt(
    Canvas canvas,
    Rect box,
    BdTerminalArt art, {
    bool disabled = false,
  }) {
    Color dim(Color c) => disabled ? bdDimDisabled(c) : c;
    canvas.drawRect(box, _solidNoAa(dim(Colors.white)));
    final inks = {
      'B': _solidNoAa(dim(art.base)),
      'M': _solidNoAa(dim(art.mid)),
      'L': _solidNoAa(dim(art.light)),
      'X': _solidNoAa(dim(const Color(0xFF000000))),
    };
    for (final e in inks.entries) {
      _stampBitmap(canvas, e.value, art.rows, box.left, box.top, on: e.key);
    }
  }

  /// LabVIEW's boolean-constant block (a 16×14 shell): 2px green border on
  /// white; False shows a green F glyph, True a green-filled inner block with
  /// the T carved in white. Measured from crc8/fg (F) and WriteConsole (T);
  /// the value is the decoded [ViHeapObject.constBool]. `#` = green.
  static const _boolFalseBlock = [
    '################',
    '################',
    '##............##',
    '##............##',
    '##....#####...##',
    '##....##......##',
    '##....####....##',
    '##....##......##',
    '##....##......##',
    '##....##......##',
    '##............##',
    '##............##',
    '################',
    '################',
  ];
  static const _boolTrueBlock = [
    '################',
    '################',
    '##............##',
    '##.##########.##',
    '##.##......##.##',
    '##.####..####.##',
    '##.####..####.##',
    '##.####..####.##',
    '##.####..####.##',
    '##.####..####.##',
    '##.##########.##',
    '##............##',
    '################',
    '################',
  ];

  /// Draws a boolean constant's 16×14 block pixel-exact from
  /// [_boolFalseBlock] / [_boolTrueBlock].
  void _drawBoolConstant(
    Canvas canvas,
    Rect box,
    bool value, {
    bool disabled = false,
  }) {
    Color dim(Color c) => disabled ? bdDimDisabled(c) : c;
    canvas.drawRect(box, _solidNoAa(dim(Colors.white)));
    _stampBitmap(
      canvas,
      _solidNoAa(dim(style.booleanGreen)),
      value ? _boolTrueBlock : _boolFalseBlock,
      box.left,
      box.top,
    );
  }

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
    final ink = _solidNoAa(dim(const Color(0xFF0000FF)));
    final l = box.left.roundToDouble(), t = box.top.roundToDouble();
    canvas.drawRect(box, _solidNoAa(dim(kBdTerminalFill)));
    // 2px blue border as four bands.
    canvas.drawRect(Rect.fromLTWH(l, t, 16, 2), ink);
    canvas.drawRect(Rect.fromLTWH(l, t + 14, 16, 2), ink);
    canvas.drawRect(Rect.fromLTWH(l, t, 2, 16), ink);
    canvas.drawRect(Rect.fromLTWH(l + 14, t, 2, 16), ink);
    final (ox, oy) = glyph.origin;
    _stampBitmap(canvas, ink, glyph.rows, l + ox, t + oy);
  }

  void _drawGlyphText(Canvas canvas, Rect box, String glyph, Color color) {
    final run = _layoutText(
      glyph,
      color: color,
      fontSize: 11,
      fontWeight: FontWeight.w700,
      fontStyle: FontStyle.italic,
    );
    _paintText(canvas, run, bdCentredTextAnchor(box, run.size));
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
    List<({HeapRect box, int bmp})> terminals, {
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
      // The conditional stop terminal at its standard 16×16 box is likewise
      // pixel-exact chrome ([_stopTerminal]).
      if (box.width == 16 && box.height == 16 && t.bmp == _bmpConditional) {
        _drawConditionalTerminal(canvas, box, disabled: disabled);
        continue;
      }
      final border = switch (t.bmp) {
        _bmpConditional => dim(const Color(0xFF007F00)),
        _ => dim(_loopBlue),
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

  /// The case selector's ◄ pager, ▼ dropdown, and ► pager, measured from
  /// crc8's crisp-black selectors. `#` = black.
  static const _selectorLeftPager = [
    '.....#',
    '...###',
    '.#####',
    '######',
    '.#####',
    '...###',
    '.....#',
  ];
  static const _selectorRightPager = [
    '#.....',
    '###...',
    '#####.',
    '######',
    '#####.',
    '###...',
    '#.....',
  ];
  static const _selectorDropdown = ['#######', '.#####.', '..###..', '...#...'];

  /// Case-selector chrome around the decoded `0x95` label [rect] (the value
  /// TEXT region): the strip extends 8px left and 18px right of it —
  /// `[◄ pager | value … ▼ | ► pager]` — with 1px box borders on the outer edges,
  /// further borders at rect.left / rect.right+10, and the
  /// crisp pager/dropdown bitmaps. Measured on crc8's selectors; the value
  /// STRING itself is drawn by the text pass (it is anti-aliased text in the
  /// reference and outside the pixel-exact goal).
  /// A small `0x53` CLUSTER container draws as ONE box: a double 1px ring in
  /// the cluster's member tint around a white interior, with every nested
  /// part scaffolding-suppressed (measured on Excel_Read_XLSX's StateData
  /// box at (316,826)). A CONSTANT cluster (`0x13` holder parent) adds the
  /// measured 13x5 interior glyph at (+5,+6) in the same tint; other shells'
  /// interior art is not yet decoded (TODO).
  void _drawSmallClusterBox(Canvas canvas, ViHeapObject object, Rect rect) {
    final tint = _dimFor(
      object.oid,
      object.resolvedMembers.isNotEmpty
          ? _clusterTint(object.resolvedMembers)
          : labviewTypeColor(object.typeKind),
    );
    canvas.drawRect(rect, _solidNoAa(tint));
    canvas.drawRect(rect.deflate(1), _solidNoAa(Colors.white));
    canvas.drawRect(rect.deflate(2), _solidNoAa(tint));
    canvas.drawRect(rect.deflate(3), _solidNoAa(Colors.white));
    if (scene.diagram.byId[object.parentOid ?? -1]?.kind != 0x13) return;
    const glyphRows = [
      '#####.###.###',
      '#...#.#.#....',
      '#####.#.#.###',
      '......#.#.#.#',
      '.###..###.###',
    ];
    final ink = _solidNoAa(tint);
    for (var r = 0; r < glyphRows.length; r++) {
      for (var c = 0; c < glyphRows[r].length; c++) {
        if (glyphRows[r].codeUnitAt(c) != 0x23) continue;
        canvas.drawRect(
          Rect.fromLTWH(rect.left + 5 + c, rect.top + 6 + r, 1, 1),
          ink,
        );
      }
    }
  }

  void _drawCaseSelector(Canvas canvas, Rect rect) {
    final ink = _solidNoAa(Colors.black);
    final l = rect.left.roundToDouble(), t = rect.top.roundToDouble();
    final r = rect.right.roundToDouble();
    final bottom = t + 16; // the strip is 17 rows; borders at t and t+16
    final left = l - 8, right = r + 18;
    void hline(double x0, double x1, double y) =>
        canvas.drawRect(Rect.fromLTRB(x0, y, x1 + 1, y + 1), ink);
    void vline(double x, double y0, double y1) =>
        canvas.drawRect(Rect.fromLTRB(x, y0, x + 1, y1 + 1), ink);
    // White strip over the border/hatch behind it, then the chrome.
    canvas.drawRect(
      Rect.fromLTRB(left, t, right + 1, bottom + 1),
      _solidNoAa(Colors.white),
    );
    hline(left, right, t);
    hline(left, right, bottom);
    vline(left, t, bottom); // outer left edge
    vline(l, t, bottom); // value box left border
    vline(r + 10, t, bottom); // value box right border
    vline(right, t, bottom); // right pager's outer edge
    _stampBitmap(canvas, ink, _selectorLeftPager, l - 7, t + 5);
    _stampBitmap(canvas, ink, _selectorDropdown, r + 1, t + 6);
    _stampBitmap(canvas, ink, _selectorRightPager, r + 11, t + 5);
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
      // One scene = one set of derived collections, so scene identity covers
      // every diagram-derived input.
      !identical(old.scene, scene) ||
      !identical(old.subViIcons, subViIcons) ||
      !identical(old.xnodeFacades, xnodeFacades) ||
      !identical(old.primIcons, primIcons) ||
      !identical(old.primIconsGrey, primIconsGrey) ||
      !identical(old.style, style) ||
      old.iconFilterQuality != iconFilterQuality ||
      old.canvasScale != canvasScale ||
      old.drawDotGrid != drawDotGrid ||
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
