/// Animated-GIF export of the Oracle tab's render-vs-reference pair: a
/// vertical orange bar sweeps across the frame and back, showing our render
/// left of the bar and the reference right of it — the wipe comparator as a
/// self-playing loop.
///
/// Compression: GIF is indexed, so both source images share one **global
/// 256-colour palette** ranked by pixel frequency. The population past the
/// palette is a thin tail: measured over all 46 snippet render/reference
/// pairs, a pair holds 47 (missing_terminal) to 905 (ProjectItems) distinct
/// colours — 35 of the 46 exceed 256 — yet the top 255 always cover at
/// least **99.72%** of pixels (worst case Export Palette Image WMF, 844
/// colours; most pairs are well above 99.9%). Web-safe chrome and flat
/// fills dominate; the tail is ClearType text fringe. So ranking keeps
/// every colour that appears more than a handful of times exactly, and
/// only the rarest fringe pixels map to their nearest palette entry. No
/// dithering — the sources are flat-colour renders where error diffusion
/// would speckle solid fills.
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
  OracleSweepGifStyle style = const OracleSweepGifStyle(),
}) => Isolate.run(
  () => encodeOracleSweepGif(
    leftRgba: leftRgba,
    rightRgba: rightRgba,
    width: width,
    height: height,
    style: style,
  ),
);

/// The sweep bar's colour — the same orange accent the interactive wipe
/// divider draws (Material `orangeAccent`).
const int kOracleSweepBarRgb = 0xffab40;

/// The sweep animation's shape: how many stops the bar makes, how long each
/// is held, and how wide it is. One value object rather than loose
/// parameters, so a caller passes an animation rather than three numbers.
class OracleSweepGifStyle {
  const OracleSweepGifStyle({
    this.positions = 24,
    this.delayCs = 6,
    this.barWidth = 3,
  });

  /// Bar stops per direction. The sweep runs out and back without
  /// duplicating the turnaround endpoints, so it emits [frameCount] frames.
  final int positions;

  /// Frame duration in hundredths of a second (6 = ~17 fps).
  final int delayCs;

  /// The bar's width in pixels.
  final int barWidth;

  /// Frames emitted for [positions] stops: out, then back with neither
  /// endpoint repeated.
  int get frameCount => 2 * positions - 2;
}

/// Encodes the sweep GIF. [leftRgba]/[rightRgba] are same-sized RGBA buffers
/// ([width] x [height]); left shows west of the bar (our render), right
/// shows east of it (the reference). The animation loops forever.
///
/// Throws [ArgumentError] on a buffer whose length does not match the given
/// size, or on a [OracleSweepGifStyle] the frame geometry cannot honour.
/// These are thrown, not asserted: the encoder's callers run it inside
/// `Isolate.run`, where a release-mode assert is stripped and the mismatch
/// resurfaces as a bare RangeError from the pixel loop.
Uint8List encodeOracleSweepGif({
  required Uint8List leftRgba,
  required Uint8List rightRgba,
  required int width,
  required int height,
  OracleSweepGifStyle style = const OracleSweepGifStyle(),
}) {
  if (width <= 0 || height <= 0) {
    throw ArgumentError(
      'sweep GIF size must be positive, got ${width}x$height',
    );
  }
  for (final (name, rgba) in [
    ('leftRgba', leftRgba),
    ('rightRgba', rightRgba),
  ]) {
    if (rgba.length != width * height * 4) {
      throw ArgumentError(
        '$name is ${rgba.length} bytes, not the ${width * height * 4} '
        'a ${width}x$height RGBA image needs',
      );
    }
  }
  if (style.positions < 2) {
    throw ArgumentError(
      'a sweep needs at least 2 stops, got ${style.positions}',
    );
  }
  if (style.barWidth < 1 || style.barWidth > width) {
    throw ArgumentError(
      'bar width ${style.barWidth} does not fit a $width px frame',
    );
  }
  final barWidth = style.barWidth;
  // Global palette: the bar colour, then the pair's colours by frequency.
  final counts = <int, int>{};
  void tally(Uint8List rgba) {
    for (var i = 0; i < rgba.length; i += 4) {
      final c = (rgba[i] << 16) | (rgba[i + 1] << 8) | rgba[i + 2];
      counts[c] = (counts[c] ?? 0) + 1;
    }
  }

  tally(leftRgba);
  tally(rightRgba);
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
    final out = Uint8List(width * height);
    for (var i = 0; i < width * height; i++) {
      final c = (rgba[i * 4] << 16) | (rgba[i * 4 + 1] << 8) | rgba[i * 4 + 2];
      out[i] = indexOf[c] ??= nearest(c);
    }
    return out;
  }

  final leftIdx = indexed(leftRgba);
  final rightIdx = indexed(rightRgba);
  // Bar stops: 0..1 forward, then back without repeating the endpoints.
  final stops = <double>[
    for (var i = 0; i < style.positions; i++) i / (style.positions - 1),
    for (var i = style.positions - 2; i >= 1; i--) i / (style.positions - 1),
  ];
  final encoder = img.GifEncoder();
  for (final stop in stops) {
    final barLeft = ((width - barWidth) * stop).round();
    final frame = img.Image(
      width: width,
      height: height,
      withPalette: true,
      palette: palette,
    );
    final data = frame.data!.toUint8List();
    data.setAll(0, rightIdx);
    for (var y = 0; y < height; y++) {
      final row = y * width;
      data.setRange(row, row + barLeft, leftIdx, row);
      data.fillRange(row + barLeft, row + barLeft + barWidth, 0);
    }
    encoder.addFrame(frame, duration: style.delayCs);
  }
  return encoder.finish()!;
}
