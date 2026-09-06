library;

import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import 'diagram_view.dart';
import 'image_clipboard.dart';
import 'oracle_gif.dart';

class BdRaster {
  const BdRaster({
    required this.image,
    required this.content,
    required this.scale,
  });

  final ui.Image image;
  final Rect content;
  final double scale;

  Rect modelRect(HeapRect bounds) => Rect.fromLTRB(
    (bounds.left - content.left) * scale,
    (bounds.top - content.top) * scale,
    (bounds.right - content.left) * scale,
    (bounds.bottom - content.top) * scale,
  );
}

GlobalHatchOffset deriveHatchOffset({
  required ViDiagram diagram,
  required BdRaster raster,
  required BdRegistration registration,
  required Uint8List referenceRgba,
  required int width,
  required int height,
  required bool errorStyle,
}) {
  final errorOids = bdErrorCaseOids(diagram);
  final drawableOids = {
    for (final object in bdDrawableObjects(diagram)) object.oid,
  };
  final tile = errorStyle ? kBdErrorHatch : kBdStructureHatch;
  final pyRange = errorStyle ? 1 : 4;
  final score = List.generate(4, (_) => List.filled(4, 0));
  var samples = 0;
  for (final frame in diagram.objects) {
    if (frame.objectClass != HeapObjectClass.bdStructureFrame ||
        !drawableOids.contains(frame.oid)) {
      continue;
    }
    if (errorOids.contains(frame.oid) != errorStyle) continue;
    final bounds = frame.absBounds;
    if (bounds == null) continue;
    for (var y = bounds.top; y <= bounds.bottom; y++) {
      for (var x = bounds.left; x <= bounds.right; x++) {
        final inset = math.min(
          math.min(x - bounds.left, bounds.right - x),
          math.min(y - bounds.top, bounds.bottom - y),
        );
        if (inset < 1 || inset > kBdHatchBand) continue;
        final rx =
            ((x - raster.content.left) * registration.scale + registration.dx)
                .round();
        final ry =
            ((y - raster.content.top) * registration.scale + registration.dy)
                .round();
        if (rx < 0 || ry < 0 || rx >= width || ry >= height) continue;
        final i = (ry * width + rx) * 4;
        final red = referenceRgba[i],
            green = referenceRgba[i + 1],
            blue = referenceRgba[i + 2];
        final bool dark;
        if (errorStyle) {
          final isField = green > 200 && red < 200 && blue < 200;
          final isStripe =
              !isField &&
              (red - blue).abs() < 30 &&
              green < 200 &&
              red > 90 &&
              red < 170;
          if (!isField && !isStripe) continue;
          dark = isStripe;
        } else {
          dark = (red + green + blue) ~/ 3 < 110;
        }
        samples++;
        for (var py = 0; py < pyRange; py++) {
          for (var px = 0; px < 4; px++) {
            final ink = tile[(y + py) & 3][(x + px) & 3] == '#';
            score[py][px] += ink == dark ? 1 : -1;
          }
        }
      }
    }
  }
  if (samples == 0) return kNoHatchOffset;
  var bestX = 0, bestY = 0, best = -samples - 1, second = -samples - 1;
  for (var py = 0; py < pyRange; py++) {
    for (var px = 0; px < 4; px++) {
      final cellScore = score[py][px];
      if (cellScore > best) {
        second = best;
        best = cellScore;
        bestX = px;
        bestY = py;
      } else if (cellScore > second) {
        second = cellScore;
      }
    }
  }
  if (best < samples ~/ 2 || best == second) return kNoHatchOffset;
  return (x: bestX, y: bestY);
}

GlobalHatchOffset deriveWireCycleOffset({
  required BdScene scene,
  required BdRaster raster,
  required BdRegistration registration,
  required Uint8List referenceRgba,
  required int width,
  required int height,
}) {
  int refPixel(int rx, int ry) {
    if (rx < 0 || ry < 0 || rx >= width || ry >= height) return -1;
    final i = (ry * width + rx) * 4;
    return (referenceRgba[i] << 16) |
        (referenceRgba[i + 1] << 8) |
        referenceRgba[i + 2];
  }

  final score = List.filled(4, 0);
  var samples = 0;
  for (final wire in scene.wires) {
    final style = wire.signalType?.renderStyle;
    if (style == ViWireRenderStyle.braid) continue;
    final cycle = kBdWireStrokeCycles[style];
    final stylePhase = kBdWireCyclePhase[style];
    if (cycle == null || stylePhase == null || cycle.length != 4) continue;
    final legs = <List<ViPoint>>[
      if (wire.routePoints case final p? when p.length >= 2) p,
      ...?wire.routeTree?.polylines,
    ];
    for (final leg in legs) {
      for (var s = 0; s + 1 < leg.length; s++) {
        final a = leg[s], b = leg[s + 1];
        if (a.x == b.x && (a.y - b.y).abs() >= 14) {
          final vlo = math.min(a.y, b.y) + 3, vhi = math.max(a.y, b.y) - 3;
          int rxOf(num x) =>
              ((x - raster.content.left) * registration.scale + registration.dx)
                  .round();
          int ryOf(num y) =>
              ((y - raster.content.top) * registration.scale + registration.dy)
                  .round();
          final bands = switch (style) {
            ViWireRenderStyle.zigzag => const [-1, 0],
            ViWireRenderStyle.chainLink => const [-1, 0, 1],
            _ => const [-2, -1, 0, 1],
          };
          final counts = <int, int>{};
          for (var y = vlo; y <= vhi; y++) {
            for (var bit = -2; bit <= 2; bit++) {
              final c = refPixel(rxOf(a.x + bit), ryOf(y));
              if (c != 0xffffff && c != -1) counts[c] = (counts[c] ?? 0) + 1;
            }
          }
          if (counts.isEmpty) continue;
          final ink =
              (counts.entries.toList()
                    ..sort((p, q) => q.value.compareTo(p.value)))
                  .first
                  .key;
          for (var y = vlo; y <= vhi; y++) {
            var clean = true;
            for (var bit = -2; bit <= 2; bit++) {
              final c = refPixel(rxOf(a.x + bit), ryOf(y));
              if (c != 0xffffff && c != ink) clean = false;
            }
            if (!clean) continue;
            samples += bands.length;
            for (var cand = 0; cand < 4; cand++) {
              for (final band in bands) {
                final x = a.x + band;
                final predicted = (x + ((y & 1) << 1) + cand) % 4 != 0;
                final observed = refPixel(rxOf(x), ryOf(y)) == ink;
                score[cand] += predicted == observed ? 1 : -1;
              }
            }
          }
          continue;
        }
        if (a.y != b.y || (a.x - b.x).abs() < 14) continue;
        final lo = math.min(a.x, b.x) + 3, hi = math.max(a.x, b.x) - 3;
        int rxOf(num x) =>
            ((x - raster.content.left) * registration.scale + registration.dx)
                .round();
        int ryOf(num y) =>
            ((y - raster.content.top) * registration.scale + registration.dy)
                .round();
        final counts = <int, int>{};
        for (var x = lo; x <= hi; x++) {
          for (var bit = -2; bit <= 2; bit++) {
            final c = refPixel(rxOf(x), ryOf(a.y + bit));
            if (c != 0xffffff && c != -1) counts[c] = (counts[c] ?? 0) + 1;
          }
        }
        if (counts.isEmpty) continue;
        final ink =
            (counts.entries.toList()
                  ..sort((p, q) => q.value.compareTo(p.value)))
                .first
                .key;
        for (var x = lo; x <= hi; x++) {
          var clean = true;
          for (var bit = -2; bit <= 2; bit++) {
            final c = refPixel(rxOf(x), ryOf(a.y + bit));
            if (c != 0xffffff && c != ink) clean = false;
          }
          if (!clean) continue;
          samples += 5;
          for (var px = 0; px < 4; px++) {
            final mask = cycle[(x + ((a.y & 1) << 1) + stylePhase + px) % 4];
            for (var bit = 0; bit < 5; bit++) {
              final inked = refPixel(rxOf(x), ryOf(a.y + bit - 2)) == ink;
              score[px] += inked == ((mask >> bit) & 1 != 0) ? 1 : -1;
            }
          }
        }
      }
    }
  }
  if (samples == 0) return kNoHatchOffset;
  var bestX = 0, best = -samples - 1, second = -samples - 1;
  for (var px = 0; px < 4; px++) {
    if (score[px] > best) {
      second = best;
      best = score[px];
      bestX = px;
    } else if (score[px] > second) {
      second = score[px];
    }
  }
  if (best < samples ~/ 2 || best == second) return kNoHatchOffset;
  return (x: bestX, y: 0);
}

Future<BdRaster?> rasteriseBlockDiagram(
  ViDiagram diagram, {
  int maxDimension = 2000,
  double pixelRatio = 1.0,
  double? scale,
  int margin = 40,
  Map<int, ViLegacyIcon> subViIcons = const {},
  Map<int, PrimIconArt> primIcons = const {},
  Map<int, ui.Image> xnodeFacades = const {},
  List<ViWire>? wires,
  List<ViHeapObject>? drawable,
  BdScene? scene,
  BdRenderStyle style = const BdRenderStyle(),
}) async {
  final ownScene = scene == null;
  final activeScene =
      scene ?? BdScene(diagram, wires: wires, drawable: drawable);
  if (activeScene.drawable.isEmpty) {
    if (ownScene) activeScene.dispose();
    return null;
  }
  final content = bdContentRect(
    activeScene.drawable,
    includeWires: false,
    margin: margin,
  );
  if (content.width <= 0 || content.height <= 0) {
    if (ownScene) activeScene.dispose();
    return null;
  }

  final longSide = math.max(content.width, content.height);
  var pxScale =
      scale ?? (maxDimension / longSide).clamp(0.01, 8.0) * pixelRatio;
  if (longSide * pxScale > 8192) pxScale = 8192 / longSide;
  final width = (content.width * pxScale).ceil().clamp(1, 8192);
  final height = (content.height * pxScale).ceil().clamp(1, 8192);

  if (activeScene.disabledOids.isNotEmpty) await ensurePrimIconsGrey();
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(
    recorder,
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
  );
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = kBdCanvas,
  );
  canvas.scale(pxScale);
  BdDiagramPainter(
    scene: activeScene,
    origin: content.topLeft,
    subViIcons: subViIcons,
    primIcons: primIcons,
    xnodeFacades: xnodeFacades,
    primIconsGrey: primIconsGreyLoaded(),
    drawDotGrid: false,
    style: style,
  ).paint(canvas, content.size);
  final picture = recorder.endRecording();
  try {
    return BdRaster(
      image: await picture.toImage(width, height),
      content: content,
      scale: pxScale,
    );
  } finally {
    picture.dispose();
    if (ownScene) activeScene.dispose();
  }
}

class ImageComparison {
  const ImageComparison({
    required this.width,
    required this.height,
    required this.meanAbsDiff,
    required this.diffFraction,
    required this.diff,
  });

  final int width;
  final int height;

  final double meanAbsDiff;

  final double diffFraction;

  final Uint8List diff;
}

ImageComparison compareRgba(
  Uint8List a,
  Uint8List b,
  int width,
  int height, {
  int threshold = 16,
}) {
  assert(a.length == b.length, 'buffers differ in length');
  assert(a.length == width * height * 4, 'buffer is not width*height*4');
  final diff = Uint8List(a.length);
  var sum = 0;
  var changed = 0;
  for (var i = 0; i < a.length; i += 4) {
    final dr = (a[i] - b[i]).abs();
    final dg = (a[i + 1] - b[i + 1]).abs();
    final db = (a[i + 2] - b[i + 2]).abs();
    sum += dr + dg + db;
    final maxChannel = math.max(dr, math.max(dg, db));
    if (maxChannel > threshold) changed++;
    diff[i] = dr;
    diff[i + 1] = dg;
    diff[i + 2] = db;
    diff[i + 3] = 0xff;
  }
  final pixels = width * height;
  return ImageComparison(
    width: width,
    height: height,
    meanAbsDiff: pixels == 0 ? 0 : sum / (pixels * 3),
    diffFraction: pixels == 0 ? 0 : changed / pixels,
    diff: diff,
  );
}

class StructuralComparison {
  const StructuralComparison({
    required this.inkFractionRender,
    required this.inkFractionReference,
    required this.inkIoU,
    required this.edgeIoU,
  });

  final double inkFractionRender;

  final double inkFractionReference;

  final double inkIoU;

  final double edgeIoU;

  double get score => (inkIoU + edgeIoU) / 2;
}

const int kBdEdgeThreshold = 64;

StructuralComparison compareStructural(
  Uint8List a,
  Uint8List b,
  int width,
  int height, {
  int inkThreshold = 12,
  int edgeThreshold = kBdEdgeThreshold,
  Uint8List? referenceEdges,
}) {
  assert(a.length == b.length, 'buffers differ in length');
  assert(a.length == width * height * 4, 'buffer is not width*height*4');
  final pixels = width * height;
  final lumA = _luma(a, pixels);
  final lumB = _luma(b, pixels);

  var inkA = 0, inkB = 0, inkInter = 0, inkUnion = 0;
  for (var i = 0; i < pixels; i++) {
    final ia = 255 - lumA[i] > inkThreshold;
    final ib = 255 - lumB[i] > inkThreshold;
    if (ia) inkA++;
    if (ib) inkB++;
    if (ia || ib) {
      inkUnion++;
      if (ia && ib) inkInter++;
    }
  }

  final edgeA = _sobelMask(lumA, width, height, edgeThreshold);
  final edgeB =
      referenceEdges ?? _sobelMask(lumB, width, height, edgeThreshold);
  var edgeInter = 0, edgeUnion = 0;
  for (var i = 0; i < pixels; i++) {
    final ea = edgeA[i] != 0;
    final eb = edgeB[i] != 0;
    if (ea || eb) {
      edgeUnion++;
      if (ea && eb) edgeInter++;
    }
  }

  return StructuralComparison(
    inkFractionRender: pixels == 0 ? 0 : inkA / pixels,
    inkFractionReference: pixels == 0 ? 0 : inkB / pixels,
    inkIoU: inkUnion == 0 ? 1 : inkInter / inkUnion,
    edgeIoU: edgeUnion == 0 ? 1 : edgeInter / edgeUnion,
  );
}

Uint8List _luma(Uint8List rgba, int pixels) {
  final out = Uint8List(pixels);
  for (var i = 0; i < pixels; i++) {
    final j = i * 4;
    out[i] = (rgba[j] * 77 + rgba[j + 1] * 150 + rgba[j + 2] * 29) >> 8;
  }
  return out;
}

Uint8List _sobelMask(Uint8List lum, int width, int height, int threshold) {
  final out = Uint8List(width * height);
  for (var y = 1; y < height - 1; y++) {
    for (var x = 1; x < width - 1; x++) {
      final i = y * width + x;
      final tl = lum[i - width - 1],
          tt = lum[i - width],
          tr = lum[i - width + 1];
      final ll = lum[i - 1], rr = lum[i + 1];
      final bl = lum[i + width - 1],
          bb = lum[i + width],
          br = lum[i + width + 1];
      final gx = (tr + 2 * rr + br) - (tl + 2 * ll + bl);
      final gy = (bl + 2 * bb + br) - (tl + 2 * tt + tr);
      if (gx.abs() + gy.abs() > threshold) out[i] = 1;
    }
  }
  return out;
}

class BdRegistration {
  const BdRegistration({
    required this.scale,
    required this.dx,
    required this.dy,
  });

  static const identity = BdRegistration(scale: 1, dx: 0, dy: 0);

  final double scale;
  final double dx;
  final double dy;

  Offset map(Offset renderPx) =>
      Offset(renderPx.dx * scale + dx, renderPx.dy * scale + dy);

  Rect mapRect(Rect renderRect) =>
      Rect.fromPoints(map(renderRect.topLeft), map(renderRect.bottomRight));
}

class BdOracleResult {
  const BdOracleResult({
    required this.rendered,
    required this.fitted,
    required this.reference,
    required this.referenceRgba,
    required this.referenceEdges,
    required this.comparison,
    required this.structural,
    required this.diffImage,
    required this.registered,
    required this.registration,
  });

  final ui.Image rendered;
  final ui.Image fitted;
  final ui.Image reference;

  final Uint8List referenceRgba;
  final Uint8List referenceEdges;

  final ImageComparison comparison;

  final StructuralComparison structural;
  final ui.Image diffImage;

  final bool registered;

  final BdRegistration registration;
}

Future<BdOracleResult> compareToReference(
  ui.Image rendered,
  ui.Image reference, {
  int threshold = 16,
  double? lockScale,
  List<Rect> anchorRects = const [],
  BdRegistration? knownRegistration,
  Uint8List? knownReferenceEdges,
}) async {
  final width = reference.width;
  final height = reference.height;
  final renderedWidth = rendered.width;
  final renderedHeight = rendered.height;
  final referenceRgba = await _rgbaOf(reference);
  final skipResample =
      lockScale == null && renderedWidth == width && renderedHeight == height;
  final renderedOwnRgba = skipResample || knownRegistration != null
      ? null
      : await _rgbaOf(rendered);
  final reg = knownRegistration != null && knownReferenceEdges != null
      ? (referenceEdges: knownReferenceEdges, registration: knownRegistration)
      : await Isolate.run(() {
          final referenceEdges =
              knownReferenceEdges ??
              _sobelMask(
                _luma(referenceRgba, width * height),
                width,
                height,
                kBdEdgeThreshold,
              );
          BdRegistration? registration = knownRegistration;
          if (registration == null && renderedOwnRgba != null) {
            final srcInk = inkBoundsOf(
              renderedOwnRgba,
              renderedWidth,
              renderedHeight,
            );
            final dstInk = inkBoundsOf(referenceRgba, width, height);
            if (srcInk != null && dstInk != null) {
              registration = lockScale != null
                  ? _translationRegistration(
                      lockScale,
                      srcInk,
                      dstInk,
                      renderedOwnRgba,
                      renderedWidth,
                      renderedHeight,
                      referenceEdges,
                      width,
                      height,
                      anchorRects: anchorRects,
                    )
                  : _inkBoundsRegistration(srcInk, dstInk);
            }
          }
          return (referenceEdges: referenceEdges, registration: registration);
        });
  final referenceEdges = reg.referenceEdges;
  ui.Image fitted;
  var registered = false;
  var registration = BdRegistration.identity;
  if (skipResample) {
    fitted = rendered;
  } else if (reg.registration != null) {
    registration = reg.registration!;
    fitted = await _redrawRegistered(rendered, registration, width, height);
    registered = true;
  } else {
    registration = _letterboxRegistration(rendered, width, height);
    fitted = await _redrawRegistered(rendered, registration, width, height);
  }
  final renderedRgba = await _rgbaOf(fitted);
  final cmp = await Isolate.run(
    () => (
      comparison: compareRgba(
        renderedRgba,
        referenceRgba,
        width,
        height,
        threshold: threshold,
      ),
      structural: compareStructural(
        renderedRgba,
        referenceRgba,
        width,
        height,
        referenceEdges: referenceEdges,
      ),
    ),
  );
  final comparison = cmp.comparison;
  final structural = cmp.structural;
  final diffImage = await imageFromRgba(comparison.diff, width, height);
  return BdOracleResult(
    rendered: rendered,
    fitted: fitted,
    reference: reference,
    referenceRgba: referenceRgba,
    referenceEdges: referenceEdges,
    comparison: comparison,
    structural: structural,
    diffImage: diffImage,
    registered: registered,
    registration: registration,
  );
}

List<Rect> bdStructureAnchorRects(
  ViDiagram diagram,
  BdRaster raster, {
  List<ViHeapObject>? drawable,
}) {
  drawable ??= bdDrawableObjects(diagram);
  final extent = bdContentRect(drawable, includeWires: false, margin: 0);
  final out = <Rect>[];
  for (final object in drawable) {
    if (object.category != ViObjectKind.structure) continue;
    final bounds = object.absBounds!;
    if (bounds.width < 24 || bounds.height < 24) continue;
    if (bounds.width >= extent.width * 0.95 &&
        bounds.height >= extent.height * 0.95) {
      continue;
    }
    out.add(raster.modelRect(bounds));
  }
  return out;
}

ViDiagram? bestBlockDiagram(ViModel model) {
  ViDiagram? best;
  var bestCount = 0;
  for (final diagram in model.blockDiagrams) {
    final count = diagram.objects.where((o) => o.absBounds != null).length;
    if (count > bestCount) {
      best = diagram;
      bestCount = count;
    }
  }
  return best;
}

Future<Uint8List> imageToPng(ui.Image image) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

Future<Uint8List> _rgbaOf(ui.Image image) async {
  final data = await image.toByteData();
  return data!.buffer.asUint8List();
}

Future<({ui.Image image, bool snippetCropped})> decodeReferenceImage(
  Uint8List bytes,
) async {
  final image = await decodeImage(bytes);
  if (extractSnippetVi(bytes) == null)
    return (image: image, snippetCropped: false);
  final interior = snippetDiagramInterior(image.width, image.height);
  if (interior.right - interior.left < 8 ||
      interior.bottom - interior.top < 8) {
    return (image: image, snippetCropped: false);
  }
  final cropped = await _cropImage(
    image,
    Rect.fromLTRB(
      interior.left.toDouble(),
      interior.top.toDouble(),
      interior.right.toDouble(),
      interior.bottom.toDouble(),
    ),
  );
  image.dispose();
  return (image: cropped, snippetCropped: true);
}

Future<ui.Image> _cropImage(ui.Image src, Rect crop) async {
  final width = crop.width.round();
  final height = crop.height.round();
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(
    recorder,
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
  );
  canvas.drawImageRect(
    src,
    crop,
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..filterQuality = FilterQuality.none,
  );
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(width, height);
  } finally {
    picture.dispose();
  }
}

class PlacementComparison {
  const PlacementComparison({required this.perObject, required this.chance});

  final List<({int oid, double support})> perObject;

  final double chance;

  int get objects => perObject.length;

  double get meanSupport => perObject.isEmpty
      ? 0
      : perObject.fold(0.0, (sum, entry) => sum + entry.support) /
            perObject.length;

  double get excessSupport {
    if (perObject.isEmpty || chance >= 1) return 0;
    var sum = 0.0;
    for (final entry in perObject) {
      sum += ((entry.support - chance) / (1 - chance)).clamp(0.0, 1.0);
    }
    return sum / perObject.length;
  }
}

PlacementComparison comparePlacement({
  required ViDiagram diagram,
  required BdRaster raster,
  required BdRegistration registration,
  required Uint8List referenceRgba,
  required int width,
  required int height,
  Uint8List? referenceEdges,
  List<ViHeapObject>? drawable,
  int tolerance = 2,
  int edgeThreshold = kBdEdgeThreshold,
  int minSide = 6,
}) {
  final pixels = width * height;
  final edges = _dilate(
    referenceEdges ??
        _sobelMask(_luma(referenceRgba, pixels), width, height, edgeThreshold),
    width,
    height,
    tolerance,
  );
  var edgePixels = 0;
  for (var i = 0; i < edges.length; i++) {
    edgePixels += edges[i];
  }
  final chance = pixels == 0 ? 0.0 : edgePixels / pixels;

  drawable ??= bdDrawableObjects(diagram);
  final extent = bdContentRect(drawable, includeWires: false, margin: 0);
  final perObject = <({int oid, double support})>[];
  for (final object in drawable) {
    if (object.category != ViObjectKind.structure &&
        object.category != ViObjectKind.node &&
        object.category != ViObjectKind.terminal &&
        object.category != ViObjectKind.decoration) {
      continue;
    }
    if (kBdTextLabelClasses.contains(object.objectClass)) continue;
    final bounds = object.absBounds!;
    if (bounds.width < minSide || bounds.height < minSide) continue;
    if (bounds.width >= extent.width * 0.95 &&
        bounds.height >= extent.height * 0.95) {
      continue;
    }
    final refRect = registration.mapRect(raster.modelRect(bounds));
    var hits = 0, samples = 0, total = 0;
    void sample(int x, int y) {
      total++;
      if (x < 0 || y < 0 || x >= width || y >= height) return;
      samples++;
      if (edges[y * width + x] != 0) hits++;
    }

    final left = refRect.left.round(), right = refRect.right.round();
    final top = refRect.top.round(), bottom = refRect.bottom.round();
    for (var x = left; x <= right; x++) {
      sample(x, top);
      sample(x, bottom);
    }
    for (var y = top + 1; y < bottom; y++) {
      sample(left, y);
      sample(right, y);
    }
    if (samples < 8 || samples * 2 < total) continue;
    perObject.add((oid: object.oid, support: hits / samples));
  }
  return PlacementComparison(perObject: perObject, chance: chance);
}

Uint8List _dilate(Uint8List mask, int width, int height, int radius) {
  if (radius <= 0) return mask;
  final horizontal = Uint8List(mask.length);
  for (var y = 0; y < height; y++) {
    final row = y * width;
    for (var x = 0; x < width; x++) {
      if (mask[row + x] == 0) continue;
      final from = math.max(0, x - radius),
          to = math.min(width - 1, x + radius);
      for (var i = from; i <= to; i++) {
        horizontal[row + i] = 1;
      }
    }
  }
  final out = Uint8List(mask.length);
  for (var y = 0; y < height; y++) {
    final row = y * width;
    for (var x = 0; x < width; x++) {
      if (horizontal[row + x] == 0) continue;
      final from = math.max(0, y - radius),
          to = math.min(height - 1, y + radius);
      for (var i = from; i <= to; i++) {
        out[i * width + x] = 1;
      }
    }
  }
  return out;
}

Rect? inkBoundsOf(
  Uint8List rgba,
  int width,
  int height, {
  int inkThreshold = 12,
  double trim = 0.01,
}) {
  assert(rgba.length == width * height * 4, 'buffer is not width*height*4');
  final cols = Uint32List(width);
  final rows = Uint32List(height);
  var total = 0;
  for (var y = 0; y < height; y++) {
    final rowBase = y * width;
    for (var x = 0; x < width; x++) {
      final j = (rowBase + x) * 4;
      final lum = (rgba[j] * 77 + rgba[j + 1] * 150 + rgba[j + 2] * 29) >> 8;
      if (255 - lum > inkThreshold) {
        cols[x]++;
        rows[y]++;
        total++;
      }
    }
  }
  if (total == 0) return null;
  final cut = (total * trim).floor();
  final left = _trimStart(cols, cut);
  final right = _trimEnd(cols, cut);
  final top = _trimStart(rows, cut);
  final bottom = _trimEnd(rows, cut);
  if (right < left || bottom < top) return null;
  return Rect.fromLTRB(
    left.toDouble(),
    top.toDouble(),
    (right + 1).toDouble(),
    (bottom + 1).toDouble(),
  );
}

int _trimStart(Uint32List hist, int cut) {
  var acc = 0;
  for (var i = 0; i < hist.length; i++) {
    acc += hist[i];
    if (acc > cut) return i;
  }
  return hist.length - 1;
}

int _trimEnd(Uint32List hist, int cut) {
  var acc = 0;
  for (var i = hist.length - 1; i >= 0; i--) {
    acc += hist[i];
    if (acc > cut) return i;
  }
  return 0;
}

BdRegistration _inkBoundsRegistration(Rect srcInk, Rect dstInk) {
  final scale = math.min(
    dstInk.width / srcInk.width,
    dstInk.height / srcInk.height,
  );
  return BdRegistration(
    scale: scale,
    dx: dstInk.center.dx - scale * srcInk.center.dx,
    dy: dstInk.center.dy - scale * srcInk.center.dy,
  );
}

BdRegistration _translationRegistration(
  double scale,
  Rect srcInk,
  Rect dstInk,
  Uint8List renderRgba,
  int renderWidth,
  int renderHeight,
  Uint8List referenceEdges,
  int width,
  int height, {
  int searchRadius = 96,
  int edgeThreshold = kBdEdgeThreshold,
  List<Rect> anchorRects = const [],
}) {
  final base = BdRegistration(
    scale: scale,
    dx: (dstInk.center.dx - scale * srcInk.center.dx).roundToDouble(),
    dy: (dstInk.center.dy - scale * srcInk.center.dy).roundToDouble(),
  );
  final renderPixels = renderWidth * renderHeight;
  final renderEdges = _sobelMask(
    _luma(renderRgba, renderPixels),
    renderWidth,
    renderHeight,
    edgeThreshold,
  );
  final points = <double>[];
  final stride = math.max(1, math.sqrt(renderPixels / 300000).ceil());
  for (var y = 0; y < renderHeight; y += stride) {
    final row = y * renderWidth;
    for (var x = 0; x < renderWidth; x += stride) {
      if (renderEdges[row + x] != 0) {
        points
          ..add(x * scale)
          ..add(y * scale);
      }
    }
  }
  if (points.isEmpty) return base;
  final nearEdges = _dilate(referenceEdges, width, height, 1);
  int hitsAt(double dx, double dy) {
    var hits = 0;
    for (var i = 0; i < points.length; i += 2) {
      final x = (points[i] + dx).round();
      final y = (points[i + 1] + dy).round();
      if (x < 0 || y < 0 || x >= width || y >= height) continue;
      hits += nearEdges[y * width + x];
    }
    return hits;
  }

  final int coarseStep = 2 * math.max(1, (points.length ~/ 2) ~/ 4000);
  int coarseHitsAt(double dx, double dy) {
    var hits = 0;
    for (var i = 0; i < points.length; i += coarseStep) {
      final x = (points[i] + dx).round();
      final y = (points[i + 1] + dy).round();
      if (x < 0 || y < 0 || x >= width || y >= height) continue;
      hits += nearEdges[y * width + x];
    }
    return hits;
  }

  final starts = <(double, double)>{
    (base.dx, base.dy),
    (
      (dstInk.left - scale * srcInk.left).roundToDouble(),
      (dstInk.top - scale * srcInk.top).roundToDouble(),
    ),
    (
      (dstInk.right - scale * srcInk.right).roundToDouble(),
      (dstInk.bottom - scale * srcInk.bottom).roundToDouble(),
    ),
  };
  final cells = <(double, double, int)>[];
  for (final (sx, sy) in starts) {
    for (var oy = -searchRadius; oy <= searchRadius; oy += 6) {
      for (var ox = -searchRadius; ox <= searchRadius; ox += 6) {
        cells.add((sx + ox, sy + oy, coarseHitsAt(sx + ox, sy + oy)));
      }
    }
  }
  cells.sort((a, b) => b.$3.compareTo(a.$3));
  final peaks = <(double, double, int)>[];
  for (final cell in cells) {
    if (peaks.length >= 8) break;
    final farEnough = peaks.every(
      (p) => math.max((p.$1 - cell.$1).abs(), (p.$2 - cell.$2).abs()) >= 12,
    );
    if (farEnough) peaks.add(cell);
  }
  final candidates = <(double, double, int)>[];
  for (final (px, py, _) in peaks) {
    var bestDx = px, bestDy = py;
    var bestHits = hitsAt(px, py);
    for (var oy = -5; oy <= 5; oy++) {
      for (var ox = -5; ox <= 5; ox++) {
        if (ox == 0 && oy == 0) continue;
        final hits = hitsAt(px + ox, py + oy);
        if (hits > bestHits) {
          bestHits = hits;
          bestDx = px + ox;
          bestDy = py + oy;
        }
      }
    }
    candidates.add((bestDx, bestDy, bestHits));
  }
  if (candidates.isEmpty) return base;
  if (anchorRects.isNotEmpty) {
    double anchorSupport(double dx, double dy, Uint8List edges) {
      var hits = 0, samples = 0;
      void sample(double fx, double fy) {
        final x = (fx * scale + dx).round(), y = (fy * scale + dy).round();
        if (x < 0 || y < 0 || x >= width || y >= height) return;
        samples++;
        hits += edges[y * width + x];
      }

      for (final rect in anchorRects) {
        for (var x = rect.left; x <= rect.right; x += 2) {
          sample(x, rect.top);
          sample(x, rect.bottom);
        }
        for (var y = rect.top + 2; y < rect.bottom; y += 2) {
          sample(rect.left, y);
          sample(rect.right, y);
        }
      }
      return samples == 0 ? 0 : hits / samples;
    }

    var best = candidates.first;
    var bestScore = anchorSupport(best.$1, best.$2, nearEdges);
    for (final cand in candidates.skip(1)) {
      final score = anchorSupport(cand.$1, cand.$2, nearEdges);
      if (score > bestScore + 1e-9 ||
          (score > bestScore - 1e-9 && cand.$3 > best.$3)) {
        best = cand;
        bestScore = score;
      }
    }
    return BdRegistration(
      scale: scale,
      dx: best.$1,
      dy: best.$2,
    )._exactSnap(points, referenceEdges, width, height);
  }
  candidates.sort((a, b) => b.$3.compareTo(a.$3));
  return BdRegistration(
    scale: scale,
    dx: candidates.first.$1,
    dy: candidates.first.$2,
  )._exactSnap(points, referenceEdges, width, height);
}

extension _ExactSnap on BdRegistration {
  BdRegistration _exactSnap(
    List<double> points,
    Uint8List referenceEdges,
    int width,
    int height,
  ) {
    int exactHits(double ex, double ey) {
      var hits = 0;
      for (var i = 0; i < points.length; i += 2) {
        final x = (points[i] + ex).round(), y = (points[i + 1] + ey).round();
        if (x < 0 || y < 0 || x >= width || y >= height) continue;
        hits += referenceEdges[y * width + x];
      }
      return hits;
    }

    var bx = dx, by = dy, best = exactHits(dx, dy);
    for (var oy = -1; oy <= 1; oy++) {
      for (var ox = -1; ox <= 1; ox++) {
        if (ox == 0 && oy == 0) continue;
        final hits = exactHits(dx + ox, dy + oy);
        if (hits > best) {
          best = hits;
          bx = dx + ox;
          by = dy + oy;
        }
      }
    }
    return BdRegistration(scale: scale, dx: bx, dy: by);
  }
}

BdRegistration _letterboxRegistration(ui.Image src, int width, int height) {
  final scale = math.min(width / src.width, height / src.height);
  return BdRegistration(
    scale: scale,
    dx: (width - src.width * scale) / 2,
    dy: (height - src.height * scale) / 2,
  );
}

Future<ui.Image> _redrawRegistered(
  ui.Image src,
  BdRegistration registration,
  int width,
  int height, {
  Color background = const Color(0xFFFFFFFF),
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(
    recorder,
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
  );
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = background,
  );
  final lossless =
      registration.scale == 1.0 &&
      registration.dx == registration.dx.roundToDouble() &&
      registration.dy == registration.dy.roundToDouble();
  canvas.drawImageRect(
    src,
    Rect.fromLTWH(0, 0, src.width.toDouble(), src.height.toDouble()),
    registration.mapRect(
      Rect.fromLTWH(0, 0, src.width.toDouble(), src.height.toDouble()),
    ),
    Paint()
      ..filterQuality = lossless ? FilterQuality.none : FilterQuality.medium,
  );
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(width, height);
  } finally {
    picture.dispose();
  }
}

class BdOracleView extends StatefulWidget {
  const BdOracleView({
    super.key,
    required this.diagram,
    this.referenceBytes,
    this.maxDimension = 1400,
    this.subViIcons = const {},
  });

  final ViDiagram? diagram;

  final Uint8List? referenceBytes;

  final int maxDimension;

  final Map<int, ViLegacyIcon> subViIcons;

  @override
  State<BdOracleView> createState() => _BdOracleViewState();
}

class _BdOracleViewState extends State<BdOracleView>
    with AutomaticKeepAliveClientMixin {
  late Future<_OracleData> _future = _build();

  @override
  void initState() {
    super.initState();
    if (primIconsLoaded().isEmpty) {
      loadPrimIcons().then((icons) {
        if (!mounted || icons.isEmpty) return;
        _retire(_future);
        final rebuilt = _build();
        setState(() {
          _future = rebuilt;
        });
      });
    }
  }

  bool _exportingGif = false;

  bool _wipe = false;
  double _wipeFraction = 0.5;
  int _wipeBoxK = -1;
  ui.Image? _wipeReference;
  ui.Image? _wipeFitted;

  int _wipeZoom = 3;
  final ScrollController _wipeH = ScrollController();
  final ScrollController _wipeV = ScrollController();

  @override
  bool get wantKeepAlive => true;

  @override
  void didUpdateWidget(BdOracleView old) {
    super.didUpdateWidget(old);
    if (!identical(old.diagram, widget.diagram) ||
        !identical(old.referenceBytes, widget.referenceBytes)) {
      _retire(_future);
      _resetWipeDownscales();
      _future = _build();
    }
  }

  void _resetWipeDownscales() {
    _wipeBoxK = -1;
    _wipeReference?.dispose();
    _wipeFitted?.dispose();
    _wipeReference = null;
    _wipeFitted = null;
  }

  @override
  void dispose() {
    _wipeH.dispose();
    _wipeV.dispose();
    _resetWipeDownscales();
    _retire(_future);
    super.dispose();
  }

  void _retire(Future<_OracleData> data) {
    data
        .then((resolved) {
          if (mounted) {
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => resolved.dispose(),
            );
          } else {
            resolved.dispose();
          }
        })
        .catchError((_) {});
  }

  Future<_OracleData> _build() async {
    final diagram = widget.diagram;
    if (diagram == null) return const _OracleData();
    final bytes = widget.referenceBytes;
    final reference = bytes == null ? null : await decodeReferenceImage(bytes);
    final snippet = reference?.snippetCropped ?? false;
    final scene = BdScene(diagram);
    final drawable = scene.drawable;
    final snippetVi = bytes == null ? null : extractSnippetVi(bytes);
    final facades = snippetVi == null
        ? const <int, ui.Image>{}
        : await loadXnodeFacades(snippetVi, diagram);
    Future<BdRaster?> render({
      required int maxDimension,
      double? scale,
      BdRenderStyle style = const BdRenderStyle(),
    }) => rasteriseBlockDiagram(
      diagram,
      primIcons: primIconsLoaded(),
      maxDimension: maxDimension,
      scale: scale,
      margin: snippet ? 2 : 40,
      subViIcons: widget.subViIcons,
      xnodeFacades: facades,
      scene: scene,
      style: style,
    );
    var raster = await render(
      maxDimension: widget.maxDimension,
      scale: snippet ? 1.0 : null,
    );
    if (raster == null) {
      reference?.image.dispose();
      scene.dispose();
      return const _OracleData();
    }
    if (reference == null) {
      scene.dispose();
      return _OracleData(rendered: raster.image);
    }
    var result = await compareToReference(
      raster.image,
      reference.image,
      lockScale: snippet ? 1.0 / raster.scale : null,
      anchorRects: snippet
          ? bdStructureAnchorRects(diagram, raster, drawable: drawable)
          : const [],
    );
    var style = const BdRenderStyle();
    if (snippet) {
      GlobalHatchOffset derive({required bool errorStyle}) => deriveHatchOffset(
        diagram: diagram,
        raster: raster!,
        registration: result.registration,
        referenceRgba: result.referenceRgba,
        width: reference.image.width,
        height: reference.image.height,
        errorStyle: errorStyle,
      );
      style = BdRenderStyle(
        hatchOffset: derive(errorStyle: false),
        errorHatchOffset: derive(errorStyle: true),
        wireCycleOffset: deriveWireCycleOffset(
          scene: scene,
          raster: raster,
          registration: result.registration,
          referenceRgba: result.referenceRgba,
          width: reference.image.width,
          height: reference.image.height,
        ),
      );
      if (style.hatchOffset != kNoHatchOffset ||
          style.errorHatchOffset != kNoHatchOffset ||
          style.wireCycleOffset != kNoHatchOffset) {
        final rephased = await render(
          maxDimension: widget.maxDimension,
          scale: 1.0,
          style: style,
        );
        if (rephased != null) {
          raster.image.dispose();
          result.fitted.dispose();
          result.diffImage.dispose();
          raster = rephased;
          result = await compareToReference(
            raster.image,
            reference.image,
            lockScale: 1.0 / raster.scale,
            knownRegistration: result.registration,
            knownReferenceEdges: result.referenceEdges,
          );
        }
      }
    }
    final placement = comparePlacement(
      diagram: diagram,
      raster: raster,
      registration: result.registration,
      referenceRgba: result.referenceRgba,
      referenceEdges: result.referenceEdges,
      drawable: drawable,
      width: reference.image.width,
      height: reference.image.height,
    );
    const ss = kOracleDisplaySupersample;
    final raster3 = await render(
      maxDimension: widget.maxDimension * ss,
      scale: raster.scale * ss,
      style: style,
    );
    ui.Image? displayFitted;
    ui.Image? displayReference;
    if (raster3 != null) {
      displayFitted = await redrawRegisteredSupersampled(
        raster3.image,
        result.registration,
        reference.image.width,
        reference.image.height,
        ss,
      );
      displayReference = await upscaleNearest(reference.image, ss);
    }
    scene.dispose();
    return _OracleData(
      rendered: raster.image,
      result: result,
      placement: placement,
      displayRendered: raster3?.image,
      displayFitted: displayFitted,
      displayReference: displayReference,
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return FutureBuilder<_OracleData>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final data = snapshot.data ?? const _OracleData();
        if (data.rendered == null) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'No block-diagram objects to render.',
                style: TextStyle(color: Colors.grey),
              ),
            ),
          );
        }
        final result = data.result;
        final placement = data.placement;
        final placementLine = placement == null || placement.objects == 0
            ? ''
            : 'Placement · '
                  '${(placement.excessSupport * 100).toStringAsFixed(1)}% '
                  'excess perimeter edge support over ${placement.objects} '
                  'boxes — where the boxes are, not how they are filled.   ';
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(8),
              child: result == null
                  ? const Text(
                      'Reference-image oracle — no reference supplied. Pass a '
                      'block-diagram screenshot of this VI to see a side-by-side '
                      'and per-pixel diff.',
                      style: TextStyle(color: Colors.grey, fontSize: 12),
                    )
                  : Text(
                      'Pixel diff · mean abs '
                      '${result.comparison.meanAbsDiff.toStringAsFixed(1)}/255 · '
                      '${(result.comparison.diffFraction * 100).toStringAsFixed(1)}% '
                      'of pixels differ (rewards whiteness).   '
                      'Structural · score '
                      '${(result.structural.score * 100).toStringAsFixed(1)}% '
                      '(ink IoU ${(result.structural.inkIoU * 100).toStringAsFixed(1)}%, '
                      'edge IoU ${(result.structural.edgeIoU * 100).toStringAsFixed(1)}%; '
                      'ink render ${(result.structural.inkFractionRender * 100).toStringAsFixed(1)}% '
                      'vs ref ${(result.structural.inkFractionReference * 100).toStringAsFixed(1)}%) — '
                      'credits drawn structure over emptiness.   '
                      '$placementLine'
                      '${result.registered ? 'Content-bounds registered' : 'Centred letterbox'}. '
                      'Coarse progress signals — not a fidelity claim.',
                      style: const TextStyle(color: Colors.grey, fontSize: 12),
                    ),
            ),
            if (result != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [
                    TextButton.icon(
                      onPressed: () => setState(() => _wipe = !_wipe),
                      icon: Icon(
                        _wipe ? Icons.view_column : Icons.compare,
                        size: 16,
                      ),
                      label: Text(_wipe ? 'Side-by-side' : 'Wipe compare'),
                    ),
                    TextButton.icon(
                      onPressed: _exportingGif
                          ? null
                          : () => _exportSweepGif(result),
                      icon: const Icon(Icons.gif_box_outlined, size: 16),
                      label: Text(
                        _exportingGif ? 'Encoding…' : 'Export sweep GIF',
                      ),
                    ),
                    if (_wipe) ...[
                      for (final zoom in const [0, 1, 2, 3])
                        Padding(
                          padding: const EdgeInsets.only(right: 2),
                          child: TextButton(
                            style: TextButton.styleFrom(
                              minimumSize: const Size(34, 28),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                              ),
                              backgroundColor: _wipeZoom == zoom
                                  ? Colors.orange.withValues(alpha: 0.25)
                                  : null,
                            ),
                            onPressed: () => setState(() => _wipeZoom = zoom),
                            child: Text(zoom == 0 ? 'Fit' : '${zoom}x'),
                          ),
                        ),
                      const Text(
                        'drag the divider — ours left, LabVIEW right; '
                        'integer zooms are pixel-exact, Fit is a box-averaged overview',
                        style: TextStyle(color: Colors.grey, fontSize: 11),
                      ),
                    ],
                  ],
                ),
              ),
            Expanded(
              child: _wipe && result != null
                  ? _wipePane(result, data)
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: _pane(
                            'Rendered (clean-room)',
                            result != null
                                ? (data.displayFitted ?? result.fitted)
                                : (data.displayRendered ?? data.rendered!),
                            supersample:
                                (result != null
                                    ? data.displayFitted != null
                                    : data.displayRendered != null)
                                ? kOracleDisplaySupersample
                                : 1,
                            base: result != null
                                ? result.fitted
                                : data.rendered,
                            copyImage: result != null
                                ? (data.displayFitted ?? result.fitted)
                                : (data.displayRendered ?? data.rendered),
                            copyLabel: 'Rendered',
                          ),
                        ),
                        if (result != null) ...[
                          Expanded(
                            child: _pane(
                              'Reference',
                              data.displayReference ?? result.reference,
                              supersample: data.displayReference != null
                                  ? kOracleDisplaySupersample
                                  : 1,
                              base: result.reference,
                              copyImage:
                                  data.displayReference ?? result.reference,
                              copyLabel: 'Reference',
                            ),
                          ),
                          Expanded(
                            child: _pane('Absolute diff', result.diffImage),
                          ),
                        ],
                      ],
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _wipePane(BdOracleResult result, _OracleData data) {
    final refImage = data.displayReference ?? result.reference;
    final fitImage = data.displayFitted ?? result.fitted;
    const ss = kOracleDisplaySupersample;
    final logicalW = result.reference.width.toDouble();
    final logicalH = result.reference.height.toDouble();
    return Padding(
      padding: const EdgeInsets.all(4),
      child: ColoredBox(
        color: const Color(0xFF202020),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final dpr = MediaQuery.devicePixelRatioOf(context);
            final fitPhys = math.min(
              constraints.maxWidth * dpr / logicalW,
              constraints.maxHeight * dpr / logicalH,
            );
            if (fitPhys <= 0 || !fitPhys.isFinite) {
              return const SizedBox.shrink();
            }
            final double dispPhysW;
            final double dispPhysH;
            ui.Image? showRef;
            ui.Image? showFit;
            if (_wipeZoom > 0) {
              dispPhysW = logicalW * _wipeZoom;
              dispPhysH = logicalH * _wipeZoom;
              _wipeBoxK = 0;
              showRef = result.reference;
              showFit = result.fitted;
            } else if (fitPhys >= 1) {
              final n = fitPhys.floor();
              dispPhysW = logicalW * n;
              dispPhysH = logicalH * n;
              _wipeBoxK = 0;
              showRef = result.reference;
              showFit = result.fitted;
            } else {
              final k = boxDownscaleFactor(refImage, ss, fitPhys);
              if (k != _wipeBoxK) {
                _wipeBoxK = k;
                Future.wait([
                  boxDownscale(refImage, k),
                  boxDownscale(fitImage, k),
                ]).then((imgs) {
                  if (mounted && _wipeBoxK == k) {
                    _wipeReference?.dispose();
                    _wipeFitted?.dispose();
                    setState(() {
                      _wipeReference = imgs[0];
                      _wipeFitted = imgs[1];
                    });
                  } else {
                    imgs[0].dispose();
                    imgs[1].dispose();
                  }
                });
              }
              dispPhysW = (refImage.width ~/ k).toDouble();
              dispPhysH = (refImage.height ~/ k).toDouble();
              showRef = _wipeReference;
              showFit = _wipeFitted;
            }
            if (showRef == null || showFit == null) {
              return const Center(child: CircularProgressIndicator());
            }
            final dispW = dispPhysW / dpr;
            final dispH = dispPhysH / dpr;
            void follow(Offset local) => setState(() {
              _wipeFraction = (local.dx / dispW).clamp(0.0, 1.0);
            });
            final content = GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (details) => follow(details.localPosition),
              onHorizontalDragUpdate: (details) =>
                  follow(details.localPosition),
              child: SizedBox(
                width: dispW,
                height: dispH,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    RawImage(
                      image: showRef,
                      fit: BoxFit.fill,
                      filterQuality: FilterQuality.none,
                    ),
                    ClipRect(
                      clipper: _LeftFractionClipper(_wipeFraction),
                      child: RawImage(
                        image: showFit,
                        fit: BoxFit.fill,
                        filterQuality: FilterQuality.none,
                      ),
                    ),
                    Positioned(
                      left: (dispW * _wipeFraction - 1).clamp(
                        0.0,
                        math.max(0.0, dispW - 2),
                      ),
                      width: 2,
                      top: 0,
                      bottom: 0,
                      child: const ColoredBox(color: Colors.orangeAccent),
                    ),
                  ],
                ),
              ),
            );
            if (dispW <= constraints.maxWidth &&
                dispH <= constraints.maxHeight) {
              return Center(child: content);
            }
            return Scrollbar(
              controller: _wipeH,
              thumbVisibility: true,
              child: SingleChildScrollView(
                controller: _wipeH,
                scrollDirection: Axis.horizontal,
                child: Scrollbar(
                  controller: _wipeV,
                  thumbVisibility: true,
                  child: SingleChildScrollView(
                    controller: _wipeV,
                    child: content,
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _pane(
    String caption,
    ui.Image image, {
    int supersample = 1,
    ui.Image? base,
    ui.Image? copyImage,
    String? copyLabel,
  }) => Padding(
    padding: const EdgeInsets.all(4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                caption,
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ),
            if (copyImage != null)
              Builder(
                builder: (context) => IconButton(
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(),
                  iconSize: 15,
                  color: Colors.grey,
                  tooltip: 'Copy ${copyLabel ?? caption} (3×) to clipboard',
                  icon: const Icon(Icons.content_copy),
                  onPressed: () =>
                      _copyImage(context, copyImage, copyLabel ?? caption),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Expanded(
          child: ColoredBox(
            color: const Color(0xFF202020),
            child: CrispImage(image, supersample: supersample, base: base),
          ),
        ),
      ],
    ),
  );

  Future<void> _exportSweepGif(BdOracleResult result) async {
    setState(() => _exportingGif = true);
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final width = result.reference.width;
      final height = result.reference.height;
      final fitted = (await result.fitted.toByteData())!.buffer.asUint8List();
      final reference = result.referenceRgba;
      final gif = await encodeOracleSweepGifOffThread(
        leftRgba: fitted,
        rightRgba: reference,
        width: width,
        height: height,
      );
      final path = await FilePicker.saveFile(
        dialogTitle: 'Save render-vs-reference sweep GIF',
        fileName: 'oracle-sweep.gif',
        type: FileType.custom,
        allowedExtensions: const ['gif'],
        bytes: gif,
      );
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            path == null
                ? 'Sweep GIF export cancelled'
                : 'Wrote sweep GIF '
                      '(${(gif.length / (1 << 20)).toStringAsFixed(1)} MB) '
                      'to $path',
          ),
        ),
      );
    } catch (e) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Could not export sweep GIF: $e')),
      );
    } finally {
      if (mounted) setState(() => _exportingGif = false);
    }
  }

  Future<void> _copyImage(
    BuildContext context,
    ui.Image image,
    String what,
  ) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    var ok = false;
    if (png != null) {
      ok = await const SystemImageClipboard().copyPng(png.buffer.asUint8List());
    }
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          ok ? 'Copied $what (3×) to clipboard' : 'Could not copy $what',
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }
}

class _OracleData {
  const _OracleData({
    this.rendered,
    this.result,
    this.placement,
    this.displayRendered,
    this.displayFitted,
    this.displayReference,
  });
  final ui.Image? rendered;
  final BdOracleResult? result;
  final PlacementComparison? placement;

  final ui.Image? displayRendered;
  final ui.Image? displayFitted;
  final ui.Image? displayReference;

  void dispose() {
    final seen = <ui.Image>{};
    void disp(ui.Image? image) {
      if (image != null && seen.add(image)) image.dispose();
    }

    disp(rendered);
    disp(displayRendered);
    disp(displayFitted);
    disp(displayReference);
    final res = result;
    if (res != null) {
      disp(res.rendered);
      disp(res.fitted);
      disp(res.reference);
      disp(res.diffImage);
    }
  }
}

const kOracleDisplaySupersample = 3;

Future<ui.Image> upscaleNearest(ui.Image src, int factor) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawImageRect(
    src,
    ui.Rect.fromLTWH(0, 0, src.width.toDouble(), src.height.toDouble()),
    ui.Rect.fromLTWH(
      0,
      0,
      (src.width * factor).toDouble(),
      (src.height * factor).toDouble(),
    ),
    ui.Paint()..filterQuality = ui.FilterQuality.none,
  );
  return recorder.endRecording().toImage(
    src.width * factor,
    src.height * factor,
  );
}

Future<ui.Image> redrawRegisteredSupersampled(
  ui.Image rendered,
  BdRegistration registration,
  int width,
  int height,
  int factor,
) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    ui.Rect.fromLTWH(
      0,
      0,
      (width * factor).toDouble(),
      (height * factor).toDouble(),
    ),
    ui.Paint()..color = const ui.Color(0xFFFFFFFF),
  );
  canvas.scale(factor.toDouble());
  canvas.translate(
    registration.dx.roundToDouble(),
    registration.dy.roundToDouble(),
  );
  canvas.scale(registration.scale);
  canvas.drawImageRect(
    rendered,
    ui.Rect.fromLTWH(
      0,
      0,
      rendered.width.toDouble(),
      rendered.height.toDouble(),
    ),
    ui.Rect.fromLTWH(0, 0, rendered.width / factor, rendered.height / factor),
    ui.Paint()..filterQuality = ui.FilterQuality.none,
  );
  return recorder.endRecording().toImage(width * factor, height * factor);
}

int boxDownscaleFactor(ui.Image src, int supersample, double fitPhys) {
  final k = supersample * (1 / fitPhys).ceil();
  return k.clamp(1, math.min(src.width, src.height));
}

Future<ui.Image> boxDownscale(ui.Image src, int k) async {
  final data = (await src.toByteData())!;
  final sw = src.width, sh = src.height;
  final bytes = data.buffer.asUint8List();
  final out = await Isolate.run(() => boxDownscaleRgba(bytes, sw, sh, k));
  return imageFromRgba(out.rgba, out.width, out.height);
}

({Uint8List rgba, int width, int height}) boxDownscaleRgba(
  Uint8List rgba,
  int width,
  int height,
  int factor,
) {
  final blockK = math.max(1, math.min(factor, math.min(width, height)));
  final dw = math.max(1, width ~/ blockK), dh = math.max(1, height ~/ blockK);
  final out = Uint8List(dw * dh * 4);
  final n = blockK * blockK;
  for (var y = 0; y < dh; y++) {
    for (var x = 0; x < dw; x++) {
      var r = 0, g = 0, b = 0, a = 0;
      for (var sy = y * blockK; sy < y * blockK + blockK; sy++) {
        var i = (sy * width + x * blockK) * 4;
        for (var sx = 0; sx < blockK; sx++) {
          r += rgba[i];
          g += rgba[i + 1];
          b += rgba[i + 2];
          a += rgba[i + 3];
          i += 4;
        }
      }
      final j = (y * dw + x) * 4;
      out[j] = r ~/ n;
      out[j + 1] = g ~/ n;
      out[j + 2] = b ~/ n;
      out[j + 3] = a ~/ n;
    }
  }
  return (rgba: out, width: dw, height: dh);
}

class CrispImage extends StatefulWidget {
  const CrispImage(this.image, {this.supersample = 1, this.base, super.key});

  final ui.Image image;
  final int supersample;

  final ui.Image? base;

  @override
  State<CrispImage> createState() => _CrispImageState();
}

class _CrispImageState extends State<CrispImage> {
  ui.Image? _scaled;
  int _boxK = -1;

  @override
  void dispose() {
    _scaled?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final dpr = MediaQuery.devicePixelRatioOf(context);
      final logicalW = widget.image.width / widget.supersample;
      final logicalH = widget.image.height / widget.supersample;
      final fitPhys = math.min(
        constraints.maxWidth * dpr / logicalW,
        constraints.maxHeight * dpr / logicalH,
      );
      if (fitPhys <= 0 || !fitPhys.isFinite) return const SizedBox.shrink();
      final double dispPhysW;
      final double dispPhysH;
      ui.Image? shown;
      if (fitPhys >= 1) {
        final n = fitPhys.floor();
        dispPhysW = logicalW * n;
        dispPhysH = logicalH * n;
        shown = widget.base ?? widget.image;
      } else {
        final k = boxDownscaleFactor(widget.image, widget.supersample, fitPhys);
        if (k != _boxK) {
          _boxK = k;
          boxDownscale(widget.image, k).then((img) {
            if (!mounted) {
              img.dispose();
            } else if (_boxK == k) {
              _scaled?.dispose();
              setState(() => _scaled = img);
            } else {
              img.dispose();
            }
          });
        }
        dispPhysW = (widget.image.width ~/ k).toDouble();
        dispPhysH = (widget.image.height ~/ k).toDouble();
        shown = _scaled;
      }
      if (shown == null) {
        return const Center(child: CircularProgressIndicator());
      }
      return Center(
        child: SizedBox(
          width: dispPhysW / dpr,
          height: dispPhysH / dpr,
          child: RawImage(
            image: shown,
            fit: BoxFit.fill,
            filterQuality: FilterQuality.none,
          ),
        ),
      );
    },
  );
}

class _LeftFractionClipper extends CustomClipper<Rect> {
  const _LeftFractionClipper(this.fraction);

  final double fraction;

  @override
  Rect getClip(Size size) =>
      Rect.fromLTRB(0, 0, size.width * fraction, size.height);

  @override
  bool shouldReclip(_LeftFractionClipper oldClipper) =>
      oldClipper.fraction != fraction;
}
