import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import 'bd_text_font.dart';
import 'generated/prim_icon_art.dart';
import 'heap_view_chrome.dart';
import 'terminal_bitmaps.dart';

import 'prim_icon_catalog.dart';
import 'span_annotations.dart';

class ViDiagramView extends StatefulWidget {
  const ViDiagramView({
    super.key,
    required this.diagrams,
    this.emptyHint = 'No decodable layout in this file.',
    this.subViNames = const [],
    this.viImages = const ViImages(),
    this.subViIcons = const {},
    this.sections = const [],
  });

  final List<BdDiagram>? diagrams;

  final String emptyHint;

  final List<String> subViNames;

  final ViImages viImages;

  /// The icons of the diagram's sub-VIs by file name, as [resolveSubViIcons] reads them.
  final Map<String, ViLegacyIcon> subViIcons;

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

  BdObject? _selected;
  Set<BdObject> _members = const {};
  Size? _lastViewport;
  Rect? _lastContent;
  bool _fitted = false;

  bool _shelfOpen = true;

  late final BdDiagram? _diagram = switch (widget.diagrams) {
    null => null,
    final diagrams => largestHeap(diagrams),
  };
  late final HeapObjectsByOid<BdObject> _byId =
      _diagram?.byId ?? HeapObjectsByOid<BdObject>(const []);

  late final Map<int, ViLegacyIcon> _subViIcons = {
    if (_diagram case final diagram?)
      for (final object in diagram.objects)
        if (kSubViCallNodeCodes.contains(object.kind))
          if (widget.subViIcons[object.label?.trim()] case final icon?)
            object.oid: icon,
  };
  Map<int, ui.Image> _xnodeFacades = const {};

  late final BdScene? _scene = switch (_diagram) {
    null => null,
    final diagram => BdScene(diagram),
  };
  List<BdObject> get _drawable => _scene?.drawable ?? const [];
  Rect get _content => _scene?.content ?? Rect.zero;
  late final Map<BdObjectKind, int> _counts = countBy(
    _drawable,
    (o) => o.category,
  );

  late final _outline = computeBdOutline(_drawable);

  @override
  void initState() {
    super.initState();
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
    if (_diagram == null) return heapPlaceholder(widget.emptyHint);
    if (_drawable.isEmpty) {
      return heapPlaceholder('Diagram has no positioned objects.');
    }

    final content = _content;
    _lastContent = content;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        heapViewToolbar(
          objectCount: _drawable.length,
          onFit: _fit,
          shelfOpen: _shelfOpen,
          onToggleShelf: () => setState(() => _shelfOpen = !_shelfOpen),
        ),
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
        if (!widget.viImages.isEmpty) ...[
          _ViImageStrip(widget.viImages),
          const SizedBox(height: 8),
        ],
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final entry in _counts.entries)
              LegendChip(
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

  Widget _diagramStack(Rect content, List<BdObject> ordered) {
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
              return heapCanvas(
                controller: _transform,
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
                          primIcons: primIcons,
                          primIconsGrey: primIconsGrey,
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

  void _selectAt(Offset local, List<BdObject> objects, Rect content) {
    final x = local.dx + content.left;
    final y = local.dy + content.top;
    BdObject? hit;
    var bestArea = double.infinity;
    for (final object in objects) {
      final bounds = object.absBounds!;
      var left = bounds.left.toDouble(), top = bounds.top.toDouble();
      var right = bounds.right.toDouble(), bottom = bounds.bottom.toDouble();
      final key = loadedPrimIconIdOf(object, version: _scene?.diagram.version);
      final art = key == null ? null : primIcons[key];
      if (art != null) {
        final stamp = primIconStampRect(
          Rect.fromLTRB(left, top, right, bottom),
          art.width,
          art.height,
          key: key,
        );
        left = math.min(left, stamp.left);
        top = math.min(top, stamp.top);
        right = math.max(right, stamp.right);
        bottom = math.max(bottom, stamp.bottom);
      }
      if (x >= left && x <= right && y >= top && y <= bottom) {
        if (!primIconHit(object, x, y, version: _scene?.diagram.version))
          continue;
        final area = (bounds.width * bounds.height).toDouble();
        if (area <= bestArea) {
          bestArea = area;
          hit = object;
        }
      }
    }
    setState(() {
      _selected = hit;
      _members = hit != null && hit.category == BdObjectKind.structure
          ? nodesWithin(hit, _drawable)
          : membersOf(hit, _byId);
    });
  }

  void _fit() {
    final viewport = _lastViewport;
    final content = _lastContent;
    if (viewport == null || content == null) return;
    final fit = fitTransform(viewport, content);
    if (fit == null) return;
    _transform.value = fit.transform;
    setState(() => _anchorScale = fit.scale.clamp(0.02, 16.0));
    _fitted = true;
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

Color _kindColor(BdObjectKind kind) => switch (kind) {
  BdObjectKind.node => const Color(0xFFE8C547),
  BdObjectKind.terminal => const Color(0xFF5C9BD6),
  BdObjectKind.terminalCluster => const Color(0xFF2BB8A8),
  BdObjectKind.structure => const Color(0xFF9A6B2E),
  BdObjectKind.frame => const Color(0xFF9A6B2E),
  BdObjectKind.decoration => const Color(0xFFBDBDBD),
  BdObjectKind.wire => const Color(0xFF303030),
  BdObjectKind.unknown => const Color(0xFF9E9E9E),
};

Color _objectColor(BdObject object) =>
    object.category == BdObjectKind.terminal &&
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

Color _clusterTint(List<ViType> members) => isErrorClusterShape(members)
    ? const Color(0xFF666600)
    : members.any((m) => !m.kind.isNumeric)
    ? const Color(0xFFFF00FF)
    : labviewTypeColor(ViTypeKind.cluster);

Color bdTerminalTypeColor(BdObject object) {
  final resolved = object.resolvedType;
  if (object.typeKind == ViTypeKind.array && resolved != null) {
    if (resolved.elementType case final element?) {
      if (element.kind == ViDataType.cluster &&
          resolved.elementMembers.isNotEmpty) {
        return _clusterTint(resolved.elementMembers);
      }
      return labviewTypeColor(
        typeKindOfDataType(element.kind) ?? ViTypeKind.unknown,
      );
    }
  }
  if (object.typeKind == ViTypeKind.cluster &&
      resolved != null &&
      resolved.members.isNotEmpty) {
    return _clusterTint(resolved.members);
  }
  return labviewTypeColor(object.typeKind);
}

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

Color? bdFillColor(BdObject object) =>
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

String? _primDetail(BdObject object) {
  final key = primIconKeyOf(object);
  if (key == null) return null;
  final name = primIconName(key);
  final status = kPrimIconStatus[name];
  final iconPart =
      'icon $name${status == null ? ' (no asset)' : ' ${status.name}'}';
  if (object.primitive?.primResId case final primResId?) {
    final op = PrimOp.fromId(primResId);
    final opPart = op == null
        ? 'primResID $primResId (uncatalogued — numeric id only)'
        : 'primResID $primResId = ${op.opName} (${op.basis == PrimNameBasis.corpusLabel ? 'corpus-labelled' : 'adjacency-inferred'})';
    return '$opPart · $iconPart';
  }
  return 'class 0x${object.kind.toRadixString(16)} single-op identity '
      '(no primResID record — nodes of this class share one operation; a '
      'visible difference between two of them is undecoded state) · $iconPart';
}

String _iconStatusSuffix(BdObject object) {
  final key = primIconKeyOf(object);
  if (key == null) return '';
  final name = primIconName(key);
  final status = kPrimIconStatus[name];
  return status == null ? '' : ' · icon ${status.name}';
}

PrimIconArt? primIconArtFor(
  BdObject object,
  BdDiagram diagram,
  Map<int, PrimIconArt> icons,
) {
  final base = primIconKeyOf(object);
  if (base == null) return null;
  final key = resolvePrimIconKey(base, diagram.version)!;
  if (base >= 0) return icons[key];
  final terms = diagram
      .childrenOf(object)
      .where((c) => c.objectClass == BdObjectClass.terminalHolder)
      .length;
  final variant =
      icons[resolvePrimIconKey(
        classVariantIconKey(object.kind, terms),
        diagram.version,
      )!];
  if (variant != null) {
    final b = object.absBounds;
    if (b != null && variant.width == b.width && variant.height == b.height) {
      return variant;
    }
  }
  final legacy = icons[key];
  final b = object.absBounds;
  if (legacy == null || b == null) return legacy;
  return legacy.width == b.width && legacy.height == b.height ? legacy : null;
}

const kPrimIconPrescale = 4;

/// One primitive icon: its pixels, the measurements the painters take from them, its [image]
/// and that image drawn at [kPrimIconPrescale] as [sharp].
class PrimIconArt {
  PrimIconArt({
    required this.width,
    required this.height,
    required this.rgba,
    required this.alpha,
    required this.cornerAa,
    required this.inkBounds,
    required this.image,
    required this.sharp,
  });

  final int width;

  final int height;

  final Uint8List rgba;

  final Uint8List alpha;

  final Set<int> cornerAa;

  final ui.Rect? inkBounds;

  final ui.Image image;

  final ui.Image sharp;
}

/// The primitive icons by icon key, filled once by [loadPrimIcons] before the first frame.
final Map<int, PrimIconArt> primIcons = {};

/// The disabled-structure variants of [primIcons], greyed through [_greyDisabledColor].
final Map<int, PrimIconArt> primIconsGrey = {};

/// The LabVIEW generations of each icon key that has several: the first major each one
/// serves and its own key, in ascending order.
final Map<int, List<(int, int)>> primIconVersions = {};

/// The key of the art [key] shows in a VI saved by LabVIEW [version]: the generation that
/// starts at or before the VI's major, else the oldest; [key] itself when it has one.
int? resolvePrimIconKey(int? key, String? version) {
  final generations = key == null ? null : primIconVersions[key];
  if (generations == null) return key;
  final major = int.tryParse((version ?? '').split('.').first) ?? 0;
  var chosen = generations.first.$2;
  for (final (from, id) in generations) {
    if (from <= major) chosen = id;
  }
  return chosen;
}

/// Raises every icon in [kPrimIconArt] into [primIcons] and [primIconsGrey]; the app calls it
/// before the first frame, so every painter finds its icons.
Map<int, PrimIconArt> loadPrimIcons() {
  if (primIcons.isNotEmpty) return primIcons;
  final indexOfCharacter = Int32List(kPrimIconPaletteCodeUnits);
  final palette = Int32List(kPrimIconPalette.length);
  var entry = 0;
  for (final MapEntry(key: character, value: argb)
      in kPrimIconPalette.entries) {
    indexOfCharacter[character.codeUnitAt(0)] = entry;
    palette[entry++] = argb;
  }
  final greyPalette = Int32List.fromList([
    0,
    for (final argb in palette.skip(1)) _greyDisabledColor(argb),
  ]);
  for (final MapEntry(key: key, value: art) in kPrimIconArt.entries) {
    if (kPrimIconStatus[key] == PrimIconStatus.rejected) continue;
    final id = parsePrimIconName(key)!;
    if (primIconVersionOf(id) case (final base, final from)) {
      (primIconVersions[base] ??= [])
        ..add((from, id))
        ..sort((a, b) => a.$1.compareTo(b.$1));
    }
    final width = art.indexOf('|');
    final height = art.length ~/ (width + 1);
    final indices = Uint16List(width * height);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        indices[y * width + x] =
            indexOfCharacter[art.codeUnitAt(y * (width + 1) + x)];
      }
    }
    final pixels = Uint8List(width * height * 4);
    final greyPixels = Uint8List(width * height * 4);
    final alpha = Uint8List(width * height);
    for (var i = 0; i < indices.length; i++) {
      final index = indices[i];
      if (index == 0) continue;
      final argb = palette[index], grey = greyPalette[index] & 0xff;
      pixels[i * 4] = (argb >> 16) & 0xff;
      pixels[i * 4 + 1] = (argb >> 8) & 0xff;
      pixels[i * 4 + 2] = argb & 0xff;
      pixels[i * 4 + 3] = 0xff;
      greyPixels[i * 4] = greyPixels[i * 4 + 1] = greyPixels[i * 4 + 2] = grey;
      greyPixels[i * 4 + 3] = 0xff;
      alpha[i] = 0xff;
    }
    final corners = <int>{};
    var minX = width, minY = height, maxX = -1, maxY = -1;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final i = y * width + x;
        if (alpha[i] == 0) continue;
        if (x < minX) minX = x;
        if (y < minY) minY = y;
        if (x > maxX) maxX = x;
        if (y > maxY) maxY = y;
        if (palette[indices[i]] != 0xffdddddd) continue;
        final onEdge =
            x == 0 ||
            y == 0 ||
            x == width - 1 ||
            y == height - 1 ||
            alpha[i - 1] == 0 ||
            alpha[i + 1] == 0 ||
            alpha[i - width] == 0 ||
            alpha[i + width] == 0;
        if (onEdge) corners.add(i);
      }
    }
    final inkBounds = maxX < minX
        ? null
        : ui.Rect.fromLTRB(
            minX.toDouble(),
            minY.toDouble(),
            maxX + 1.0,
            maxY + 1.0,
          );
    final rects = _rects(indices, width, height, palette.length);
    final image = _imageOf(rects, palette, width, height);
    final greyImage = _imageOf(rects, greyPalette, width, height);
    primIcons[id] = PrimIconArt(
      width: width,
      height: height,
      rgba: pixels,
      alpha: alpha,
      cornerAa: corners,
      inkBounds: inkBounds,
      image: image,
      sharp: _prescaled(image),
    );
    primIconsGrey[id] = PrimIconArt(
      width: width,
      height: height,
      rgba: greyPixels,
      alpha: alpha,
      cornerAa: corners,
      inkBounds: inkBounds,
      image: greyImage,
      sharp: _prescaled(greyImage),
    );
  }
  return primIcons;
}

/// The opaque pixels of [indices] as rectangles of one palette index each, grouped by that
/// index: every run of equal pixels in a row, merged with the identical run beneath it. The six
/// vertices of each rectangle's two triangles follow one another.
List<Float32List> _rects(
  Uint16List indices,
  int width,
  int height,
  int colors,
) {
  final left = Int32List(indices.length ~/ 2 + 1);
  final top = Int32List(left.length);
  final right = Int32List(left.length);
  final bottom = Int32List(left.length);
  final color = Int32List(left.length);
  final rectAbove = Int32List(width);
  final rectHere = Int32List(width);
  final perColor = Int32List(colors);
  var count = 0;
  for (var y = 0; y < height; y++) {
    final row = y * width;
    rectHere.fillRange(0, width, -1);
    var x = 0;
    while (x < width) {
      final index = indices[row + x];
      if (index == 0) {
        x++;
        continue;
      }
      var end = x + 1;
      while (end < width && indices[row + end] == index) {
        end++;
      }
      final above = y == 0 ? -1 : rectAbove[x];
      if (above >= 0 &&
          right[above] == end &&
          color[above] == index &&
          bottom[above] == y) {
        bottom[above] = y + 1;
        rectHere[x] = above;
      } else {
        left[count] = x;
        top[count] = y;
        right[count] = end;
        bottom[count] = y + 1;
        color[count] = index;
        perColor[index]++;
        rectHere[x] = count;
        count++;
      }
      x = end;
    }
    rectAbove.setAll(0, rectHere);
  }
  final vertices = [
    for (var c = 0; c < colors; c++) Float32List(perColor[c] * 12),
  ];
  final filled = Int32List(colors);
  for (var r = 0; r < count; r++) {
    final c = color[r];
    final out = vertices[c];
    final p = filled[c] * 12;
    filled[c]++;
    final l = left[r].toDouble(), t = top[r].toDouble();
    final rr = right[r].toDouble(), bb = bottom[r].toDouble();
    out[p] = l;
    out[p + 1] = t;
    out[p + 2] = rr;
    out[p + 3] = t;
    out[p + 4] = l;
    out[p + 5] = bb;
    out[p + 6] = rr;
    out[p + 7] = t;
    out[p + 8] = rr;
    out[p + 9] = bb;
    out[p + 10] = l;
    out[p + 11] = bb;
  }
  return vertices;
}

/// An image raised on the spot from [rects], one draw per palette entry.
ui.Image _imageOf(
  List<Float32List> rects,
  Int32List palette,
  int width,
  int height,
) {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  final paint = ui.Paint()..isAntiAlias = false;
  for (var c = 1; c < rects.length; c++) {
    if (rects[c].isEmpty) continue;
    paint.color = ui.Color(palette[c]);
    canvas.drawVertices(
      ui.Vertices.raw(ui.VertexMode.triangles, rects[c]),
      ui.BlendMode.srcOver,
      paint,
    );
  }
  return recorder.endRecording().toImageSync(width, height);
}

ui.Image _prescaled(ui.Image image) {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawImageRect(
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
  return recorder.endRecording().toImageSync(
    image.width * kPrimIconPrescale,
    image.height * kPrimIconPrescale,
  );
}

/// The disabled-structure grey of one opaque ARGB colour: white for light colours, 170 otherwise.
int _greyDisabledColor(int argb) {
  final r = (argb >> 16) & 0xff, g = (argb >> 8) & 0xff, b = argb & 0xff;
  final v = r + g + b >= 3 * 204 ? 255 : 170;
  return 0xff000000 | (v << 16) | (v << 8) | v;
}

Future<ui.Image> decodeImage(Uint8List bytes) {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromList(bytes, completer.complete);
  return completer.future;
}

Future<Map<int, ui.Image>> xnodeFacadesFromSections(
  List<DecodedSection> sections,
  BdDiagram diagram,
) async {
  final xnodes = [
    for (final o in diagram.objects)
      if (o.objectClass == BdObjectClass.xnode && o.absBounds != null) o,
  ];
  if (xnodes.isEmpty) return const {};
  final dsims = [
    for (final s in sections)
      if (s.tag == 'DSIM') s,
  ];
  final out = <int, ui.Image>{};
  for (var k = 0; k < xnodes.length && k < dsims.length; k++) {
    final payload = dsims[k].bytes;
    if (payload.length < 46) continue;
    final image = ViDataSpaceImage(payload);
    if (image is! ViDataSpacePng) continue;
    final png = image.png;
    final b = xnodes[k].absBounds!;
    if (png.width != b.right - b.left || png.height != b.bottom - b.top) {
      continue;
    }
    final codec = await ui.instantiateImageCodec(png.serialize());
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
  BdDiagram diagram,
) async {
  if (!diagram.objects.any(
    (o) => o.objectClass == BdObjectClass.xnode && o.absBounds != null,
  )) {
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

const _kCornerAaRung2 = Color(0xFFAAAAAA);

ui.Rect? primIconInkBounds(int key) => primIcons[key]?.inkBounds;

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

int? loadedPrimIconIdOf(BdObject object, {String? version}) {
  final base = primIconKeyOf(object);
  if (base == null) return null;
  final key = resolvePrimIconKey(base, version)!;
  if (base >= 0) return key;
  final b = object.absBounds;
  if (b == null) return key;
  for (var t = 0; t <= 15; t++) {
    final id = resolvePrimIconKey(
      classVariantIconKey(object.kind, t),
      version,
    )!;
    final art = primIcons[id];
    if (art != null && art.width == b.width && art.height == b.height) {
      return id;
    }
  }
  final legacy = primIcons[key];
  if (legacy != null &&
      (legacy.width != b.width || legacy.height != b.height)) {
    return null;
  }
  return key;
}

bool primIconHit(BdObject object, double x, double y, {String? version}) {
  final id = loadedPrimIconIdOf(object, version: version);
  final art = id == null ? null : primIcons[id];
  final bounds = object.absBounds;
  if (art == null || bounds == null) return true;
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
  BdObject object, {
  required bool horizontal,
  required int cross,
  required int sign,
  String? version,
}) {
  final id = loadedPrimIconIdOf(object, version: version);
  final art = id == null ? null : primIcons[id];
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
  Map<Rect, BdObject> iconNodeObjects,
  List<Rect> nodeCoverRects,
  List<Rect> furnitureRects,
});

class BdScene {
  BdScene(BdDiagram diagram, {List<ViWire>? wires, List<BdObject>? drawable})
    : semantics = ViDiagramSemantics(diagram, wires: wires, drawable: drawable);

  final ViDiagramSemantics semantics;

  BdDiagram get diagram => semantics.diagram;

  List<BdObject> get drawable => semantics.drawable;

  List<ViWire> get wires => semantics.wires;

  List<BdObject> get ordered => semantics.ordered;

  Set<int> get disabledOids => semantics.disabledOids;

  Set<int> get errorCaseOids => semantics.errorCaseOids;

  Map<HeapRect, BdBorderTerminal> get borderTerminalKinds =>
      semantics.borderTerminalKinds;

  Map<int, List<({HeapRect box, int bmp})>> get structureTerminals =>
      semantics.structureTerminals;

  Map<int, String> get constValues => semantics.constValues;

  List<HeapRect> get furnitureBounds => semantics.furnitureBounds;

  late final Rect content = heapContentRect(
    drawable.where((o) => o.category != BdObjectKind.wire),
  );

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

  List<BdObject> get objects => scene.ordered;
  List<ViWire> get wires => scene.wires;
  Set<int> get disabledOids => scene.disabledOids;
  Set<int> get errorCaseOids => scene.errorCaseOids;
  Map<HeapRect, BdBorderTerminal> get borderTerminalKinds =>
      scene.borderTerminalKinds;
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

  Rect _rectOf(BdObject object) => _toCanvas(object.absBounds!);

  @override
  void paint(Canvas canvas, Size size) {
    scene.paintedText.clear();
    canvas.scale(canvasScale);
    size = Size(size.width / canvasScale, size.height / canvasScale);
    canvas.drawRect(Offset.zero & size, Paint()..color = kBdCanvas);
    if (drawDotGrid) _drawDotGrid(canvas, size);

    final structures = objects
        .where((o) => o.category == BdObjectKind.structure)
        .toList();
    final decorations = objects
        .where((o) => o.category == BdObjectKind.decoration)
        .toList();
    final wires = objects
        .where((o) => o.category == BdObjectKind.wire)
        .toList();
    final solids =
        objects
            .where(
              (o) =>
                  o.category != BdObjectKind.structure &&
                  o.category != BdObjectKind.decoration &&
                  o.category != BdObjectKind.wire,
            )
            .toList()
          ..sort(
            (a, b) => (b.absBounds!.width * b.absBounds!.height).compareTo(
              a.absBounds!.width * a.absBounds!.height,
            ),
          );

    final arrayShellOids = {
      for (final o in objects)
        if (o.objectClass == BdObjectClass.numeric && o.parentOid != null)
          o.parentOid!,
    };
    final tunnelSquares = <(Rect, BdBorderTerminal, Color)>[];
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
    _paintAttachmentArrows(canvas);
    _paintCaptions(canvas);
  }

  void _paintDecorations(Canvas canvas, List<BdObject> decorations) {
    final backdropCandidates = [
      for (final other in objects)
        if (other.category == BdObjectKind.node ||
            other.category == BdObjectKind.structure ||
            other.category == BdObjectKind.terminal)
          other,
    ];
    bool isBackdrop(BdObject deco) {
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
      if (object.objectClass == BdObjectClass.attachmentArrow) continue;
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
    List<BdObject> structures, {
    required Set<int> arrayShellOids,
    required Set<Rect> chromeOwnedRects,
  }) {
    for (final object in structures) {
      if (object.objectClass == BdObjectClass.cluster) {
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
      if (object.objectClass == BdObjectClass.array &&
          arrayShellOids.contains(object.oid)) {
        _drawArrayConstantShell(canvas, object);
        continue;
      }
      switch (object.objectClass) {
        case BdObjectClass.forLoop:
          _drawForLoopBorder(canvas, rect, disabled: structDisabled);
        case BdObjectClass.whileLoop:
          _drawWhileLoopBand(
            canvas,
            rect,
            structColor,
            disabled: structDisabled,
          );
        case BdObjectClass.caseStructure:
          _drawStructureHatchBorder(
            canvas,
            rect,
            object.absBounds!.left,
            object.absBounds!.top,
            disabled: structDisabled,
            error: errorCaseOids.contains(object.oid),
          );
          if (object.hasFlag(ViObjFlag.caseInsensitiveSelector)) {
            _drawCaseInsensitiveBadge(
              canvas,
              rect,
              disabled: structDisabled,
              oid: object.oid,
            );
          }
        case BdObjectClass.flatSequence:
          _drawFlatSequenceBorder(canvas, rect, object);
        case BdObjectClass.sequenceFrame:
          break;
        case BdObjectClass.disableStructure:
          final showsDisabled = scene.diagram
              .childrenOf(object)
              .any(
                (k) =>
                    k.objectClass == BdObjectClass.caseSelectorLabel &&
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
              _dimFor(object.oid, _kindColor(BdObjectKind.structure));
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

  void _paintCaseSelectorStrips(Canvas canvas, List<BdObject> solids) {
    for (final object in solids) {
      if (object.objectClass == BdObjectClass.caseSelectorLabel)
        _drawCaseSelector(canvas, _rectOf(object));
    }
  }

  void _paintBorderChrome(
    Canvas canvas,
    List<(Rect, BdBorderTerminal, Color)> tunnelSquares,
  ) {
    tunnelSquares.sort(
      (a, b) => _chromeZOrder(
        a.$2.objectClass,
      ).compareTo(_chromeZOrder(b.$2.objectClass)),
    );
    for (final (rect, info, color) in tunnelSquares) {
      _drawBorderTerminalChrome(canvas, rect, info, color);
    }
  }

  void _paintWireObjects(Canvas canvas, List<BdObject> wires) {
    final wirePaint = Paint()
      ..color = _kindColor(BdObjectKind.wire)
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
    List<BdObject> solids,
    List<(int, Rect, Color)> labelBackings,
  ) {
    final stampedPrimIcons = <({Rect dst, int id})>[];
    for (final object in solids) {
      final rect = _rectOf(object);
      if (kBdTextLabelClasses.contains(object.objectClass)) {
        if (object.objectClass == BdObjectClass.caseSelectorLabel) continue;
        final holder = scene.diagram.byId[object.parentOid ?? -1];
        final backed =
            holder?.objectClass == BdObjectClass.frame ||
            (holder?.objectClass == BdObjectClass.array &&
                !object.hasFlag(ViObjFlag.labelNoBacking));
        final backing = object.isLabelHidden || !backed || object.bgRgb == null
            ? null
            : bdDecodedColor(bdLabelBackingRgb(object.bgRgb!));
        if (backing != null) labelBackings.add((object.oid, rect, backing));
        continue;
      }
      if (object.objectClass == BdObjectClass.cluster &&
          rect.width <= 40 &&
          rect.height <= 24) {
        _drawSmallClusterBox(canvas, object, rect);
        continue;
      }
      switch (object.category) {
        case BdObjectKind.terminal:
          _paintTerminal(canvas, object, rect);
        case BdObjectKind.node:
          _paintNode(canvas, object, rect, stampedPrimIcons);
        default:
          _paintPlainSolid(canvas, object, rect);
      }
    }
  }

  void _paintTerminal(Canvas canvas, BdObject object, Rect rect) {
    final isIndicator = object.panelTerminal?.isIndicator;
    var box = rect;
    if (constValues[object.oid] != null) {
      final kids = scene.diagram.childrenOf(object);
      final named = kids.any(
        (c) =>
            c.objectClass == BdObjectClass.textLabel &&
            !c.isLabelHidden &&
            (c.label?.trim().isNotEmpty ?? false),
      );
      if (named) {
        for (final c in kids) {
          final b = c.absBounds;
          if (c.objectClass == BdObjectClass.chrome &&
              b != null &&
              b.right > b.left) {
            box = _toCanvas(b);
            break;
          }
        }
      }
    }
    final constHolder = scene.diagram.byId[object.parentOid ?? -1];
    final boolValue = constHolder?.constant?.boolValue;
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
        isIndicator != null &&
        box.width == 32 &&
        box.height == 16) {
      final elementKind = artType == ViDataType.array
          ? object.resolvedType?.elementType?.kind
          : null;
      final art = elementKind != null
          ? bdArrayTerminalArtFor(elementKind, indicator: isIndicator == true)
          : bdTerminalArtFor(artType, indicator: isIndicator == true);
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
    final shellParent = scene.diagram.byId[object.parentOid ?? -1];
    if (object.objectClass == BdObjectClass.numeric &&
        shellParent?.objectClass == BdObjectClass.array) {
      return;
    }
    if (isIndicator == true) {
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
      if (object.objectClass == BdObjectClass.string && box.width > 8) {
        canvas.drawRect(
          Rect.fromLTWH(box.left, box.top, 4, box.height),
          _solidNoAa(border),
        );
      }
      if (object.objectClass == BdObjectClass.path &&
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
        shellParent?.objectClass == BdObjectClass.constant;
    if (isIndicator != true &&
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
    if (isIndicator != null && box.height >= 12 && box.width >= 12) {
      final indicator = isIndicator == true;
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
                .childrenOf(object)
                .where(
                  (part) =>
                      part.objectClass == BdObjectClass.controlPart &&
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
            (shellParent?.objectClass == BdObjectClass.constant &&
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
    BdObject object,
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
    if (object.objectClass == BdObjectClass.bundleByName) {
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
      final dst = primIconStampRect(
        rect,
        primIcon.width,
        primIcon.height,
        key: iconKey,
      );
      final art = filter == FilterQuality.none
          ? primIcon.image
          : primIcon.sharp;
      canvas.drawImageRect(
        art,
        Rect.fromLTWH(0, 0, art.width.toDouble(), art.height.toDouble()),
        dst,
        Paint()..filterQuality = filter,
      );
      final ladderId = disabled
          ? null
          : loadedPrimIconIdOf(object, version: scene.diagram.version);
      final corners =
          (ladderId == null ? null : primIcons[ladderId]?.cornerAa) ??
          const <int>{};
      for (final artIndex in corners) {
        final artWidth = primIcon.width;
        final cornerX = dst.left + artIndex % artWidth;
        final cornerY = dst.top + artIndex ~/ artWidth;
        var beneathCorner = false;
        Color? restore;
        for (final prior in stampedPrimIcons.reversed) {
          final localX = (cornerX - prior.dst.left).round();
          final localY = (cornerY - prior.dst.top).round();
          final priorArt = primIcons[prior.id];
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
    final glyph = switch (object.primitive?.primResId) {
      final id? when icon == null && primIcon == null => primOpGlyph(
        PrimOp.fromId(id),
      ),
      _ => null,
    };
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

  void _paintGrowableNode(Canvas canvas, BdObject object, Rect rect) {
    canvas.drawRect(
      rect,
      Paint()..color = _dimFor(object.oid, const Color(0xFF444444)),
    );
    canvas.drawRect(
      rect.deflate(1),
      Paint()..color = _dimFor(object.oid, Colors.white),
    );
    final rows = <HeapRect>[];
    final rowTerms = <(BdObject, HeapRect)>[];
    final cells = <HeapRect>[];
    final nodeH = object.absBounds!.bottom - object.absBounds!.top;
    final nodeW = object.absBounds!.right - object.absBounds!.left;
    for (final dco in scene.diagram.childrenOf(object)) {
      if (dco.objectClass != BdObjectClass.terminalHolder) continue;
      for (final t in scene.diagram.childrenOf(dco)) {
        final tb = t.termBounds;
        if (t.objectClass != BdObjectClass.byNameTerminal || tb == null)
          continue;
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
          ? term.resolvedType?.elementType?.kind
          : null;
      final rowColor = elementKind != null
          ? labviewTypeColor(
              typeKindOfDataType(elementKind) ?? ViTypeKind.unknown,
            )
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

  void _paintPlainSolid(Canvas canvas, BdObject object, Rect rect) {
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

  /// The arrow from a label to the object it is attached to. Its tip is the pixel where the
  /// line between the two centres enters the target's drawn box, its tail the pixel where the
  /// line from that tip to the label's centre leaves the label, and the shaft runs from the
  /// tail toward the target's centre, stopping short of the tip.
  void _paintAttachmentArrows(Canvas canvas) {
    final diagram = scene.diagram;
    for (final label in objects) {
      final glyph = diagram
          .byId[label.refsOf(HeapRefKind.attachmentRef)?.firstOrNull ?? -1];
      final target =
          diagram.byId[glyph
                  ?.refsOf(HeapRefKind.attachedObjectRef)
                  ?.firstOrNull ??
              -1];
      final lb = label.absBounds;
      if (glyph == null || target == null || lb == null) continue;
      final targetRect = _attachmentTargetRect(target);
      if (targetRect == null) continue;
      final labelRect = _toCanvas(lb);
      final labelCentre = _pixelOf(labelRect.center);
      final targetCentre = _pixelOf(targetRect.center);
      final tip = _rayPixelAt(labelCentre, targetCentre, (p, d) {
        return _rayEntersRect(p, d, targetRect);
      });
      if (tip == null) continue;
      final tail = _rayPixelAt(tip, labelCentre, (p, d) {
        return _rayEntersRect(p, d, labelRect);
      });
      if (tail == null) continue;
      final head = tip + const Offset(0.5, 0.5);
      final foot = tail + const Offset(0.5, 0.5);
      final aim = targetCentre + const Offset(0.5, 0.5) - foot;
      if (aim.distance == 0) continue;
      final along = aim / aim.distance;
      final across = Offset(-along.dy, along.dx);
      final reach =
          (head - foot).dx * along.dx +
          (head - foot).dy * along.dy -
          kAttachmentArrowShaftEnd;
      final ink = Paint()
        ..color = _dimFor(label.oid, Colors.black)
        ..isAntiAlias = true;
      if (reach > 0) {
        canvas.drawLine(
          foot,
          foot + along * reach,
          ink
            ..style = PaintingStyle.stroke
            ..strokeWidth = kAttachmentArrowShaftWidth
            ..strokeCap = StrokeCap.butt,
        );
      }
      final base = head - along * kAttachmentArrowHeadLength;
      final wing = across * kAttachmentArrowHeadHalfWidth;
      final notch = base + along * kAttachmentArrowHeadNotch;
      canvas.drawPath(
        Path()
          ..moveTo(head.dx, head.dy)
          ..lineTo((base + wing).dx, (base + wing).dy)
          ..lineTo(notch.dx, notch.dy)
          ..lineTo((base - wing).dx, (base - wing).dy)
          ..close(),
        ink..style = PaintingStyle.fill,
      );
    }
  }

  /// The box an attachment arrow aims at: the icon art stamped for a primitive, the element
  /// frame of an array, else the object's absolute box.
  Rect? _attachmentTargetRect(BdObject target) {
    final bounds = _absRectOf(target);
    if (bounds == null) return null;
    if (target.objectClass == BdObjectClass.array) {
      final frame = _arrayElementFrame(target, bounds);
      if (frame != null) return _toCanvas(frame);
    }
    final rect = _toCanvas(bounds);
    final id = loadedPrimIconIdOf(target);
    final art = id == null ? null : primIcons[id];
    if (art == null) return rect;
    return primIconStampRect(rect, art.width, art.height, key: id);
  }

  /// The frame around an array's elements: the largest chrome child that reaches the
  /// array's bottom-right corner without starting at its top-left.
  HeapRect? _arrayElementFrame(BdObject array, HeapRect bounds) {
    HeapRect? frame;
    for (final child in scene.diagram.childrenOf(array)) {
      final b = child.bounds;
      if (child.objectClass != BdObjectClass.chrome || b == null) continue;
      if (b.right != bounds.width || b.bottom != bounds.height) continue;
      if (b.left <= 0 && b.top <= 0) continue;
      if (frame == null || b.width * b.height > frame.width * frame.height) {
        frame = b;
      }
    }
    if (frame == null) return null;
    return HeapRect(
      top: bounds.top + frame.top,
      left: bounds.left + frame.left,
      bottom: bounds.top + frame.bottom,
      right: bounds.left + frame.right,
    );
  }

  /// The pixel holding [point], as its top-left corner.
  static Offset _pixelOf(Offset point) =>
      Offset(point.dx.floorToDouble(), point.dy.floorToDouble());

  /// The pixel where the ray from [from] through [to] crosses the box that [crossing]
  /// measures, or null when the ray never does.
  static Offset? _rayPixelAt(
    Offset from,
    Offset to,
    double? Function(Offset origin, Offset direction) crossing,
  ) {
    final span = to - from;
    if (span.distance == 0) return null;
    final direction = span / span.distance;
    final distance = crossing(from, direction);
    if (distance == null || distance < 0) return null;
    return _pixelOf(from + direction * distance);
  }

  /// How far along [direction] from [origin] the ray enters [rect].
  static double? _rayEntersRect(Offset origin, Offset direction, Rect rect) {
    var distance = double.negativeInfinity;
    if (direction.dx > 0) {
      distance = math.max(distance, (rect.left - origin.dx) / direction.dx);
    } else if (direction.dx < 0) {
      distance = math.max(distance, (rect.right - origin.dx) / direction.dx);
    }
    if (direction.dy > 0) {
      distance = math.max(distance, (rect.top - origin.dy) / direction.dy);
    } else if (direction.dy < 0) {
      distance = math.max(distance, (rect.bottom - origin.dy) / direction.dy);
    }
    return distance.isFinite ? distance : null;
  }

  /// The absolute box of [object]: its bounds, or its terminal box within the nearest bounded
  /// ancestor.
  HeapRect? _absRectOf(BdObject object) {
    final bounds = object.absBounds;
    if (bounds != null) return bounds;
    final term = object.termBounds;
    if (term == null) return null;
    var owner = scene.diagram.parentOf(object);
    while (owner != null && owner.absBounds == null) {
      owner = scene.diagram.parentOf(owner);
    }
    final ob = owner?.absBounds;
    if (ob == null) return null;
    return HeapRect(
      top: ob.top + term.top,
      left: ob.left + term.left,
      bottom: ob.top + term.bottom,
      right: ob.left + term.right,
    );
  }

  void _paintCaptions(Canvas canvas) {
    final byOid = {for (final o in objects) o.oid: o};
    for (final object in objects) {
      if (kBdTextLabelClasses.contains(object.objectClass)) {
        if (object.isLabelHidden) continue;
        var text = object.objectClass == BdObjectClass.caseSelectorLabel
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
        final selector = object.objectClass == BdObjectClass.caseSelectorLabel;
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
      if (object.category == BdObjectKind.structure ||
          object.category == BdObjectKind.node) {
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
    List<(Rect, BdBorderTerminal, Color)>? tunnelSquares,
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
    final iconNodeObjects = <Rect, BdObject>{};
    final nodeCoverRects = <Rect>[];
    for (final object in objects) {
      final bounds = object.absBounds;
      if (bounds == null) continue;
      if (object.category == BdObjectKind.node &&
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
      if (object.category == BdObjectKind.terminal &&
          object.typeKind != ViTypeKind.unknown) {
        typedTerminalColors[packed] = bdTerminalTypeColor(object);
      }
      final iconKey = loadedPrimIconIdOf(
        object,
        version: scene.diagram.version,
      );
      if (iconKey != null) {
        final boxRect = _toCanvas(bounds);
        iconNodeRects.add(boxRect);
        iconNodeObjects[boxRect] = object;
        final art = primIcons[iconKey];
        final ink = art?.inkBounds;
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
      final output = switch (object.primitive?.primResId) {
        final id? => PrimOp.fromId(id)?.output,
        null => null,
      };
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
        final resolved = endpoint.resolvedType;
        if (resolved != null && isErrorClusterShape(resolved.members)) {
          netError[root] = true;
        }
        if ((resolved?.members.isNotEmpty ?? false) ||
            (resolved?.elementMembers.isNotEmpty ?? false) ||
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
    required List<(Rect, BdBorderTerminal, Color)>? tunnelSquares,
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

  List<(Rect, BdBorderTerminal)> _wireTunnelChrome(ViWire wire) {
    final tunnels = <(Rect, BdBorderTerminal)>[];
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
                version: scene.diagram.version,
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
                version: scene.diagram.version,
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
                version: scene.diagram.version,
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
                version: scene.diagram.version,
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
      version: scene.diagram.version,
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
          version: scene.diagram.version,
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
            version: scene.diagram.version,
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
            version: scene.diagram.version,
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
        version: scene.diagram.version,
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
        if (shell.objectClass != BdObjectClass.array ||
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

  void _drawFlatSequenceBorder(Canvas canvas, Rect rect, BdObject seq) {
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
          .childrenOf(seq)
          .where(
            (c) =>
                c.objectClass == BdObjectClass.sequenceFrame &&
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

  void _drawArrayConstantShell(Canvas canvas, BdObject shell) {
    final children = scene.diagram.childrenOf(shell).toList();
    ViTypeKind elementType = ViTypeKind.unknown;
    BdObject? element;
    for (final c in children) {
      if (c.objectClass != BdObjectClass.numeric) continue;
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
      if (c.objectClass == BdObjectClass.numeric &&
          b != null &&
          !identical(c, element)) {
        for (final part in scene.diagram.childrenOf(c)) {
          final pb = part.absBounds;
          if (pb == null) continue;
          if (part.objectClass == BdObjectClass.controlPart ||
              part.objectClass == BdObjectClass.chrome)
            border(pb);
          if (part.objectClass == BdObjectClass.chrome &&
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
          if (part.objectClass == BdObjectClass.controlPart) {
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
      if (c.objectClass != BdObjectClass.chrome ||
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
    final values = holder?.constant?.array;
    final dims = holder?.constant?.arrayDims;
    final format = bdDisplayFormatOf(scene.diagram, element.oid);
    final marker = kBdRadixMarkerGlyphs[bdFormatConversion(format)];
    var radixDx = 2, radixDy = 3;
    for (final part in scene.diagram.childrenOf(element)) {
      if (part.objectClass == BdObjectClass.controlPart &&
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

  static int _chromeZOrder(BdObjectClass objectClass) => switch (objectClass) {
    BdObjectClass.loopTunnel || BdObjectClass.caseTunnel => 0,
    BdObjectClass.leftShiftRegister || BdObjectClass.rightShiftRegister => 1,
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
    BdBorderTerminal info,
    Color wireColor,
  ) {
    final objectClass = info.objectClass;
    final ringColor = info.disabled ? kBdDisabledChromeGrey : kBdTunnelBorder;
    final creamColor = info.disabled
        ? bdDimDisabled(kBdTerminalFill)
        : kBdTerminalFill;
    final noAa = _solidNoAa(wireColor);
    if (kBdTunnelClasses.contains(objectClass)) {
      {
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
      }
    } else if (kBdShiftRegisterClasses.contains(objectClass)) {
      {
        canvas.drawRect(t, noAa);
        canvas.drawRect(t.deflate(2), _solidNoAa(creamColor));
        if (t.width == 16 && t.height == 12) {
          final down = objectClass == BdObjectClass.leftShiftRegister;
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
      }
    } else if (objectClass == BdObjectClass.caseSelectorTerminal) {
      {
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

  void _drawSmallClusterBox(Canvas canvas, BdObject object, Rect rect) {
    final tint = _dimFor(object.oid, switch (object.resolvedType) {
      final resolved? when resolved.members.isNotEmpty => _clusterTint(
        resolved.members,
      ),
      _ => labviewTypeColor(object.typeKind),
    });
    canvas.drawRect(rect, _solidNoAa(tint));
    canvas.drawRect(rect.deflate(1), _solidNoAa(Colors.white));
    canvas.drawRect(rect.deflate(2), _solidNoAa(tint));
    canvas.drawRect(rect.deflate(3), _solidNoAa(Colors.white));
    if (scene.diagram.byId[object.parentOid ?? -1]?.objectClass !=
        BdObjectClass.constant) {
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
  final BdObject? selected;
  final Set<BdObject> members;

  final double canvasScale;

  Rect _rectOf(BdObject o) {
    final bounds = o.absBounds!;
    final rect = Rect.fromLTRB(
      bounds.left - origin.dx,
      bounds.top - origin.dy,
      bounds.right - origin.dx,
      bounds.bottom - origin.dy,
    );
    final key = primIconKeyOf(o);
    final art = key == null ? null : primIcons[key];
    return art == null
        ? rect
        : primIconStampRect(rect, art.width, art.height, key: key);
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

class _DetailsCard extends StatelessWidget {
  const _DetailsCard({
    required this.object,
    required this.onClose,
    this.members = const {},
  });
  final BdObject object;
  final VoidCallback onClose;

  final Set<BdObject> members;

  static String _contentLabel(BdObject o) {
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
    return HeapDetailsCard(
      swatch: _objectColor(object),
      title:
          object.label ??
          (!cls.isUnknown
              ? cls.label
              : switch (object.category) {
                  BdObjectKind.node => 'Node',
                  BdObjectKind.structure => 'Structure',
                  BdObjectKind.terminal => 'Terminal',
                  _ => cls.label,
                }),
      subtitle:
          '${cls.label}$conf · class 0x${object.kind.toRadixString(16)} · oid ${object.oid}'
          '${object.isLabelHidden ? ' · hidden' : ''}'
          '${switch (object.frames) {
            final frames? => ' · shows frame ${frames.visibleFrameIndex + 1}',
            null => '',
          }}'
          '${_iconStatusSuffix(object)}'
          '${object.typeKind != ViTypeKind.unknown ? ' · type ${object.typeKind.name}' : ''}'
          '${bounds != null ? ' · ${bounds.width}×${bounds.height} @(${bounds.left},${bounds.top})' : ''}'
          '${object.parentOid != null ? ' · parent ${object.parentOid}' : ''}',
      details: [
        if (_primDetail(object) case final prim?) detailLine('primitive', prim),
        if (object.items.isNotEmpty)
          detailLine(
            'values',
            object.items.take(8).join(', ') +
                (object.items.length > 8 ? ', …' : ''),
          ),
        if (object.helpText != null &&
            stripHelpMarkup(object.helpText!).isNotEmpty)
          detailLine('help', stripHelpMarkup(object.helpText!)),
        if (object.constant?.text case final text? when text.isNotEmpty)
          detailLine('const', text),
        if (members.isNotEmpty)
          detailLine(
            'contains',
            members.map(_contentLabel).take(10).join(', ') +
                (members.length > 10 ? ', …' : ''),
          ),
      ],
      onClose: onClose,
    );
  }
}

class _BdOutline extends StatelessWidget {
  const _BdOutline({required this.outline, this.linkedSubVis = const []});
  final ({
    Map<BdObjectClass, int> structuresByClass,
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

  @override
  Widget build(BuildContext context) {
    final icon = images.bestIcon;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          if (icon != null)
            _tile(
              'VI icon (${icon.depth.tag})',
              CustomPaint(
                size: const Size(36, 36),
                painter: LegacyIconPainter(icon),
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

/// The attachment arrow's shaft width, and how far short of the tip the shaft ends.
const double kAttachmentArrowShaftWidth = 2;

const double kAttachmentArrowShaftEnd = 11;

/// The attachment arrow's head: its length from tip to barbs, half its width across the
/// barbs, and how far the notch between the barbs cuts back toward the tip.
const double kAttachmentArrowHeadLength = 11.75;

const double kAttachmentArrowHeadHalfWidth = 3.75;

const double kAttachmentArrowHeadNotch = 3;
