import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_inspector/src/bd_oracle.dart';
import 'package:labwright_vi_inspector/src/diagram_view.dart';
import 'package:labwright_vi_inspector/src/oracle_gif.dart';

import 'util.dart';

Uint8List _flat(int w, int h, int color) {
  final out = Uint8List(w * h * 4);
  for (var i = 0; i < w * h; i++) {
    out[i * 4] = color >> 16;
    out[i * 4 + 1] = (color >> 8) & 0xff;
    out[i * 4 + 2] = color & 0xff;
    out[i * 4 + 3] = 0xff;
  }
  return out;
}

int _pixel(img.Image frame, int x, int y) {
  final p = frame.getPixel(x, y);
  return (p.r.toInt() << 16) | (p.g.toInt() << 8) | p.b.toInt();
}

void main() {
  test('off-thread encode crosses the isolate boundary', () async {
    final gif = await encodeOracleSweepGifOffThread(
      leftRgba: _flat(40, 12, 0xffffff),
      rightRgba: _flat(40, 12, 0x0000ff),
      width: 40,
      height: 12,
    );
    final decoded = img.decodeGif(gif)!;
    expect(decoded.numFrames, 2 * 24 - 2);
  });

  test('sweep GIF frames composite left/bar/right exactly', () {
    const w = 40, h = 10, positions = 5;
    final gif = encodeOracleSweepGif(
      leftRgba: _flat(w, h, 0xff0000),
      rightRgba: _flat(w, h, 0x0000ff),
      width: w,
      height: h,
      style: const OracleSweepGifStyle(positions: positions),
    );
    final decoded = img.decodeGif(gif)!;
    expect(decoded.frames.length, 2 * positions - 2);
    expect((decoded.width, decoded.height), (w, h));
    expect(decoded.loopCount, 0, reason: 'infinite loop');
    for (final (f, stop) in [
      (0, 0.0),
      (1, 0.25),
      (decoded.frames.length - 1, 0.25),
      (positions - 1, 1.0),
    ]) {
      final frame = decoded.frames[f];
      final barLeft = ((w - 3) * stop).round();
      for (var x = 0; x < w; x++) {
        final want = x < barLeft
            ? 0xff0000
            : x < barLeft + 3
            ? kOracleSweepBarRgb
            : 0x0000ff;
        expect(_pixel(frame, x, h ~/ 2), want, reason: 'frame $f column $x');
      }
    }
  });

  test(
    'a size or animation the frames cannot honour throws, in release too',
    () {
      for (final (what, call) in [
        (
          'short buffer',
          () => encodeOracleSweepGif(
            leftRgba: _flat(4, 4, 0),
            rightRgba: _flat(4, 5, 0),
            width: 4,
            height: 5,
          ),
        ),
        (
          'zero size',
          () => encodeOracleSweepGif(
            leftRgba: _flat(0, 0, 0),
            rightRgba: _flat(0, 0, 0),
            width: 0,
            height: 0,
          ),
        ),
        (
          'one stop',
          () => encodeOracleSweepGif(
            leftRgba: _flat(4, 4, 0),
            rightRgba: _flat(4, 4, 0),
            width: 4,
            height: 4,
            style: const OracleSweepGifStyle(positions: 1),
          ),
        ),
        (
          'bar wider than the frame',
          () => encodeOracleSweepGif(
            leftRgba: _flat(4, 4, 0),
            rightRgba: _flat(4, 4, 0),
            width: 4,
            height: 4,
            style: const OracleSweepGifStyle(barWidth: 5),
          ),
        ),
      ]) {
        expect(call, throwsA(isA<ArgumentError>()), reason: what);
      }
    },
  );

  test('box downscale clamps a factor beyond the source to a 1 px floor', () {
    for (final (factor, want) in const [
      (2, (2, 1)),
      (9, (2, 1)),
      (0, (4, 2)),
    ]) {
      final out = boxDownscaleRgba(_flat(4, 2, 0x808080), 4, 2, factor);
      expect((out.width, out.height), want, reason: 'factor $factor');
      expect(out.rgba.sublist(0, 3), orderedEquals([0x80, 0x80, 0x80]));
    }
  });

  testWidgets('corpus pair exports a faithful sweep GIF within budget', (
    tester,
  ) async {
    await loadRealTextFont();
    await tester.runAsync(() async {
      final bytes = snippetPng('crc8.png').readAsBytesSync();
      final bd = bestBlockDiagram(buildViModel(extractSnippetVi(bytes)!))!;
      final raster = (await rasteriseBlockDiagram(
        bd,
        primIcons: await loadPrimIcons(),
        scale: 1.0,
        margin: 2,
      ))!;
      final reference = await decodeReferenceImage(bytes);
      final result = await compareToReference(
        raster.image,
        reference.image,
        lockScale: 1.0 / raster.scale,
        anchorRects: bdStructureAnchorRects(bd, raster),
      );
      final w = reference.image.width, h = reference.image.height;
      final fitted = (await result.fitted.toByteData())!.buffer.asUint8List();
      final gif = encodeOracleSweepGif(
        leftRgba: fitted,
        rightRgba: result.referenceRgba,
        width: w,
        height: h,
      );
      expect(
        gif.length,
        lessThan(2 << 20),
        reason: 'a typical snippet sweep stays under 2 MB',
      );
      final decoded = img.decodeGif(gif)!;
      expect(decoded.frames.length, 46);
      expect((decoded.width, decoded.height), (w, h));
      final frame = decoded.frames[0];
      var off = 0;
      for (var y = 0; y < h; y++) {
        for (var x = 3; x < w; x++) {
          final i = (y * w + x) * 4;
          final ref =
              (result.referenceRgba[i] << 16) |
              (result.referenceRgba[i + 1] << 8) |
              result.referenceRgba[i + 2];
          if (_pixel(frame, x, y) != ref) off++;
        }
      }
      expect(
        off,
        lessThan(w * h * 0.001),
        reason: 'palette must not posterize',
      );
      raster.image.dispose();
      reference.image.dispose();
      result.fitted.dispose();
      result.diffImage.dispose();
    });
  });
}
