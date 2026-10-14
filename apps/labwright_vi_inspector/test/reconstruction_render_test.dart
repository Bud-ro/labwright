@Tags(['corpus'])
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_inspector/src/bd_oracle.dart';

import '../../../packages/labwright_rsrc_parse/test/reconstruction/registry.dart';
import 'util.dart';

Future<ui.Image> _render(ViModel model) async => (await rasteriseBlockDiagram(
  bestBlockDiagram(model)!,
  scale: 1.0,
  margin: 2,
))!.image;

Future<Uint8List> _rgba(ui.Image image) async =>
    (await image.toByteData())!.buffer.asUint8List();

void main() {
  for (final MapEntry(key: png, value: build) in reconstructions.entries) {
    testWidgets(
      '$png rebuilt from the API draws the same after a file round trip',
      (tester) async {
        await loadRealTextFont();
        await tester.runAsync(() async {
          final built = build();
          final direct = await _render(built);
          final reread = await _render(buildViModel(built.serialize()));
          final out = Directory(
            '${Platform.environment['TMPDIR'] ?? '/tmp'}/reconstruction-render',
          )..createSync(recursive: true);
          File(
            '${out.path}/${png.replaceAll('.png', '')}.png',
          ).writeAsBytesSync(await imageToPng(direct));
          expect((reread.width, reread.height), (direct.width, direct.height));
          final comparison = compareRgba(
            await _rgba(direct),
            await _rgba(reread),
            direct.width,
            direct.height,
            threshold: 0,
          );
          expect(comparison.diffFraction, 0);
        });
      },
    );
  }
}
