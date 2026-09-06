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

/// A read-only layout view of a decoded VI block diagram: every recovered
/// object drawn at its absolute coordinates, with nesting-aware z-order,
/// type-faithful terminal colours, structure frames, labels, click-to-inspect,
/// pan/zoom and auto-fit.
///
/// Backed by the clean-room `labwright_rsrc_parse` decode (`buildViModel` →
/// `blockDiagrams`/`frontPanelDiagrams`); only objects with recovered absolute
/// bounds are drawn. Wires come from the decoded `0x17` signal endpoint
/// binding ([ViDiagram.wires]); the wire datatype is not decoded, so a run is
/// neutral except where an anchor coincides with a typed terminal.
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
  /// (`model.subViNames`), recoverable for ~82% of VIs. A linker dependency
  /// list, not a per-node call mapping. Empty for the front panel.
  final List<String> subViNames;

  /// True when rendering the front panel, where structure containers
  /// (clusters/arrays/panes) show their caption instead of a class-kind badge
  /// so the badge never obscures the control's label.
  final bool isFrontPanel;

  /// The VI's own recovered images — its 32×32 icon (`icl8`/`icl4`/`ICON`) and
  /// any embedded diagram PNGs (`MNGI`/`DSIM`), shown as an identity strip
  /// above the diagram.
  final ViImages viImages;

  /// Resolver stamping each subVI-call node with the icon of the VI it
  /// targets: given the `.vi`/`.vim` filenames this diagram calls
  /// ([subViWantedNames]), returns a `filename → icon` map (see
  /// `resolveSubViIconsFor`). Block diagram only; a node whose target is not
  /// found keeps the neutral connector-pane plate, and null draws no icons.
  final Future<Map<String, ViLegacyIcon>> Function(Set<String> wantedNames)?
  subViIconResolver;

  /// The VI's decoded sections, used to recover XNode facade images (`DSIM`
  /// PNGs stamped over `0x105` nodes — see [xnodeFacadesFromSections]). Empty
  /// draws XNodes as plain boxes.
  final List<DecodedSection> sections;

  @override
  State<ViDiagramView> createState() => _ViDiagramViewState();
}

class _ViDiagramViewState extends State<ViDiagramView> {
  final _transform = TransformationController();

  /// The zoom the diagram layer is rasterised at. Pan/zoom scales the cached
  /// layer; the layer re-rasterises once a gesture settles at a meaningfully
  /// different zoom.
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

  /// SubVI-call node icons resolved from the called VIs' own files, populated
  /// asynchronously by [_resolveIcons]; empty until then.
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

  /// The control-flow outline, derived once (a rebuild re-walks every object).
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

  /// Resolves the subVI-call node icons and repaints once. A no-op on the
  /// front panel, without a resolver, or when the diagram calls no subVIs.
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
  /// features / class confidence / linked subVIs).
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
                    // The boundary isolates the diagram into its own layer,
                    // rasterised at the settled zoom (_anchorScale) with
                    // Transform.scale cancelling that factor: at rest the
                    // compositor shows the layer 1:1, and only a mid-gesture
                    // scale stretches a stale raster.
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
      // Icon art can overhang its model box (measured placements go as far as
      // dy -5), so the coarse test is the box union the stamp; the alpha mask
      // then decides precisely.
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
    // Array grid cells are painted furniture, not heap objects: the constant
    // stores one element prototype (`0x50`) plus index spinners, and the
    // painter tiles the rest from [ViHeapObject.constArray]. A click on a
    // painted cell therefore falls to the smallest containing real object, the
    // `0x52` shell, while the prototype and spinners select themselves.
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

/// Terminals coloured by data type, everything else by class.
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

/// LabVIEW's datatype colours, sampled from reference renders: orange = float,
/// blue = int/enum, teal = path, yellow = call-library node. Unknown stays
/// neutral.
Color labviewTypeColor(ViTypeKind kind) => switch (kind) {
  // Float is (255,102,0): the reference PNGs carry 1,000 px of 0xFF6600 and
  // none of 0xFF8000.
  ViTypeKind.numericFloat => const Color(0xFFFF6600),
  // Boolean green (0,102,0) is the wire/selector-border green; a decoded
  // constant foreground is a different green, 0x007F00.
  ViTypeKind.numericInt => const Color(0xFF0000FF),
  ViTypeKind.enumRing => const Color(0xFF0000FF),
  ViTypeKind.string => const Color(0xFFFF00FF),
  ViTypeKind.boolean => const Color(0xFF006600),
  ViTypeKind.path => const Color(0xFF006666),
  ViTypeKind.clnNode => const Color(0xFFE8C547),
  // Cluster/array/refnum borders are not yet colour-sampled from a reference;
  // they keep the neutral grey.
  ViTypeKind.cluster ||
  ViTypeKind.array ||
  ViTypeKind.refnum => const Color(0xFF8A8A8A),
  ViTypeKind.unknown => const Color(0xFF8A8A8A),
};

/// The block-diagram canvas fill — pure white, shared by the render and the
/// oracle's letterbox so an empty margin matches a white reference screenshot.
const Color kBdCanvas = Color(0xFFFFFFFF);

/// The alignment-grid dot colour on [kBdCanvas] — low enough contrast that a
/// dot pixel stays within the oracle's per-channel match threshold.
const Color kBdGridDot = Color(0x0C000000);

/// Fill for a subVI-call node icon plate (LabVIEW's default connector-pane
/// icon background).
const Color kBdSubViNodeFill = Color(0xFFECECEC);

/// Fill for a non-subVI node plate: one neutral pale gold for every node that
/// is not a recognised subVI call, rather than a per-function colour.
const Color kBdPrimitiveNodeFill = Color(0xFFFBEEC2);

/// Fill for a terminal whose datatype is not recovered. Datatype-known
/// terminals use [labviewTypeColor] instead.
const Color kBdUnknownTerminalFill = Color(0xFFD8D8D8);

/// Neutral dataflow-wire colour. A [ViWire] (signal `0x17`) carries endpoint
/// binding but no decoded datatype, so a run stays neutral unless an endpoint
/// anchor coincides with a terminal whose datatype was recovered (see
/// [bdWireColor]).
const Color kBdWireColor = Color(0xFF2B2B2B);

/// The 1 px border around a structure tunnel square; the fill is the wire's
/// own colour.
const Color kBdTunnelBorder = Color(0xFF444444);

/// The cream fill inside shift-register and selector border terminals,
/// (255,255,204) — the same cream as primitive icon bodies.
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

/// The error cluster's member fingerprint — `[boolean, i32, string]`
/// (status/code/source), the resolved members of every corpus `error in/out`
/// terminal. Error wires draw the dark-yellow braid palette, not the member
/// tint.
bool _isErrorClusterMembers(List<ViType> members) =>
    members.length == 3 &&
    members[0].kind == ViDataType.boolean &&
    members[1].kind == ViDataType.i32 &&
    members[2].kind == ViDataType.string;

/// A cluster's ink follows its member make-up: any non-numeric member draws
/// the magenta family, the error cluster the braid's dark yellow. LabVIEW's
/// all-numeric cluster brown is not yet reference-measured, so that case keeps
/// the neutral grey.
Color _clusterTint(List<ViType> members) => _isErrorClusterMembers(members)
    ? const Color(0xFF666600)
    : members.any((m) => !_isNumericDataType(m.kind))
    ? const Color(0xFFFF00FF)
    : labviewTypeColor(ViTypeKind.cluster);

/// The type colour of a terminal, resolving arrays to their element ink and
/// clusters to their member-make-up tint ([_clusterTint]); scalars fall
/// through to [labviewTypeColor].
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
/// show different phases. `#` = black.
const kBdStructureHatch = ['.#.#', '#.#.', '##..', '..##'];

/// Width (px) of the hatch band inside a case/sequence frame's solid 1px
/// outer border.
const kBdHatchBand = 5;

/// The single-diagonal stripe lattice of an error case's border band
/// ([bdErrorCaseOids]), indexed like [kBdStructureHatch] — grey ink on the
/// green band where `(absX + absY) % 4 == 0`. Its per-capture phase is
/// independent of the black hatch's (one capture carries different phases for
/// the two lattices), so it takes its own derived offset.
const kBdErrorHatch = ['#...', '...#', '..#.', '.#..'];

/// The block-diagram render style: every capture-varying piece of the
/// structure chrome in one object.
///
/// The colours come from the capture environment's system palette, not the
/// .vi: same-version captures measure greys 119/127/119 and greens
/// 153/178/153, and the defaults here are the corpus-dominant readings. Hatch
/// offsets are likewise per-capture brush phases ([GlobalHatchOffset]), which
/// the oracle derives, since a mis-phased lattice reads as structural noise
/// where an 8-shade band delta does not.
class BdRenderStyle {
  const BdRenderStyle({
    this.whileBandGrey = const Color(0xFF777777),
    this.errorCaseGreen = const Color(0xFF99FF99),
    this.booleanGreen = const Color(0xFF006600),
    this.hatchOffset = kNoHatchOffset,
    this.errorHatchOffset = kNoHatchOffset,
    this.wireCycleOffset = kNoHatchOffset,
  });

  /// The while-loop band and error-stripe grey — corpus-dominant (119,119,119);
  /// some captures render LabVIEW's stored default 0x7F7F7F literally.
  final Color whileBandGrey;

  /// The error case's green band field — corpus-dominant (153,255,153).
  final Color errorCaseGreen;

  /// The boolean-datatype green of T/F constant blocks and the while-loop stop
  /// terminal's ring — corpus-dominant (0,102,0), (0,127,0) in some captures.
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

/// The grey a disabled frame renders dark neutral chrome in — the same
/// (170,170,170) line-work grey as the disabled icon palette
/// ([_greyDisabledPalette]). A disabled tunnel's whole [kBdTunnelBorder] ring
/// reads (170,170,170) where the wire transform [dimDisabledFrameRgb] would
/// predict (187,187,187): neutral chrome takes the icon mapping, wire-derived
/// colours take the formula.
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

/// The decoded fill colour for [object]: a control's interior
/// [ViHeapObject.contentRgb] if present, else its [ViHeapObject.bgRgb]. Null
/// when neither was decoded, leaving the object its neutral category fill.
Color? bdFillColor(ViHeapObject object) =>
    bdDecodedColor(object.contentRgb) ?? bdDecodedColor(object.bgRgb);

/// [color] rendered through the measured disabled-frame palette transform
/// ([dimDisabledFrameRgb], per channel `c' = min(255, 153 + c ~/ 2)`) —
/// how LabVIEW draws every colour inside a disable structure's displayed
/// Disabled frame. Alpha stays opaque.
Color bdDimDisabled(Color color) =>
    Color(0xFF000000 | dimDisabledFrameRgb(color.toARGB32() & 0xFFFFFF));

/// The measured horizontal column cycles of the patterned wire strokes, from
/// the [ViWireRenderStyle] catalogue: per style, the repeating per-column
/// 5-bit ink masks where bit `b` inks row `cross + (b - 2)` (bit 2 = the route
/// row; higher bits are rows below it, y growing downward). The census
/// canonicalises each cycle by rotation, so the on-screen phase is separate
/// ([kBdWireCyclePhase]); dotted styles apply their checkerboard law directly
/// instead. Only the solid styles and the dotted pair have vertical treatments
/// in the painter, so every style here is drawn patterned on horizontal runs.
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

/// The measured relative phase of each horizontal stroke cycle: LabVIEW
/// indexes a cycle by `x + 2·(y & 1) + stylePhase + captureShift` — the
/// pattern slides two columns between even and odd route rows, each style
/// carries a fixed rotation relative to the others, and the whole family
/// shifts by the capture viewport's pan (the same screen anchoring as the
/// hatch lattice — [BdRenderStyle.wireCycleOffset]). Rebased so zigzag is 0.
/// Absent styles keep phase 0. TODO: census the chainLinkWide/weave/dense
/// phases when a clean reference run appears.
const Map<ViWireRenderStyle, int> kBdWireCyclePhase = {
  ViWireRenderStyle.zigzag: 0,
  ViWireRenderStyle.chainLink: 2,
  ViWireRenderStyle.braid: 0,
  ViWireRenderStyle.braidWide: 1,
};

/// The cross-axis ink band of a stroke [style] around its route row/column,
/// as inclusive offsets — the rows a horizontal run of the style inks. Solid
/// and dotted bands are census-measured (a 2 px wire straddles
/// `cross-1..cross`, transposed on vertical runs); patterned bands are the
/// union of their catalogued cycle masks.
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

/// The sign (+1 down/right, −1 up/left) of [route]'s implied closing run.
///
/// [ViWireRoute.jointSigns] carries segments `1..pointCount-2`, so its last
/// entry is the closing run's stored sign. A route that stores none is a
/// single run opened by [direction], whose sign is therefore the closing one —
/// the same fallback the package walkers use (`walkOneAnchoredRoute` and
/// `ViWire.routePoints`).
int bdRouteClosingSign(ViWireRoute route, WireRouteDirection direction) =>
    route.jointSigns.isEmpty
    ? direction.dx + direction.dy
    : route.jointSigns.last;

/// The colour a [wire] is drawn in: [kBdWireColor] unless one of its endpoint
/// anchors matches a terminal whose datatype was recovered, in which case that
/// terminal's [labviewTypeColor] is used. [typedTerminalColors] maps a packed
/// endpoint-anchor rectangle (`t,l,b,r`) to that terminal's colour. Pure +
/// public for testing.
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
  // No typed terminal: if the first endpoint carrying an anchor is a
  // primitive whose catalogued op fixes its output type, the wire carries
  // that output ([PrimOp.output], from documented semantics only).
  final source = wire.endpointAnchors.firstWhere(
    (anchor) => anchor != null,
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
  // Last: the signal's own decoded type word — an estimate (89.9% family
  // agreement corpus-wide; see [ViSignalType]), outranked by every
  // terminal-derived source above. Arrays colour by element kind.
  final wordKind = wire.elementTypeKind;
  if (wordKind != null && wordKind != ViTypeKind.unknown) {
    return labviewTypeColor(wordKind);
  }
  return kBdWireColor;
}

/// The measured radix-marker glyphs LabVIEW draws before a non-decimal
/// constant's digits, inside the constant's `0xb` radix part: `#` rows at the
/// glyph's offset from the part's top-left corner, inked in the type colour.
/// The 4×4 `x` and 4×6 `b` share a baseline at part top+9. TODO: the octal
/// marker is not yet reference-measured, so `o` draws nothing.
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
/// class identity for the single-op classes, plus the icon asset key and its
/// review status. Null for non-primitive objects.
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

/// Resolves [object]'s prim icon: a primResID key directly; a class key first
/// per terminal count ([classVariantIconKey], the `0x15` DCO children), then
/// the legacy single-art class asset requiring an exact box-size match (class
/// art varies per arity — a 0x44 at 32x35 must not wear the 32x27 art).
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
      .where((c) => c.kind == kNodeEndpointDcoKind)
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

/// Builtin prim terminal positions, keyed by (icon key, terminal index among
/// the prim's `0x15` DCO children, box width, box height) with the offset
/// relative to the prim box's top-left. LabVIEW measures a route's stored
/// segment lengths from the node terminal, which for a primitive is
/// environment-builtin geometry the file does not carry, so a route departing
/// a prim ships with [ViWire.routeHeadSlack] and resolves here.
///
/// Entries come from the corpus route census (a reverse walk with stored bends
/// determines the origin's coordinate perpendicular to its closing axis, so
/// wires of both closing parities assemble a terminal's full position) and
/// from reference-render bend columns/rows; an axis stays null until
/// determined. Growable classes move terminals with the box, hence the size
/// key.
///
/// TODO: five entries — `(1051, 2)`, `(1052, 1)`, `(1052, 2)`, `(1070, 0)` and
/// `(1081, 0)`, all at 32x32 — record no derivation basis, and the corpus
/// route census cannot supply one: a full sweep (7,569 files, 14,640
/// head-slack wires) produces no observation for any of the five keys, so
/// re-deriving them needs a reference render.
const Map<(int, int, int, int), ({int? dx, int? dy})> _kBdPrimTerminals = {
  // Multiply's triangle: inputs at art rows top+5 / top+15 (art top =
  // box.top+6), output at mid-height.
  (1050, 0, 32, 32): (dx: 21, dy: 16),
  (1050, 1, 32, 32): (dx: null, dy: 21),
  (1051, 2, 32, 32): (dx: 11, dy: 11),
  (1052, 1, 32, 32): (dx: null, dy: 21),
  (1052, 2, 32, 32): (dx: null, dy: 11),
  (1056, 3, 32, 32): (dx: 10, dy: 10),
  (1063, 0, 32, 32): (dx: 22, dy: 16),
  // Logical Shift's output rides the tag-art apex row.
  (1081, 0, 32, 32): (dx: null, dy: 16),
  // Random Number's output rides its dice-art middle row.
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
/// ([_kBdPrimTerminals]) in absolute diagram coordinates, either axis null
/// while undetermined; null when the endpoint is not a prim `0x15` DCO or its
/// terminal is uncatalogued.
({int? x, int? y})? bdPrimTerminalOf(ViDiagram diagram, int endpointOid) {
  final head = diagram.byId[endpointOid];
  final parentOid = head?.parentOid;
  if (head == null || head.kind != kNodeEndpointDcoKind || parentOid == null)
    return null;
  final parent = diagram.byId[parentOid];
  final box = parent?.absBounds;
  if (parent == null || box == null) return null;
  final key = primIconKeyOf(parent);
  if (key == null) return null;
  var termIdx = -1;
  var at = 0;
  for (final c in diagram.childrenByOid[parentOid] ?? const <ViHeapObject>[]) {
    if (c.kind != kNodeEndpointDcoKind) continue;
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

/// Integer prescale applied to every bundled icon at load: the asset
/// replicated [kPrimIconPrescale]x with nearest sampling, bit-exact blocks.
/// Drawn back at logical size with nearest it recovers the original pixels
/// exactly, keeping the 1:1 oracle raster bit-perfect; drawn with linear it is
/// "sharp bilinear", the interpolation band being only 1/[kPrimIconPrescale]
/// of a source pixel wide.
const kPrimIconPrescale = 4;

/// A bundled icon at both resolutions. [base] is the asset's own pixels — the
/// only image nearest sampling may touch, since nearest on the prescale at a
/// mismatched scale (4x art on a 3x canvas) doubles some columns and drops
/// others. [sharp] is the [kPrimIconPrescale]x prescale for the
/// sharp-bilinear interactive path.
typedef PrimIconArt = ({ui.Image base, ui.Image sharp});

/// The bundled primitive icon assets (assets/prim_icons/prim<id>.png, icon art
/// harvested from the snippet references with a transparent exterior), decoded
/// once and keyed by primResID.
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
    // A rejected icon never stamps; the node falls back to the plate +
    // operator glyph.
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
    final rgba = await image.toByteData();
    if (rgba != null) {
      final alpha = Uint8List(image.width * image.height);
      for (var i = 0; i < alpha.length; i++) {
        alpha[i] = rgba.getUint8(i * 4 + 3);
      }
      final pixels = Uint8List.fromList(
        rgba.buffer.asUint8List(rgba.offsetInBytes, rgba.lengthInBytes),
      );
      // An opaque `dddddd` on the art's ink boundary (a transparent or
      // outside 4-neighbour) is a plate corner-AA pixel
      // ([_PrimIconPixels.cornerAa]).
      final corners = <int>{};
      var minX = image.width, minY = image.height, maxX = -1, maxY = -1;
      for (var y = 0; y < image.height; y++) {
        for (var x = 0; x < image.width; x++) {
          final artIndex = y * image.width + x;
          if (alpha[artIndex] == 0) continue;
          if (x < minX) minX = x;
          if (y < minY) minY = y;
          if (x > maxX) maxX = x;
          if (y > maxY) maxY = y;
          if (alpha[artIndex] != 255) continue;
          final byteIndex = artIndex * 4;
          if (pixels[byteIndex] != 0xdd ||
              pixels[byteIndex + 1] != 0xdd ||
              pixels[byteIndex + 2] != 0xdd) {
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
      _primIconPixels[id] = _PrimIconPixels(
        width: image.width,
        height: image.height,
        alpha: alpha,
        rgba: pixels,
        cornerAa: corners,
        inkBounds: maxX >= minX && maxY >= minY
            ? ui.Rect.fromLTRB(
                minX.toDouble(),
                minY.toDouble(),
                maxX + 1.0,
                maxY + 1.0,
              )
            : null,
      );
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

/// The disabled-diagram rendering of [rgba] in place: LabVIEW draws a disabled
/// frame's icons as grey line-work on white. Every opaque pixel of the
/// measured pairs maps (255,255,204) → (255,255,255) and
/// (76,76,61) → (170,170,170): light fills go white, everything else the
/// uniform grey, with the 204-average threshold between them the one
/// assumption. TODO: recheck it when a corpus pair exercises a mid tone.
/// Alpha is preserved.
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
/// [ensurePrimIconsGrey] runs, which only happens for a diagram containing a
/// disabled frame.
Map<int, PrimIconArt> primIconsGreyLoaded() => _primIconsGreySync;

/// Decodes PNG/other-encoded image [bytes] to a [ui.Image].
Future<ui.Image> decodeImage(Uint8List bytes) {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromList(bytes, completer.complete);
  return completer.future;
}

/// XNode facade images: the k-th `0x105` object in heap order pairs with the
/// k-th `DSIM` section, accepted only on exact geometry (corpus-verified — the
/// per-snippet DSIM/0x105 counts and dimensions match, and the facades'
/// error-code text matches the `C6 5D` configs under the same objects).
/// A `DSIM` is a 46-byte geometry header followed by a PNG whose alpha is
/// inverted (0 = opaque) with magenta (255,0,255) as a transparency key.
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

/// Builds a [ui.Image] from a raw RGBA buffer ([width]×[height]×4 bytes).
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

/// Builds the disabled-palette variants of every loaded icon, once, on first
/// demand (a diagram with a non-empty [bdDisabledObjectOids] set).
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

/// Recolours a primitive icon by exact palette substitution: every pixel whose
/// RGB appears in [rgbMapping] (0xRRGGBB → 0xRRGGBB) is replaced, alpha
/// preserved, and pixels outside the mapping keep their colour.
/// Disabled-frame rendering uses the value-based [_greyDisabledPalette].
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

/// The decoded pixel side of one bundled icon, held together so every read
/// along a paint path costs a single lookup.
class _PrimIconPixels {
  const _PrimIconPixels({
    required this.width,
    required this.height,
    required this.alpha,
    required this.rgba,
    required this.cornerAa,
    required this.inkBounds,
  });

  final int width;
  final int height;

  /// One byte per pixel, backing pixel-precise hit testing at logical
  /// resolution: a stamped icon's transparent surround must not swallow clicks
  /// meant for the wire or canvas behind it.
  final Uint8List alpha;

  /// The art's raw RGBA — the pixel source the plate corner-AA ladder reads
  /// when an overlap must restore the art a corner pixel yields to.
  final Uint8List rgba;

  /// The art positions (`y * width + x`) of the plate corner-AA pixels: the
  /// `dddddd` blends baked where a prim plate's rounded outline corner
  /// anti-aliased against the white canvas (the triangle plates carry one at
  /// each left corner). Canvas artefacts, not plate art, so overlapping prim
  /// boxes compose them by the icon pass's measured ladder, not source-over.
  final Set<int> cornerAa;

  /// The art-space opaque-pixel bounding box, null for fully transparent art.
  final ui.Rect? inkBounds;
}

final Map<int, _PrimIconPixels> _primIconPixels = {};

/// The corner-AA ladder's second rung: the measured screen value where two
/// plate corner-AA pixels coincide on bare canvas (stacked plates on a 20 px
/// pitch land one plate's bottom corner on the next plate's top corner).
const _kCornerAaRung2 = Color(0xFFAAAAAA);

/// The art-space ink (opaque-pixel) bounding box of the icon keyed [key], null
/// while the icons load or for keys without art. The wire fallback router
/// anchors an icon-stamped endpoint here rather than at the larger node box.
ui.Rect? primIconInkBounds(int key) => _primIconPixels[key]?.inkBounds;

/// Where icon art lands within a node's box. Placement is a fixed
/// per-primitive property measured against LabVIEW's own renders
/// ([kPrimIconPlacement]); no centring rule reproduces it. Unmeasured keys
/// centre with the half-pixel floored. Offsets stay whole logical pixels
/// either way — a fractional stamp splits border ink across resample
/// boundaries. The stamp, the selection outline, and the alpha hitbox all
/// share this rect.
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

/// Resolves the loaded icon id for [object]: a primResID directly; a class key
/// by probing its per-arity variants ([classVariantIconKey]) for one whose art
/// matches the node box (variant art is always the full box rect), else the
/// legacy plain class id requiring an exact box-size match. Same-size arities
/// (0x44 t4/t5) alias here — harmless for masks and ink edges, which only read
/// the fully-opaque rect; the stamp path ([primIconArtFor]) resolves by the
/// true terminal count.
int? loadedPrimIconIdOf(ViHeapObject object) {
  final key = primIconKeyOf(object);
  if (key == null || key >= 0) return key;
  final b = object.absBounds;
  if (b == null) return key;
  for (var t = 0; t <= 15; t++) {
    final id = classVariantIconKey(object.kind, t);
    final art = _primIconPixels[id];
    if (art != null && art.width == b.width && art.height == b.height) {
      return id;
    }
  }
  final legacy = _primIconPixels[key];
  if (legacy != null &&
      (legacy.width != b.width || legacy.height != b.height)) {
    return null;
  }
  return key;
}

/// Whether the diagram-space point ([x],[y]) lands on an opaque pixel of the
/// primitive icon stamped on [object]. True when no icon is stamped, leaving
/// the plain bounds hit; pixel-precise otherwise, so an icon's transparent
/// surround does not swallow clicks.
///
/// An object without [ViHeapObject.absBounds] stamps nothing — there is no
/// rect to place the art in — so the mask cannot narrow the hit and the answer
/// is again true: this test only ever removes hits the caller's own bounds
/// test has already accepted.
bool primIconHit(ViHeapObject object, double x, double y) {
  final id = loadedPrimIconIdOf(object);
  final art = id == null ? null : _primIconPixels[id];
  final bounds = object.absBounds;
  if (art == null || bounds == null || _primIconsSync[id] == null) return true;
  final stamp = primIconStampRect(
    Rect.fromLTRB(
      bounds.left.toDouble(),
      bounds.top.toDouble(),
      bounds.right.toDouble(),
      bounds.bottom.toDouble(),
    ),
    art.width,
    art.height,
    key: id,
  );
  final ix = (x - stamp.left).floor();
  final iy = (y - stamp.top).floor();
  if (ix < 0 || iy < 0 || ix >= art.width || iy >= art.height) return false;
  return art.alpha[iy * art.width + ix] > 0;
}

/// The absolute diagram coordinate of [object]'s stamped-art opaque edge along
/// one axis, on the line a wire's implied closing run arrives on. For a
/// horizontal run ([horizontal] true) the scan is across art row [cross] (an
/// absolute y) and [sign] is the run's x direction: `+1` returns the leftmost
/// opaque column, `-1` the column just past the rightmost. A vertical run
/// scans column [cross] (an absolute x) for the top/bottom opaque row. Null
/// when the object stamps no masked art or that row/column holds no opaque
/// pixel — a transparency the per-art ink bounding box
/// ([primIconInkBounds]) cannot report.
int? primIconInkEdge(
  ViHeapObject object, {
  required bool horizontal,
  required int cross,
  required int sign,
}) {
  final id = loadedPrimIconIdOf(object);
  final art = id == null ? null : _primIconPixels[id];
  final b = object.absBounds;
  if (art == null || b == null) return null;
  final stamp = primIconStampRect(
    Rect.fromLTRB(
      b.left.toDouble(),
      b.top.toDouble(),
      b.right.toDouble(),
      b.bottom.toDouble(),
    ),
    art.width,
    art.height,
    key: id,
  );
  if (horizontal) {
    final iy = (cross - stamp.top).floor();
    if (iy < 0 || iy >= art.height) return null;
    final base = iy * art.width;
    if (sign >= 0) {
      for (var ix = 0; ix < art.width; ix++) {
        if (art.alpha[base + ix] > 0) return stamp.left.floor() + ix;
      }
    } else {
      for (var ix = art.width - 1; ix >= 0; ix--) {
        if (art.alpha[base + ix] > 0) return stamp.left.floor() + ix + 1;
      }
    }
    return null;
  }
  final ix = (cross - stamp.left).floor();
  if (ix < 0 || ix >= art.width) return null;
  if (sign >= 0) {
    for (var iy = 0; iy < art.height; iy++) {
      if (art.alpha[iy * art.width + ix] > 0) return stamp.top.floor() + iy;
    }
  } else {
    for (var iy = art.height - 1; iy >= 0; iy--) {
      if (art.alpha[iy * art.width + ix] > 0) return stamp.top.floor() + iy + 1;
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

/// The per-diagram lookups the wire pass resolves once before drawing any wire:
/// packed endpoint-anchor rect → recovered terminal colour and catalogued node
/// output colour, the icon-stamped node boxes with their art ink rects and
/// owning objects, the node boxes that cover wire ink, and the furniture rects
/// a leg end trims to. All in canvas coordinates except the packed colour keys,
/// which are absolute ([_packRect]).
typedef _BdWireAnchors = ({
  Map<int, Color> typedTerminalColors,
  Map<int, Color> sourceOutputColors,
  Set<Rect> iconNodeRects,
  Map<Rect, Rect> iconInkRects,
  Map<Rect, ViHeapObject> iconNodeObjects,
  List<Rect> nodeCoverRects,
  List<Rect> furnitureRects,
});

/// Everything the block-diagram painter needs that derives from one
/// [ViDiagram], computed once and passed as a unit. The decode-only half is
/// [ViDiagramSemantics], shared with non-rendering consumers; this adds the
/// canvas-space extent and the painter's text caches. Members are lazy, so a
/// caller that never paints wires never pays for their analysis.
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

  /// The drawn object set ([bdDrawableObjects]); callers may override it.
  List<ViHeapObject> get drawable => semantics.drawable;

  /// The decoded dataflow wires ([bdVisibleWires], one per `0x17` signal);
  /// pass `const []` for a wire-free render.
  List<ViWire> get wires => semantics.wires;

  /// [drawable] in painting order ([bdPaintOrder]).
  List<ViHeapObject> get ordered => semantics.ordered;

  /// Objects under a disabled displayed frame ([bdDisabledObjectOids]).
  Set<int> get disabledOids => semantics.disabledOids;

  /// Case structures displaying their "No Error" frame ([bdErrorCaseOids]).
  Set<int> get errorCaseOids => semantics.errorCaseOids;

  /// Attach rect → terminal class ([bdBorderTerminalKinds]).
  Map<HeapRect, ({int kind, bool hollow, bool centreDot, bool disabled})>
  get borderTerminalKinds => semantics.borderTerminalKinds;

  /// Per structure oid, its modeled terminals ([bdStructureTerminals]).
  Map<int, List<({HeapRect box, int bmp})>> get structureTerminals =>
      semantics.structureTerminals;

  /// Per terminal oid, the literal its constant box displays.
  Map<int, String> get constValues => semantics.constValues;

  /// The display-part furniture boxes the into-DCO wire trim stops on.
  List<HeapRect> get furnitureBounds => semantics.furnitureBounds;

  /// The ink envelope of [drawable]. Wires are excluded: their absolute
  /// anchoring is unverified, and a misanchored run must not blow up the fit.
  late final Rect content = drawable.isEmpty
      ? Rect.zero
      : bdContentRect(drawable, includeWires: false);

  /// Scale-independent text layouts, cached across repaints and zoom
  /// re-anchors (the canvas itself is scaled, so a layout never depends on
  /// [BdDiagramPainter.canvasScale]). Keyed by text + full style ([BdRunKey],
  /// a record: value equality with no key string to build or parse).
  final Map<BdRunKey, BdTextRun> textLayoutCache = {};

  /// Per-glyph layout/paint slots backing [textLayoutCache] (see [BdGlyph]),
  /// keyed by glyph + full style and shared by every run that uses the glyph.
  final Map<BdGlyphKey, BdGlyph> textGlyphCache = {};

  /// Whether [paintedText] is recorded. Off by default: the record and rect
  /// cost an allocation per run per paint.
  bool recordPaintedText = false;

  /// Every text run the last paint drew (when [recordPaintedText]): its
  /// string, the canvas-space rect of its laid-out box, and the style size it
  /// was set in. Rebuilt each paint.
  final List<({String text, Rect rect, double fontSize})> paintedText = [];

  /// Releases the native handles the text caches hold — every recorded run
  /// picture and every cached glyph's painters. Call it when the scene is
  /// discarded; the scene must not be painted afterwards.
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
/// string, the full style, and the effective line count — two runs of the same
/// single-line text share a layout however tall the boxes holding them are.
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

/// The block-diagram text size, in logical px per em, calibrated against the
/// references' own text ink (the Windows UI face, drawn here with the
/// metric-compatible bundled Selawik). Every text class measures cap height
/// 9 px, x-height 6 px, descender 3 px. On the whole-pixel glyph lattice
/// ([BdTextRun]) 12.0 em matches the reference ink within ±1 px on all but a
/// handful of ~200 runs.
const double kBdTextSize = 12.0;

/// Line box height as a multiple of the em size: `ceil(fontSize * this)` is
/// both the reported line-box height and the multi-line baseline pitch —
/// 15 px at [kBdTextSize], the reference's baseline pitch.
const double kBdTextLineHeight = 14.5 / kBdTextSize;

/// The line box (px) a run of em size [fontSize] sets on, and the pitch of
/// its baselines: the [kBdTextLineHeight] multiple taken up to a whole pixel
/// row, since the reference pens every baseline on a whole row.
double bdLineBox(double fontSize) =>
    (fontSize * kBdTextLineHeight).ceilToDouble();

/// Ink-weight overdraw alpha: every text run re-draws itself once at this
/// alpha under the full-strength pass, darkening each AA fringe pixel from
/// coverage `a` to `1-(1-a)(1-0.75a)`. Plain rasterisation measures 0.78-0.81
/// of the references' mean ink and a full double-paint 1.07-1.09; this alpha
/// lands 1.00-1.02.
const double kBdTextOverdrawAlpha = 0.75;

/// The bold face's overdraw alpha: bold stems are already multi-pixel, so the
/// regular fringe lift lands 1.14x the reference's mean ink. This alpha lands
/// 1.015 at 12 em and is extrapolated to every other bold size.
/// TODO(labwright): calibrate the bold alpha per size.
const double kBdTextOverdrawAlphaBold = 0.15;

/// The anchor for a text run of [text] size centred in [box] — both axes
/// truncate the half pixel, so a run one px narrower than an even gap sits
/// left/above the symmetric centre.
///
/// Measured by registering each painted run's ink onto its reference's: 781 of
/// 786 confidently registered runs sit at shift 0 under this law, while the 41
/// even-gap growable-node row texts move one px off the reference under the
/// label law below. The vertical half pixel is unmeasurable on this corpus and
/// is floored to match the horizontal axis. Glyph stamps centre the same way.
Offset bdCentredTextAnchor(Rect box, Size text) => Offset(
  box.left + ((box.width - text.width) / 2).floorToDouble(),
  box.top + ((box.height - text.height) / 2).floorToDouble(),
);

/// The vertical half of [bdCentredTextAnchor], for runs whose horizontal
/// anchor is justified rather than centred.
double bdCentredTextTop(Rect box, double textHeight) =>
    box.top + ((box.height - textHeight) / 2).floorToDouble();

/// The left anchor of a centre-justified label run
/// ([ViHeapObject.labelJustifyCenter]) of [textWidth] in its stored [bounds]:
/// centred over `width − 1`, so an even gap inks one px left of the symmetric
/// centre — a different law from [bdCentredTextAnchor], measured separately on
/// the same registration probe. Odd-gap labels read the same either way.
double bdCentredLabelLeft(Rect bounds, double textWidth) =>
    bounds.left + ((bounds.width - textWidth - 1) / 2).floorToDouble();

/// One cached glyph of the diagram text face at a full style+colour: the
/// full-ink and [kBdTextOverdrawAlpha] companion painters, the pen advance
/// snapped to whole pixels, and the painter's own (fractional) alphabetic
/// baseline distance, used to land the outline on an integer baseline row.
///
/// The capture rasterizer (classic GDI text output) pens each glyph a whole
/// number of pixels after the last and sets every baseline on a whole pixel
/// row; the face's fractional advances (Selawik digits 6.469 px, `e` 6.275 px)
/// would otherwise drift several px over a long run, where the references
/// space value digits on an exact 6 px pitch.
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

  /// The whole-pixel pen advance: the face's hinted 12 ppem advance
  /// ([bdHintedAdvance]) where it differs from rounding, else the fractional
  /// advance rounded.
  final int advance;

  /// [main]'s alphabetic-baseline distance from its paint origin.
  final double baseline;

  /// Releases both painters' native layout resources.
  void dispose() {
    main.dispose();
    dim.dispose();
  }
}

/// A laid-out text run on the whole-pixel glyph lattice: every glyph pens at
/// an integer x, every line's baseline on an integer row at the
/// [kBdTextLineHeight] pitch, with the overdraw pass recorded under the
/// full-strength pass at identical origins. Laid out once and replayed from a
/// recorded picture, so a repaint saves the layout, not the draw count.
class BdTextRun {
  BdTextRun({
    required this.text,
    required this.width,
    required this.height,
    required this.fontSize,
    required ui.Picture picture,
  }) : _picture = picture;

  /// The string the run lays out.
  final String text;

  /// The widest line's advance sum — an exact whole number of pixels.
  final double width;

  /// `lineHeight * lineCount` — 15 px line boxes at 12 em.
  final double height;

  /// The em size the run was set in.
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

/// The static diagram layer: grid, objects, and labels. Depends only on the
/// memoized object list + origin, so a selection tap repaints [_OverlayPainter]
/// instead. Public so the off-screen [BdOracle] rasterises with the same
/// drawing as the view.
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
    // GDI pens by the face's hinted per-ppem advance (`hdmx`), not the rounded
    // linear one; at 12 ppem the two differ on a handful of glyphs
    // ([bdHintedAdvance]). Other em sizes keep the rounded engine width.
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

  /// A laid-out [BdTextRun] from the scene's scale-independent layout cache
  /// ([BdScene.textLayoutCache]). Lines are the text's own newlines, truncated
  /// to [maxLines]; each glyph pens at the integer advance sum, each line's
  /// baseline on the integer row nearest the face's own (12 at 12 em).
  BdTextRun _layoutText(
    String text, {
    required Color color,
    double fontSize = kBdTextSize,
    FontWeight fontWeight = FontWeight.w400,
    FontStyle? fontStyle,
    int? maxLines,
  }) {
    // The effective line count keys the cache: a taller box that truncates
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
    // The overdraw pass first ([kBdTextOverdrawAlpha]), then the
    // full-strength pass over it at identical integer origins.
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

  /// Paints [run] at [at], snapped to whole pixels — the references pen every
  /// run at integer device coordinates — and records the run's canvas rect on
  /// [BdScene.paintedText]. [clip] crops overlong text the way LabVIEW crops a
  /// value display to its box: a hard pixel clip showing cut glyphs, never an
  /// ellipsis.
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

  /// Resolved subVI-call node icons keyed by [ViHeapObject.oid] — the 32×32
  /// icon of the VI a node targets, loaded from that VI's own file. A node
  /// without an entry keeps the neutral connector-pane plate.
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

  /// Whether every pixel of the axis-aligned polyline [points] lies under some
  /// box in [cover] (canvas coords; a box covers `[left, right-1] × [top,
  /// bottom-1]`, its drawn extent). Interval-merges the covering boxes along
  /// each run, bridging a 1 px seam between abutting boxes — a stacked prim
  /// chain's divider row carries no wire ink either. Any wider gap is visible
  /// ink and reads false.
  static bool _polylineUnderNodes(List<Offset> points, List<Rect> cover) {
    for (var segmentIndex = 1; segmentIndex < points.length; segmentIndex++) {
      final start = points[segmentIndex - 1], end = points[segmentIndex];
      final horizontal = start.dy == end.dy;
      final runLo = horizontal
          ? math.min(start.dx, end.dx)
          : math.min(start.dy, end.dy);
      final runHi = horizontal
          ? math.max(start.dx, end.dx)
          : math.max(start.dy, end.dy);
      var at = runLo;
      var progressed = true;
      while (at <= runHi && progressed) {
        progressed = false;
        for (final box in cover) {
          final crossOk = horizontal
              ? (start.dy >= box.top && start.dy < box.bottom)
              : (start.dx >= box.left && start.dx < box.right);
          if (!crossOk) continue;
          final (boxLo, boxHi) = horizontal
              ? (box.left, box.right)
              : (box.top, box.bottom);
          if (boxLo <= at + 1 && boxHi > at) {
            at = boxHi;
            progressed = true;
          }
        }
      }
      if (at <= runHi) return false;
    }
    return points.isNotEmpty;
  }

  /// [color] through the measured disabled-frame palette transform when the
  /// object [oid] sits under a disabled displayed frame ([disabledOids]).
  Color _dimFor(int oid, Color color) => disabledOids.contains(oid)
      ? bdDimDisabled(color).withValues(alpha: color.a)
      : color;

  /// Sampling for stamped icons: nearest (the default) is pixel-exact in the
  /// 1:1 oracle raster; the interactive view passes [FilterQuality.low]
  /// because its zoom is arbitrary and nearest minification drops pixels.
  final FilterQuality iconFilterQuality;

  /// The zoom this layer rasterises at. The interactive view re-anchors the
  /// layer to the settled zoom after each gesture, so the cached raster the
  /// compositor scales is already crisp at the zoom being viewed.
  final double canvasScale;

  /// Whether the canvas alignment-dot grid draws — an interactive-view
  /// affordance only. The oracle raster omits it: reference renders have a
  /// plain white canvas, and near-white dots break byte-exact comparisons.
  final bool drawDotGrid;

  /// [object]'s recovered bounds in canvas coordinates.
  Rect _rectOf(ViHeapObject object) => _toCanvas(object.absBounds!);

  @override
  void paint(Canvas canvas, Size size) {
    scene.paintedText.clear();
    // Everything below draws in logical diagram units under this one scale,
    // so strokes, text, and icons render at the zoom's real resolution.
    canvas.scale(canvasScale);
    size = Size(size.width / canvasScale, size.height / canvasScale);
    canvas.drawRect(Offset.zero & size, Paint()..color = kBdCanvas);
    if (drawDotGrid) _drawDotGrid(canvas, size);

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

    final arrayShellOids = {
      for (final o in objects)
        if (o.objectClass == HeapObjectClass.numericControl &&
            o.parentOid != null)
          o.parentOid!,
    };
    final tunnelSquares =
        <
          (
            Rect,
            ({int kind, bool hollow, bool centreDot, bool disabled}),
            Color,
          )
        >[];
    // Rects owned by the border-terminal chrome pass (shift registers,
    // selectors, tunnels). A modeled structure terminal at the same rect must
    // not also draw: its anti-aliased ring bleeds blended pixels just outside
    // the rect that the byte-exact chrome cannot cover.
    final chromeOwnedRects = <Rect>{
      for (final attach in borderTerminalKinds.keys) _toCanvas(attach),
    };
    final labelBackings = <(int, Rect, Color)>[];

    _paintDecorations(canvas, decorations);
    // Wire pass: over the canvas/decorations, under every structure/node.
    _drawWires(canvas, tunnelSquares: tunnelSquares);
    _paintStructures(
      canvas,
      structures,
      arrayShellOids: arrayShellOids,
      chromeOwnedRects: chromeOwnedRects,
    );
    _paintCaseSelectorStrips(canvas, solids);
    _paintBorderChrome(canvas, tunnelSquares);
    _paintWireObjects(canvas, wires);
    _paintSolids(canvas, solids, labelBackings);
    _paintLabelBackings(canvas, labelBackings);
    _paintCaptions(canvas);
  }

  /// Decoration pass: the backmost layer, so an opaque decoration never
  /// occludes the runs routed across it. One enclosing other drawn logic is a
  /// backdrop whose interior LabVIEW leaves as plain canvas.
  void _paintDecorations(Canvas canvas, List<ViHeapObject> decorations) {
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
      // An undecoded decoration is still a visible drawn element: a thin
      // border, plus a neutral near-canvas plate when it is a leaf box.
      final rect = _rectOf(object);
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
  }

  /// Structure pass: each structure draws the border chrome and corner
  /// terminals of its own class, over the wire pass.
  void _paintStructures(
    Canvas canvas,
    List<ViHeapObject> structures, {
    required Set<int> arrayShellOids,
    required Set<Rect> chromeOwnedRects,
  }) {
    for (final object in structures) {
      // A small 0x53 cluster container is a single drawn box, not a frame —
      // same chrome as the solids pass, drawn here after the wire pass because
      // the reference covers a wire crossing the box's interior.
      if (object.objectClass == HeapObjectClass.loop) {
        final rect = _rectOf(object);
        if (rect.width <= 40 && rect.height <= 24) {
          _drawSmallClusterBox(canvas, object, rect);
          continue;
        }
      }
      // Class-accurate structure chrome, no badge text: LabVIEW names a
      // construct by its border furniture. Kinds without measured chrome keep
      // a neutral double-line frame.
      final rect = _rectOf(object);
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
      // Structure terminals draw at their modeled frame-relative positions
      // with their modeled glyph (see [bdStructureTerminals]).
      final terminals =
          structureTerminals[object.oid] ?? const <({HeapRect box, int bmp})>[];
      // An array constant shell (a 0x52 container holding a 0x50 index box) is
      // not a drawn frame — LabVIEW shows only its parts. A 0x52 without an
      // index box keeps its generic frame.
      if (object.objectClass == HeapObjectClass.caseOrSequence &&
          arrayShellOids.contains(object.oid)) {
        _drawArrayConstantShell(canvas, object);
        continue;
      }
      switch (object.objectClass) {
        case HeapObjectClass
            .bdForLoop: // Crisp 1px black border + stacked pages.
          _drawForLoopBorder(canvas, rect, disabled: structDisabled);
        case HeapObjectClass
            .bdWhileLoop: // Crisp rounded grey band + terminals.
          _drawWhileLoopBand(
            canvas,
            rect,
            structColor,
            disabled: structDisabled,
          );
        case HeapObjectClass
            .bdStructureFrame: // Solid 1px border + global hatch band.
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
          // corner, over the hatch band.
          if (((object.objFlags ?? 0) & 0x1000000) != 0) {
            _drawCaseInsensitiveBadge(
              canvas,
              rect,
              disabled: structDisabled,
              oid: object.oid,
            );
          }
        case HeapObjectClass.bdFlatSequence: // The film-strip border.
          _drawFlatSequenceBorder(canvas, rect, object);
        case HeapObjectClass.bdSequenceFrame:
          // The parent flat sequence owns the strip chrome and the
          // inter-frame dividers; the frame itself draws nothing.
          break;
        case HeapObjectClass.bdDisableStructure:
          // Displaying its Disabled frame: one 1px (153,153,153) rectangle,
          // no double line, no tint. Displaying an enabled frame: a 3px
          // (119,119,119) crosshatch band on the left/right/bottom edges (the
          // case-hatch lattice anchored to the structure's own rect with a +1
          // row phase) and a plain 1px black top row between the corners.
          final showsDisabled = scene.diagram
              .children(object.oid)
              .any(
                (k) =>
                    k.objectClass == HeapObjectClass.bdSelectorLabel &&
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
  }

  /// Case-selector strip pass, under the border-terminal chrome: the reference
  /// draws a case's ? tunnel and its wire over the strip's bottom-left corner
  /// where they overlap.
  void _paintCaseSelectorStrips(Canvas canvas, List<ViHeapObject> solids) {
    for (final object in solids) {
      if (object.objectClass == HeapObjectClass.bdSelectorLabel)
        _drawCaseSelector(canvas, _rectOf(object));
    }
  }

  /// Border-terminal chrome pass. Overlapping terminals stack squares first,
  /// then registers, then selectors: a selector draws over the select tunnel
  /// sharing its edge (a 0x2e/0x2d pair overlaps by two rows).
  void _paintBorderChrome(
    Canvas canvas,
    List<
      (Rect, ({int kind, bool hollow, bool centreDot, bool disabled}), Color)
    >
    tunnelSquares,
  ) {
    tunnelSquares.sort(
      (a, b) => _chromeZOrder(a.$2.kind).compareTo(_chromeZOrder(b.$2.kind)),
    );
    for (final (rect, info, color) in tunnelSquares) {
      _drawBorderTerminalChrome(canvas, rect, info, color);
    }
  }

  /// Wire-object pass: each 0x1d object is one stored Manhattan run, drawn as
  /// its own segment. Runs of the same wire already meet at their bend corners
  /// (79% of consecutive segment pairs share an exact endpoint), so a bent wire
  /// connects by geometry alone; runs that do not touch are left unbridged,
  /// since a gap belongs to a different wire.
  void _paintWireObjects(Canvas canvas, List<ViHeapObject> wires) {
    final wirePaint = Paint()
      ..color = _kindColor(ViObjectKind.wire)
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.square;
    for (final object in wires) {
      final rect = _rectOf(object);
      // A zero-area segment is an unanchored stub, a point rather than a run.
      if (rect.width == 0 && rect.height == 0) continue;
      canvas.drawLine(rect.topLeft, rect.bottomRight, wirePaint);
    }
  }

  /// Solids pass: terminals, nodes, controls. Free-label backings are collected
  /// into [labelBackings] for the pass that draws them above this one.
  void _paintSolids(
    Canvas canvas,
    List<ViHeapObject> solids,
    List<(int, Rect, Color)> labelBackings,
  ) {
    // Prim icon stamps already painted in this pass, in paint order — the
    // lookup behind the plate corner-AA ladder (see the stamping branch).
    final stampedPrimIcons = <({Rect dst, int id})>[];
    for (final object in solids) {
      final rect = _rectOf(object);
      // Free-text label parts (control caption 0x0a, case selector 0x95) draw
      // as text; a backed label also shows an opaque bordered fill. Two backed
      // classes across the 812 drawn corpus `0x0a` labels: a free label (`0x1b`
      // holder) with a decoded background, and an array-docked label (`0x52`
      // array shell) with a decoded background and no `0x800` value-window
      // flag. Every other owned label shows none.
      if (kBdTextLabelClasses.contains(object.objectClass)) {
        // The selector's chrome drew in the strip pass, its value text in the
        // text pass.
        if (object.objectClass == HeapObjectClass.bdSelectorLabel) continue;
        final holder = scene.diagram.byId[object.parentOid ?? -1];
        final backed =
            holder?.kind == 0x1b ||
            (holder?.objectClass == HeapObjectClass.caseOrSequence &&
                ((object.objFlags ?? 0) & 0x800) == 0);
        final backing = object.isLabelHidden || !backed || object.bgRgb == null
            ? null
            : bdDecodedColor(bdLabelBackingRgb(object.bgRgb!));
        // Free labels float above nodes in LabVIEW's z-order, so their
        // backings are deferred past this pass.
        if (backing != null) labelBackings.add((object.oid, rect, backing));
        continue;
      }
      if (object.objectClass == HeapObjectClass.loop &&
          rect.width <= 40 &&
          rect.height <= 24) {
        _drawSmallClusterBox(canvas, object, rect);
        continue;
      }
      switch (object.category) {
        case ViObjectKind.terminal:
          _paintTerminal(canvas, object, rect);
        case ViObjectKind.node:
          _paintNode(canvas, object, rect, stampedPrimIcons);
        default:
          _paintPlainSolid(canvas, object, rect);
      }
    }
  }

  /// A terminal/constant [object]: its value-window box, measured terminal art
  /// or generic datatype-coloured chrome, radix marker, literal and glyph.
  void _paintTerminal(Canvas canvas, ViHeapObject object, Rect rect) {
    // A named constant boxes only its value part (the `0x9` child
    // window): the visible caption sits beside the box, inside the same
    // terminal bounds. An unnamed constant's whole bounds are the box.
    var box = rect;
    if (constValues[object.oid] != null) {
      final kids =
          scene.diagram.childrenByOid[object.oid] ?? const <ViHeapObject>[];
      final named = kids.any(
        (c) =>
            c.objectClass == HeapObjectClass.controlLabel &&
            !c.isLabelHidden &&
            (c.label?.trim().isNotEmpty ?? false),
      );
      if (named) {
        for (final c in kids) {
          final b = c.absBounds;
          if (c.objectClass == HeapObjectClass.controlChrome &&
              b != null &&
              b.right > b.left) {
            box = _toCanvas(b);
            break;
          }
        }
      }
    }
    // A boolean constant's shell draws the T/F block, picked by the
    // decoded [ViHeapObject.constBool].
    final constHolder = scene.diagram.byId[object.parentOid ?? -1];
    final boolValue = constHolder?.objectClass == HeapObjectClass.bdConstDco
        ? constHolder!.constBool
        : null;
    if (boolValue != null && box.width == 16 && box.height == 14) {
      _drawBoolConstant(
        canvas,
        box,
        boolValue,
        disabled: disabledOids.contains(object.oid),
      );
      return;
    }
    // A terminal whose (datatype, direction) has reference-measured art
    // at the standard 32×16 box draws it pixel-exact ([kBdTerminalArt]);
    // unmeasured types keep the generic frame.
    final artType = object.dataType ?? _dataTypeOfTypeKind(object.typeKind);
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
          : bdTerminalArtFor(artType, indicator: object.isIndicator == true);
      if (art != null) {
        _drawTerminalArt(
          canvas,
          box,
          art,
          disabled: disabledOids.contains(object.oid),
        );
        return;
      }
    }
    // Generic terminal chrome: a datatype-coloured double border (2 px
    // outer, 1 px white gap, 1 px inner) over a plate shaded around the
    // dataflow arrow. A recovered datatype or decoded foreground colour
    // drives the colour; an unrecovered one stays neutral grey.
    final typed = object.typeKind != ViTypeKind.unknown || object.fgRgb != null;
    final tint = _dimFor(
      object.oid,
      object.typeKind != ViTypeKind.unknown
          ? labviewTypeColor(object.typeKind)
          : (bdDecodedColor(object.fgRgb) ?? kBdUnknownTerminalFill),
    );
    // An unknown-type terminal keeps a dark neutral border; the light
    // "unknown" grey is invisible to the eye and the edge masks alike.
    final border = typed ? tint : _dimFor(object.oid, const Color(0xFF5A5A5A));
    // A constant box ([constValues]) carries the 2 px outer border only,
    // no inner ring, and shows its decoded literal instead of a glyph.
    final constValue = constValues[object.oid];
    final shellParent = scene.diagram.byId[object.parentOid ?? -1];
    if (object.objectClass == HeapObjectClass.numericControl &&
        shellParent?.objectClass == HeapObjectClass.caseOrSequence) {
      // Both the index box (window, spinner boxes, arrows) and the
      // element cells are the array shell's furniture
      // ([_drawArrayConstantShell]); a generic frame would double them.
      return;
    }
    // Indicators wear a thin 1px single border, controls the 2px
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
      // A string shell's left border is 4 px against 2 on the other
      // three sides.
      if (object.objectClass == HeapObjectClass.stringOrArrayControl &&
          box.width > 8) {
        canvas.drawRect(
          Rect.fromLTWH(box.left, box.top, 4, box.height),
          _solidNoAa(border),
        );
      }
      // A path shell carries the path glyph inside its left border: two
      // linked 4x4 squares in the border teal, the lower square 2 px
      // right of the upper, anchored at (+3,+4).
      if (object.objectClass == HeapObjectClass.pathControl &&
          box.width > 14 &&
          box.height >= 17) {
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
    // Any constant skips the inner ring, including one whose value is
    // not decoded (a `0x13` holder marks it).
    final isConstant =
        constValue != null ||
        shellParent?.objectClass == HeapObjectClass.bdConstDco;
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
    // The dataflow arrow sits inside the box: a right-pointing triangle
    // 3 px deep and ~7 px tall. Data leaving (a control) puts the tip on
    // the 2 px outer border with the base 1 px past the inner border;
    // data arriving (an indicator) puts the base on the inner border.
    if (object.isIndicator != null && box.height >= 12 && box.width >= 12) {
      final indicator = object.isIndicator == true;
      final cy = box.center.dy;
      final double tipX;
      if (indicator) {
        tipX = box.left + 7;
      } else {
        tipX = box.right - 3;
      }
      final shade = Rect.fromLTRB(
        indicator ? box.left + 3 : box.right - 10,
        box.top + 4,
        indicator ? box.left + 10 : box.right - 3,
        box.bottom - 4,
      );
      canvas.drawRect(shade, Paint()..color = tint.withValues(alpha: 0.25));
      final tri = Path()
        ..moveTo(tipX - 3, cy - 3.5)
        ..lineTo(tipX, cy)
        ..lineTo(tipX - 3, cy + 3.5)
        ..close();
      canvas.drawPath(
        tri,
        Paint()
          ..color = _dimFor(object.oid, Colors.black).withValues(alpha: 0.87),
      );
    }
    // A non-decimal constant's radix marker ([kBdRadixMarkerGlyphs]) at
    // its 0xb radix part, in the type colour; decimal constants draw
    // nothing there.
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
                  (part) =>
                      part.objectClass == HeapObjectClass.controlSubPart &&
                      part.absBounds != null,
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
    // A constant's decoded literal, right-aligned as LabVIEW justifies
    // numeric displays: the text advance ends 4 px inside the window's
    // right edge. Inked black through the disabled transform, which
    // renders digits as the (153,153,153) dim of black.
    if (constValue != null && box.width >= 12 && box.height >= 12) {
      final run = _layoutText(
        constValue,
        color: _dimFor(object.oid, Colors.black),
        maxLines: 1,
      );
      _paintText(
        canvas,
        run,
        Offset(box.right - 4 - run.width, bdCentredTextTop(box, run.height)),
        clip: box.deflate(hasRadixMarker ? 2 : 1),
      );
    }
    // The resolved data type's short label (DBL / I32 / TF / abc), sized
    // to sit inside the double border even on a 16 px terminal. A
    // constant box shows its value instead — a decoded text value on the
    // `0x13` holder draws from its value-label part in the text pass.
    final glyph =
        constValue != null ||
            object.dataType == null ||
            (shellParent?.objectClass == HeapObjectClass.bdConstDco &&
                bdDrawnConstText(shellParent) != null)
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
  }

  /// A node [object]: its XNode facade, growable chrome, primitive/subVI icon
  /// art or plate, and the operator glyph when no art resolves. Icon stamps are
  /// appended to [stampedPrimIcons] in paint order for the corner-AA ladder.
  void _paintNode(
    Canvas canvas,
    ViHeapObject object,
    Rect rect,
    List<({Rect dst, int id})> stampedPrimIcons,
  ) {
    // Node icon plate: a verified primitive icon stamps at natural size;
    // a subVI call stamps the icon resolved from its own file
    // ([subViIcons]). Without either, subVI calls get the light-grey
    // connector-pane plate and primitive nodes the pale-gold plate with
    // the operator glyph, both inside the 1 px black node border.
    final isSubVi = kSubViCallNodeCodes.contains(object.kind);
    // An XNode facade is the node's own stored image, drawn verbatim at
    // its bounds (the DSIM geometry matches them exactly).
    final facade = xnodeFacades[object.oid];
    if (facade != null) {
      canvas.drawImageRect(
        facade,
        Rect.fromLTWH(0, 0, facade.width.toDouble(), facade.height.toDouble()),
        rect,
        Paint()..filterQuality = FilterQuality.none,
      );
      return;
    }
    if (object.objectClass == HeapObjectClass.bdGrowableNode) {
      _paintGrowableNode(canvas, object, rect);
      return;
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
      // The harvested art carries its own borders and transparency — no
      // plate, backing, or extra frame. Exactness paths sample the
      // asset's own pixels with nearest; the sharp-bilinear interactive
      // path samples the prescale with linear.
      final filter =
          iconFilterQuality == FilterQuality.none ||
              canvasScale >= kPrimIconPrescale
          ? FilterQuality.none
          : iconFilterQuality;
      final art = filter == FilterQuality.none ? primIcon.base : primIcon.sharp;
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
      // Plate corner-AA ladder: a corner pixel
      // ([_PrimIconPixels.cornerAa]) is anti-aliasing baked against the
      // white canvas, not opaque art, so over an earlier stamp it
      // composes by the measured ladder —
      //  * over another stamp's opaque art it deposits nothing;
      //  * two corner pixels coinciding on bare canvas deepen the blend
      //    one rung, `dddddd` -> `aaaaaa`;
      //  * on bare canvas alone the baked `dddddd` stands.
      // TODO: no pixel-local source-over/coverage model yields 255->221
      // and 221->170 from the same stamp; revisit the second rung when
      // the corpus grows another corner-corner collision.
      final ladderId = disabled ? null : loadedPrimIconIdOf(object);
      final corners =
          (ladderId == null ? null : _primIconPixels[ladderId]?.cornerAa) ??
          const <int>{};
      for (final artIndex in corners) {
        final artWidth = primIcon.base.width;
        final cornerX = dst.left + artIndex % artWidth;
        final cornerY = dst.top + artIndex ~/ artWidth;
        var beneathCorner = false;
        Color? restore;
        for (final prior in stampedPrimIcons.reversed) {
          final localX = (cornerX - prior.dst.left).round();
          final localY = (cornerY - prior.dst.top).round();
          final priorArt = _primIconPixels[prior.id];
          if (priorArt == null ||
              localX < 0 ||
              localY < 0 ||
              localX >= priorArt.width ||
              localY >= priorArt.height) {
            continue;
          }
          final priorIndex = localY * priorArt.width + localX;
          if (priorArt.alpha[priorIndex] == 0) continue;
          if (priorArt.cornerAa.contains(priorIndex)) {
            beneathCorner = true;
            continue;
          }
          restore = Color.fromARGB(
            0xff,
            priorArt.rgba[priorIndex * 4],
            priorArt.rgba[priorIndex * 4 + 1],
            priorArt.rgba[priorIndex * 4 + 2],
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
      // A node without icon art is a 1 px black ring on the exact
      // bounds, no anti-aliasing.
      final ring = _solidNoAa(_dimFor(object.oid, Colors.black));
      canvas.drawRect(Rect.fromLTWH(rect.left, rect.top, rect.width, 1), ring);
      canvas.drawRect(
        Rect.fromLTWH(rect.left, rect.bottom - 1, rect.width, 1),
        ring,
      );
      canvas.drawRect(Rect.fromLTWH(rect.left, rect.top, 1, rect.height), ring);
      canvas.drawRect(
        Rect.fromLTWH(rect.right - 1, rect.top, 1, rect.height),
        ring,
      );
    }
    // A decoded primitive identity draws its operator glyph on the plate
    // when no icon asset exists — the recognisable core of the art.
    // Uncatalogued ids draw nothing.
    final glyph = icon == null && primIcon == null && object.primResId != null
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
  }

  /// A growable node (0x63): (68,68,68) ring, white field, and its `0x62`
  /// terminal strips laid out from their node-local termBounds. Full-height
  /// cells are terminals — (255,255,204) fill with a 1px black separator on the
  /// edge facing the interior, the left cell carrying the solid black input
  /// arrow and right-column cells the ridged output arrow. Partial-height cells
  /// are text rows: the resolved data-space name in the type colour (arrays by
  /// element), with 1px black dividers at shared row boundaries. objFlags bit
  /// 0x10000 marks the input-side flavour; both share the chrome.
  void _paintGrowableNode(Canvas canvas, ViHeapObject object, Rect rect) {
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
      if (dco.kind != kNodeEndpointDcoKind) continue;
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
        // Input terminal cell: cream to the interior separator, and
        // the black arrow into the node — a 6x3 shaft with a 4-column
        // head, centred.
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
        canvas.drawRect(Rect.fromLTWH(rect.left + 1, cy - 1.0, 6, 3), black);
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
        // The ridged output arrow through the columns, centred on the
        // node's middle row.
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
    // Row text: the terminal's resolved data-space name in the type
    // colour, centred in the row cell with the half pixel truncated
    // (every odd cell−text gap corpus-wide inks at the floor).
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
      _paintText(canvas, run, bdCentredTextAnchor(cell, run.size), clip: cell);
    }
  }

  /// A control/indicator with no measured chrome: a rounded plate in its
  /// decoded interior colour under a thin border.
  void _paintPlainSolid(Canvas canvas, ViHeapObject object, Rect rect) {
    final rr = RRect.fromRectAndRadius(rect, const Radius.circular(2.5));
    // A control/indicator takes its decoded interior colour when
    // recovered, else its neutral category colour.
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

  /// Free-label backing pass, above every node/icon they overlap: a 1px black
  /// border on the outermost pixel ring of the label bounds, filled with the
  /// decoded colour.
  void _paintLabelBackings(
    Canvas canvas,
    List<(int, Rect, Color)> labelBackings,
  ) {
    for (final (oid, rect, backing) in labelBackings) {
      canvas.drawRect(rect, Paint()..color = _dimFor(oid, Colors.black));
      canvas.drawRect(rect.deflate(1), Paint()..color = _dimFor(oid, backing));
    }
  }

  /// Text pass: only recovered captions and constant literals, matching
  /// LabVIEW's sparse on-canvas text — no per-terminal datatype annotations.
  void _paintCaptions(Canvas canvas) {
    // The drawn-object index for owner lookups in the text pass.
    final byOid = {for (final o in objects) o.oid: o};
    for (final object in objects) {
      // Standalone label parts (0x0a free label / control caption, 0x95 case
      // selector) draw their recovered caption as multi-line text within their
      // own bounds; 1819/1849 corpus-wide carry a plausible non-origin box,
      // and degenerate boxes are skipped below.
      if (kBdTextLabelClasses.contains(object.objectClass)) {
        // LabVIEW hides a label whose part sets objFlags bit 0x08
        // ([ViHeapObject.isLabelHidden], false for 0x95 by its class check —
        // a selector's value text is furniture and never hides).
        if (object.isLabelHidden) continue;
        // The selector's stored value text keeps its own padding spaces
        // (" 3 ", " 0, Default "), LabVIEW's left inset, so it is not trimmed.
        var text = object.objectClass == HeapObjectClass.bdSelectorLabel
            ? (object.label?.trim().isEmpty ?? true ? null : object.label)
            : object.label?.trim();
        if (text == null || text.isEmpty) {
          // An owned label with no recovered caption is the owner's value
          // display when a constant value decoded on the const holder above it
          // (`0x13` → shell → label); otherwise it shows the owner's resolved
          // data-space name, the VCTP type name.
          final diagramById = scene.diagram.byId;
          String? constValue;
          var ancestorOid = object.parentOid;
          for (var hop = 0; hop < 4 && ancestorOid != null; hop++) {
            final ancestor = diagramById[ancestorOid];
            if (ancestor == null) break;
            final decoded = bdDrawnConstText(ancestor);
            if (decoded != null) {
              constValue = decoded;
              break;
            }
            ancestorOid = ancestor.parentOid;
          }
          text = constValue ?? byOid[object.parentOid]?.typeName;
        }
        if (text == null || text.isEmpty) continue;
        final rect = _rectOf(object);
        if (rect.width < 8 || rect.height < 8) continue;
        // The selector's value text fills its decoded label bounds
        // left-justified; the pagers and dropdown sit outside them (see
        // [_drawCaseSelector]), and the recovered label carries its own
        // leading space, so the first glyph inks 4 px in.
        final selector = object.objectClass == HeapObjectClass.bdSelectorLabel;
        // The label's decoded face: its first font run resolved against the
        // VI's FTAB ([ViHeapObject.labelFont]). Weight 1000 draws the bold
        // face; a non-default table size (its cell height in px, 15 = the
        // default UI font whose em is [kBdTextSize]) scales the em by size/15.
        // TODO(labwright): render FTAB face names — a non-default family
        // (Courier New) currently falls back to the default face.
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
          // Never truncated or auto-wrapped: LabVIEW sizes a label's bounds to
          // its text, multi-line captions carrying their own newlines.
          maxLines: math.max(1, (rect.height / bdLineBox(fontSize)).round()),
        );
        // A selector's value text hard-clips 4 px inside its label part's
        // right bound — cut glyphs, no ellipsis. A centre-justified label
        // ([ViHeapObject.labelJustifyCenter], the 0x021 word's 0x20 bit)
        // centres by [bdCentredLabelLeft], a different half-pixel law from the
        // cell centring of [bdCentredTextAnchor]. A left-justified label pens
        // at [ViHeapObject.labelTextInset] (the 0x021 word's 0x800000 bit:
        // 2 px, else 1 px) inside its bounds.
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
      // Structures and nodes carry their identity in border chrome and icon
      // plates, so neither stamps text. A constant/terminal shows its
      // recovered literal ([bdDrawnConstText]) when one exists, falling back
      // to its recovered label; an undecoded value renders no text.
      final String? text;
      if (object.category == ViObjectKind.structure ||
          object.category == ViObjectKind.node) {
        text = null;
      } else {
        final literal = bdDrawnConstText(object);
        final label = object.label?.trim();
        text = literal ?? (label != null && label.isNotEmpty ? label : null);
      }
      if (text == null) continue;
      final rect = _rectOf(object);
      if (rect.width < 26 || rect.height < 11) continue;
      // A caption/constant inks in the object's decoded foreground colour or a
      // neutral near-black, and pens at the same [ViHeapObject.labelTextInset]
      // a label does: no run this fallback draws registers confidently against
      // a reference, so it has no measured inset of its own.
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

  /// Draws each decoded [ViWire] in heap serialization order of the `0x17`
  /// signals ([ViDiagram.wires] order, preserved by [bdVisibleWires]) — the
  /// order the crossing rule keys off (see `wire_render.dart`: where two wires
  /// cross, the later-serialized signal breaks with a 1 px gap either side of
  /// the earlier wire's ink band).
  ///
  /// Geometry: a wire with a proven absolute polyline ([ViWire.routePoints])
  /// or branch tree ([ViWire.routeTree]) draws it as stored, except that a
  /// terminal segment ending on an icon-stamped node extends under the art —
  /// to where the art becomes opaque on the arrival row/column
  /// ([primIconInkEdge]), falling back to the centre of the stamped art's ink
  /// rect (the node box when no art resolves). A one-anchored walk entering
  /// off-centre extends along [ViWire.routeClosingStep] instead, to the same
  /// ink edge. A wire with no decoded route is not drawn.
  ///
  /// Stroke: the wire-type word's measured render style
  /// ([ViSignalTypeRenderStyle.renderStyle]); the estimate tier
  /// ([renderStyleEstimate]) stands in only for the simple solid/dotted
  /// styles, and wires with neither keep the pre-catalogue laws (array ⇒ 2 px,
  /// scalar boolean ⇒ dotted, else 1 px). Colour precedence is
  /// [bdWireColor]'s; a signal under a disabled frame draws through
  /// [bdDimDisabled].
  void _drawWires(
    Canvas canvas, {
    List<
      (Rect, ({int kind, bool hollow, bool centreDot, bool disabled}), Color)
    >?
    tunnelSquares,
  }) {
    if (wires.isEmpty) return;
    final anchors = _collectWireAnchors();
    final nets = _resolveWireNets(anchors);
    // Segments already drawn by earlier wires (heap serialization order), in
    // integer pixel space — the crossing rule cuts later wires around them.
    final drawn = <_BdWireSeg>[];
    for (final wire in wires) {
      _drawOneWire(
        canvas,
        wire,
        anchors: anchors,
        nets: nets,
        drawn: drawn,
        tunnelSquares: tunnelSquares,
      );
    }
  }

  /// The per-diagram lookups the wire pass resolves once over [objects].
  _BdWireAnchors _collectWireAnchors() {
    // Endpoint-anchor rectangle → recovered terminal colour; the icon-stamped
    // node rects; each node's catalogued output colour ([PrimOp.output]).
    final typedTerminalColors = <int, Color>{};
    final sourceOutputColors = <int, Color>{};
    final iconNodeRects = <Rect>{};
    // Node box → the stamped art's ink bounding box (canvas coords): the
    // measured art edge a fallback-routed endpoint anchors to, since the
    // reference wires run at the art's edge-centre row, not the box's.
    final iconInkRects = <Rect, Rect>{};
    // Node box (canvas coords) → its object, so a wire's into-node closing run
    // can query the art's opaque edge on the exact arrival row.
    final iconNodeObjects = <Rect, ViHeapObject>{};
    // Node-category boxes (canvas coords): the cover set for the
    // fully-under-nodes withhold below. LabVIEW paints nodes over wires, so a
    // polyline every pixel of which lies under node boxes has no visible ink.
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
    // [BdScene.furnitureBounds] in canvas space, for the into-DCO leg trim.
    final furnitureRects = <Rect>[
      for (final bounds in scene.furnitureBounds) _toCanvas(bounds),
    ];
    return (
      typedTerminalColors: typedTerminalColors,
      sourceOutputColors: sourceOutputColors,
      iconNodeRects: iconNodeRects,
      iconInkRects: iconInkRects,
      iconNodeObjects: iconNodeObjects,
      nodeCoverRects: nodeCoverRects,
      furnitureRects: furnitureRects,
    );
  }

  /// Wire-net colour resolution. LabVIEW draws one dataflow wire as a chain
  /// of 0x17 signals joined end to end through tunnels and junction stubs,
  /// every segment inking the same type colour. The authoritative tint lives
  /// on whichever signal touches a resolved terminal (the others' endpoints
  /// are unbounded `0x1d`/`0x15` stubs), so signals union into nets by shared
  /// route endpoints/junctions and each takes its net's best-resolved colour.
  /// Tiers per signal, lowest wins:
  ///   0 typed endpoint-anchor rect ([typedTerminalColors]),
  ///   1 resolved endpoint object ([bdTerminalTypeColor] — carries the
  ///     cluster member tint the anchor map cannot),
  ///   2 the documented output of the primitive under the signal's first
  ///     anchored endpoint ([sourceOutputColors]),
  ///   3 the signal word's element family (the 89.9% estimate tier).
  /// The neutral grey means unresolved at every tier and never propagates.
  Map<int, ({Color? color, bool error})> _resolveWireNets(
    _BdWireAnchors anchors,
  ) {
    final typedTerminalColors = anchors.typedTerminalColors;
    final sourceOutputColors = anchors.sourceOutputColors;
    const unresolvedGrey = Color(0xFF8A8A8A);
    final netParent = <int, int>{
      for (final wire in wires) wire.signalOid: wire.signalOid,
    };
    int netFind(int signalOid) {
      var root = signalOid;
      while (netParent[root] != root) {
        root = netParent[root]!;
      }
      var cursor = signalOid;
      while (netParent[cursor] != root) {
        final next = netParent[cursor]!;
        netParent[cursor] = root;
        cursor = next;
      }
      return root;
    }

    void netUnion(int left, int right) =>
        netParent[netFind(left)] = netFind(right);
    final pointOwner = <int, int>{};
    List<ViPoint> netPointsOf(ViWire wire) => [
      for (final run in [
        if (wire.routePoints case final points? when points.isNotEmpty) points,
        ...?wire.routeTree?.polylines,
      ]) ...[run.first, run.last],
      ...?wire.routeTree?.junctions,
    ];
    for (final wire in wires) {
      // Signals join a net where route endpoints/junctions coincide and where
      // they share a decoded attach rect (the two signals either side of one
      // tunnel).
      final keys = [
        for (final point in netPointsOf(wire))
          ((point.x + 0x8000) << 17) | (point.y + 0x8000),
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
        (anchor) => anchor != null,
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
        // Refnum wires ink the same 0x006666 teal as paths.
        // [labviewTypeColor] keeps refnum terminal borders neutral: no
        // reference has measured those yet.
        consider(
          3,
          wordKind == ViTypeKind.refnum
              ? const Color(0xFF006666)
              : labviewTypeColor(wordKind),
        );
      }
    }
    final resolved = <int, ({Color? color, bool error})>{};
    for (final wire in wires) {
      final root = netFind(wire.signalOid);
      resolved[wire.signalOid] = (
        color: netBest[root]?.$2,
        error: netError[root] ?? false,
      );
    }
    return resolved;
  }

  /// Draws one decoded [wire]: its endpoint chrome, the legs its stored route
  /// resolves to, the crossing-cut strokes, and its branch dots.
  void _drawOneWire(
    Canvas canvas,
    ViWire wire, {
    required _BdWireAnchors anchors,
    required Map<int, ({Color? color, bool error})> nets,
    required List<_BdWireSeg> drawn,
    required List<
      (Rect, ({int kind, bool hollow, bool centreDot, bool disabled}), Color)
    >?
    tunnelSquares,
  }) {
    final tunnels = _wireTunnelChrome(wire);
    // The signal takes its net's best-resolved colour; an unresolved net
    // keeps the neutral wire dark. Braid (depth-3 cluster) special case: an
    // error net, or a braid net with no resolution at all (the corpus'
    // unresolved braids are the error chains), draws the dark-yellow error
    // palette — olive flanks plus a yellow/black weave, its tunnels filling
    // the flank olive.
    final net = nets[wire.signalOid]!;
    var color = net.color ?? kBdWireColor;
    var errorBraid = false;
    if (wire.signalType?.renderStyle == ViWireRenderStyle.braid) {
      errorBraid =
          net.error || net.color == null || color == const Color(0xFF666600);
      if (errorBraid) color = const Color(0xFF666600);
    }
    final wireDisabled = disabledOids.contains(wire.signalOid);
    if (wireDisabled) color = bdDimDisabled(color);
    // Chrome is collected whenever its position is decoded, even when no
    // route can be drawn, and painted after the structure chrome (LabVIEW
    // draws the terminal over the band). A terminal inside a disabled frame
    // dims even when the wire's own signal is outside it.
    tunnelSquares?.addAll([
      for (final (tunnelRect, info) in tunnels)
        (
          tunnelRect,
          info,
          info.disabled && !wireDisabled ? bdDimDisabled(color) : color,
        ),
    ]);
    // Leg polylines: the proven absolute polyline when the parse shipped
    // one, drawn as-is.
    final routePoints = wire.routePoints;
    final routeTree = wire.routeTree;
    final legs = <List<Offset>>[];
    final junctions = <Offset>[];
    // Whether the straight-stub tier below may draw this wire: no decoded
    // route shipped, or the shipped polyline was withheld as fully covered
    // by node boxes, leaving only the seam between the adjacent nodes' art
    // — exactly what the stub tier draws from the ink edges.
    var stubEligible = routeTree == null && routePoints == null;
    if (routeTree != null) {
      // A proven branching tree ([ViWire.routeTree]): every run drawn
      // origin-relative with a branch dot at each junction, through the same
      // stroke and crossing-gap machinery as any other leg. Its endpoints
      // are decoded attach points, so the attach-rect pass owns their
      // chrome.
      for (final run in routeTree.polylines) {
        legs.add([
          for (final point in run)
            Offset(point.x - origin.dx, point.y - origin.dy),
        ]);
      }
      for (final junction in routeTree.junctions) {
        junctions.add(Offset(junction.x - origin.dx, junction.y - origin.dy));
      }
    } else if (routePoints != null) {
      final points = _resolvedRoutePolyline(wire, routePoints, anchors);
      // Withhold a polyline with no visible box-level ink: every pixel under
      // a node box ([anchors.nodeCoverRects]) is painted over by node art. A
      // withheld 2-point wire falls through to the straight-stub tier, which
      // draws the seam ink between the adjacent nodes' art edges.
      if (points.length >= 2) {
        if (!_polylineUnderNodes(points, anchors.nodeCoverRects)) {
          legs.add(points);
        } else {
          stubEligible = true;
        }
      }
    } else if (wire.branchRoute != null && wire.endpointOids.length >= 3) {
      // A branching table whose origin is a catalogued prim terminal
      // ([bdPrimTerminalOf], both axes) with no endpoint resolving a
      // standard attach: the stored tree decodes off that origin and ships
      // only when every walked leaf lands exactly on its own endpoint's
      // catalogued terminal or [ViDiagram.dcoChildTerminalAttach] candidate.
      // Leaves sit under their nodes' art.
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
            remaining.update(leaf, (count) => count + 1, ifAbsent: () => 1);
          }
          for (
            var endpointIndex = 1;
            endpointIndex < wire.endpointOids.length;
            endpointIndex++
          ) {
            final oid = wire.endpointOids[endpointIndex];
            final term = bdPrimTerminalOf(scene.diagram, oid);
            ViPoint? match;
            for (final candidate in [
              if (term?.x != null && term?.y != null) (x: term!.x!, y: term.y!),
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
              for (final point in run)
                Offset(point.x - origin.dx, point.y - origin.dy),
            ]);
          }
          for (final junction in tree.junctions) {
            junctions.add(
              Offset(junction.x - origin.dx, junction.y - origin.dy),
            );
          }
        }
      }
    }
    // Stub tiers: each draws only where no earlier tier resolved a leg.
    if (stubEligible) {
      if (legs.isEmpty) _straightStubLeg(wire, legs);
      if (legs.isEmpty) _threePointStubLeg(wire, legs);
      if (legs.isEmpty) _walkedRouteLeg(wire, legs);
      if (legs.isEmpty) _coveredAttachWalkLeg(wire, legs);
      if (legs.isEmpty) _containerFaceLeg(wire, legs);
    }
    // A wire with no decoded route is not drawn: only its endpoint chrome,
    // collected above, appears. Stroke style: the measured tier first, then
    // the estimate tier for the simple solid/dotted styles only, then the
    // pre-catalogue laws (array ⇒ 2 px, scalar boolean ⇒ dotted, else 1 px).
    final style = _wireStrokeStyle(wire);
    final fill = _solidNoAa(color);
    _strokeWireLegs(
      canvas,
      fill,
      style,
      legs,
      junctions,
      drawn,
      errorBraid: errorBraid,
    );
    // Branch dots sit on top of the wire's own runs in the same colour;
    // terminal features, not crossing segments, so they stay out of [drawn].
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

  /// [wire]'s endpoints that carry a decoded border-terminal attach rect,
  /// paired with the chrome kind catalogued at it.
  List<(Rect, ({int kind, bool hollow, bool centreDot, bool disabled}))>
  _wireTunnelChrome(ViWire wire) {
    // Endpoints with a decoded attach rect get their border-terminal chrome
    // drawn at it. A wire's body comes from its decoded route
    // ([ViWire.routePoints] / [ViWire.routeTree]) alone.
    final tunnels =
        <(Rect, ({int kind, bool hollow, bool centreDot, bool disabled}))>[];
    for (
      var endpointIndex = 0;
      endpointIndex < wire.endpointAnchors.length;
      endpointIndex++
    ) {
      final anchor = wire.endpointAnchors[endpointIndex];
      if (anchor == null) continue;
      // A zero-area anchor is an endpoint whose nearest bounded owner is a
      // degenerate wire-segment stub — no chrome to place there.
      if (anchor.width <= 0 && anchor.height <= 0) continue;
      final attach = endpointIndex < wire.endpointAttachRects.length
          ? wire.endpointAttachRects[endpointIndex]
          : null;
      if (attach == null) continue;
      final attachRect = _toCanvas(attach);
      final info = borderTerminalKinds[attach];
      if (info != null) tunnels.add((attachRect, info));
    }
    return tunnels;
  }

  /// [wire]'s proven absolute polyline ([ViWire.routePoints]) in canvas
  /// coordinates, with the head slack resolved, catalogued terminals
  /// re-anchored, icon-stamped ends run under the art, and value-display ends
  /// trimmed to their window chrome.
  List<Offset> _resolvedRoutePolyline(
    ViWire wire,
    List<ViPoint> routePoints,
    _BdWireAnchors anchors,
  ) {
    final points = [
      for (final point in routePoints)
        Offset(point.x - origin.dx, point.y - origin.dy),
    ];
    // A proven polyline connects at its decoded attach point on the
    // endpoint's own border. Where that endpoint is an icon-stamped node,
    // LabVIEW draws the wire under the art, so the terminal segment
    // extends into the icon and the art masks the covered interior.
    if (points.length >= 2 && wire.endpointAnchors.length >= 2) {
      final slack = wire.routeHeadSlack;
      if (slack != null) {
        _slideSlackHead(wire, points, slack);
      } else {
        _reanchorPolyline(wire, points, anchors);
      }
      final sinkBox = points.isEmpty
          ? null
          : _iconBoxOfEndpoint(
              wire,
              wire.endpointAnchors.length - 1,
              anchors.iconNodeRects,
            );
      if (sinkBox != null) {
        _extendIntoSinkIcon(wire, points, sinkBox, anchors);
      }
    }
    // A leg end attached inside a value-display endpoint (a numeric or
    // array constant) shows no ink before the display's opaque window
    // chrome: the stored attach point sits under the control's transparent
    // label gap, where the reference is white. The end slides forward
    // along its own segment to the first furniture (`0x9`/`0xe0`) rect
    // edge inside the anchor; an anchor with no furniture on the segment
    // is left exact.
    if (points.length >= 2 && wire.endpointAnchors.length >= 2) {
      _trimEndToFurniture(wire, points, anchors, head: true);
      _trimEndToFurniture(wire, points, anchors, head: false);
    }
    return points;
  }

  /// [wire]'s endpoint anchor at [endpointIndex] as a canvas rect, when that
  /// rect is an icon-stamped node box.
  Rect? _iconBoxOfEndpoint(
    ViWire wire,
    int endpointIndex,
    Set<Rect> iconNodeRects,
  ) {
    final anchor = wire.endpointAnchors[endpointIndex];
    if (anchor == null) return null;
    final box = Rect.fromLTRB(
      anchor.left - origin.dx,
      anchor.top - origin.dy,
      anchor.right - origin.dx,
      anchor.bottom - origin.dy,
    );
    return iconNodeRects.contains(box) ? box : null;
  }

  /// A slack-headed walk ([ViWire.routeHeadSlack]): the stored
  /// lengths measure from the head prim's own terminal, a builtin
  /// position the file does not carry, so the walk placed the head on
  /// the prim's border and left the slack-axis coordinate free.
  /// Resolve it from [bdPrimTerminalOf] by sliding every point but
  /// the anchored tail. An uncatalogued terminal is not drawn.
  void _slideSlackHead(ViWire wire, List<Offset> points, ViStep slack) {
    final terminal = bdPrimTerminalOf(scene.diagram, wire.endpointOids[0]);
    final terminalX = terminal?.x, terminalY = terminal?.y;
    final head = points.first;
    // The catalog entry must agree with the walk's fixed
    // perpendicular coordinate, and the slide must run along the
    // shipped interior-ward step: a contrary slide means the resolved
    // terminal is wrong, and would shorten or invert the closing run.
    final slide = slack.dx != 0
        ? (terminalX == null ? null : terminalX - origin.dx - head.dx)
        : (terminalY == null ? null : terminalY - origin.dy - head.dy);
    final resolved =
        terminalX != null &&
        terminalY != null &&
        slide != null &&
        slide * (slack.dx + slack.dy) >= 0 &&
        (slack.dx != 0
            ? (head.dy + origin.dy).round() == terminalY
            : (head.dx + origin.dx).round() == terminalX);
    if (!resolved) {
      points.clear();
    } else {
      final delta = slack.dx != 0 ? Offset(slide, 0) : Offset(0, slide);
      for (var index = 0; index < points.length - 1; index++) {
        points[index] = points[index] + delta;
      }
    }
  }

  /// A polyline closed onto a [ViDiagram.dcoChildTerminalAttach]
  /// candidate whose prim terminal is catalogued at both axes
  /// re-anchors: the whole polyline translates so that endpoint sits
  /// on the catalogued terminal, which outranks the candidate
  /// convention. Two catalogued ends demanding different translations
  /// contradict, and the wire is withheld.
  void _reanchorPolyline(
    ViWire wire,
    List<Offset> points,
    _BdWireAnchors anchors,
  ) {
    Offset? reanchor;
    var reanchorConflict = false;
    if (wire.endpointOids.length == 2) {
      for (final (endpointIndex, point) in [
        (0, points.first),
        (1, points.last),
      ]) {
        final oid = wire.endpointOids[endpointIndex];
        if (scene.diagram.wireAttachPoint(oid) != null) continue;
        final abs = (
          x: (point.dx + origin.dx).round(),
          y: (point.dy + origin.dy).round(),
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
      for (var index = 0; index < points.length; index++) {
        points[index] = points[index] + reanchor;
      }
    }
    final sourceBox = _iconBoxOfEndpoint(wire, 0, anchors.iconNodeRects);
    if (points.length >= 2 && sourceBox != null) {
      final inkCentre = (anchors.iconInkRects[sourceBox] ?? sourceBox).center;
      final head = points.first, next = points[1];
      points[0] = head.dy == next.dy
          ? Offset(inkCentre.dx, head.dy)
          : Offset(head.dx, inkCentre.dy);
    }
  }

  /// Runs [points]' sink end under the art stamped on [sinkBox], to where the
  /// art becomes opaque on the arrival row/column ([primIconInkEdge]).
  void _extendIntoSinkIcon(
    ViWire wire,
    List<Offset> points,
    Rect sinkBox,
    _BdWireAnchors anchors,
  ) {
    final ink = anchors.iconInkRects[sinkBox] ?? sinkBox;
    final closing = wire.routeClosingStep;
    if (closing != null) {
      // The polyline ends at the last decoded bend inside the node;
      // the implied closing run enters along [ViWire.routeClosingStep]
      // at the wire's own input row, not the box centre. Extend from
      // that bend along the closing axis to where the art becomes
      // opaque on the arrival row ([primIconInkEdge]), falling back to
      // the ink-box edge when the row carries no masked art.
      final last = points.last;
      final farObj = anchors.iconNodeObjects[sinkBox];
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
      // The closing run steps from the bend in the closing direction.
      // An edge behind the bend means the run lies entirely under
      // opaque art and adds no visible ink; extending to it would drag
      // a stroke backwards across the art and out the far side.
      final along =
          (target.dx - last.dx) * closing.dx +
          (target.dy - last.dy) * closing.dy;
      if (along > 0) points.add(target);
    } else {
      // The closing run reached the box edge: run on under the art to
      // where it becomes opaque on the arrival row/column
      // ([primIconInkEdge]) and no further — the reference leaves the
      // art's transparent cells white, so overrunning to the icon
      // centre paints ink LabVIEW never shows. Falls back to the
      // icon-ink centre when the line carries no masked art.
      final inkCentre = ink.center;
      final last = points.last, prior = points[points.length - 2];
      final farObj = anchors.iconNodeObjects[sinkBox];
      if (last.dy == prior.dy) {
        final edge = farObj == null
            ? null
            : primIconInkEdge(
                farObj,
                horizontal: true,
                cross: (last.dy + origin.dy).round(),
                sign: last.dx >= prior.dx ? 1 : -1,
              );
        points[points.length - 1] = Offset(
          edge != null ? edge - origin.dx : inkCentre.dx,
          last.dy,
        );
      } else {
        final edge = farObj == null
            ? null
            : primIconInkEdge(
                farObj,
                horizontal: false,
                cross: (last.dx + origin.dx).round(),
                sign: last.dy >= prior.dy ? 1 : -1,
              );
        points[points.length - 1] = Offset(
          last.dx,
          edge != null ? edge - origin.dy : inkCentre.dy,
        );
      }
    }
  }

  /// Slides the head (or tail) end of [points] forward along its own segment
  /// to the first furniture rect edge inside its endpoint anchor.
  void _trimEndToFurniture(
    ViWire wire,
    List<Offset> points,
    _BdWireAnchors anchors, {
    required bool head,
  }) {
    final index = head ? 0 : wire.endpointAnchors.length - 1;
    final anchor = wire.endpointAnchors[index];
    if (anchor == null || anchor.width <= 0 || anchor.height <= 0) {
      return;
    }
    final anchorRect = _toCanvas(anchor);
    if (anchors.iconNodeRects.contains(anchorRect)) return;
    final end = head ? points.first : points.last;
    final next = head ? points[1] : points[points.length - 2];
    if (!anchorRect.contains(end)) return;
    final horizontal = end.dy == next.dy;
    if (!horizontal && end.dx != next.dx) return;
    final sign = horizontal ? (next.dx - end.dx).sign : (next.dy - end.dy).sign;
    if (sign == 0) return;
    double? best;
    for (final furniture in anchors.furnitureRects) {
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
          ((horizontal ? next.dx : next.dy) - (horizontal ? end.dx : end.dy)) *
          sign;
      if (along <= 0 || along > limit) continue;
      if (best == null ||
          along < (best - (horizontal ? end.dx : end.dy)) * sign) {
        best = near;
      }
    }
    if (best == null) return;
    final trimmed = horizontal ? Offset(best, end.dy) : Offset(end.dx, best);
    if (head) {
      points[0] = trimmed;
    } else {
      points[points.length - 1] = trimmed;
    }
  }

  /// A straight 2-point route between undecoded attach points: one implied
  /// segment at the endpoints' shared terminal row/column, of which only the
  /// gap between the two nodes' ink is visible. The cross coordinate comes from
  /// a decoded attach rect or a catalogued builtin terminal
  /// ([bdPrimTerminalOf]), every determinable end agreeing; each visible bound
  /// comes from the adjacent node's art ink edge on that row
  /// ([primIconInkEdge]) or the attach rect's border. An end resolving neither
  /// way is not drawn.
  void _straightStubLeg(ViWire wire, List<List<Offset>> legs) {
    if (wire.route?.pointCount != 2 ||
        wire.route?.direction == null ||
        wire.endpointOids.length != 2 ||
        wire.endpointAttachRects.length < 2) {
      return;
    }
    final dir = wire.route!.direction!;
    final horizontal = dir.dy == 0;
    final crossCandidates = <int>{};
    for (var endpointIndex = 0; endpointIndex < 2; endpointIndex++) {
      final attach = wire.endpointAttachRects[endpointIndex];
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
          wire.endpointOids[endpointIndex],
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
      final lowBound = _stubVisibleBound(
        wire,
        lowEnd,
        horizontal: horizontal,
        cross: cross,
        lowSide: true,
      );
      final highBound = _stubVisibleBound(
        wire,
        1 - lowEnd,
        horizontal: horizontal,
        cross: cross,
        lowSide: false,
      );
      if (lowBound != null && highBound != null && lowBound <= highBound) {
        legs.add(
          horizontal
              ? [
                  Offset(lowBound - origin.dx, cross - origin.dy),
                  Offset(highBound - origin.dx, cross - origin.dy),
                ]
              : [
                  Offset(cross - origin.dx, lowBound - origin.dy),
                  Offset(cross - origin.dx, highBound - origin.dy),
                ],
        );
      }
    }
  }

  /// The coordinate at which a straight stub's ink becomes visible past
  /// [wire]'s endpoint [endpointIndex], travelling along the [horizontal] axis
  /// on row/column [cross]: the endpoint's attach-rect border, else the owning
  /// node's art ink edge ([primIconInkEdge]), else its plain box border.
  /// [lowSide] picks the end at the run's low-coordinate side. Null when the
  /// endpoint resolves none of the three.
  int? _stubVisibleBound(
    ViWire wire,
    int endpointIndex, {
    required bool horizontal,
    required int cross,
    required bool lowSide,
  }) {
    final attach = wire.endpointAttachRects[endpointIndex];
    if (attach != null &&
        attach.right > attach.left &&
        attach.bottom > attach.top) {
      return horizontal
          ? (lowSide ? attach.right : attach.left - 1)
          : (lowSide ? attach.bottom : attach.top - 1);
    }
    final dco = scene.diagram.byId[wire.endpointOids[endpointIndex]];
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
    // A node drawn as a plain box (no icon art resolved) covers its interior
    // with the box chrome, so the wire's visible ink ends at the 1 px border,
    // provided the arrival row lies inside the box.
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

  /// A 3-point route table anchored at one decoded attach rect, with a
  /// plain prim DCO at the other end. Three resolutions, tried in order,
  /// each requiring arrival equality or containment:
  ///
  ///  1. Attach-origin onto a catalogued terminal: the walk starts at the
  ///     attach centre and its closing run's arrival coordinate must
  ///     equal the far prim's catalogued cross coordinate
  ///     ([bdPrimTerminalOf]); visible from the anchor border to the far
  ///     node's art ink edge.
  ///  2. Prim-origin onto the attach: the table is stored from the prim's
  ///     terminal instead, so the catalogued coordinate walked through
  ///     the first segment must equal the attach's centre cross and the
  ///     closing sign must point from the prim's box toward the attach;
  ///     visible from the prim's art ink edge to the attach border, the
  ///     origin jog under the art.
  ///  3. Attach-origin with the far terminal uncatalogued but the walked
  ///     bend landing inside the far node's box: the closing run and
  ///     terminal sit under the node, whose art overdraws the covered
  ///     interior, so the visible ink ends at the node's art edge.
  void _threePointStubLeg(ViWire wire, List<List<Offset>> legs) {
    if (wire.route?.pointCount != 3 ||
        wire.route?.direction == null ||
        wire.route!.segmentLengths.length != 1 ||
        wire.endpointOids.length != 2 ||
        wire.endpointAttachRects.length < 2) {
      return;
    }
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
      final terminal = bdPrimTerminalOf(scene.diagram, wire.endpointOids[head]);
      final headObj = scene.diagram.byId[wire.endpointOids[head]];
      final headOwner = headObj?.parentOid == null
          ? null
          : scene.diagram.byId[headObj!.parentOid!];
      final headBox = headOwner?.absBounds;
      final closingSign = bdRouteClosingSign(route, dir);
      if (headOwner == null || headBox == null) break;
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
      // Prim-origin: the first segment departs the prim's terminal, so its
      // axis coordinate is the catalogued one walked by the stored length.
      final primCoord = dir.dx == 0 ? terminal?.y : terminal?.x;
      if (primCoord != null) {
        final closingCross =
            primCoord + (dir.dx + dir.dy) * route.segmentLengths[0];
        final attachCross = dir.dx == 0 ? start.y : start.x;
        // The closing sign must carry the run off the prim's box toward
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

  /// A full stored route departing a catalogued prim terminal
  /// ([bdPrimTerminalOf], both axes) with no decoded attach at that end:
  /// every stored segment walks off that origin, and the implied closing
  /// run's arrival coordinate must equal the far end's independently
  /// known cross coordinate — a decoded attach rect's centre row/column,
  /// the far prim's catalogued terminal, or its [dcoChildTerminalAttach]
  /// candidate. The closing run ends at the far attach rect's border or
  /// at the far node's art ink edge ([primIconInkEdge], plain box border
  /// when no art resolves).
  void _walkedRouteLeg(ViWire wire, List<List<Offset>> legs) {
    if (wire.routePoints != null ||
        (wire.route?.pointCount ?? 0) < 3 ||
        wire.route?.direction == null ||
        wire.route!.segmentLengths.length != wire.route!.pointCount - 2 ||
        wire.endpointOids.length != 2) {
      return;
    }
    final route = wire.route!;
    final headTerminal = bdPrimTerminalOf(scene.diagram, wire.endpointOids[0]);
    final headAttach = wire.endpointAttachRects[0];
    if (headTerminal?.x != null &&
        headTerminal?.y != null &&
        (headAttach == null ||
            headAttach.right <= headAttach.left ||
            headAttach.bottom <= headAttach.top)) {
      final walk = walkRouteBends(
        route,
        origin: (x: headTerminal!.x!, y: headTerminal.y!),
      )!;
      final bends = walk.points;
      final lastBend = bends.last;
      final closingHorizontal = walk.closingHorizontal;
      final closingSign = walk.closingSign;
      final arrivalCross = closingHorizontal ? lastBend.y : lastBend.x;
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
          for (final candidate
              in scene.diagram
                      .dcoChildTerminalAttach(wire.endpointOids[1])
                      ?.candidates ??
                  const <ViPoint>[]) {
            final cross = closingHorizontal ? candidate.y : candidate.x;
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
          (terminus - (closingHorizontal ? lastBend.x : lastBend.y)) *
                  closingSign >=
              0) {
        legs.add([
          for (final bend in bends)
            Offset(bend.x - origin.dx, bend.y - origin.dy),
          closingHorizontal
              ? Offset(terminus - origin.dx, lastBend.y - origin.dy)
              : Offset(lastBend.x - origin.dx, terminus - origin.dy),
        ]);
      }
    }
  }

  /// Attach-origin covered walk: the full stored table departs a decoded
  /// attach rect toward a far prim with no decoded attach, every walked
  /// bend staying inside that rect, so the origin jogs under the
  /// terminal's own chrome and only the closing run's tail is visible.
  /// Ships when the arrival coordinate equals the far prim's catalogued
  /// terminal cross coordinate ([bdPrimTerminalOf]) and the run exits the
  /// rect toward the far node; visible from the attach rect's border to
  /// the far node's art ink edge ([primIconInkEdge]).
  void _coveredAttachWalkLeg(ViWire wire, List<List<Offset>> legs) {
    if (wire.routePoints != null ||
        (wire.route?.pointCount ?? 0) < 4 ||
        wire.route?.direction == null ||
        wire.route!.segmentLengths.length != wire.route!.pointCount - 2 ||
        wire.endpointOids.length != 2 ||
        wire.endpointAttachRects.length < 2) {
      return;
    }
    final route = wire.route!;
    for (final (tail, head) in [(0, 1), (1, 0)]) {
      final attach = wire.endpointAttachRects[tail];
      if (attach == null ||
          attach.right <= attach.left ||
          attach.bottom <= attach.top) {
        continue;
      }
      if (wire.endpointAttachRects[head] != null) continue;
      final walk = walkRouteBends(
        route,
        origin: (
          x: attach.left + (attach.right - attach.left) ~/ 2,
          y: attach.top + (attach.bottom - attach.top) ~/ 2,
        ),
      )!;
      var covered = true;
      for (var index = 1; index < walk.points.length; index++) {
        final bend = walk.points[index];
        covered =
            covered &&
            bend.x >= attach.left &&
            bend.x < attach.right &&
            bend.y >= attach.top &&
            bend.y < attach.bottom;
      }
      if (!covered) break;
      final lastBend = walk.points.last;
      final closingHorizontal = walk.closingHorizontal;
      final closingSign = walk.closingSign;
      final arrivalCross = closingHorizontal ? lastBend.y : lastBend.x;
      final terminal = bdPrimTerminalOf(scene.diagram, wire.endpointOids[head]);
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

  /// Container-face run: one endpoint resolves an exact border-terminal
  /// attach (a tunnel-family rect; every catalogued kind fits 16 px), the
  /// other a large container face (an array-block value rect, tens of px
  /// a side). The stored route closes onto the exact attach, so the
  /// closing run's cross coordinate is that attach's own — the
  /// container's centre is not its connection point. Ships when the cross
  /// lies within the container's span, the rects are disjoint along the
  /// closing axis, and the closing sign carries the run from the
  /// container to the attach; a longer table's interior bends jog on the
  /// container's side, so the stored first segment must point into it.
  void _containerFaceLeg(ViWire wire, List<List<Offset>> legs) {
    if (wire.route?.direction == null ||
        wire.endpointOids.length != 2 ||
        wire.endpointAttachRects.length < 2) {
      return;
    }
    const exactMax = 16, containerMin = 17;
    final route = wire.route!;
    final dir = route.direction!;
    final closingHorizontal = route.pointCount == 2
        ? dir.isHorizontal
        : (route.pointCount.isEven ? dir.isHorizontal : !dir.isHorizontal);
    // A 3+-point table carrying no joint signs disagrees with its own
    // point count, so no closing direction is stored; 0 is not a sign and
    // rejects the run below rather than assuming one.
    final closingSign = route.pointCount > 2 && route.jointSigns.isEmpty
        ? 0
        : bdRouteClosingSign(route, dir);
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
      if (container.width < containerMin || container.height < containerMin) {
        continue;
      }
      final attachPoint = scene.diagram.wireAttachPoint(
        wire.endpointOids[exactEnd],
      );
      if (attachPoint == null) continue;
      // Travel sign from the container face to the exact attach along
      // the closing axis, from the rects' disjoint order.
      final int toExact, cross, faceLo, faceHi;
      if (closingHorizontal) {
        cross = attachPoint.y;
        if (cross <= container.top || cross >= container.bottom) continue;
        if (container.right <= exact.left) {
          toExact = 1;
          faceLo = container.right;
          faceHi = exact.left - 1;
        } else if (exact.right <= container.left) {
          toExact = -1;
          faceLo = exact.right;
          faceHi = container.left - 1;
        } else {
          continue;
        }
      } else {
        cross = attachPoint.x;
        if (cross <= container.left || cross >= container.right) continue;
        if (container.bottom <= exact.top) {
          toExact = 1;
          faceLo = container.bottom;
          faceHi = exact.top - 1;
        } else if (exact.bottom <= container.top) {
          toExact = -1;
          faceLo = exact.bottom;
          faceHi = container.top - 1;
        } else {
          continue;
        }
      }
      // An n==2 table's sign runs endpoint 0 -> 1; a longer table's
      // closing sign runs container -> exact.
      final wantSign = route.pointCount == 2
          ? (exactEnd == 0 ? -toExact : toExact)
          : toExact;
      if (closingSign != wantSign || faceLo > faceHi) continue;
      // An array-shell container's box edge is not chrome: the shell draws
      // only its wrap frames ([bdArrayShellWrapRects]) plus the
      // index/label furniture, and the label band is bare canvas, so the
      // run's ink continues past the box edge until it touches the wrap
      // spanning its cross coordinate. Containers that are not drawn array
      // shells keep their box face.
      var runLo = faceLo, runHi = faceHi;
      for (final shell in scene.drawable) {
        final bounds = shell.absBounds;
        if (shell.objectClass != HeapObjectClass.caseOrSequence ||
            bounds == null ||
            bounds.left != container.left ||
            bounds.top != container.top ||
            bounds.right != container.right ||
            bounds.bottom != container.bottom) {
          continue;
        }
        // The first opaque chrome the ink meets travelling from the exact
        // attach: the outermost candidate wins, so a nested frame never
        // stops the run early.
        int? face;
        for (final wrap in bdArrayShellWrapRects(scene.diagram, shell.oid)) {
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

  /// [wire]'s stroke style: the measured tier first, then the estimate tier
  /// for the simple solid/dotted styles only, then the pre-catalogue laws
  /// (array ⇒ 2 px, scalar boolean ⇒ dotted, else 1 px).
  ViWireRenderStyle _wireStrokeStyle(ViWire wire) {
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
    return style;
  }

  /// Strokes every segment of [legs], cutting the crossing gaps the measured
  /// rule opens over the earlier-wire segments in [drawn], and appends this
  /// wire's own segments to [drawn] once the whole wire is stroked.
  void _strokeWireLegs(
    Canvas canvas,
    Paint fill,
    ViWireRenderStyle style,
    List<List<Offset>> legs,
    List<Offset> junctions,
    List<_BdWireSeg> drawn, {
    required bool errorBraid,
  }) {
    final (bandLo, bandHi) = bdWireStrokeBand(style);
    // Appended to [drawn] only after the whole wire, so a wire never gaps
    // against its own bends.
    final mine = <_BdWireSeg>[];
    for (final leg in legs) {
      for (var segmentIndex = 1; segmentIndex < leg.length; segmentIndex++) {
        final start = leg[segmentIndex - 1], end = leg[segmentIndex];
        if (start == end) continue;
        final horizontal = start.dy == end.dy;
        var runLo =
            (horizontal
                    ? math.min(start.dx, end.dx)
                    : math.min(start.dy, end.dy))
                .floor();
        var runHi =
            (horizontal
                    ? math.max(start.dx, end.dx)
                    : math.max(start.dy, end.dy))
                .floor();
        final cross = (horizontal ? start.dy : start.dx).floor();
        // Bend continuity: at a shared vertex the segment also covers the
        // perpendicular partner's ink band, so the two bands fully overlap
        // and the texture masks the whole corner square. The braid is the
        // one exception: its horizontal run owns the corner (flanks and core
        // texture extend over the vertical's band) while the vertical run
        // starts at band+1, below the horizontal band.
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
            if (segmentIndex >= 2) leg[segmentIndex - 2],
            if (segmentIndex + 1 < leg.length) leg[segmentIndex + 1],
          ]) {
            final nCross = (horizontal ? neighbour.dx : neighbour.dy).floor();
            if (nCross + bandLo < runLo) runLo = nCross + bandLo;
            if (nCross + bandHi > runHi) runHi = nCross + bandHi;
          }
        }
        if (style == ViWireRenderStyle.braid && !horizontal) {
          for (final neighbour in [
            if (segmentIndex >= 2) leg[segmentIndex - 2],
            if (segmentIndex + 1 < leg.length) leg[segmentIndex + 1],
          ]) {
            final nCross = (horizontal ? neighbour.dx : neighbour.dy).floor();
            if ((nCross - runLo).abs() <= 1) runLo = nCross + 2;
            if ((runHi - nCross).abs() <= 1) runHi = nCross - 2;
          }
        }
        // A braid elbow's outer wall is continuous: the cell where the
        // vertical's far flank column (away from the horizontal run) meets
        // the route row inks even where the core texture would hole it,
        // while the mirrored near-side cell stays a texture hole. Junction
        // blobs own their measured art instead.
        if (style == ViWireRenderStyle.braid && horizontal) {
          for (final (vertex, other) in [
            if (segmentIndex >= 2) (start, end),
            if (segmentIndex + 1 < leg.length) (end, start),
          ]) {
            final bendX = vertex.dx.floor();
            final farX = bendX - (other.dx > vertex.dx ? 1 : -1);
            final isJunction = junctions.any(
              (junction) =>
                  junction.dx.floor() == bendX && junction.dy.floor() == cross,
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
        // this later-drawn segment properly crosses an earlier wire's
        // perpendicular segment, it skips a 1 px gap either side of the
        // earlier stroke's ink band. Endpoint touches are not crossings.
        final gaps = <(int, int)>[];
        for (final earlier in drawn) {
          if (earlier.horizontal == horizontal) continue;
          if (earlier.bandLo > runLo &&
              earlier.bandHi < runHi &&
              cross + bandLo > earlier.lo &&
              cross + bandHi < earlier.hi) {
            gaps.add((earlier.bandLo - 1, earlier.bandHi + 1));
          }
        }
        _strokeSegment(
          canvas,
          fill,
          style,
          horizontal,
          runLo,
          runHi,
          cross,
          gaps,
          errorBraid: errorBraid,
        );
        mine.add((
          horizontal: horizontal,
          lo: runLo,
          hi: runHi,
          bandLo: cross + bandLo,
          bandHi: cross + bandHi,
        ));
      }
    }
    drawn.addAll(mine);
  }

  /// A flat sequence's film-strip border, byte-measured: 10 px top/bottom
  /// bands — 1 px black outer edge, (221,221,221) grey, a 6-row sprocket strip
  /// of 6 px-wide black-outlined white holes on a 12 px period starting at
  /// left+9, grey, 1 px black inner edge — 6 px side bands whose outer two
  /// columns weave a 2×2 black/grey checker on absolute row pairs, and a 7 px
  /// black/grey/black divider at each inter-frame boundary (the cumulative
  /// 0x121 frame widths).
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
    // Side bands. The woven checker columns and grey mid columns run the full
    // height (t+1 .. b-1), through the corner rows and over the bands' inner
    // border rows, so the border reads interrupted where they cross it. Only
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
      // corner, clipped by the woven columns — a white sliver with its black
      // border, stamped over the checker.
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
      // pokes 1px through each band's inner border row, the divider's black
      // edges carrying the border's line across as the visible seam.
      var cum = 0.0;
      final frames = scene.diagram
          .children(seq.oid)
          .where(
            (c) =>
                c.objectClass == HeapObjectClass.bdSequenceFrame &&
                c.absBounds != null,
          )
          .toList();
      for (var i = 0; i + 1 < frames.length; i++) {
        cum += frames[i].absBounds!.right - frames[i].absBounds!.left;
        px(blackFill, l + cum - 6, innerTop, 1, sideH);
        px(greyFill, l + cum - 5, innerTop - 1, 5, sideH + 2);
        px(blackFill, l + cum, innerTop, 1, sideH);
      }
    }
  }

  /// An array constant's drawn furniture. Wrap selection lives in
  /// [bdArrayShellWrapRects], shared with the wire container-face law:
  ///
  ///  * a 1 px border in the element type's colour + opaque white fill at each
  ///    outermost bounded `0x9` wrap part, except one demoted to a grid window
  ///    by containing a `0x50` without being its largest container. A `0x9`
  ///    nested inside a sibling `0x9` draws nothing of its own: its edges are
  ///    covered by the cell rings;
  ///  * the index `0x50`'s value window and its two `0xb` spinner boxes;
  ///  * the element `0x50` tiled as a cell grid — the element's bounds give
  ///    the cell pitch, the smallest `0x9` containing it is the grid window,
  ///    and every cell draws the measured constant-cell chrome
  ///    ([_drawArrayCell]), adjacent 3 px rings unioning into the observed
  ///    4 px double walls. Cells beyond the decoded element count draw the
  ///    dimmed style.
  void _drawArrayConstantShell(Canvas canvas, ViHeapObject shell) {
    final children = scene.diagram.children(shell.oid).toList();
    ViTypeKind elementType = ViTypeKind.unknown;
    ViHeapObject? element;
    for (final c in children) {
      if (c.objectClass != HeapObjectClass.numericControl) continue;
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
    // Outermost wrap fills+borders first: the index/element furniture paints
    // over the opaque wrap, whatever the heap child order. The wrap masks a
    // wire attaching under the array, whose ink starts at the wrap border.
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
      if (c.objectClass == HeapObjectClass.numericControl &&
          b != null &&
          !identical(c, element)) {
        for (final part in scene.diagram.children(c.oid)) {
          final pb = part.absBounds;
          if (pb == null) continue;
          if (part.objectClass == HeapObjectClass.controlSubPart ||
              part.objectClass == HeapObjectClass.controlChrome)
            border(pb);
          // The index window shows the array's displayed index
          // ([ViHeapObject.arrayIndex], the tag-`0x15` group value the cell
          // grid also enumerates from) at the text inset window.left+2.
          if (part.objectClass == HeapObjectClass.controlChrome &&
              pb.width >= 10 &&
              pb.height >= 12) {
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
          // The spinner's fat triangle: rows t+2..t+5 at widths 1/3/3/5
          // centred on l+3, the up box's tip on top and the down box's
          // mirrored.
          if (part.objectClass == HeapObjectClass.controlSubPart) {
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
    // The grid window: the smallest 0x9 containing the element prototype. A 1D
    // array stores it at exactly the prototype's rect, one cell; a 2D grid
    // tiles it.
    HeapRect grid = cell;
    var gridArea = 1 << 60;
    for (final c in children) {
      final b = c.absBounds;
      if (c.objectClass != HeapObjectClass.controlChrome ||
          b == null ||
          !contains(b, cell))
        continue;
      final area = b.width * b.height;
      if (area < gridArea) {
        grid = b;
        gridArea = area;
      }
    }
    final cols = math.max(1, grid.width ~/ cellW);
    final rows = math.max(1, grid.height ~/ cellH);
    final holder = scene.diagram.byId[shell.parentOid ?? -1];
    final values = holder?.objectClass == HeapObjectClass.bdConstDco
        ? holder!.constArray
        : null;
    final dims = holder?.objectClass == HeapObjectClass.bdConstDco
        ? holder!.constArrayDims
        : null;
    final format = bdDisplayFormatOf(scene.diagram, element.oid);
    final marker = kBdRadixMarkerGlyphs[bdFormatConversion(format)];
    // The radix part's offset inside its cell, from the prototype's own 0xb
    // child; +2,+3 in every measured array.
    var radixDx = 2, radixDy = 3;
    for (final part in scene.diagram.children(element.oid)) {
      if (part.objectClass == HeapObjectClass.controlSubPart &&
          part.absBounds != null) {
        radixDx = part.absBounds!.left - cell.left;
        radixDy = part.absBounds!.top - cell.top;
      }
    }
    // The visible window starts at the shell's displayed index (the tag-`0x15`
    // value). Multi-dimension index offsets are not yet decoded, so only a 1D
    // window shifts.
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

  /// One array-constant element cell, byte-measured: a 3 px ring in the
  /// element colour whose outer edge sits 1 px outside the cell rect on the
  /// left/top and on its right/bottom edges, white field, the value digits in
  /// AA black, and the radix-marker glyph of a non-decimal display format at
  /// the cell's radix-part corner. A cell past the decoded element count (an
  /// empty array's prototype) keeps the pure ring edge over a [bdDimDisabled]
  /// inner 2 px — (153,153,255) on a blue element — and shows the dimmed
  /// default `0` as a (153,153,153) digit.
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
    // Digits sit left-aligned after the radix zone on the centred line box:
    // decimal at cell.left+3, hex at cell.left+9 past the marker.
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

  /// The branch-junction dot LabVIEW stamps where a wire forks, in the wire's
  /// colour ([fill]). Two measured shapes by stroke [band]: the solid 2 px
  /// band (−1..0) gets a diamond hugging the 2×2 crossing — rows band±2
  /// relative to the junction with widths 2/4/6/6/4/2 anchored on the band
  /// columns, the 6-wide middle rows lying under the wire's own runs — and
  /// every other band gets the 5x5 disc with the corner pixels clipped (row
  /// widths 3/5/5/5/3, centred on the junction pixel). The patterned
  /// multi-row bands are unmeasured and keep the disc.
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
    // All pattern lattices anchor to absolute diagram coordinates; the canvas
    // origin is the interactive view's pan and must not slide them.
    final ox = origin.dx.round(), oy = origin.dy.round();
    final (bandLo, bandHi) = band;
    if (style == ViWireRenderStyle.braid) {
      // Braid junctions, byte-measured from one corpus junction each — the
      // vertical run joins from above for the error braid and leaves below for
      // the pink braid; mirrored topologies reuse the stamp flipped.
      if (errorBraid) {
        // The error wedge: weave-law colours through the 5-wide core (yellow
        // where (x+y+1) mod 4 < 2), black transition rows toward the vertical,
        // olive rim and taper away from it.
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
        // The pink-braid blob: solid taper rows above and below; the weave row
        // keeps the wire's own lattice; the flank rows show the weave's hole
        // classes ((x+y) mod 4 in {0,3}) within one column of the junction and
        // fill solid outside it.
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
    // Whether a blob pixel is punched white by the wire's own global pattern
    // lattice: the reference keeps the stroke lattice through the junction,
    // holing exactly at the cycle's no-ink column.
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

    // Blob geometry: the diamond hugging the stroke band (rows band±2, reach
    // shrinking with distance) serves the solid 2 px wire and the patterned
    // (-1,0)-band styles, whose reference blobs read as the same diamond under
    // their punch lattice. The 1 px styles keep the corner-clipped 5x5 disc.
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
        // Measured across every corpus zigzag junction, zero counterexamples:
        //  * band rows hole the stroke lattice's no-ink column within the
        //    4-wide window dx in [-2, +1] of the junction — one such column
        //    lands per row;
        //  * the first row beyond the band, on both sides, keeps the stroke
        //    lattice through the band columns, whether or not a run continues
        //    there;
        //  * everything else (the outermost taper rows and the reach columns)
        //    fills solid.
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
  /// dotted checkerboard (ink where `x + y` is even, zero counterexamples
  /// across 20 clean corpus runs in both orientations), and the patterned
  /// column cycles ([kBdWireStrokeCycles]). Vertical runs of the multi-row
  /// patterned styles draw a plain 1 px line instead: the census found those
  /// cycles orientation-dependent (vertical string wires compress to a
  /// period-2 cycle) and their vertical forms are not yet measured.
  /// TODO: catalogue the vertical cycles and draw them.
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
    // One model for every patterned stroke: a wire is a colour, a band width,
    // and a global texture the band masks in. The texture anchors to absolute
    // diagram coordinates (plus the capture's screen shift for the string
    // family), so runs, corners, and both orientations are the same texture
    // under different masks — the measured per-orientation cycles, the
    // vertical compressed forms and the bend behaviour all fall out of the
    // masking, with no per-style phase constants. The three textures:
    //  * string family (zigzag / chainLink / chainLinkWide): hole where `x` is
    //    odd and `(x ~/ 2) + y` is odd — a 4-period weave whose 2/3/4-row
    //    masks are exactly the measured cycles and whose 2/3-col masks are the
    //    measured vertical forms;
    //  * braid family (cluster braids): the diagonal 50% texture, ink where
    //    `(x + y) mod 4` is 1 or 2, between solid band-edge rows. The error
    //    braid paints the texture's holes black and its ink yellow between
    //    olive edges — the same lattice with its own palette;
    //  * dotted family: the `(x + y)`-even checkerboard on a 1-row mask; the
    //    2-row mask is the measured alternating-dot form.
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
        // The dense/weave cycles have no texture derivation yet: the
        // catalogued horizontal cycles stand in and vertical runs draw a plain
        // 1 px line. TODO: measure them and fold them into the model.
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

  /// A solid fill of [color] with anti-aliasing off — the pixel-exact chrome
  /// paint, whose hard edges the oracle byte-compares.
  static Paint _solidNoAa(Color color) => Paint()
    ..color = color
    ..isAntiAlias = false;

  /// Paints a batch of 1x1 cells (given as pixel-centre coordinates,
  /// `x + 0.5, y + 0.5, …`) in one canvas call: width-1 square-cap points
  /// rasterise to exactly the pixels a per-cell 1x1 drawRect fill covers,
  /// without the per-cell engine call that dominated large structure bands.
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

  /// Border-terminal chrome at a decoded attach rect, per terminal class,
  /// every spec read from reference pixels:
  ///
  /// - tunnel `0x22` / select `0x2d`: the rect filled with the wire's colour
  ///   under a 1 px [kBdTunnelBorder] ring, over the structure band.
  /// - shift registers `0x27`/`0x28` (16x12): a 2 px wire-colour border, cream
  ///   fill, and a wire-colour 5-row triangle glyph — down (10,8,6,4,2 wide)
  ///   on the left register, up on the right.
  /// - selector `0x2e` (8x12): a 1 px wire-colour border, cream fill, and the
  ///   6x10 `?` glyph.
  ///
  /// A register/selector whose rect differs from the measured size draws
  /// border + fill only; the glyph layout belongs to the measured geometry and
  /// is never scaled.
  ///
  /// A terminal inside a displayed Disabled frame (`info.disabled`) draws its
  /// wire-derived colours through [bdDimDisabled] and its neutral chrome
  /// through the measured disabled mappings: the dark ring becomes the icon
  /// line-work grey ([kBdDisabledChromeGrey]) and the cream fill white.
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
        // Hollow ([kTunnelHollowFlag]): cream interior with a 5x5 wire-colour
        // ring, open at the middle of its top/bottom edges. Solid:
        // wire-colour fill.
        if (info.hollow) {
          canvas.drawRect(t, _solidNoAa(creamColor));
          if (t.width == 9 && t.height == 9) {
            const ring = ['xx.xx', 'x...x', 'x...x', 'x...x', 'xx.xx'];
            _stampBitmap(canvas, noAa, ring, t.left + 2, t.top + 2, on: 'x');
          }
        } else {
          canvas.drawRect(t, noAa);
          // The centre-dot variant ([kTunnelCentreDotFlags]): a 3×3 white
          // centre with a wire-colour dot.
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

  /// The while-loop's rounded corners, measured per-corner: the rounding is
  /// not symmetric — right and bottom round a pixel fuller than left and top.
  /// `#` = grey band pixel, indexed
  /// `[distance-from-cap-edge][distance-from-side-edge]` from the outer
  /// corner. The bottom-right corner is the arrow ([_kWhileArrow]).
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

  /// The rotational arrow in a while-loop's bottom-right corner — the
  /// gap-and-arrowhead marking the frame a while loop. Rows run top→bottom,
  /// the last at the band's bottom row; columns run left→right ending at the
  /// frame's right edge. `#` grey.
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

  /// The while-loop border: a [_kWhileBand]-px mid-grey (0xFF777777) band,
  /// hard-edged so its outer edge is a line the oracle registration locks
  /// onto, with rounded corners and the rotational arrow ([_kWhileArrow]) in
  /// the bottom-right. The interior stays clear; a decoded [tint] only
  /// recolours the band.
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
    // Bottom-right arrow footprint, anchored to the frame's right/bottom edge
    // and excluded from the ring loop so the arrow alone fills it. Its last
    // row is the band's bottom row.
    final aw = _kWhileArrow.first.length, ah = _kWhileArrow.length;
    final ax0 = r - aw, ay0 = b - ah;

    final pts = <double>[];
    void add(int x, int y) => pts
      ..add(x + 0.5)
      ..add(y + 0.5);

    // Only band cells are visited — full rows inside the top/bottom bands, and
    // just the left/right band columns of the middle rows — so the cost is
    // O(perimeter x band), never O(area).
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

  /// Draws a for-loop's border pixel-exact: 1px-black chrome shaped as a stack
  /// of three pages, the top page's bottom-right corner turned up in a
  /// dog-ear. Fixed decoration whose geometry does not vary with the loop's
  /// `N`; no anti-aliasing, no interior wash.
  ///
  /// The back page is the full rectangle `[left, top]..[right-5, bottom-5]`,
  /// but its bottom-right corner is folded: the right and bottom edges stop
  /// [_kForLoopFold] px short and an 8×8 triangular flap (top + left +
  /// diagonal hypotenuse) stands in for the square corner. Two more pages peek
  /// out below-and-right at +2 and +4 px, each contributing only its bottom
  /// edge, right edge, and the corner steps tying it to the page behind — a
  /// 3px horizontal at the top-right and a 1px vertical at the bottom-left.
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

  /// Draws a case/sequence frame's border: a solid 1px black outer rectangle
  /// wrapping a [kBdHatchBand]-px band of the global [kBdStructureHatch]
  /// lattice — or, for an [error] case displaying its "No Error" frame, a
  /// green field striped with the [kBdErrorHatch] lattice. Each lattice is
  /// keyed on absolute diagram coordinates ([absLeft]/[absTop] give the
  /// frame's top-left there) plus its own per-capture offset, so the pattern
  /// is continuous across the diagram. Drawn before the tunnel chrome pass.
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
    // cells are visited, so the cost is O(perimeter x band), never O(area).
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
  /// (rect.left + 2 + col, rect.bottom - 9 + row).
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

  /// Side length (px) of the for-loop's dog-ear corner fold — fixed chrome.
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

  /// The for-loop count `N` and iteration `i` glyphs as LabVIEW rasters them
  /// inside a 16×16 border terminal — 1px cells at box-relative (col,row) from
  /// [origin]. Blue ink on a cream field with a 2px blue border, reproduced
  /// pixel-for-pixel rather than approximated with a font.
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

  /// The while-loop conditional (stop) terminal as LabVIEW rasters it in a
  /// 16×16 border box: a 1px [BdRenderStyle.booleanGreen] ring, cream field,
  /// black octagon outline, red fill. Identical on both capture palettes
  /// modulo the ring green.
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
  /// the T carved in white. The value is the decoded
  /// [ViHeapObject.constBool]. `#` = green.
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

  /// Draws a structure's modeled terminals at their frame-relative boxes, each
  /// with its modeled glyph (`termBMPs`): `i`→1, `N`→2, conditional stop→192,
  /// shift registers→3 (left ▼) / 4 (right ▲), case selector→5.
  ///
  /// A terminal whose box the chrome pass owns ([chromeOwnedRects]) is
  /// skipped: that chrome reproduces the reference byte-for-byte inside the
  /// rect, and this pass's anti-aliased ring would bleed blended pixels just
  /// outside it. [disabled] routes the colours through the measured
  /// disabled-frame transform.
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
      // Count `N` / iteration `i` terminals: a 16×16 blue box with a cream
      // field and a bitmap glyph, pixel-exact.
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
      // The conditional stop terminal at its standard 16×16 box.
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
          // ▼ delivers on the left border, ▲ stores on the right.
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

  /// The case selector's ◄ pager, ▼ dropdown, and ► pager. `#` = black.
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

  /// A small `0x53` cluster container drawn as one box: a double 1px ring in
  /// the cluster's member tint around a white interior, with every nested part
  /// scaffolding-suppressed. A constant cluster (`0x13` holder parent) adds
  /// the measured 13x5 interior glyph at (+5,+6) in the same tint.
  /// TODO: other shells' interior art is not yet decoded.
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
    if (scene.diagram.byId[object.parentOid ?? -1]?.objectClass !=
        HeapObjectClass.bdConstDco) {
      return;
    }
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

  /// Case-selector chrome around the decoded `0x95` label [rect] (the value
  /// text region): the strip extends 8px left and 18px right of it —
  /// `[◄ pager | value … ▼ | ► pager]` — with 1px box borders on the outer
  /// edges, further borders at rect.left / rect.right+10, and the pager and
  /// dropdown bitmaps. The value string is drawn by the text pass.
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
    final dot = Paint()..color = kBdGridDot;
    for (var x = 0.0; x < size.width; x += step) {
      for (var y = 0.0; y < size.height; y += step) {
        canvas.drawCircle(Offset(x, y), 0.5, dot);
      }
    }
  }

  @override
  bool shouldRepaint(covariant BdDiagramPainter old) =>
      // Scene identity covers every diagram-derived input.
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

/// The overlay layer: the selection and declared-member highlight strokes. A
/// few `drawRect`s, so a selection tap repaints this rather than the static
/// object layer. Shares the object→canvas mapping with [BdDiagramPainter].
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
    // Icon-stamped nodes outline the stamped art, not the model box, matching
    // what is drawn and what the alpha hitbox accepts.
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

/// A "label: value" detail row for the selected-object card.
Widget _detail(String label, String value) => Padding(
  padding: const EdgeInsets.only(top: 3),
  // Text.rich, not RichText, so the body inherits the ambient theme colour;
  // the label blue reads on both themes.
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

  /// The logic objects a selected structure contains, listed textually.
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
                    '${kMultiFrameStructureClasses.contains(object.objectClass) ? ' · shows frame ${object.visibleFrameIndex + 1}' : ''}'
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

/// The control-flow outline strip under the diagram toolbar: structures
/// grouped by catalog kind plus the named subVI/function calls. Renders
/// nothing when the diagram has neither.
class _BdOutline extends StatelessWidget {
  const _BdOutline({required this.outline, this.linkedSubVis = const []});
  final ({
    Map<HeapObjectClass, int> structuresByClass,
    List<String> labeledNodes,
    int nodeCount,
    Map<ClassConfidence, int> confidence,
  })
  outline;

  /// The VI's sub-VI dependency names from the LIbd linker block, shown
  /// separately from the heap-derived diagram-labeled nodes.
  final List<String> linkedSubVis;

  @override
  Widget build(BuildContext context) {
    final structs = outline.structuresByClass.entries.toList()
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
                  Text('${entry.key.label} ×${entry.value}', style: muted),
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

/// The VI-identity image strip above the block diagram: this VI's own icon at
/// the richest available depth, captioned with its source tag — what a caller
/// renders on a subVI node. The icons of the subVIs this diagram calls are
/// stamped on their nodes instead (see [ViDiagramView.subViIconResolver]).
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
          // Only the VI icon shows here; other recovered image resources
          // belong to the Images tab. A single fixed-size icon can never
          // overflow this row.
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
