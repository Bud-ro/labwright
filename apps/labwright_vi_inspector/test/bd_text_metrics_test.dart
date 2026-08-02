import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_inspector/src/bd_oracle.dart';
import 'package:labwright_vi_inspector/src/diagram_view.dart';

import 'util.dart';

/// Text-metric pins through the FULL painter: known labels' laid-out rects
/// ([BdScene.paintedText]) on three snippet VIs, in canvas coordinates.
/// The widths/heights were measured against the references' own text ink
/// after the Selawik calibration (see [kBdTextSize]); a font swap, size
/// drift, or placement regression moves them and fails here. Tolerance
/// ±0.75 px absorbs engine-level layout jitter without letting a size
/// step (≥1 px on these run lengths) through.
void main() {
  const cases = <String, List<(String, double, double, double, double)>>{
    // (text, left, top, width, height)
    'Excel_Read_XLSX.png': [
      ('Path in (xlsx,tsv,txt,csv,xml)', 3.0, 3.0, 140.3, 15.0),
      ('Worksheets', 1821.0, 227.0, 62.0, 15.0),
      ('Excel Workbook (*.xlsx)', 373.0, 96.0, 122.2, 15.0),
      (' Default ', 655.0, 333.0, 44.9, 15.0),
      ('lvtemporary_%d', 386.0, 430.0, 85.5, 15.0),
      // Right-aligned value text on the 6 px digit pitch (the numeric-
      // display law + [kBdDigitRunSpacing]): the layout box ends 4 px
      // inside the value window; reference digit ink matches exactly
      // (dLeft/dRight 0) where the centred anchor sat 1 px right.
      ('1000000', 391.9, 490.0, 42.1, 15.0),
    ],
    'MD5.png': [
      ('D76AA478', 1422.0, 790.0, 56.2, 15.0),
      ('Message String', 137.0, 284.0, 81.3, 15.0),
      // Bold (tag-0x25 style run): the reference inks this heading 79 px
      // wide with the regular face's 9 px caps; Selawik Bold at 12 em lays
      // out 81.9 (ink within 2 px), where the regular face ran 6 px short.
      ('Calculate MD5', 985.0, 213.0, 81.9, 15.0),
      (' 0, Default ', 1788.0, 386.0, 57.2, 15.0),
    ],
    'crc8.png': [
      ('Reflect Output?', 844.0, 88.0, 82.5, 15.0),
      (' True ', 870.0, 105.0, 30.1, 15.0),
      // Right-aligned value text (see the '1000000' note): reference ink
      // matches exactly at this anchor (dLeft/dRight 0).
      ('256', 114.0, 230.0, 18.0, 15.0),
      ('Create CRC-8 LUT', 170.0, 237.0, 94.4, 15.0),
      (
        'Uses Look Up Tables (LUTs)\n'
            'for better performance on\n'
            'large data sets.',
        638.0,
        90.0,
        145.1,
        45.0,
      ),
    ],
  };
  for (final entry in cases.entries) {
    testWidgets('${entry.key} painted text metrics', (tester) async {
      final dir = repoDir(
        'packages/labwright_rsrc_parse/corpus/vi/rcpacini_VI-Snippets',
      );
      if (dir == null) {
        markTestSkipped('corpus not fetched');
        return;
      }
      final f = dir
          .listSync(recursive: true)
          .whereType<File>()
          .firstWhere((x) => x.path.endsWith('/${entry.key}'));
      final viBytes = extractSnippetVi(f.readAsBytesSync())!;
      final bd = bestBlockDiagram(buildViModel(viBytes))!;
      final scene = BdScene(bd);
      await loadRealTextFont();
      await tester.runAsync(() async {
        final raster = (await rasteriseBlockDiagram(
          bd,
          primIcons: await loadPrimIcons(),
          xnodeFacades: await loadXnodeFacades(viBytes, bd),
          scale: 1.0,
          margin: 2,
          scene: scene,
        ))!;
        raster.image.dispose();
      });
      for (final (text, left, top, width, height) in entry.value) {
        final run = scene.paintedText
            .where((r) => r.text == text)
            .reduce(
              (a, b) =>
                  (a.rect.left - left).abs() + (a.rect.top - top).abs() <
                      (b.rect.left - left).abs() + (b.rect.top - top).abs()
                  ? a
                  : b,
            );
        final rect = run.rect;
        final label = '${entry.key} "${text.split('\n').first}"';
        expect(rect.left, closeTo(left, 0.75), reason: '$label left');
        expect(rect.top, closeTo(top, 0.75), reason: '$label top');
        expect(rect.width, closeTo(width, 0.75), reason: '$label width');
        expect(rect.height, closeTo(height, 0.75), reason: '$label height');
      }
    });
  }
}
