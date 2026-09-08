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

part 'bd_paint_text.dart';
part 'bd_paint_wires.dart';
part 'bd_paint_structures.dart';
part 'bd_paint_nodes.dart';

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

  final List<ViDiagram>? diagrams;

  final String emptyHint;

  final List<String> subViNames;

  final bool isFrontPanel;

  final ViImages viImages;

  final Future<Map<String, ViLegacyIcon>> Function(Set<String> wantedNames)?
  subViIconResolver;

  final List<DecodedSection> sections;

  @override
  State<ViDiagramView> createState() => _ViDiagramViewState();
}

class _ViDiagramViewState extends State<ViDiagramView> {
  final _transform = TransformationController();

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

  bool _shelfOpen = true;

  late final ViDiagram? _diagram = _largestDiagram(widget.diagrams);
  late final Map<int, ViHeapObject> _byId = _diagram?.byId ?? const {};

  Map<int, ViLegacyIcon> _subViIcons = const {};
  Map<int, PrimIconArt> _primIcons = const {};
  Map<int, ui.Image> _xnodeFacades = const {};

  late final BdScene? _scene = switch (_diagram) {
    null => null,
    final diagram => BdScene(diagram),
  };
  List<ViHeapObject> get _drawable => _scene?.drawable ?? const [];
  Rect get _content => _scene?.content ?? Rect.zero;
  late final Map<ViObjectKind, int> _counts = _computeCounts();

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
                              style: BdRenderStyle(
                                dotGrid: true,
                                iconFilterQuality: FilterQuality.low,
                                canvasScale: _anchorScale,
                              ),
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

Color labviewTypeColor(ViTypeKind kind) => switch (kind) {
  ViTypeKind.numericFloat => const Color(0xFFFF6600),
  ViTypeKind.numericInt => const Color(0xFF0000FF),
  ViTypeKind.enumRing => const Color(0xFF0000FF),
  ViTypeKind.string => const Color(0xFFFF00FF),
  ViTypeKind.boolean => const Color(0xFF006600),
  ViTypeKind.path => const Color(0xFF006666),
  ViTypeKind.clnNode => const Color(0xFFE8C547),
  ViTypeKind.cluster ||
  ViTypeKind.array ||
  ViTypeKind.refnum => const Color(0xFF8A8A8A),
  ViTypeKind.unknown => const Color(0xFF8A8A8A),
};

const Color kBdCanvas = Color(0xFFFFFFFF);

const Color kBdGridDot = Color(0x0C000000);

const Color kBdSubViNodeFill = Color(0xFFECECEC);

const Color kBdPrimitiveNodeFill = Color(0xFFFBEEC2);

const Color kBdUnknownTerminalFill = Color(0xFFD8D8D8);

const Color kBdWireColor = Color(0xFF2B2B2B);

const Color kBdTunnelBorder = Color(0xFF444444);

const Color kBdTerminalFill = Color(0xFFFFFFCC);

ViDataType? _dataTypeOfTypeKind(ViTypeKind kind) => switch (kind) {
  ViTypeKind.boolean => ViDataType.boolean,
  ViTypeKind.string => ViDataType.string,
  ViTypeKind.cluster => ViDataType.cluster,
  ViTypeKind.path => ViDataType.path,
  ViTypeKind.enumRing => ViDataType.enumU8,
  _ => null,
};

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

bool _isErrorClusterMembers(List<ViType> members) =>
    members.length == 3 &&
    members[0].kind == ViDataType.boolean &&
    members[1].kind == ViDataType.i32 &&
    members[2].kind == ViDataType.string;

Color _clusterTint(List<ViType> members) => _isErrorClusterMembers(members)
    ? const Color(0xFF666600)
    : members.any((m) => !_isNumericDataType(m.kind))
    ? const Color(0xFFFF00FF)
    : labviewTypeColor(ViTypeKind.cluster);

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

const int kDefaultStructureRgb = 0x7F7F7F;

typedef GlobalHatchOffset = ({int x, int y});

const GlobalHatchOffset kNoHatchOffset = (x: 0, y: 0);

const kBdStructureHatch = ['.#.#', '#.#.', '##..', '..##'];

const kBdHatchBand = 5;

const kBdErrorHatch = ['#...', '...#', '..#.', '.#..'];

class BdRenderStyle {
  const BdRenderStyle({
    this.whileBandGrey = const Color(0xFF777777),
    this.errorCaseGreen = const Color(0xFF99FF99),
    this.booleanGreen = const Color(0xFF006600),
    this.hatchOffset = kNoHatchOffset,
    this.errorHatchOffset = kNoHatchOffset,
    this.wireCycleOffset = kNoHatchOffset,
    this.dotGrid = false,
    this.iconFilterQuality = FilterQuality.none,
    this.canvasScale = 1,
  });

  final bool dotGrid;

  final FilterQuality iconFilterQuality;

  final double canvasScale;

  final Color whileBandGrey;

  final Color errorCaseGreen;

  final Color booleanGreen;

  final GlobalHatchOffset hatchOffset;

  final GlobalHatchOffset errorHatchOffset;

  final GlobalHatchOffset wireCycleOffset;
}

const Color kBdDisabledChromeGrey = Color(0xFFAAAAAA);

Color? bdDecodedColor(int? rgb) =>
    rgb == null ? null : Color(0xFF000000 | (rgb & 0xFFFFFF));

int bdLabelBackingRgb(int rgb) => rgb == 0xFFFFD7 ? 0xFFFFCC : rgb;

Color? bdFillColor(ViHeapObject object) =>
    bdDecodedColor(object.contentRgb) ?? bdDecodedColor(object.bgRgb);

Color bdDimDisabled(Color color) =>
    Color(0xFF000000 | dimDisabledFrameRgb(color.toARGB32() & 0xFFFFFF));

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

const Map<ViWireRenderStyle, int> kBdWireCyclePhase = {
  ViWireRenderStyle.zigzag: 0,
  ViWireRenderStyle.chainLink: 2,
  ViWireRenderStyle.braid: 0,
  ViWireRenderStyle.braidWide: 1,
};

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

int bdRouteClosingSign(ViWireRoute route, WireRouteDirection direction) =>
    route.jointSigns.isEmpty
    ? direction.dx + direction.dy
    : route.jointSigns.last;

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
  final wordKind = wire.elementTypeKind;
  if (wordKind != null && wordKind != ViTypeKind.unknown) {
    return labviewTypeColor(wordKind);
  }
  return kBdWireColor;
}

const Map<String, (int, int, List<String>)> kBdRadixMarkerGlyphs = {
  'x': (1, 5, ['#..#', '.##.', '.##.', '#..#']),
  'X': (1, 5, ['#..#', '.##.', '.##.', '#..#']),
  'b': (1, 3, ['#...', '#...', '###.', '#..#', '#..#', '###.']),
  'B': (1, 3, ['#...', '#...', '###.', '#..#', '#..#', '###.']),
};

int _packRect(int top, int left, int bottom, int right) =>
    ((top + 0x8000) << 48) |
    ((left + 0x8000) << 32) |
    ((bottom + 0x8000) << 16) |
    (right + 0x8000);

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

String _iconStatusSuffix(ViHeapObject object) {
  final key = primIconKeyOf(object);
  if (key == null) return '';
  final name = key >= 0 ? 'prim$key' : 'class${-key}';
  final status = kPrimIconStatus[name];
  return status == null ? '' : ' · icon ${status.name}';
}

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

const Map<(int, int, int, int), ({int? dx, int? dy})> _kBdPrimTerminals = {
  (1050, 0, 32, 32): (dx: 21, dy: 16),
  (1050, 1, 32, 32): (dx: null, dy: 21),
  (1051, 2, 32, 32): (dx: 11, dy: 11),
  (1052, 1, 32, 32): (dx: null, dy: 21),
  (1052, 2, 32, 32): (dx: null, dy: 11),
  (1056, 3, 32, 32): (dx: 10, dy: 10),
  (1063, 0, 32, 32): (dx: 22, dy: 16),
  (1081, 0, 32, 32): (dx: null, dy: 16),
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
  final sizedKey = (key, termIdx, box.right - box.left, box.bottom - box.top);
  final offset = _kBdPrimTerminals[sizedKey] ?? kBdPrimTerminalCensus[sizedKey];
  if (offset == null) return null;
  return (
    x: offset.dx == null ? null : box.left + offset.dx!,
    y: offset.dy == null ? null : box.top + offset.dy!,
  );
}

const kPrimIconPrescale = 4;

typedef PrimIconArt = ({ui.Image base, ui.Image sharp});

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

void _greyDisabledPalette(Uint8List rgba) {
  for (var i = 0; i < rgba.length; i += 4) {
    if (rgba[i + 3] == 0) continue;
    final light = (rgba[i] + rgba[i + 1] + rgba[i + 2]) >= 3 * 204;
    final v = light ? 255 : 170;
    rgba[i] = rgba[i + 1] = rgba[i + 2] = v;
  }
}

Map<int, PrimIconArt> primIconsGreyLoaded() => _primIconsGreySync;

Future<ui.Image> decodeImage(Uint8List bytes) {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromList(bytes, completer.complete);
  return completer.future;
}

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

  final Uint8List alpha;

  final Uint8List rgba;

  final Set<int> cornerAa;

  final ui.Rect? inkBounds;
}

final Map<int, _PrimIconPixels> _primIconPixels = {};

const _kCornerAaRung2 = Color(0xFFAAAAAA);

ui.Rect? primIconInkBounds(int key) => _primIconPixels[key]?.inkBounds;

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

Map<int, PrimIconArt> primIconsLoaded() => _primIconsSync;

typedef _BdWireSeg = ({
  bool horizontal,
  int lo,
  int hi,
  int bandLo,
  int bandHi,
});

typedef _BdWireAnchors = ({
  Map<int, Color> typedTerminalColors,
  Map<int, Color> sourceOutputColors,
  Set<Rect> iconNodeRects,
  Map<Rect, Rect> iconInkRects,
  Map<Rect, ViHeapObject> iconNodeObjects,
  List<Rect> nodeCoverRects,
  List<Rect> furnitureRects,
});

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

  final ViDiagramSemantics semantics;

  ViDiagram get diagram => semantics.diagram;

  List<ViHeapObject> get drawable => semantics.drawable;

  List<ViWire> get wires => semantics.wires;

  List<ViHeapObject> get ordered => semantics.ordered;

  Set<int> get disabledOids => semantics.disabledOids;

  Set<int> get errorCaseOids => semantics.errorCaseOids;

  Map<HeapRect, ({int kind, bool hollow, bool centreDot, bool disabled})>
  get borderTerminalKinds => semantics.borderTerminalKinds;

  Map<int, List<({HeapRect box, int bmp})>> get structureTerminals =>
      semantics.structureTerminals;

  Map<int, String> get constValues => semantics.constValues;

  List<HeapRect> get furnitureBounds => semantics.furnitureBounds;

  late final Rect content = drawable.isEmpty
      ? Rect.zero
      : bdContentRect(drawable, includeWires: false);

  final Map<BdRunKey, BdTextRun> textLayoutCache = {};

  final Map<BdGlyphKey, BdGlyph> textGlyphCache = {};

  bool recordPaintedText = false;

  final List<({String text, Rect rect, double fontSize})> paintedText = [];

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

typedef BdRunKey = (
  String text,
  int color,
  double fontSize,
  FontWeight fontWeight,
  FontStyle? fontStyle,
  int lineCount,
  String fontFamily,
);

typedef BdGlyphKey = (
  String glyph,
  int color,
  double fontSize,
  FontWeight fontWeight,
  FontStyle? fontStyle,
  String fontFamily,
);

const double kBdTextSize = 12.0;

const double kBdTextLineHeight = 14.5 / kBdTextSize;

double bdLineBox(double fontSize) =>
    (fontSize * kBdTextLineHeight).ceilToDouble();

const double kBdTextOverdrawAlpha = 0.75;

const double kBdTextOverdrawAlphaBold = 0.15;

Offset bdCentredTextAnchor(Rect box, Size text) => Offset(
  box.left + ((box.width - text.width) / 2).floorToDouble(),
  box.top + ((box.height - text.height) / 2).floorToDouble(),
);

double bdCentredTextTop(Rect box, double textHeight) =>
    box.top + ((box.height - textHeight) / 2).floorToDouble();

double bdCentredLabelLeft(Rect bounds, double textWidth) =>
    bounds.left + ((bounds.width - textWidth - 1) / 2).floorToDouble();

class BdGlyph {
  BdGlyph({
    required this.main,
    required this.dim,
    required this.advance,
    required this.baseline,
  });

  final TextPainter main;

  final TextPainter dim;

  final int advance;

  final double baseline;

  void dispose() {
    main.dispose();
    dim.dispose();
  }
}

class BdTextRun {
  BdTextRun({
    required this.text,
    required this.width,
    required this.height,
    required this.fontSize,
    required ui.Picture picture,
  }) : _picture = picture;

  final String text;

  final double width;

  final double height;

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

  void dispose() => _picture.dispose();
}

class BdDiagramPainter extends CustomPainter {
  BdDiagramPainter({
    required this.scene,
    required this.origin,
    this.subViIcons = const {},
    this.xnodeFacades = const {},
    this.primIcons = const {},
    this.primIconsGrey = const {},
    this.style = const BdRenderStyle(),
  });

  final BdScene scene;

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

  final Map<int, ViLegacyIcon> subViIcons;

  final Map<int, ui.Image> xnodeFacades;

  final Map<int, PrimIconArt> primIcons;

  final Map<int, PrimIconArt> primIconsGrey;

  final BdRenderStyle style;

  Rect _toCanvas(HeapRect rect) => Rect.fromLTRB(
    rect.left - origin.dx,
    rect.top - origin.dy,
    rect.right - origin.dx,
    rect.bottom - origin.dy,
  );

  Color _dimFor(int oid, Color color) => disabledOids.contains(oid)
      ? bdDimDisabled(color).withValues(alpha: color.a)
      : color;

  Rect _rectOf(ViHeapObject object) => _toCanvas(object.absBounds!);

  @override
  void paint(Canvas canvas, Size size) {
    scene.paintedText.clear();
    canvas.scale(style.canvasScale);
    size = Size(
      size.width / style.canvasScale,
      size.height / style.canvasScale,
    );
    canvas.drawRect(Offset.zero & size, Paint()..color = kBdCanvas);
    if (style.dotGrid) _drawDotGrid(canvas, size);

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
    final chromeOwnedRects = <Rect>{
      for (final attach in borderTerminalKinds.keys) _toCanvas(attach),
    };
    final labelBackings = <(int, Rect, Color)>[];

    _paintDecorations(canvas, decorations);
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
      !identical(old.scene, scene) ||
      !identical(old.subViIcons, subViIcons) ||
      !identical(old.xnodeFacades, xnodeFacades) ||
      !identical(old.primIcons, primIcons) ||
      !identical(old.primIconsGrey, primIconsGrey) ||
      !identical(old.style, style) ||
      old.origin != origin;
}

int _chromeZOrder(int kind) => switch (kind) {
  0x22 || 0x2d => 0,
  0x27 || 0x28 => 1,
  _ => 2,
};

Paint _solidNoAa(Color color) => Paint()
  ..color = color
  ..isAntiAlias = false;

void _drawCellPoints(Canvas canvas, List<double> centres, Color color) {
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

void _stampBitmap(
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

  final double canvasScale;

  Rect _rectOf(ViHeapObject o) {
    final bounds = o.absBounds!;
    final rect = Rect.fromLTRB(
      bounds.left - origin.dx,
      bounds.top - origin.dy,
      bounds.right - origin.dx,
      bounds.bottom - origin.dy,
    );
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

Widget _detail(String label, String value) => Padding(
  padding: const EdgeInsets.only(top: 3),
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

class _BdOutline extends StatelessWidget {
  const _BdOutline({required this.outline, this.linkedSubVis = const []});
  final ({
    Map<HeapObjectClass, int> structuresByClass,
    List<String> labeledNodes,
    int nodeCount,
    Map<ClassConfidence, int> confidence,
  })
  outline;

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

class _ViImageStrip extends StatelessWidget {
  const _ViImageStrip(this.images);
  final ViImages images;

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
