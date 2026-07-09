/// A **reference-image oracle** for the block-diagram renderer: it rasterises a
/// decoded [ViDiagram] with the exact same [BdDiagramPainter] the on-screen view
/// uses, then measures how far that render is from a supplied reference
/// screenshot (a documentation image of the same VI's LabVIEW block diagram).
///
/// The comparison is a straight per-pixel absolute difference after the rendered
/// image is letterboxed into the reference's dimensions. It is a *coarse* signal
/// — the render is not pixel-perfect and the two images have different origins,
/// scales and anti-aliasing — so [ImageComparison.meanAbsDiff] /
/// [ImageComparison.diffFraction] are progress metrics, not a pass/fail gate, and
/// the side-by-side + diff visualisation is the primary output for a human to
/// judge fidelity. No claim of LabVIEW equivalence is made or implied.
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
/// (then multiplied by [pixelRatio]); the raster is clamped to 8192px. Returns
/// null when the diagram has no positioned objects.
Future<BdRaster?> rasteriseBlockDiagram(
  ViDiagram diagram, {
  int maxDimension = 2000,
  double pixelRatio = 1.0,
}) async {
  final drawable = bdDrawableObjects(diagram);
  if (drawable.isEmpty) return null;
  final content = bdContentRect(drawable, includeWires: false);
  if (content.width <= 0 || content.height <= 0) return null;
  final ordered = bdPaintOrder(drawable, diagram.byId);

  final longSide = math.max(content.width, content.height);
  final scale = (maxDimension / longSide).clamp(0.01, 8.0) * pixelRatio;
  final width = (content.width * scale).ceil().clamp(1, 8192);
  final height = (content.height * scale).ceil().clamp(1, 8192);

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(
    recorder,
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
  );
  canvas.scale(scale);
  BdDiagramPainter(
    objects: ordered,
    origin: content.topLeft,
  ).paint(canvas, content.size);
  final picture = recorder.endRecording();
  try {
    return BdRaster(
      image: await picture.toImage(width, height),
      content: content,
      scale: scale,
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

/// The full output of comparing a rendered block diagram to a reference image:
/// the rendered raster, the rendered raster letterboxed into the reference's
/// dimensions, the reference, the [comparison] metrics, and a diff image.
class BdOracleResult {
  const BdOracleResult({
    required this.rendered,
    required this.fitted,
    required this.reference,
    required this.comparison,
    required this.diffImage,
  });

  final ui.Image rendered;
  final ui.Image fitted;
  final ui.Image reference;
  final ImageComparison comparison;
  final ui.Image diffImage;
}

/// Compares a [rendered] block diagram against a [reference] image: the render is
/// letterboxed (aspect-preserved, centred) into the reference's dimensions, then
/// diffed pixel-for-pixel. See [ImageComparison] for the honest interpretation of
/// the metrics.
Future<BdOracleResult> compareToReference(
  ui.Image rendered,
  ui.Image reference, {
  int threshold = 16,
}) async {
  final width = reference.width;
  final height = reference.height;
  // Skip the resample when the render already matches the reference exactly, so
  // an identical pair diffs to a true zero (a same-size letterbox still applies
  // a sub-pixel filter).
  final fitted = (rendered.width == width && rendered.height == height)
      ? rendered
      : await _letterbox(rendered, width, height);
  final renderedRgba = await _rgbaOf(fitted);
  final referenceRgba = await _rgbaOf(reference);
  final comparison = compareRgba(
    renderedRgba,
    referenceRgba,
    width,
    height,
    threshold: threshold,
  );
  final diffImage = await imageFromRgba(comparison.diff, width, height);
  return BdOracleResult(
    rendered: rendered,
    fitted: fitted,
    reference: reference,
    comparison: comparison,
    diffImage: diffImage,
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

/// Redraws [src] centred and aspect-preserved into a [width]×[height] canvas over
/// a white background — so a render and a reference of different sizes/aspects
/// can be diffed on a common grid.
Future<ui.Image> _letterbox(
  ui.Image src,
  int width,
  int height, {
  Color background = const Color(0xFFFFFFFF),
}) {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(
    recorder,
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
  );
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = background,
  );
  final scale = math.min(width / src.width, height / src.height);
  final drawWidth = src.width * scale;
  final drawHeight = src.height * scale;
  canvas.drawImageRect(
    src,
    Rect.fromLTWH(0, 0, src.width.toDouble(), src.height.toDouble()),
    Rect.fromLTWH(
      (width - drawWidth) / 2,
      (height - drawHeight) / 2,
      drawWidth,
      drawHeight,
    ),
    Paint()..filterQuality = FilterQuality.medium,
  );
  return recorder.endRecording().toImage(width, height);
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
  });

  /// The block diagram to render.
  final ViDiagram? diagram;

  /// PNG/other-encoded bytes of a reference block-diagram screenshot, or null.
  final Uint8List? referenceBytes;

  /// Longer-side cap for the off-screen raster.
  final int maxDimension;

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
      _future = _build();
    }
  }

  Future<_OracleData> _build() async {
    final diagram = widget.diagram;
    if (diagram == null) return const _OracleData();
    final raster = await rasteriseBlockDiagram(
      diagram,
      maxDimension: widget.maxDimension,
    );
    if (raster == null) return const _OracleData();
    final bytes = widget.referenceBytes;
    if (bytes == null) return _OracleData(rendered: raster.image);
    final reference = await decodeImage(bytes);
    final result = await compareToReference(raster.image, reference);
    return _OracleData(rendered: raster.image, result: result);
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
                      'Absolute-difference oracle · mean abs diff '
                      '${result.comparison.meanAbsDiff.toStringAsFixed(1)}/255 · '
                      '${(result.comparison.diffFraction * 100).toStringAsFixed(1)}% '
                      'of pixels differ. Coarse progress signal (render is not '
                      'pixel-perfect and origins/scales differ) — not a fidelity '
                      'claim.',
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
  const _OracleData({this.rendered, this.result});
  final ui.Image? rendered;
  final BdOracleResult? result;
}
