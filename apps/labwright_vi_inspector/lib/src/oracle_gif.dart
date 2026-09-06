library;

import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

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

const int kOracleSweepBarRgb = 0xffab40;

class OracleSweepGifStyle {
  const OracleSweepGifStyle({
    this.positions = 24,
    this.delayCs = 6,
    this.barWidth = 3,
  });

  final int positions;

  final int delayCs;

  final int barWidth;

  int get frameCount => 2 * positions - 2;
}

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
