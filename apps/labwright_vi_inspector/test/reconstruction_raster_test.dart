@Tags(['corpus'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_inspector/src/bd_oracle.dart';

import '../../../packages/labwright_rsrc_parse/test/reconstruction/for_loop_range_reconstruction.dart';
import '../../../packages/labwright_rsrc_parse/test/reconstruction/snippet_example_reconstruction.dart';
import '../../../packages/labwright_rsrc_parse/test/reconstruction/while_loop_infinite_reconstruction.dart';
import 'util.dart';

/// The reconstructions that draw as their snippet draws, by snippet file name.
final Map<String, ViModel Function()> layoutReconstructions = {
  'While_Loop_-_Infinite_Loop.png': buildWhileLoopInfinite,
  'snippet_example.png': buildSnippetExample,
  '30934016_6biOD.png': buildForLoopRange,
};

Future<ui.Image> _render(ViModel model) async => (await rasteriseBlockDiagram(
  bestBlockDiagram(model)!,
  scale: 1.0,
  margin: 2,
))!.image;

Future<Uint8List> _rgba(ui.Image image) async =>
    (await image.toByteData())!.buffer.asUint8List();

void main() {
  for (final MapEntry(key: png, value: build)
      in layoutReconstructions.entries) {
    testWidgets('$png rebuilt from the API draws the same pixels', (
      tester,
    ) async {
      await loadRealTextFont();
      await tester.runAsync(() async {
        final original = await _render(
          buildViModel(extractSnippetVi(snippetPng(png).readAsBytesSync())!),
        );
        final built = await _render(build());
        final out = Directory(
          '${Platform.environment['TMPDIR'] ?? '/tmp'}/reconstruction-raster',
        )..createSync(recursive: true);
        final stem = png.replaceAll('.png', '');
        File(
          '${out.path}/$stem-original.png',
        ).writeAsBytesSync(await imageToPng(original));
        File(
          '${out.path}/$stem-built.png',
        ).writeAsBytesSync(await imageToPng(built));
        expect(
          (built.width, built.height),
          (original.width, original.height),
          reason: 'raster size',
        );
        final a = await _rgba(original), b = await _rgba(built);
        final comparison = compareRgba(
          a,
          b,
          original.width,
          original.height,
          threshold: 0,
        );
        final diff = await decodeImageFromPixels(
          comparison.diff,
          original.width,
          original.height,
        );
        File(
          '${out.path}/$stem-diff.png',
        ).writeAsBytesSync(await imageToPng(diff));
        expect(
          comparison.diffFraction,
          0,
          reason: 'pixels differing out of ${a.length ~/ 4}',
        );
      });
    });
  }
}

Future<ui.Image> decodeImageFromPixels(
  Uint8List rgba,
  int width,
  int height,
) async {
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
