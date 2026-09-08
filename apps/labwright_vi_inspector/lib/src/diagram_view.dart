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

  Map<int, ViLegacyIcon> _subViIcons = const {};
  Map<int, PrimIconArt> _primIcons = const {};
  Map<int, ui.Image> _xnodeFacades = const {};

  late final BdScene? _scene = switch (_largestDiagram(widget.diagrams)) {
    null => null,
    final diagram => BdScene(diagram),
  };

  @override
  void initState() {
    super.initState();
    _resolveIcons();
    loadPrimIcons().then((icons) {
      if (mounted && icons.isNotEmpty) setState(() => _primIcons = icons);
    });
    final scene = _scene;
    if (scene == null) return;
    if (widget.sections.isNotEmpty) {
      xnodeFacadesFromSections(widget.sections, scene.diagram).then((facades) {
        if (!mounted) {
          for (final image in facades.values) {
            image.dispose();
          }
          return;
        }
        if (facades.isNotEmpty) setState(() => _xnodeFacades = facades);
      });
    }
    if (scene.disabledOids.isNotEmpty) {
      ensurePrimIconsGrey().then((grey) {
        if (mounted && grey.isNotEmpty) setState(() {});
      });
    }
  }

  Future<void> _resolveIcons() async {
    final diagram = _scene?.diagram;
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
    final scene = _scene;
    if (scene == null) {
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
    if (scene.drawable.isEmpty) {
      return const Center(
        child: Text(
          'Diagram has no positioned objects.',
          style: TextStyle(color: Colors.grey),
        ),
      );
    }

    final content = scene.content;
    _lastContent = content;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _toolbar(scene.drawable.length),
        const SizedBox(height: 4),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _diagramStack(content, scene)),
              if (_shelfOpen) _shelf(scene),
            ],
          ),
        ),
      ],
    );
  }

  Widget _shelf(BdScene scene) => SizedBox(
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
            for (final entry in scene.kindCounts.entries)
              _LegendChip(
                color: _kindColor(entry.key),
                label: '${entry.key.name} ${entry.value}',
              ),
          ],
        ),
        const SizedBox(height: 8),
        _BdOutline(outline: scene.outline, linkedSubVis: widget.subViNames),
      ],
    ),
  );

  Widget _diagramStack(Rect content, BdScene scene) {
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
                            scene,
                            content,
                          ),
                          child: CustomPaint(
                            size: Size(
                              content.width * _anchorScale,
                              content.height * _anchorScale,
                            ),
                            painter: BdDiagramPainter(
                              scene: scene,
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

  void _selectAt(Offset local, BdScene scene, Rect content) {
    final x = local.dx + content.left;
    final y = local.dy + content.top;
    ViHeapObject? hit;
    var bestArea = double.infinity;
    for (final object in scene.ordered) {
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
          ? nodesWithin(hit, scene.drawable)
          : membersOf(hit, scene.diagram.byId);
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
  });

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
  for (final c in diagram.children(parentOid)) {
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

final _kPrimIconAsset = RegExp(
  r'assets/prim_icons/(prim|class)(\d+)(?:_t(\d+))?(?:_[a-z0-9-]+)?\.png$',
);

Future<Map<int, PrimIconArt>> loadPrimIcons() => _primIcons ??= () async {
  final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
  final icons = <int, PrimIconArt>{};
  for (final asset in manifest.listAssets()) {
    final match = _kPrimIconAsset.firstMatch(asset);
    if (match == null) continue;
    final family = match.group(1)!;
    final digits = match.group(2)!;
    final variant = match.group(3);
    final statusKey = '$family$digits${variant == null ? '' : '_t$variant'}';
    if (kPrimIconStatus[statusKey] == PrimIconStatus.rejected) {
      continue;
    }
    final bytes = await rootBundle.load(asset);
    final image = await decodeImage(bytes.buffer.asUint8List());
    final number = int.parse(digits);
    final id = family == 'prim'
        ? number
        : (variant == null
              ? -number
              : classVariantIconKey(number, int.parse(variant)));
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

Future<Uint8List> rgbaOf(ui.Image image) async =>
    (await image.toByteData())!.buffer.asUint8List();

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

  late final Map<ViObjectKind, int> kindCounts = drawable.fold(
    <ViObjectKind, int>{},
    (counts, object) =>
        counts..update(object.category, (n) => n + 1, ifAbsent: () => 1),
  );

  late final outline = computeBdOutline(drawable);

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
    this.iconFilterQuality = FilterQuality.none,
    this.canvasScale = 1,
    this.drawDotGrid = true,
    this.style = const BdRenderStyle(),
  });

  final BdScene scene;

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

  BdTextRun _layoutText(
    String text, {
    required Color color,
    double fontSize = kBdTextSize,
    FontWeight fontWeight = FontWeight.w400,
    FontStyle? fontStyle,
    int? maxLines,
  }) {
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

  Color _dimFor(int oid, Color color) => disabledOids.contains(oid)
      ? bdDimDisabled(color).withValues(alpha: color.a)
      : color;

  final FilterQuality iconFilterQuality;

  final double canvasScale;

  final bool drawDotGrid;

  Rect _rectOf(ViHeapObject object) => _toCanvas(object.absBounds!);

  @override
  void paint(Canvas canvas, Size size) {
    scene.paintedText.clear();
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

  void _paintStructures(
    Canvas canvas,
    List<ViHeapObject> structures, {
    required Set<int> arrayShellOids,
    required Set<Rect> chromeOwnedRects,
  }) {
    for (final object in structures) {
      if (object.objectClass == HeapObjectClass.loop) {
        final rect = _rectOf(object);
        if (rect.width <= 40 && rect.height <= 24) {
          _drawSmallClusterBox(canvas, object, rect);
          continue;
        }
      }
      final rect = _rectOf(object);
      final structDisabled = disabledOids.contains(object.oid);
      final structColor = switch (object.structRgb == kDefaultStructureRgb
          ? null
          : bdDecodedColor(object.structRgb)) {
        null => null,
        final c => _dimFor(object.oid, c),
      };
      final terminals =
          structureTerminals[object.oid] ?? const <({HeapRect box, int bmp})>[];
      if (object.objectClass == HeapObjectClass.caseOrSequence &&
          arrayShellOids.contains(object.oid)) {
        _drawArrayConstantShell(canvas, object);
        continue;
      }
      switch (object.objectClass) {
        case HeapObjectClass.bdForLoop:
          _drawForLoopBorder(canvas, rect, disabled: structDisabled);
        case HeapObjectClass.bdWhileLoop:
          _drawWhileLoopBand(
            canvas,
            rect,
            structColor,
            disabled: structDisabled,
          );
        case HeapObjectClass.bdStructureFrame:
          _drawStructureHatchBorder(
            canvas,
            rect,
            object.absBounds!.left,
            object.absBounds!.top,
            disabled: structDisabled,
            error: errorCaseOids.contains(object.oid),
          );
          if (((object.objFlags ?? 0) & 0x1000000) != 0) {
            _drawCaseInsensitiveBadge(
              canvas,
              rect,
              disabled: structDisabled,
              oid: object.oid,
            );
          }
        case HeapObjectClass.bdFlatSequence:
          _drawFlatSequenceBorder(canvas, rect, object);
        case HeapObjectClass.bdSequenceFrame:
          break;
        case HeapObjectClass.bdDisableStructure:
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
          continue;
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

  void _paintCaseSelectorStrips(Canvas canvas, List<ViHeapObject> solids) {
    for (final object in solids) {
      if (object.objectClass == HeapObjectClass.bdSelectorLabel)
        _drawCaseSelector(canvas, _rectOf(object));
    }
  }

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

  void _paintWireObjects(Canvas canvas, List<ViHeapObject> wires) {
    final wirePaint = Paint()
      ..color = _kindColor(ViObjectKind.wire)
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.square;
    for (final object in wires) {
      final rect = _rectOf(object);
      if (rect.width == 0 && rect.height == 0) continue;
      canvas.drawLine(rect.topLeft, rect.bottomRight, wirePaint);
    }
  }

  void _paintSolids(
    Canvas canvas,
    List<ViHeapObject> solids,
    List<(int, Rect, Color)> labelBackings,
  ) {
    final stampedPrimIcons = <({Rect dst, int id})>[];
    for (final object in solids) {
      final rect = _rectOf(object);
      if (kBdTextLabelClasses.contains(object.objectClass)) {
        if (object.objectClass == HeapObjectClass.bdSelectorLabel) continue;
        final holder = scene.diagram.byId[object.parentOid];
        final backed =
            holder?.kind == 0x1b ||
            (holder?.objectClass == HeapObjectClass.caseOrSequence &&
                ((object.objFlags ?? 0) & 0x800) == 0);
        final backing = object.isLabelHidden || !backed || object.bgRgb == null
            ? null
            : bdDecodedColor(bdLabelBackingRgb(object.bgRgb!));
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

  void _paintTerminal(Canvas canvas, ViHeapObject object, Rect rect) {
    var box = rect;
    if (constValues[object.oid] != null) {
      final kids = scene.diagram.children(object.oid);
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
    final constHolder = scene.diagram.byId[object.parentOid];
    final boolValue =
        constHolder != null &&
            constHolder.objectClass == HeapObjectClass.bdConstDco
        ? constHolder.constBool
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
    final artType = object.dataType ?? _dataTypeOfTypeKind(object.typeKind);
    if (artType != null &&
        object.isIndicator != null &&
        box.width == 32 &&
        box.height == 16) {
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
    final typed = object.typeKind != ViTypeKind.unknown || object.fgRgb != null;
    final tint = _dimFor(
      object.oid,
      object.typeKind != ViTypeKind.unknown
          ? labviewTypeColor(object.typeKind)
          : (bdDecodedColor(object.fgRgb) ?? kBdUnknownTerminalFill),
    );
    final border = typed ? tint : _dimFor(object.oid, const Color(0xFF5A5A5A));
    final constValue = constValues[object.oid];
    final shellParent = scene.diagram.byId[object.parentOid];
    if (object.objectClass == HeapObjectClass.numericControl &&
        shellParent?.objectClass == HeapObjectClass.caseOrSequence) {
      return;
    }
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
      if (object.objectClass == HeapObjectClass.stringOrArrayControl &&
          box.width > 8) {
        canvas.drawRect(
          Rect.fromLTWH(box.left, box.top, 4, box.height),
          _solidNoAa(border),
        );
      }
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

  void _paintNode(
    Canvas canvas,
    ViHeapObject object,
    Rect rect,
    List<({Rect dst, int id})> stampedPrimIcons,
  ) {
    final isSubVi = kSubViCallNodeCodes.contains(object.kind);
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

  void _paintPlainSolid(Canvas canvas, ViHeapObject object, Rect rect) {
    final rr = RRect.fromRectAndRadius(rect, const Radius.circular(2.5));
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

  void _paintLabelBackings(
    Canvas canvas,
    List<(int, Rect, Color)> labelBackings,
  ) {
    for (final (oid, rect, backing) in labelBackings) {
      canvas.drawRect(rect, Paint()..color = _dimFor(oid, Colors.black));
      canvas.drawRect(rect.deflate(1), Paint()..color = _dimFor(oid, backing));
    }
  }

  void _paintCaptions(Canvas canvas) {
    final byOid = {for (final o in objects) o.oid: o};
    for (final object in objects) {
      if (kBdTextLabelClasses.contains(object.objectClass)) {
        if (object.isLabelHidden) continue;
        var text = object.objectClass == HeapObjectClass.bdSelectorLabel
            ? (object.label?.trim().isEmpty ?? true ? null : object.label)
            : object.label?.trim();
        if (text == null || text.isEmpty) {
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
        final selector = object.objectClass == HeapObjectClass.bdSelectorLabel;
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
          maxLines: math.max(1, (rect.height / bdLineBox(fontSize)).round()),
        );
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

  _BdWireAnchors _collectWireAnchors() {
    final typedTerminalColors = <int, Color>{};
    final sourceOutputColors = <int, Color>{};
    final iconNodeRects = <Rect>{};
    final iconInkRects = <Rect, Rect>{};
    final iconNodeObjects = <Rect, ViHeapObject>{};
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
    tunnelSquares?.addAll([
      for (final (tunnelRect, info) in tunnels)
        (
          tunnelRect,
          info,
          info.disabled && !wireDisabled ? bdDimDisabled(color) : color,
        ),
    ]);
    final routePoints = wire.routePoints;
    final routeTree = wire.routeTree;
    final legs = <List<Offset>>[];
    final junctions = <Offset>[];
    var stubEligible = routeTree == null && routePoints == null;
    if (routeTree != null) {
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
      if (points.length >= 2) {
        if (!_polylineUnderNodes(points, anchors.nodeCoverRects)) {
          legs.add(points);
        } else {
          stubEligible = true;
        }
      }
    } else if (wire.branchRoute != null && wire.endpointOids.length >= 3) {
      final headTerminal = bdPrimTerminalOf(
        scene.diagram,
        wire.endpointOids[0],
      );
      final headX = headTerminal?.x, headY = headTerminal?.y;
      if (headX != null && headY != null) {
        final tree = walkWireBranchRoute(wire.branchRoute!, (
          x: headX,
          y: headY,
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
    if (stubEligible) {
      if (legs.isEmpty) _straightStubLeg(wire, legs);
      if (legs.isEmpty) _threePointStubLeg(wire, legs);
      if (legs.isEmpty) _walkedRouteLeg(wire, legs);
      if (legs.isEmpty) _coveredAttachWalkLeg(wire, legs);
      if (legs.isEmpty) _containerFaceLeg(wire, legs);
    }
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

  List<(Rect, ({int kind, bool hollow, bool centreDot, bool disabled}))>
  _wireTunnelChrome(ViWire wire) {
    final tunnels =
        <(Rect, ({int kind, bool hollow, bool centreDot, bool disabled}))>[];
    for (
      var endpointIndex = 0;
      endpointIndex < wire.endpointAnchors.length;
      endpointIndex++
    ) {
      final anchor = wire.endpointAnchors[endpointIndex];
      if (anchor == null) continue;
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

  List<Offset> _resolvedRoutePolyline(
    ViWire wire,
    List<ViPoint> routePoints,
    _BdWireAnchors anchors,
  ) {
    final points = [
      for (final point in routePoints)
        Offset(point.x - origin.dx, point.y - origin.dy),
    ];
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
    if (points.length >= 2 && wire.endpointAnchors.length >= 2) {
      _trimEndToFurniture(wire, points, anchors, head: true);
      _trimEndToFurniture(wire, points, anchors, head: false);
    }
    return points;
  }

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

  void _slideSlackHead(ViWire wire, List<Offset> points, ViStep slack) {
    final terminal = bdPrimTerminalOf(scene.diagram, wire.endpointOids[0]);
    final terminalX = terminal?.x, terminalY = terminal?.y;
    final head = points.first;
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
        final termX = term?.x, termY = term?.y;
        if (termX == null || termY == null) continue;
        final delta = Offset(
          (termX - abs.x).toDouble(),
          (termY - abs.y).toDouble(),
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

  void _extendIntoSinkIcon(
    ViWire wire,
    List<Offset> points,
    Rect sinkBox,
    _BdWireAnchors anchors,
  ) {
    final ink = anchors.iconInkRects[sinkBox] ?? sinkBox;
    final closing = wire.routeClosingStep;
    if (closing != null) {
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
      final along =
          (target.dx - last.dx) * closing.dx +
          (target.dy - last.dy) * closing.dy;
      if (along > 0) points.add(target);
    } else {
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
      final primCoord = dir.dx == 0 ? terminal?.y : terminal?.x;
      if (primCoord != null) {
        final closingCross =
            primCoord + (dir.dx + dir.dy) * route.segmentLengths[0];
        final attachCross = dir.dx == 0 ? start.y : start.x;
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
    final headX = headTerminal?.x, headY = headTerminal?.y;
    final headAttach = wire.endpointAttachRects[0];
    if (headX != null &&
        headY != null &&
        (headAttach == null ||
            headAttach.right <= headAttach.left ||
            headAttach.bottom <= headAttach.top)) {
      final walk = walkRouteBends(route, origin: (x: headX, y: headY))!;
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
      final wantSign = route.pointCount == 2
          ? (exactEnd == 0 ? -toExact : toExact)
          : toExact;
      if (closingSign != wantSign || faceLo > faceHi) continue;
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
    final innerTop = t + 10, innerBottom = b - 10;
    final sideH = innerBottom - innerTop;
    if (sideH > 0) {
      px(greyFill, l + 2, t + 1, 3, b - t - 2);
      px(blackFill, l + 5, innerTop, 1, sideH);
      px(blackFill, r - 6, innerTop, 1, sideH);
      px(greyFill, r - 5, t + 1, 3, b - t - 2);
      for (var y = t + 1; y < b - 1; y++) {
        final greyFirst = (((y + origin.dy).round() + 1) ~/ 2).isOdd;
        px(greyFirst ? greyFill : blackFill, l, y.toDouble());
        px(greyFirst ? blackFill : greyFill, l + 1, y.toDouble());
        px(greyFirst ? blackFill : greyFill, r - 2, y.toDouble());
        px(greyFirst ? greyFill : blackFill, r - 1, y.toDouble());
      }
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
    final holder = scene.diagram.byId[shell.parentOid];
    final constHolder =
        holder != null && holder.objectClass == HeapObjectClass.bdConstDco
        ? holder
        : null;
    final values = constHolder?.constArray;
    final dims = constHolder?.constArrayDims;
    final format = bdDisplayFormatOf(scene.diagram, element.oid);
    final marker = kBdRadixMarkerGlyphs[bdFormatConversion(format)];
    var radixDx = 2, radixDy = 3;
    for (final part in scene.diagram.children(element.oid)) {
      if (part.objectClass == HeapObjectClass.controlSubPart &&
          part.absBounds != null) {
        radixDx = part.absBounds!.left - cell.left;
        radixDy = part.absBounds!.top - cell.top;
      }
    }
    final windowStart = dims != null && dims.length >= 2
        ? 0
        : (shell.arrayIndex ?? 0);
    for (var j = 0; j < rows; j++) {
      for (var i = 0; i < cols; i++) {
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
    final ox = origin.dx.round(), oy = origin.dy.round();
    final (bandLo, bandHi) = band;
    if (style == ViWireRenderStyle.braid) {
      if (errorBraid) {
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

  static int _chromeZOrder(int kind) => switch (kind) {
    0x22 || 0x2d => 0,
    0x27 || 0x28 => 1,
    _ => 2,
  };

  static Paint _solidNoAa(Color color) => Paint()
    ..color = color
    ..isAntiAlias = false;

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
        if (info.hollow) {
          canvas.drawRect(t, _solidNoAa(creamColor));
          if (t.width == 9 && t.height == 9) {
            const ring = ['xx.xx', 'x...x', 'x...x', 'x...x', 'xx.xx'];
            _stampBitmap(canvas, noAa, ring, t.left + 2, t.top + 2, on: 'x');
          }
        } else {
          canvas.drawRect(t, noAa);
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

  void _drawWhileLoopBand(
    Canvas canvas,
    Rect rect,
    Color? tint, {
    bool disabled = false,
  }) {
    Color dim(Color c) => disabled ? bdDimDisabled(c) : c;
    final grey = tint ?? dim(style.whileBandGrey);
    final l = rect.left.round(), t = rect.top.round();
    final r = rect.right.round(), b = rect.bottom.round();
    const band = _kWhileBand;
    final aw = _kWhileArrow.first.length, ah = _kWhileArrow.length;
    final ax0 = r - aw, ay0 = b - ah;

    final pts = <double>[];
    void add(int x, int y) => pts
      ..add(x + 0.5)
      ..add(y + 0.5);

    void cell(int x, int y) {
      final dt = y - t, db = b - 1 - y;
      final dl = x - l, dr = r - 1 - x;
      if (x >= ax0 && y >= ay0) return;
      bool grey1;
      if (dt < band && dl < band) {
        grey1 = _kWhileCornerTL[dt][dl] == '#';
      } else if (dt < band && dr < band) {
        grey1 = _kWhileCornerTR[dt][dr] == '#';
      } else if (db < band && dl < band) {
        grey1 = _kWhileCornerBL[db][dl] == '#';
      } else {
        grey1 = true;
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
    for (var ry = 0; ry < ah; ry++) {
      for (var rx = 0; rx < aw; rx++) {
        if (_kWhileArrow[ry][rx] == '#') add(ax0 + rx, ay0 + ry);
      }
    }
    _drawCellPoints(canvas, pts, grey);
  }

  static const _kWhileBand = 6;

  void _drawForLoopBorder(Canvas canvas, Rect rect, {bool disabled = false}) {
    final ink = disabled
        ? bdDimDisabled(const Color(0xFF000000))
        : const Color(0xFF000000);
    final paint = _solidNoAa(ink);
    final l = rect.left.roundToDouble();
    final t = rect.top.roundToDouble();
    final r = rect.right.roundToDouble();
    final b = rect.bottom.roundToDouble();
    void px(double x, double y) =>
        canvas.drawRect(Rect.fromLTRB(x, y, x + 1, y + 1), paint);
    void hline(double x0, double x1, double y) =>
        canvas.drawRect(Rect.fromLTRB(x0, y, x1 + 1, y + 1), paint);
    void vline(double x, double y0, double y1) =>
        canvas.drawRect(Rect.fromLTRB(x, y0, x + 1, y1 + 1), paint);

    const fold = _kForLoopFold;
    final backRight = r - 5, backBottom = b - 5;
    hline(l, backRight, t);
    vline(l, t, backBottom);
    vline(backRight, t, backBottom - fold);
    hline(l, backRight - fold, backBottom);
    hline(backRight - fold, backRight, backBottom - fold);
    vline(backRight - fold, backBottom - fold, backBottom);
    for (var i = 1; i < fold; i++) {
      px(backRight - i, backBottom - fold + i);
    }
    for (final o in const [2.0, 4.0]) {
      hline(l + o, backRight + o, backBottom + o);
      vline(backRight + o, t + o, backBottom + o);
      hline(backRight + o - 2, backRight + o, t + o);
      px(l + o, backBottom + o - 1);
    }
  }

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
    final tile = error ? kBdErrorHatch : kBdStructureHatch;
    final offset = error ? style.errorHatchOffset : style.hatchOffset;
    final band = <double>[];
    final field = error ? <double>[] : null;
    void cell(int i, int j) {
      final d = math.min(math.min(i, j), math.min(w - 1 - i, h - 1 - j));
      if (d < 1 || d > kBdHatchBand) return;
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

  static const _kCaseInsensitiveGlyph = [
    '.####.............',
    '##..##............',
    '##..##.......###..',
    '######.####....##.',
    '##..##.......####.',
    '##..##.####.##.##.',
    '##..##.......#####',
  ];

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

  static const _kForLoopFold = 8.0;

  static const _loopBlue = Color(0xFF0033CC);

  static const _bmpIteration = 1;
  static const _bmpCount = 2;
  static const _bmpLeftShiftRegister = 3;
  static const _bmpRightShiftRegister = 4;
  static const _bmpCaseSelector = 5;
  static const _bmpConditional = 192;

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
    if (scene.diagram.byId[object.parentOid]?.objectClass !=
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

  void _drawCaseSelector(Canvas canvas, Rect rect) {
    final ink = _solidNoAa(Colors.black);
    final l = rect.left.roundToDouble(), t = rect.top.roundToDouble();
    final r = rect.right.roundToDouble();
    final bottom = t + 16;
    final left = l - 8, right = r + 18;
    void hline(double x0, double x1, double y) =>
        canvas.drawRect(Rect.fromLTRB(x0, y, x1 + 1, y + 1), ink);
    void vline(double x, double y0, double y1) =>
        canvas.drawRect(Rect.fromLTRB(x, y0, x + 1, y1 + 1), ink);
    canvas.drawRect(
      Rect.fromLTRB(left, t, right + 1, bottom + 1),
      _solidNoAa(Colors.white),
    );
    hline(left, right, t);
    hline(left, right, bottom);
    vline(left, t, bottom);
    vline(l, t, bottom);
    vline(r + 10, t, bottom);
    vline(right, t, bottom);
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
