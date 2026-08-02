/// A **reference-image oracle** for the block-diagram renderer: it rasterises a
/// decoded [ViDiagram] with the exact same [BdDiagramPainter] the on-screen view
/// uses, then measures how far that render is from a supplied reference
/// screenshot (a documentation image of the same VI's LabVIEW block diagram).
///
/// The strongest reference is a **VI-snippet PNG** (see `extractSnippetVi`): its
/// raster is LabVIEW's own render of the very VI embedded in the file, at
/// 1 diagram unit == 1 px. [decodeReferenceImage] crops the snippet chrome away
/// and the render is rasterised at that same unit scale, so the pair is
/// same-VI, same-scale by construction. [comparePlacement] then scores the
/// decoded geometry (structure/node/terminal boxes) against the reference's
/// drawn outlines independently of rendering fidelity.
///
/// Two comparisons are reported. The [ImageComparison] is a straight per-pixel
/// absolute difference after the render is letterboxed into the reference's
/// dimensions — but that metric is minimised by a blank (white) render, so more
/// drawn content can *raise* it. The [StructuralComparison] corrects for that: it
/// credits drawn structure by comparing the two images' ink and Sobel-edge masks
/// as intersection-over-union, so drawing the nodes/wires correctly scores
/// better, not worse. Before either comparison the render is registered onto the
/// reference by aligning their drawn-ink bounding boxes (see [inkBoundsOf]), so a
/// correct render framed at a different crop or scale than the screenshot is not
/// penalised for the framing. Both are still *coarse* signals — the render is not
/// pixel-perfect, registration aligns only extents, and the two images differ in
/// anti-aliasing — so they are progress metrics, not a pass/fail gate, and the
/// side-by-side + diff visualisation is the primary output for a human to judge
/// fidelity. No claim of LabVIEW equivalence is made or implied.
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

/// A rasterised block diagram: the [image] plus the model-space [content]
/// rectangle and the model-pixel → image-pixel [scale] it was drawn at (so a
/// caller can map a heap object's bounds back onto the raster).
class BdRaster {
  const BdRaster({
    required this.image,
    required this.content,
    required this.scale,
  });

  final ui.Image image;
  final Rect content;
  final double scale;

  /// [bounds] (absolute diagram coordinates) mapped into this raster's image
  /// space (content origin subtracted, then scaled).
  Rect modelRect(HeapRect bounds) => Rect.fromLTRB(
    (bounds.left - content.left) * scale,
    (bounds.top - content.top) * scale,
    (bounds.right - content.left) * scale,
    (bounds.bottom - content.top) * scale,
  );
}

/// Derives a reference capture's [GlobalHatchOffset] for the black case-hatch
/// lattice ([errorStyle] false) or the error-case stripe lattice (true; a
/// SEPARATE per-capture phase — one capture measures different phases for the
/// two lattices). Scores every lattice phase against the reference pixels
/// inside the case frames' hatch bands. LabVIEW anchors each lattice to its
/// device/window brush origin at render time — not stored in the .vi and
/// different per capture — so the phase can only be measured from the capture
/// itself. Returns [kNoHatchOffset] unless one phase wins decisively (≥75%
/// pixel agreement and a strict margin over the runner-up), so
/// content-overdrawn or recoloured bands never force a bogus phase.
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
  // The stripe lattice depends only on (px+py) mod 4, so its 16 phases
  // collapse to 4 distinct lattices — searching py too would make every
  // winner tie its aliases and the margin check reject them all.
  final pyRange = errorStyle ? 1 : 4;
  final score = List.generate(4, (_) => List.filled(4, 0));
  var samples = 0;
  for (final frame in diagram.objects) {
    if (frame.kind != 0x2c || !drawableOids.contains(frame.oid)) continue;
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
          // Stripe grey on the green field; anything else is overdraw.
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
  // score = agree − disagree, so ≥75% agreement means score ≥ samples/2.
  if (best < samples ~/ 2 || best == second) return kNoHatchOffset;
  return (x: bestX, y: bestY);
}

/// Derives a reference capture's [BdRenderStyle.wireCycleOffset] — the mod-4
/// column shift the capture viewport's pan gives the patterned wire-stroke
/// cycles ([kBdWireCyclePhase]; the same screen anchoring as the hatch
/// lattice). Only the `x` component is meaningful: a row-parity pan flip is
/// identical to a column shift of 2 (the cycles' row term is `2·(y & 1)`
/// mod 4), so the candidate space is exactly the 4 column shifts. Scores
/// every clean column of every horizontal patterned leg against the
/// reference under each candidate. Braid legs are excluded: the
/// error-cluster braid draws its own weave palette, and telling error from
/// plain braid here would duplicate the painter's net resolution. Returns
/// [kNoHatchOffset] unless one shift wins decisively (≥75% bit agreement
/// and a strict margin), so a diagram without patterned wires keeps the
/// neutral phase.
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
        // VERTICAL string-family runs score the same global texture through
        // their column masks (ink where `(x + 2·(y&1) + shift) mod 4 != 0`),
        // so captures without long horizontal patterned runs still derive.
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
        // The leg's ink colour: the modal non-white pixel over its band.
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
          // Columns carrying any third colour are overdrawn — skip them.
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

/// Rasterises [diagram]'s drawable objects to a [ui.Image] using the shared
/// [BdDiagramPainter], off-screen (via a [ui.PictureRecorder], no widget tree).
/// The whole content rectangle is fit within [maxDimension] on its longer side
/// (then multiplied by [pixelRatio]); the raster is clamped to 8192px. Pass
/// [scale] to rasterise at an exact model-pixel → image-pixel factor instead
/// (1.0 matches LabVIEW's own 1 diagram unit == 1 px snippet render, making a
/// snippet reference comparable without resampling). Returns null when the
/// diagram has no positioned objects.
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
  // wires defaults to the diagram's visible dataflow wires; pass `const []`
  // to rasterise the wire-free layout (measuring the before/after delta), or
  // a pre-built [scene] to reuse its cached analyses across renders.
  scene ??= BdScene(diagram, wires: wires, drawable: drawable);
  if (scene.drawable.isEmpty) return null;
  final content = bdContentRect(
    scene.drawable,
    includeWires: false,
    margin: margin,
  );
  if (content.width <= 0 || content.height <= 0) return null;

  final longSide = math.max(content.width, content.height);
  var pxScale =
      scale ?? (maxDimension / longSide).clamp(0.01, 8.0) * pixelRatio;
  // The raster is capped at 8192 px a side; an explicit scale that would
  // overflow it is reduced so ALL content stays on the canvas (the returned
  // [BdRaster.scale] is always the factor actually drawn at).
  if (longSide * pxScale > 8192) pxScale = 8192 / longSide;
  final width = (content.width * pxScale).ceil().clamp(1, 8192);
  final height = (content.height * pxScale).ceil().clamp(1, 8192);

  // The raster must be exact on first paint, so a diagram holding a
  // disabled frame waits for the grey variants (built once, lazily).
  if (scene.disabledOids.isNotEmpty) await ensurePrimIconsGrey();
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(
    recorder,
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
  );
  // Fill the whole pixel raster with the canvas colour before scaling: the
  // painter fills only content.size*scale, but the image is ceil()'d, so without
  // this the <1px right/bottom remainder stays transparent and every ink/luma
  // comparison would read that transparent strip as ink.
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = kBdCanvas,
  );
  canvas.scale(pxScale);
  BdDiagramPainter(
    scene: scene,
    origin: content.topLeft,
    subViIcons: subViIcons,
    primIcons: primIcons,
    xnodeFacades: xnodeFacades,
    primIconsGrey: primIconsGreyLoaded(),
    // The reference renders have a plain white canvas; the interactive
    // view's alignment-dot grid would break byte-exact comparisons.
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
  }
}

/// The result of an absolute-difference image comparison over two equal-sized
/// RGBA buffers.
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

  /// Mean per-channel absolute difference over the RGB channels of every pixel,
  /// on a 0..255 scale (0 == identical images).
  final double meanAbsDiff;

  /// Fraction (0..1) of pixels whose strongest channel differs by more than the
  /// comparison threshold.
  final double diffFraction;

  /// A per-pixel absolute-difference RGBA visualisation (opaque; brighter =
  /// more different), the same [width]×[height] as the inputs.
  final Uint8List diff;
}

/// Compares two equal-length RGBA buffers ([width]×[height]×4 bytes each),
/// returning per-channel mean absolute difference, the fraction of pixels
/// differing beyond [threshold], and a diff visualisation. Pure + total (asserts
/// matching sizes). Alpha is ignored in the metric so a transparent-vs-opaque
/// background does not dominate.
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

/// A **structural** comparison of two equal-sized RGBA buffers that credits
/// drawn content over emptiness — unlike [compareRgba], whose per-pixel diff is
/// minimised by a blank (white) render.
///
/// It derives two masks per image and compares them spatially:
/// - an **ink** mask: pixels darker than the near-white canvas by more than a
///   threshold (the drawn boxes, wires, terminals, text);
/// - an **edge** mask: strong Sobel luminance gradients (the outlines of that
///   same drawn structure).
///
/// The agreement of each mask is reported as intersection-over-union (IoU). More
/// *correct* drawn structure (nodes in the right place, wires between them)
/// raises the overlap and therefore the score, so the metric rewards drawing —
/// the opposite of the whiteness-rewarding pixel diff. It is still a coarse,
/// origin/scale-approximate progress signal, not a claim of LabVIEW fidelity.
class StructuralComparison {
  const StructuralComparison({
    required this.inkFractionRender,
    required this.inkFractionReference,
    required this.inkIoU,
    required this.edgeIoU,
  });

  /// Fraction (0..1) of the render's pixels that are ink (non-background).
  final double inkFractionRender;

  /// Fraction (0..1) of the reference's pixels that are ink (non-background).
  final double inkFractionReference;

  /// Intersection-over-union of the two ink masks (1 == the drawn regions
  /// coincide exactly; 0 == they never overlap; 1 when both images are blank).
  final double inkIoU;

  /// Intersection-over-union of the two Sobel edge masks.
  final double edgeIoU;

  /// Combined structural score (0..1, higher = more structurally alike): the
  /// mean of [inkIoU] and [edgeIoU]. 1.0 for identical images; ~0 when the two
  /// share no drawn content (e.g. a blank render vs a populated reference).
  double get score => (inkIoU + edgeIoU) / 2;
}

/// The default Sobel gradient-magnitude threshold above which a pixel counts
/// as an **edge** — shared by the structural comparison, the translation
/// refinement and the placement metric so their edge masks agree.
const int kBdEdgeThreshold = 64;

/// Computes the [StructuralComparison] of two equal-length RGBA buffers
/// ([width]×[height]×4 bytes each). A pixel is **ink** when its luminance is
/// darker than white by more than [inkThreshold]; an **edge** when its Sobel
/// gradient magnitude exceeds [edgeThreshold]. Pass [referenceEdges] when
/// [b]'s Sobel mask (same threshold) is already computed, to skip that pass.
/// Pure + total (asserts matching sizes).
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

/// Per-pixel Rec.601 luminance (0..255) of an RGBA buffer, [pixels] long.
Uint8List _luma(Uint8List rgba, int pixels) {
  final out = Uint8List(pixels);
  for (var i = 0; i < pixels; i++) {
    final j = i * 4;
    out[i] = (rgba[j] * 77 + rgba[j + 1] * 150 + rgba[j + 2] * 29) >> 8;
  }
  return out;
}

/// A binary Sobel edge mask (1 where the gradient magnitude exceeds
/// [threshold]) over a [width]×[height] luminance plane; the 1-px border is 0.
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

/// The similarity map from render pixels to reference pixels the comparison
/// placed the render with: `referencePx = renderPx * scale + (dx, dy)`.
/// Identity on the same-size fast path. Lets a caller carry any render-space
/// rectangle (e.g. a structure frame's bounds) into reference space — the
/// basis of [comparePlacement].
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

/// The full output of comparing a rendered block diagram to a reference image:
/// the rendered raster, the rendered raster letterboxed into the reference's
/// dimensions, the reference, the [comparison] metrics, and a diff image.
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

  /// The reference's raw RGBA (already read back from the GPU once) and its
  /// Sobel edge mask at [kBdEdgeThreshold] — shared with [comparePlacement]
  /// so a caller never re-reads or re-derives them.
  final Uint8List referenceRgba;
  final Uint8List referenceEdges;

  final ImageComparison comparison;

  /// The structural (ink + edge IoU) comparison — the metric that credits drawn
  /// content over emptiness (see [StructuralComparison]).
  final StructuralComparison structural;
  final ui.Image diffImage;

  /// True when [fitted] was placed by **content-bounds registration** (the
  /// render's ink bounding box scaled + centred onto the reference's, see
  /// [inkBoundsOf]) rather than a naive centred letterbox. Registration cancels
  /// the crop/margin/scale mismatch between a clean-room render and a
  /// documentation screenshot, so a correct render is not penalised for being
  /// framed differently. False on the same-size fast path or when either image
  /// has no ink to register on.
  final bool registered;

  /// The render-pixel → reference-pixel map the comparison placed [rendered]
  /// with (identity on the same-size fast path).
  final BdRegistration registration;
}

/// Compares a [rendered] block diagram against a [reference] image: the render is
/// letterboxed (aspect-preserved, centred) into the reference's dimensions, then
/// diffed pixel-for-pixel. See [ImageComparison] for the honest interpretation of
/// the metrics.
///
/// Pass [lockScale] when the render→reference pixel scale is **known** (a
/// snippet reference at 1 px per model unit compared against a unit-scale
/// render: 1.0). Registration then only *translates* — a multi-start,
/// multi-peak edge-overlap search — instead of deriving a scale from the ink
/// extents, which a sparse render (e.g. a diagram whose only content is
/// undrawn text labels) can distort arbitrarily. [anchorRects] (render-space
/// boxes of the diagram's structures) disambiguate between competing peaks:
/// repetitive texture (hatched structure borders) can out-score the true
/// alignment on raw edge hits, but the large, unique structure boxes do not
/// alias.
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
  // The render's own pixels are needed for registration whenever a resample
  // can happen (see below); read them up front so every pure pixel pass can
  // run off the UI isolate — the O(pixels) loops (Sobel mask, the
  // translation search, the RGBA + structural diffs) caused a visible jank
  // spike when the oracle first opened.
  final skipResample =
      lockScale == null && renderedWidth == width && renderedHeight == height;
  // A caller re-comparing the SAME geometry (a lattice-rephased re-render
  // registers where the original did — only pattern phases moved) passes the
  // first result's registration and reference edge mask back in, and the
  // whole search is skipped: re-deriving a known answer is pure waste.
  final renderedOwnRgba = skipResample || knownRegistration != null
      ? null
      : await _rgbaOf(rendered);
  final reg = knownRegistration != null && knownReferenceEdges != null
      ? (referenceEdges: knownReferenceEdges, registration: knownRegistration)
      : await Isolate.run(() {
          // The reference's Sobel edge mask, computed once and shared by the
          // translation refinement, the structural comparison, and (via the
          // result) the placement metric — three consumers, one O(pixels) pass.
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
            // Register the render onto the reference by aligning their drawn-ink
            // bounding boxes (aspect-preserved scale + centre), so a correct
            // render at a different crop/scale is credited instead of penalised.
            // Null when either image has no ink to register on (the caller falls
            // back to a centred letterbox).
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
  // Skip the resample when the render already matches the reference exactly, so
  // an identical pair diffs to a true zero (a same-size letterbox still applies
  // a sub-pixel filter). Never taken under [lockScale]: equal dimensions do
  // not imply aligned content, and the locked path owes the caller a real
  // translation search.
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

/// Render-space boxes of [diagram]'s drawable structures (excluding the
/// whole-extent root and sub-glyph frames) — the large, unique anchors that
/// disambiguate the locked-scale registration between competing edge peaks.
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

/// The block diagram of [model] with the most positioned objects — the one
/// the Oracle tab renders against a snippet reference (and the corpus sweep
/// measures). Null when no diagram has a positioned object.
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

/// Encodes [image] to PNG bytes (for writing a side-by-side / diff artifact).
Future<Uint8List> imageToPng(ui.Image image) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

/// The raw RGBA bytes of [image].
Future<Uint8List> _rgbaOf(ui.Image image) async {
  final data = await image.toByteData();
  return data!.buffer.asUint8List();
}

/// Decodes reference-image [bytes], cropping away the snippet chrome (header
/// strip + dashed frame, see [snippetDiagramInterior]) when the bytes are a
/// VI-snippet PNG — the remaining pixels are exactly LabVIEW's block-diagram
/// render of the embedded VI, at 1 diagram unit == 1 px. Non-snippet bytes
/// decode unchanged.
///
/// [snippetCropped] is the single source of truth for whether the returned
/// image is such a unit-scale diagram: a caller must gate its unit-scale
/// render + locked-scale registration on it, never on re-detecting the
/// snippet itself — a snippet too small to crop safely comes back uncropped
/// (chrome still present) and must be compared generically.
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

/// Redraws the [src] pixels inside [crop] as their own image (1:1, no filter).
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

/// A **placement** comparison: how well the decoded objects' rectangles land on
/// the reference image's drawn structure, independent of rendering fidelity
/// (icon art, colours, text) — the signal the ink/edge IoU cannot give, because
/// those are dominated by how the boxes are *filled*, not where they *are*.
///
/// For each measured object rectangle the render's box border is carried into
/// reference space (raster scale + [BdRegistration]) and scored by **perimeter
/// edge support**: the fraction of its border pixels lying within [comparePlacement]'s
/// tolerance of a reference Sobel edge. A correctly placed box traces the
/// reference's drawn outline (LabVIEW draws structures, nodes and terminals as
/// bordered rectangles), so support is high; a mis-placed box crosses empty
/// canvas, so support collapses. Coarse and honest: it certifies *placement
/// against this reference*, not LabVIEW-equivalent rendering.
class PlacementComparison {
  const PlacementComparison({required this.perObject, required this.chance});

  /// Per measured object: its oid and perimeter edge support (0..1).
  final List<({int oid, double support})> perObject;

  /// The support a randomly placed border would collect: the fraction of the
  /// reference's pixels lying within tolerance of an edge. Dense diagrams have
  /// a high chance rate — raw [meanSupport] must be read against it.
  final double chance;

  /// How many object rectangles were measured.
  int get objects => perObject.length;

  /// Mean perimeter edge support over the measured objects (0..1; 0 when
  /// nothing was measurable).
  double get meanSupport => perObject.isEmpty
      ? 0
      : perObject.fold(0.0, (sum, entry) => sum + entry.support) /
            perObject.length;

  /// Mean support **in excess of chance**, per object, rescaled so 0 means
  /// "no better than a randomly placed border on this reference" and 1 means
  /// "every border pixel on an edge" — the score that ranks placement across
  /// references of different densities.
  double get excessSupport {
    if (perObject.isEmpty || chance >= 1) return 0;
    var sum = 0.0;
    for (final entry in perObject) {
      sum += ((entry.support - chance) / (1 - chance)).clamp(0.0, 1.0);
    }
    return sum / perObject.length;
  }
}

/// Measures [PlacementComparison] for [diagram] rendered as [raster] and
/// compared against a reference of [width]×[height] RGBA bytes
/// ([referenceRgba]) under the render→reference [registration].
///
/// Measured rectangles are the drawable structures, nodes, terminals and
/// decorations — LabVIEW draws each as a bordered box — at least [minSide]
/// model units on both sides, excluding free-text label parts
/// ([kBdTextLabelCodes]: drawn as bare text, no box outline to trace) and any
/// box spanning (nearly) the whole drawable extent: the decoded root diagram
/// object has such bounds but LabVIEW draws no border around the diagram
/// itself. A border sample counts as supported when a reference edge pixel
/// lies within [tolerance] px (Chebyshev); boxes with too little of their
/// perimeter inside the reference are skipped.
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
    if (kBdTextLabelCodes.contains(object.kind)) continue;
    final bounds = object.absBounds!;
    if (bounds.width < minSide || bounds.height < minSide) continue;
    // The whole-extent box (the decoded diagram root): no drawn counterpart.
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
    // A box mostly outside the reference can't be judged against it.
    if (samples < 8 || samples * 2 < total) continue;
    perObject.add((oid: object.oid, support: hits / samples));
  }
  return PlacementComparison(perObject: perObject, chance: chance);
}

/// Chebyshev dilation of a binary [mask] by [radius], via a horizontal then a
/// vertical sliding pass — O(pixels · radius), no per-pixel neighbourhood scan.
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

/// The tight bounding rectangle of the **ink** (non-background) pixels in an
/// RGBA buffer, robust to a small fraction of stray outlier ink. A pixel is ink
/// when it is darker than white by more than [inkThreshold] (the same test the
/// [StructuralComparison] uses). Each axis is trimmed to the span that holds all
/// but [trim] of that axis's ink mass from each end, so an isolated speck — a
/// screenshot's window chrome, a stray anti-aliased pixel — does not stretch the
/// box. Returns null when the buffer holds no ink. Pure + total; O(pixels).
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

/// The first index of [hist] at which the cumulative sum from the start first
/// exceeds [cut] (the trimmed lower bound).
int _trimStart(Uint32List hist, int cut) {
  var acc = 0;
  for (var i = 0; i < hist.length; i++) {
    acc += hist[i];
    if (acc > cut) return i;
  }
  return hist.length - 1;
}

/// The last index of [hist] at which the cumulative sum from the end first
/// exceeds [cut] (the trimmed upper bound).
int _trimEnd(Uint32List hist, int cut) {
  var acc = 0;
  for (var i = hist.length - 1; i >= 0; i--) {
    acc += hist[i];
    if (acc > cut) return i;
  }
  return 0;
}

/// The **content-bounds registration**: the similarity map that scales the
/// render's ink bounding box [srcInk] (aspect-preserved) and centres it onto
/// the reference ink box [dstInk] — cancelling the crop/margin/scale mismatch
/// between a clean-room render and a screenshot. Not feature-level
/// registration; it aligns extents and centres, nothing finer.
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

/// A **translation-only** registration at the fixed render→reference [scale]:
/// a coarse-to-fine offset search maximising how many of the render's
/// Sobel-edge pixels land on (near) reference edges — the same agreement
/// [comparePlacement] samples, so the metric is measured at the globally best
/// alignment. The search runs from THREE starts — the ink bounding boxes'
/// centre, top-left and bottom-right alignments — because each start's bias
/// fails differently: extra ink the other side lacks drags the centre, while
/// a missing corner element drags one corner but rarely both. Used when the
/// scale is known by construction (snippet pairs), where fitting a scale from
/// ink extents would mis-scale the whole frame whenever one side draws
/// content the other lacks.
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
  // Whole-pixel offsets only: at the locked (typically 1:1) scale a
  // fractional translation would sub-pixel-blur the redraw, betraying the
  // no-resampling contract the locked path exists for.
  final base = BdRegistration(
    scale: scale,
    dx: (dstInk.center.dx - scale * srcInk.center.dx).roundToDouble(),
    dy: (dstInk.center.dy - scale * srcInk.center.dy).roundToDouble(),
  );
  // Sparse render edge samples (strided to a bounded count), pre-scaled.
  final renderPixels = renderWidth * renderHeight;
  final renderEdges = _sobelMask(
    _luma(renderRgba, renderPixels),
    renderWidth,
    renderHeight,
    edgeThreshold,
  );
  final points = <double>[]; // x0,y0, x1,y1, … in reference scale
  // Sample at most ~300k candidate positions; edge pixels are a fraction.
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

  // The stride-6 sweep only RANKS cells to seed peaks — a strided subset of
  // the edge samples ranks them the same way at a fraction of the cost (the
  // full sample set still scores every refinement and the exact snap). The
  // subset is at most ~4k points, taken uniformly across the list.
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

  // Multi-start, multi-peak coarse-to-fine. A stride-6 sweep around each
  // start collects candidate cells; non-maximum suppression keeps the
  // strongest well-separated PEAKS (repetitive texture — hatched structure
  // borders — makes edge overlap multi-modal, and the false mode can carry
  // more raw hits than the true alignment); each peak is refined at 1 px.
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
    // Re-score the peak with the FULL sample set before refining: the coarse
    // rank is subsampled, and mixing the two scales would let any full-set
    // neighbour beat the peak by construction.
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
  // Final selection: the diagram's structure boxes are large and unique, so
  // their perimeter edge support discriminates the true peak — and, in the
  // sub-pixel snap below, the true whole-pixel offset — where raw hits cannot.
  // Even a single structure (e.g. a lone while loop) is a strong enough anchor;
  // with none, raw hits decide.
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
  /// Nudges the registration by up to ±1px to maximise how many of the render's
  /// edge [points] land EXACTLY on a reference edge (the UN-dilated Sobel map).
  ///
  /// The coarse peak search scores overlap through a 1px dilation, which cannot
  /// tell a pixel-exact alignment from its immediate neighbour, so its integer
  /// pick can sit a pixel off the truth (most visible on diagrams whose only
  /// structure is a faint grey loop, where the dilated peak wanders). Scoring
  /// every edge point un-dilated breaks that tie toward the alignment where the
  /// whole render — not just structure borders — coincides with the reference.
  /// Moves only on a strict improvement, so a render with no exact overlap
  /// anywhere keeps the coarse pick.
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

/// The centred aspect-preserved letterbox of [src] into [width]×[height], as a
/// registration map — the fallback when either image has no ink to register on.
BdRegistration _letterboxRegistration(ui.Image src, int width, int height) {
  final scale = math.min(width / src.width, height / src.height);
  return BdRegistration(
    scale: scale,
    dx: (width - src.width * scale) / 2,
    dy: (height - src.height * scale) / 2,
  );
}

/// Redraws [src] into a [width]×[height] canvas under the [registration] map,
/// over a white background — so a render and a reference of different
/// sizes/aspects can be diffed on a common grid.
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
  // A unit-scale, whole-pixel map (the locked snippet path) is a pure blit:
  // filtering would sub-pixel-blur a render the caller compares losslessly.
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

/// A visual block-diagram oracle panel: the clean-room render on the left, an
/// optional reference screenshot in the middle, and their absolute-difference on
/// the right, with the [ImageComparison] metrics. When no reference is supplied
/// it shows only the render and an affordance describing how to drop one in.
///
/// This is an inspector/diagnostic surface, not a claim of LabVIEW fidelity: the
/// metrics are a coarse progress signal (see [compareToReference]).
class BdOracleView extends StatefulWidget {
  const BdOracleView({
    super.key,
    required this.diagram,
    this.referenceBytes,
    this.maxDimension = 1400,
    this.subViIcons = const {},
  });

  /// The block diagram to render.
  final ViDiagram? diagram;

  /// PNG/other-encoded bytes of a reference block-diagram screenshot, or null.
  final Uint8List? referenceBytes;

  /// Longer-side cap for the off-screen raster.
  final int maxDimension;

  /// SubVI-call node icons (oid → icon) to stamp on the render, matching the
  /// on-screen block-diagram view (resolved by `resolveSubViIconsFor`). Empty by
  /// default.
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
    // Rebuild the raster once the bundled primitive icons decode; the first
    // build proceeds without them rather than blocking on asset IO.
    if (primIconsLoaded().isEmpty) {
      loadPrimIcons().then((icons) {
        if (!mounted || icons.isEmpty) return;
        // _build() returns a Future — start it outside setState (a setState
        // callback must not return one) and swap the field synchronously.
        _retire(_future);
        final rebuilt = _build();
        setState(() {
          _future = rebuilt;
        });
      });
    }
  }

  /// True while a sweep-GIF export is encoding (the button disables so a
  /// second press cannot start a parallel encode).
  bool _exportingGif = false;

  /// Wipe mode: the registered render and the reference overlaid, split at a
  /// draggable divider (ours left, LabVIEW right).
  bool _wipe = false;
  double _wipeFraction = 0.5;
  int _wipeBoxK = -1;
  ui.Image? _wipeReference;
  ui.Image? _wipeFitted;

  /// Wipe zoom: 0 = fit (box-averaged overview), else an integer physical
  /// scale — the only scales at which single-pixel features render without
  /// parity-dependent splitting, so pixel inspection defaults to 1:1.
  int _wipeZoom = 3;
  final ScrollController _wipeH = ScrollController();
  final ScrollController _wipeV = ScrollController();

  // The comparison (rasterise + decode + multi-peak registration) costs a
  // noticeable fraction of a second on large VIs; keep the tab's state alive
  // so revisiting the Oracle tab shows the cached result instead of
  // recomputing it.
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

  /// Frees and clears the fit-mode box-downscaled pair — on replacement, on
  /// diagram change (they belong to the old diagram), and at teardown.
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

  /// Frees a (possibly still-pending) render's images once it resolves. When the
  /// widget is still mounted the free is deferred to after the current frame, so
  /// a `RawImage` that was showing them is out of the tree first.
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
    // A cropped snippet reference is LabVIEW's own render at 1 model unit ==
    // 1 px, so the render is rasterised at that exact scale and registered at
    // the locked render→reference scale — translation-only, never fitted.
    // decodeReferenceImage's snippetCropped flag drives BOTH decisions, so an
    // uncroppable snippet falls back to the generic comparison whole.
    final snippet = reference?.snippetCropped ?? false;
    // One scene for the whole pipeline: its lazy analyses (paint order,
    // wires, chrome indexes, hidden frames) run once and every rasterise —
    // initial, rephased, supersampled — reuses them.
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
      // A snippet reference is LabVIEW's crop of the diagram's ink plus a
      // 2 px margin, so the unit-scale render uses the same margin — matched
      // dimensions, not just matched scale.
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
      return const _OracleData();
    }
    if (reference == null) return _OracleData(rendered: raster.image);
    var result = await compareToReference(
      raster.image,
      reference.image,
      lockScale: snippet ? 1.0 / raster.scale : null,
      anchorRects: snippet
          ? bdStructureAnchorRects(diagram, raster, drawable: drawable)
          : const [],
    );
    // The reference capture's hatch phases (the black case lattice and the
    // error-case stripe lattice each carry their own) are brush phases from
    // the capture environment, not stored in the .vi, so they are measured
    // from the capture and the render redone at the matching style — the only
    // path to a 1:1 hatch comparison. Chrome COLOURS stay at the style's
    // fixed corpus-dominant defaults: a capture from another environment may
    // read a few shades off, which is reference variance, not render error.
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
          // Same geometry, rephased lattices: the first pass's registration
          // and reference edge mask still hold — no second search.
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
    // Display pair: our side re-rendered as vectors at the supersample (real
    // detail for the downscale), the reference nearest-upscaled to match.
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
                    Builder(
                      builder: (context) => TextButton.icon(
                        onPressed: _exportingGif
                            ? null
                            : () => _exportSweepGif(context, result),
                        icon: const Icon(Icons.gif_box_outlined, size: 16),
                        label: Text(
                          _exportingGif ? 'Encoding…' : 'Export sweep GIF',
                        ),
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
                            // Show the render REGISTERED into the reference
                            // frame (same placement the wipe overlays), so
                            // toggling this pane against Reference reveals real
                            // per-pixel differences — the raw content-framed
                            // render sits at a different origin and reads as a
                            // whole-image 1px shift.
                            result != null
                                ? (data.displayFitted ?? result.fitted)
                                : (data.displayRendered ?? data.rendered!),
                            supersample:
                                (result != null
                                    ? data.displayFitted != null
                                    : data.displayRendered != null)
                                ? kOracleDisplaySupersample
                                : 1,
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

  /// The wipe comparator: the reference fills the pane and the registered
  /// render covers it up to [_wipeFraction] of the image width, with a
  /// draggable divider. Both images share the reference frame, so features
  /// line up across the divider.
  Widget _wipePane(BdOracleResult result, _OracleData data) {
    // Source pair: our side supersampled (real vector detail), the reference
    // nearest-upscaled to match — both at kOracleDisplaySupersample x the
    // 1:1 comparison images.
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
            // Display ONLY at integer ratios of the 1:1 image — the sole
            // scales at which every logical pixel maps to the same number of
            // device pixels (uniform lines, even checkerboards). The fit
            // snaps DOWN to n:1 nearest, or 1:n via an exact box-average of
            // the supersampled pair; the remainder letterboxes.
            final dpr = MediaQuery.devicePixelRatioOf(context);
            final fitPhys = math.min(
              constraints.maxWidth * dpr / logicalW,
              constraints.maxHeight * dpr / logicalH,
            );
            // A collapsed pane makes the minify maths degenerate
            // ((1/0).ceil() throws); nothing is visible at that size anyway.
            if (fitPhys <= 0 || !fitPhys.isFinite) {
              return const SizedBox.shrink();
            }
            final double dispPhysW;
            final double dispPhysH;
            ui.Image? showRef;
            ui.Image? showFit;
            if (_wipeZoom > 0) {
              // Integer zoom: the pristine 1:1 pair at z:1 physical —
              // bit-exact by construction; the pane scrolls to reach the
              // rest of the diagram.
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
                    // The ratio moved on (or the view is gone) before this
                    // pair resolved — free it, nothing will show it.
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
            // Laid out at physical-size / dpr, so each image blits exactly
            // once, 1:1 physical (nearest for the integer upscale; the
            // box-averaged pair is already at target resolution).
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
            // Oversized (zoom): scroll on both axes — the divider drag owns
            // horizontal gestures, so scrolling rides the bars and the wheel.
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
            child: CrispImage(image, supersample: supersample),
          ),
        ),
      ],
    ),
  );

  /// Exports the registered pair as the orange-bar sweep GIF
  /// ([encodeOracleSweepGif]): our render west of the bar, the reference east
  /// — both from the 1:1 comparison pair, so they are pixel-aligned. The
  /// encode runs off the UI isolate; the save destination comes from the OS
  /// save dialog (matching the file-open flow), and a snackbar reports where
  /// the file went.
  Future<void> _exportSweepGif(
    BuildContext context,
    BdOracleResult result,
  ) async {
    setState(() => _exportingGif = true);
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final width = result.reference.width;
      final height = result.reference.height;
      final fitted = (await result.fitted.toByteData())!.buffer.asUint8List();
      final reference = result.referenceRgba;
      final gif = await Isolate.run(
        () => encodeOracleSweepGif(
          leftRgba: fitted,
          rightRgba: reference,
          width: width,
          height: height,
        ),
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

  /// Copies a pane's [image] to the system clipboard as a PNG. The oracle
  /// panes pass their [kOracleDisplaySupersample]x display image, so the copy
  /// matches the wipe-compare's pixel scale.
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

  /// The wipe/pane images at [kOracleDisplaySupersample]x (see there); the
  /// 1:1 [result] images remain the metric inputs.
  final ui.Image? displayRendered;
  final ui.Image? displayFitted;
  final ui.Image? displayReference;

  /// Releases the GPU-backed images this render holds (each at most once — the
  /// result's `rendered` and same-size `fitted` alias other fields).
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

/// The oracle's DISPLAY images are rendered at this integer multiple of the
/// comparison scale and downscaled to the pane — a 1:1 raster minified to a
/// pane simply has too few source pixels for any filter to save (a 22 px
/// icon shown at 13 px is destroyed information). Our side re-renders as
/// vectors at 3x (real detail); the reference bitmap nearest-upscales 3x
/// (honest block replication) so both wipe halves share one resolution and
/// one downscale path. The 1:1 images remain the metric inputs.
const kOracleDisplaySupersample = 3;

/// [src] nearest-upscaled by the integer [factor] — exact block replication.
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

/// Redraws a supersampled render into the supersampled reference frame under
/// the 1:1 [registration]: the [factor]-scaled canvas applies the same
/// logical transform, so the display image aligns with the upscaled
/// reference exactly where the 1:1 fitted aligns with the 1:1 reference.
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
  // The translate must land on whole 1:1 pixels: a fractional offset slices
  // logical pixels across box-average boundaries and breaks uniformity.
  canvas.translate(
    registration.dx.roundToDouble(),
    registration.dy.roundToDouble(),
  );
  canvas.scale(registration.scale);
  // The rendered image is itself [factor]x: draw it at logical (1:1) size —
  // net 1:1 pixels on the supersampled canvas, sampled exactly.
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

/// Exact integer box-average downscale by [k]: every destination pixel is
/// the unweighted mean of one k x k source block. Phase-free by
/// construction — a 1 px feature lands identically wherever it sits, so
/// lines keep one thickness and checkerboards stay even. (Any NON-integer
/// resample ratio is phase-dependent: some source columns get one
/// destination pixel and some get two, which is exactly the uneven
/// checkerboard and the 1.25/0.75 split-line artefact.)
/// The box factor for showing a [supersample]x [src] at a pane fit of
/// [fitPhys] (< 1): `supersample * ceil(1/fitPhys)`, clamped so the result
/// keeps at least one pixel per axis — an extreme squeeze must degrade to a
/// tiny image, never a zero-dimension one.
int boxDownscaleFactor(ui.Image src, int supersample, double fitPhys) {
  final k = supersample * (1 / fitPhys).ceil();
  return k.clamp(1, math.min(src.width, src.height));
}

Future<ui.Image> boxDownscale(ui.Image src, int k) async {
  final data = (await src.toByteData())!;
  final sw = src.width, sh = src.height;
  // A factor beyond a source dimension is clamped (every caller already
  // clamps via [boxDownscaleFactor]); the floor below then keeps the block
  // reads in bounds AND the output at least 1x1.
  final blockK = math.min(k, math.min(sw, sh));
  final dw = math.max(1, sw ~/ blockK), dh = math.max(1, sh ~/ blockK);
  final bytes = data.buffer.asUint8List();
  // The averaging is O(source pixels) on multi-megapixel supersampled
  // rasters — off the UI isolate so pane resizes don't jank.
  final out = await Isolate.run(() {
    final out = Uint8List(dw * dh * 4);
    final n = blockK * blockK;
    for (var y = 0; y < dh; y++) {
      for (var x = 0; x < dw; x++) {
        var r = 0, g = 0, b = 0, a = 0;
        for (var sy = y * blockK; sy < y * blockK + blockK; sy++) {
          var i = (sy * sw + x * blockK) * 4;
          for (var sx = 0; sx < blockK; sx++) {
            r += bytes[i];
            g += bytes[i + 1];
            b += bytes[i + 2];
            a += bytes[i + 3];
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
    return out;
  });
  return imageFromRgba(out, dw, dh);
}

/// Shows [image] crisp at any pane size: at native size or larger it draws
/// 1:1 with nearest sampling (the raster matches the reference pixel for
/// pixel — filtering would only blur it); minified it draws an
/// iteratively-halved downscale at the EXACT display width, so the
/// compositor never rescales anything.
class CrispImage extends StatefulWidget {
  /// [image] displays only at integer ratios of its logical size (see
  /// [boxDownscale] — the sole phase-free scales): n:1 nearest upscale, or
  /// 1:n via exact box-averaging, letterboxing the remainder. When the image
  /// is a supersample of the logical content, pass the factor so ratios
  /// snap against LOGICAL pixels.
  const CrispImage(this.image, {this.supersample = 1, super.key});

  final ui.Image image;
  final int supersample;

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
      // A collapsed pane (zero constraint axis) makes fitPhys 0 and the
      // minify maths degenerate ((1/0).ceil() throws); nothing is visible
      // at that size anyway.
      if (fitPhys <= 0 || !fitPhys.isFinite) return const SizedBox.shrink();
      final double dispPhysW;
      final double dispPhysH;
      ui.Image? shown;
      if (fitPhys >= 1) {
        final n = fitPhys.floor();
        dispPhysW = logicalW * n;
        dispPhysH = logicalH * n;
        shown = widget.image;
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

/// Clips its child to the leftmost [fraction] of its width — the moving half
/// of the oracle's wipe comparator.
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
