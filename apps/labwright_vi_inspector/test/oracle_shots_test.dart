import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_inspector/src/bd_oracle.dart';
import 'package:labwright_vi_inspector/src/diagram_view.dart';

import 'bd_snippet_oracle_test.dart' show snippetCorpusPngs;
import 'util.dart';

/// Exports side-by-side screenshot pairs of the oracle comparison for
/// eyeballing: per snippet, `<name>_ours.png` (the registered render fitted
/// into the reference frame) and `<name>_labview.png` (the reference), both
/// 2x nearest-upscaled so single pixels survive image viewers.
///
/// Export is opt-in (it writes files outside the build tree):
/// `flutter test test/oracle_shots_test.dart --dart-define=SHOT_DIR=<dir>`
/// with an optional `--dart-define=SHOTS=crc8.png,crc16.png` naming the
/// snippets (default `crc8.png`; the `.png` suffix may be omitted).
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
    if (pngs.isEmpty) {
      markTestSkipped('corpus not fetched');
      return;
    }
    await loadRealTextFont();
    final wanted = [
      for (final name in shots.split(','))
        if (name.trim().isNotEmpty)
          name.trim().endsWith('.png') ? name.trim() : '${name.trim()}.png',
    ];
    await tester.runAsync(() async {
      final outDir = Directory(shotDir)..createSync(recursive: true);
      final icons = await loadPrimIcons();
      var exported = 0;
      for (final name in wanted) {
        final file = pngs.firstWhere(
          (f) => f.path.endsWith('/$name'),
          orElse: () => fail('no snippet named $name in the corpus'),
        );
        final bytes = file.readAsBytesSync();
        final bd = bestBlockDiagram(buildViModel(extractSnippetVi(bytes)!))!;
        final drawable = bdDrawableObjects(bd);
        final wires = bdVisibleWires(bd);
        final raster = (await rasteriseBlockDiagram(
          bd,
          primIcons: icons,
          scale: 1.0,
          margin: 2,
          wires: wires,
          drawable: drawable,
        ))!;
        final reference = await decodeReferenceImage(bytes);
        final result = await compareToReference(
          raster.image,
          reference.image,
          lockScale: 1.0 / raster.scale,
          anchorRects: bdStructureAnchorRects(bd, raster, drawable: drawable),
        );
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
