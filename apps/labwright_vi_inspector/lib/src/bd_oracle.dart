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
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import 'diagram_view.dart';

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
  Map<int, ViLegacyIcon> subViIcons = const {},
  List<ViWire>? wires,
}) async {
  final drawable = bdDrawableObjects(diagram);
  if (drawable.isEmpty) return null;
  final content = bdContentRect(drawable, includeWires: false);
  if (content.width <= 0 || content.height <= 0) return null;
  final ordered = bdPaintOrder(drawable, diagram.byId);
  // Defaults to the diagram's decoded dataflow wires; pass `const []` to
  // rasterise the wire-free layout (used to measure the before/after delta).
  final wireList = wires ?? diagram.wires;

  final longSide = math.max(content.width, content.height);
  final pxScale =
      scale ?? (maxDimension / longSide).clamp(0.01, 8.0) * pixelRatio;
  final width = (content.width * pxScale).ceil().clamp(1, 8192);
  final height = (content.height * pxScale).ceil().clamp(1, 8192);

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
    objects: ordered,
    origin: content.topLeft,
    wires: wireList,
    subViIcons: subViIcons,
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

/// Computes the [StructuralComparison] of two equal-length RGBA buffers
/// ([width]×[height]×4 bytes each). A pixel is **ink** when its luminance is
/// darker than white by more than [inkThreshold]; an **edge** when its Sobel
/// gradient magnitude exceeds [edgeThreshold]. Pure + total (asserts matching
/// sizes).
StructuralComparison compareStructural(
  Uint8List a,
  Uint8List b,
  int width,
  int height, {
  int inkThreshold = 12,
  int edgeThreshold = 64,
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
  final edgeB = _sobelMask(lumB, width, height, edgeThreshold);
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
    required this.comparison,
    required this.structural,
    required this.diffImage,
    required this.registered,
    required this.registration,
  });

  final ui.Image rendered;
  final ui.Image fitted;
  final ui.Image reference;
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
/// render: 1.0). Registration then only *translates* — first aligning the two
/// ink bounding-box centres, then refining by ink overlap — instead of deriving
/// a scale from the ink extents, which a sparse render (e.g. a diagram whose
/// only content is undrawn text labels) can distort arbitrarily.
Future<BdOracleResult> compareToReference(
  ui.Image rendered,
  ui.Image reference, {
  int threshold = 16,
  double? lockScale,
}) async {
  final width = reference.width;
  final height = reference.height;
  final referenceRgba = await _rgbaOf(reference);
  // Skip the resample when the render already matches the reference exactly, so
  // an identical pair diffs to a true zero (a same-size letterbox still applies
  // a sub-pixel filter).
  ui.Image fitted;
  var registered = false;
  var registration = BdRegistration.identity;
  if (rendered.width == width && rendered.height == height) {
    fitted = rendered;
  } else {
    // Register the render onto the reference by aligning their drawn-ink
    // bounding boxes (aspect-preserved scale + centre), so a correct render at
    // a different crop/scale is credited instead of penalised. Falls back to a
    // centred letterbox when either image has no ink to register on.
    final renderedOwnRgba = await _rgbaOf(rendered);
    final srcInk = inkBoundsOf(
      renderedOwnRgba,
      rendered.width,
      rendered.height,
    );
    final dstInk = inkBoundsOf(referenceRgba, width, height);
    if (srcInk != null && dstInk != null) {
      registration = lockScale != null
          ? _translationRegistration(
              lockScale,
              srcInk,
              dstInk,
              renderedOwnRgba,
              rendered.width,
              rendered.height,
              referenceRgba,
              width,
              height,
            )
          : _inkBoundsRegistration(srcInk, dstInk);
      fitted = await _redrawRegistered(rendered, registration, width, height);
      registered = true;
    } else {
      registration = _letterboxRegistration(rendered, width, height);
      fitted = await _redrawRegistered(rendered, registration, width, height);
    }
  }
  final renderedRgba = await _rgbaOf(fitted);
  final comparison = compareRgba(
    renderedRgba,
    referenceRgba,
    width,
    height,
    threshold: threshold,
  );
  final structural = compareStructural(
    renderedRgba,
    referenceRgba,
    width,
    height,
  );
  final diffImage = await imageFromRgba(comparison.diff, width, height);
  return BdOracleResult(
    rendered: rendered,
    fitted: fitted,
    reference: reference,
    comparison: comparison,
    structural: structural,
    diffImage: diffImage,
    registered: registered,
    registration: registration,
  );
}

/// Decodes PNG/other-encoded image [bytes] to a [ui.Image].
Future<ui.Image> decodeImage(Uint8List bytes) {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromList(bytes, completer.complete);
  return completer.future;
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
Future<ui.Image> decodeReferenceImage(Uint8List bytes) async {
  final image = await decodeImage(bytes);
  if (extractSnippetVi(bytes) == null) return image;
  final interior = snippetDiagramInterior(image.width, image.height);
  if (interior.right - interior.left < 8 ||
      interior.bottom - interior.top < 8) {
    return image;
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
  return cropped;
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
      : perObject.fold(0.0, (a, e) => a + e.support) / perObject.length;

  /// Mean support **in excess of chance**, per object, rescaled so 0 means
  /// "no better than a randomly placed border on this reference" and 1 means
  /// "every border pixel on an edge" — the score that ranks placement across
  /// references of different densities.
  double get excessSupport {
    if (perObject.isEmpty || chance >= 1) return 0;
    var sum = 0.0;
    for (final e in perObject) {
      sum += ((e.support - chance) / (1 - chance)).clamp(0.0, 1.0);
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
  int tolerance = 2,
  int edgeThreshold = 64,
  int minSide = 6,
}) {
  final pixels = width * height;
  final edges = _dilate(
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

  final drawable = bdDrawableObjects(diagram);
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
    final renderRect = Rect.fromLTRB(
      (bounds.left - raster.content.left) * raster.scale,
      (bounds.top - raster.content.top) * raster.scale,
      (bounds.right - raster.content.left) * raster.scale,
      (bounds.bottom - raster.content.top) * raster.scale,
    );
    final r = registration.mapRect(renderRect);
    var hits = 0, samples = 0, total = 0;
    void sample(int x, int y) {
      total++;
      if (x < 0 || y < 0 || x >= width || y >= height) return;
      samples++;
      if (edges[y * width + x] != 0) hits++;
    }

    final left = r.left.round(), right = r.right.round();
    final top = r.top.round(), bottom = r.bottom.round();
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
/// starts from aligning the ink bounding-box centres ([srcInk] onto [dstInk]),
/// then refines the offset over a ±[searchRadius] px window to maximise how
/// many of the render's Sobel-edge pixels land on (near) reference edges — the
/// same agreement [comparePlacement] samples, so the metric is measured at the
/// globally best alignment. Used when the scale is known by construction
/// (snippet pairs), where fitting a scale from ink extents would mis-scale the
/// whole frame whenever one side draws content the other lacks, and where
/// centre-alignment alone inherits a bias from any ink one side draws beyond
/// the other's crop.
BdRegistration _translationRegistration(
  double scale,
  Rect srcInk,
  Rect dstInk,
  Uint8List renderRgba,
  int renderWidth,
  int renderHeight,
  Uint8List referenceRgba,
  int width,
  int height, {
  int searchRadius = 12,
  int edgeThreshold = 64,
}) {
  final base = BdRegistration(
    scale: scale,
    dx: dstInk.center.dx - scale * srcInk.center.dx,
    dy: dstInk.center.dy - scale * srcInk.center.dy,
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
  final referenceEdges = _dilate(
    _sobelMask(
      _luma(referenceRgba, width * height),
      width,
      height,
      edgeThreshold,
    ),
    width,
    height,
    1,
  );
  var bestDx = base.dx, bestDy = base.dy, bestHits = -1;
  for (var oy = -searchRadius; oy <= searchRadius; oy++) {
    for (var ox = -searchRadius; ox <= searchRadius; ox++) {
      final dx = base.dx + ox, dy = base.dy + oy;
      var hits = 0;
      for (var i = 0; i < points.length; i += 2) {
        final x = (points[i] + dx).round();
        final y = (points[i + 1] + dy).round();
        if (x < 0 || y < 0 || x >= width || y >= height) continue;
        hits += referenceEdges[y * width + x];
      }
      if (hits > bestHits) {
        bestHits = hits;
        bestDx = dx;
        bestDy = dy;
      }
    }
  }
  return BdRegistration(scale: scale, dx: bestDx, dy: bestDy);
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
  canvas.drawImageRect(
    src,
    Rect.fromLTWH(0, 0, src.width.toDouble(), src.height.toDouble()),
    registration.mapRect(
      Rect.fromLTWH(0, 0, src.width.toDouble(), src.height.toDouble()),
    ),
    Paint()..filterQuality = FilterQuality.medium,
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

class _BdOracleViewState extends State<BdOracleView> {
  late Future<_OracleData> _future = _build();

  @override
  void didUpdateWidget(BdOracleView old) {
    super.didUpdateWidget(old);
    if (!identical(old.diagram, widget.diagram) ||
        !identical(old.referenceBytes, widget.referenceBytes)) {
      _retire(_future);
      _future = _build();
    }
  }

  @override
  void dispose() {
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
    // A snippet reference is LabVIEW's own render at 1 model unit == 1 px, so
    // the render is rasterised at that exact scale — no resampling loss.
    final snippet = bytes != null && extractSnippetVi(bytes) != null;
    final raster = await rasteriseBlockDiagram(
      diagram,
      maxDimension: widget.maxDimension,
      scale: snippet ? 1.0 : null,
      subViIcons: widget.subViIcons,
    );
    if (raster == null) return const _OracleData();
    if (bytes == null) return _OracleData(rendered: raster.image);
    final reference = await decodeReferenceImage(bytes);
    // Snippet raster and unit-scale render are both 1 px per model unit, so
    // the registration scale is known — translation-only, never fitted.
    final result = await compareToReference(
      raster.image,
      reference,
      lockScale: snippet ? 1.0 : null,
    );
    final placement = comparePlacement(
      diagram: diagram,
      raster: raster,
      registration: result.registration,
      referenceRgba: await reference.toByteData().then(
        (d) => d!.buffer.asUint8List(),
      ),
      width: reference.width,
      height: reference.height,
    );
    return _OracleData(
      rendered: raster.image,
      result: result,
      placement: placement,
    );
  }

  @override
  Widget build(BuildContext context) {
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
                      '${data.placement == null || data.placement!.objects == 0 ? '' : 'Placement · '
                                '${(data.placement!.meanSupport * 100).toStringAsFixed(1)}% '
                                'perimeter edge support over ${data.placement!.objects} boxes — '
                                'where the boxes are, not how they are filled.   '}'
                      '${result.registered ? 'Content-bounds registered' : 'Centred letterbox'}. '
                      'Coarse progress signals — not a fidelity claim.',
                      style: const TextStyle(color: Colors.grey, fontSize: 12),
                    ),
            ),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: _pane('Rendered (clean-room)', data.rendered!),
                  ),
                  if (result != null) ...[
                    Expanded(child: _pane('Reference', result.reference)),
                    Expanded(child: _pane('Absolute diff', result.diffImage)),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _pane(String caption, ui.Image image) => Padding(
    padding: const EdgeInsets.all(4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(caption, style: const TextStyle(fontSize: 11, color: Colors.grey)),
        const SizedBox(height: 4),
        Expanded(
          child: ColoredBox(
            color: const Color(0xFF202020),
            child: FittedBox(
              child: SizedBox(
                width: image.width.toDouble(),
                height: image.height.toDouble(),
                child: RawImage(image: image, fit: BoxFit.contain),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

class _OracleData {
  const _OracleData({this.rendered, this.result, this.placement});
  final ui.Image? rendered;
  final BdOracleResult? result;
  final PlacementComparison? placement;

  /// Releases the GPU-backed images this render holds (each at most once — the
  /// result's `rendered` and same-size `fitted` alias other fields).
  void dispose() {
    final seen = <ui.Image>{};
    void disp(ui.Image? image) {
      if (image != null && seen.add(image)) image.dispose();
    }

    disp(rendered);
    final r = result;
    if (r != null) {
      disp(r.rendered);
      disp(r.fitted);
      disp(r.reference);
      disp(r.diffImage);
    }
  }
}
