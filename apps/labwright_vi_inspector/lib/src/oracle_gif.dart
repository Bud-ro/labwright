/// Animated-GIF export of the Oracle tab's render-vs-reference pair: a
/// vertical orange bar sweeps across the frame and back, showing our render
/// left of the bar and the reference right of it — the wipe comparator as a
/// self-playing loop.
///
/// Compression: GIF is indexed, so both source images share one **global
/// 256-colour palette** ranked by pixel frequency. The pair's colour
/// population is small (web-safe chrome plus ClearType text fringes measured
/// at ~370-400 distinct colours per corpus reference, with the top 255
/// covering >99.97% of pixels), so ranking keeps every colour that appears
/// more than a handful of times exactly; only the rarest fringe pixels map
/// to their nearest palette entry. No dithering — the sources are flat-
/// colour renders where error diffusion would speckle solid fills.
///
/// Everything operates on plain RGBA byte buffers so the encode runs in a
/// background isolate and in plain Dart tests.
library;

import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// [encodeOracleSweepGif] on a worker isolate. Lives at top level so the
/// spawned closure's context holds ONLY these sendable parameters — inside a
/// State method the enclosing scope's context chain rides along, and one
/// unsendable local there (a ui.Image, a messenger) makes the whole closure
/// unsendable at runtime.
Future<Uint8List> encodeOracleSweepGifOffThread({
  required Uint8List leftRgba,
  required Uint8List rightRgba,
  required int width,
  required int height,
}) => Isolate.run(
  () => encodeOracleSweepGif(
    leftRgba: leftRgba,
    rightRgba: rightRgba,
    width: width,
    height: height,
  ),
);

/// The sweep bar's colour — the same orange accent the interactive wipe
/// divider draws (Material `orangeAccent`).
const int kOracleSweepBarRgb = 0xffab40;

/// Encodes the sweep GIF. [leftRgba]/[rightRgba] are same-sized RGBA buffers
/// ([width] x [height]); left shows west of the bar (our render), right
/// shows east of it (the reference). The bar makes [positions] stops each
/// direction ([2 * positions - 2] frames — the turnaround endpoints are not
/// duplicated), each held [delayCs] hundredths of a second, looping forever.
/// [downscale] box-averages both sources by that integer factor first (1 =
/// full resolution).
Uint8List encodeOracleSweepGif({
  required Uint8List leftRgba,
  required Uint8List rightRgba,
  required int width,
  required int height,
  int positions = 24,
  int delayCs = 6,
  int barWidth = 3,
  int downscale = 1,
}) {
  assert(leftRgba.length == width * height * 4);
  assert(rightRgba.length == width * height * 4);
  assert(positions >= 2);
  var left = leftRgba, right = rightRgba, w = width, h = height;
  if (downscale > 1) {
    left = _boxDownscaleRgba(left, width, height, downscale);
    right = _boxDownscaleRgba(right, width, height, downscale);
    w = width ~/ downscale;
    h = height ~/ downscale;
  }
  // Global palette: the bar colour, then the pair's colours by frequency.
  final counts = <int, int>{};
  void tally(Uint8List rgba) {
    for (var i = 0; i < rgba.length; i += 4) {
      final c = (rgba[i] << 16) | (rgba[i + 1] << 8) | rgba[i + 2];
      counts[c] = (counts[c] ?? 0) + 1;
    }
  }

  tally(left);
  tally(right);
  final ranked = counts.keys.toList()..sort((a, b) => counts[b]! - counts[a]!);
  final paletteColors = <int>[
    kOracleSweepBarRgb,
    ...ranked.where((c) => c != kOracleSweepBarRgb).take(255),
  ];
  final palette = img.PaletteUint8(256, 3);
  for (var i = 0; i < paletteColors.length; i++) {
    final c = paletteColors[i];
    palette.setRgb(i, c >> 16, (c >> 8) & 0xff, c & 0xff);
  }
  // Colour -> index; colours past the 255 kept map to the nearest entry.
  final indexOf = <int, int>{
    for (var i = 0; i < paletteColors.length; i++) paletteColors[i]: i,
  };
  int nearest(int c) {
    final r = c >> 16, g = (c >> 8) & 0xff, b = c & 0xff;
    var best = 0, bestD = 1 << 30;
    for (var i = 0; i < paletteColors.length; i++) {
      final p = paletteColors[i];
      final dr = r - (p >> 16), dg = g - ((p >> 8) & 0xff), db = b - (p & 0xff);
      final d = dr * dr + dg * dg + db * db;
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    return best;
  }

  Uint8List indexed(Uint8List rgba) {
    final out = Uint8List(w * h);
    for (var i = 0; i < w * h; i++) {
      final c = (rgba[i * 4] << 16) | (rgba[i * 4 + 1] << 8) | rgba[i * 4 + 2];
      out[i] = indexOf[c] ??= nearest(c);
    }
    return out;
  }

  final leftIdx = indexed(left);
  final rightIdx = indexed(right);
  // Bar stops: 0..1 forward, then back without repeating the endpoints.
  final stops = <double>[
    for (var i = 0; i < positions; i++) i / (positions - 1),
    for (var i = positions - 2; i >= 1; i--) i / (positions - 1),
  ];
  final encoder = img.GifEncoder();
  for (final stop in stops) {
    final barLeft = ((w - barWidth) * stop).round();
    final frame = img.Image(
      width: w,
      height: h,
      withPalette: true,
      palette: palette,
    );
    final data = Uint8List.view(frame.buffer);
    data.setAll(0, rightIdx);
    for (var y = 0; y < h; y++) {
      final row = y * w;
      data.setRange(row, row + barLeft, leftIdx, row);
      data.fillRange(row + barLeft, row + barLeft + barWidth, 0);
    }
    encoder.addFrame(frame, duration: delayCs);
  }
  return encoder.finish()!;
}

/// Integer box-average downscale of an RGBA buffer by [k] (truncating the
/// remainder rows/columns).
Uint8List _boxDownscaleRgba(Uint8List rgba, int width, int height, int k) {
  final dw = width ~/ k, dh = height ~/ k;
  final out = Uint8List(dw * dh * 4);
  final n = k * k;
  for (var y = 0; y < dh; y++) {
    for (var x = 0; x < dw; x++) {
      var r = 0, g = 0, b = 0, a = 0;
      for (var sy = y * k; sy < y * k + k; sy++) {
        var i = (sy * width + x * k) * 4;
        for (var sx = 0; sx < k; sx++) {
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
  return out;
}
