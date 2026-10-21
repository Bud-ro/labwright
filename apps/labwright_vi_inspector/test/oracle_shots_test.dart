@Tags(['corpus'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_inspector/src/bd_oracle.dart';
import 'package:labwright_vi_inspector/src/diagram_view.dart';

import 'util.dart';

/// Export is opt-in (it writes files outside the build tree):
/// `flutter test test/oracle_shots_test.dart --dart-define=SHOT_DIR=<dir>`
void main() {
  const shotDir = String.fromEnvironment('SHOT_DIR');
  const shots = String.fromEnvironment('SHOTS', defaultValue: 'crc8.png');
  testWidgets('SHOT_DIR=<dir> exports <snippet>_{ours,labview}.png pairs', (
    tester,
  ) async {
    if (shotDir.isEmpty) {
      markTestSkipped('pass --dart-define=SHOT_DIR=<dir> to export');
      return;
    }
    final pngs = snippetCorpusPngs();
    await loadRealTextFont();
    final wanted = [
      for (final name in shots.split(','))
        if (name.trim().isNotEmpty)
          name.trim().endsWith('.png') ? name.trim() : '${name.trim()}.png',
    ];
    await tester.runAsync(() async {
      final outDir = Directory(shotDir)..createSync(recursive: true);
      final icons = loadPrimIcons();
      var exported = 0;
      for (final name in wanted) {
        final file = pngs.firstWhere(
          (f) => f.path.endsWith('/$name'),
          orElse: () => fail('no snippet named $name in the corpus'),
        );
        final bytes = file.readAsBytesSync();
        final bd = bestBlockDiagram(buildViModel(extractSnippetVi(bytes)!))!;
        final scene = BdScene(bd)..recordPaintedText = true;
        final drawable = scene.drawable;
        Future<BdRaster> render(BdRenderStyle style) async =>
            (await rasteriseBlockDiagram(
              bd,
              primIcons: icons,
              scale: 1.0,
              margin: 2,
              scene: scene,
              style: style,
            ))!;
        var raster = await render(const BdRenderStyle());
        final reference = await decodeReferenceImage(bytes);
        var result = await compareToReference(
          raster.image,
          reference.image,
          lockScale: 1.0 / raster.scale,
          anchorRects: bdStructureAnchorRects(bd, raster, drawable: drawable),
        );
        final style = deriveSnippetStyle(
          diagram: bd,
          scene: scene,
          raster: raster,
          registration: result.registration,
          referenceRgba: result.referenceRgba,
          width: reference.image.width,
          height: reference.image.height,
        );
        if (snippetStyleRephases(style)) {
          raster = await render(style);
          result = await compareToReference(
            raster.image,
            reference.image,
            lockScale: 1.0 / raster.scale,
            knownRegistration: result.registration,
            knownReferenceEdges: result.referenceEdges,
          );
        }
        final base = name.substring(0, name.length - '.png'.length);
        final ours = await upscaleNearest(result.fitted, 2);
        final labview = await upscaleNearest(reference.image, 2);
        File(
          '${outDir.path}/${base}_ours.png',
        ).writeAsBytesSync(await imageToPng(ours));
        File(
          '${outDir.path}/${base}_labview.png',
        ).writeAsBytesSync(await imageToPng(labview));
        exported++;
        // ignore: avoid_print
        print('exported ${outDir.path}/${base}_{ours,labview}.png');
      }
      expect(exported, wanted.length);
    });
  });
}
