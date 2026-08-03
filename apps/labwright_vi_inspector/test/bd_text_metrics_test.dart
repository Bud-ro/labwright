import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_inspector/src/bd_oracle.dart';
import 'package:labwright_vi_inspector/src/diagram_view.dart';

import 'util.dart';

/// Text-metric pins through the FULL painter: known labels' laid-out rects
/// ([BdScene.paintedText]) on three snippet VIs, in canvas coordinates.
/// The widths/heights were measured against the references' own text ink
/// on the whole-pixel glyph lattice ([BdTextRun]: integer per-glyph
/// advances — hinted 12 ppem where GDI's hdmx differs from rounding
/// ([bdHintedAdvance]) — and integer anchors, so every rect is a whole
/// number of px); a font swap, size drift, or placement regression moves
/// them and fails here. Tolerance ±0.75 px absorbs engine-level layout
/// jitter without letting a 1 px advance step through.
void main() {
  const cases = <String, List<(String, double, double, double, double)>>{
    // (text, left, top, width, height)
    'Excel_Read_XLSX.png': [
      // 146 = the hinted 12 ppem advances ([bdHintedAdvance]: `m` 11, not
      // the rounded-linear 10); the run's reference ink bbox matches
      // exactly at these advances (dL/dR/dT/dB all 0 on the ink probe).
      ('Path in (xlsx,tsv,txt,csv,xml)', 3.0, 3.0, 146.0, 15.0),
      ('Worksheets', 1821.0, 227.0, 61.0, 15.0),
      ('Excel Workbook (*.xlsx)', 373.0, 96.0, 124.0, 15.0),
      (' Default ', 655.0, 333.0, 44.0, 15.0),
      // 86 = hinted `m` 11 (see the `Path in…` note). 387 = the 2 px
      // label-text inset (the 0x021 word's 0x800000 bit): the reference
      // `l` stem inks at bounds.left+3 (canvas 388), one bearing px past
      // the pen — the 1 px inset sat one px left of the reference run.
      ('lvtemporary_%d', 387.0, 430.0, 86.0, 15.0),
      // Right-aligned value text on the 6 px digit pitch (the numeric-
      // display law + integer glyph advances): the layout box ends 4 px
      // inside the value window; reference digit ink matches exactly
      // (dLeft/dRight 0) where the centred anchor sat 1 px right.
      ('1000000', 392.0, 490.0, 42.0, 15.0),
    ],
    'MD5.png': [
      // Array-cell text on the centred line box (the cell anchor law):
      // cell ink bboxes match the reference at dT=0 where the old row
      // nudge sat 1 px up.
      ('D76AA478', 1422.0, 791.0, 54.0, 15.0),
      // 138 = the 2 px label-text inset (the 0x021 word's 0x800000 bit;
      // mode 0x804404): the registered reference run correlates at +1
      // from the old 1 px inset across the whole word.
      ('Message String', 138.0, 284.0, 80.0, 15.0),
      // Bold (FTAB-resolved font run): 80 = the bold face's hinted
      // 12 ppem advances (`e` 7, not the rounded-linear 6); the heading's
      // 79 px reference ink sits inside it exactly (ink probe dL/dR 0 —
      // the layout box ends one bearing px past the `5`'s ink).
      ('Calculate MD5', 985.0, 213.0, 80.0, 15.0),
      // Hard-clipped 4 px inside the 35 px selector-label bounds (the
      // reference shows exactly ` 0, De`, no ellipsis) — the rect records
      // the clipped extent.
      (' 0, Default ', 1788.0, 386.0, 30.0, 15.0),
    ],
    'crc8.png': [
      ('Reflect Output?', 844.0, 88.0, 82.0, 15.0),
      (' True ', 870.0, 105.0, 29.0, 15.0),
      // Right-aligned value text (see the '1000000' note): reference ink
      // matches exactly at this anchor (dLeft/dRight 0).
      ('256', 114.0, 230.0, 18.0, 15.0),
      // 94 = the hinted 12 ppem advances (`C` 8 ×3, not the rounded-linear
      // 7); reference ink bbox exact at these advances (see the
      // `Path in…` note).
      ('Create CRC-8 LUT', 170.0, 237.0, 94.0, 15.0),
      (
        'Uses Look Up Tables (LUTs)\n'
            'for better performance on\n'
            'large data sets.',
        638.0,
        90.0,
        143.0,
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
      addTearDown(scene.dispose);
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
