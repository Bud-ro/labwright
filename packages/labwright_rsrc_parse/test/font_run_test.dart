import 'dart:io';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';
import 'test_util.dart';

/// Font-run resolution pins on snippet references: a heap text run's u8 is a
/// FONT ID into the VI's `FTAB` at entry `fontId + 3`
/// ([ViFontTable.entryForRunFontId]) — byte-identical run records render
/// bold in one VI and regular in another, resolved solely by that VI's
/// table. Each row pins one reference-verified label: (snippet, oid,
/// fontId, bold, resolvedSize, family-or-null-for-predefined).
void main() {
  const cases = <(String, int, int, bool, int, String?)>[
    // MD5's four bold headings all carry fontId 1 → a weight-1000 entry.
    ('MD5.png', 401, 1, true, 15, null),
    // fg's identical fontId-1 runs resolve to an inherit-app-font entry:
    // its reference shows every label REGULAR.
    ('fg.png', 170, 1, false, 15, null),
    ('fg.png', 85, 1, false, 15, null),
    // crc32_lookup_table: fontId 1 regular, fontId 2 the 21 px bold heading.
    ('crc32_lookup_table.png', 269, 1, false, 15, null),
    ('crc32_lookup_table.png', 296, 2, true, 21, null),
    // VI Tree: fontId 2 lands on an inherit entry — regular.
    ('VI Tree.png', 68, 2, false, 15, null),
    // Read VI Blocks: fontId 1 the 20 px bold numbering, fontId 3 the
    // monospace table face.
    ('Read VI Blocks.png', 3483, 1, true, 20, null),
    ('Read VI Blocks.png', 2729, 3, false, 15, 'Courier New'),
  ];
  test('heap font runs resolve against the FTAB (fontId + 3 law)', () {
    if (!corpusOrSkip(corpusViDir)) return;
    final byName = <String, File>{};
    for (final f in corpusViDir.listSync(recursive: true).whereType<File>()) {
      if (f.path.endsWith('.png')) byName[f.path.split('/').last] = f;
    }
    for (final (name, oid, fontId, bold, sizePx, family) in cases) {
      final file = byName[name]!;
      final model = buildViModel(extractSnippetVi(file.readAsBytesSync())!);
      final table = model.fontTable!;
      expect(table.nameTableComplete, isTrue, reason: '$name FTAB complete');
      // Every corpus table opens with the three materialized predefined
      // slots the run ids index past.
      expect(table.entries.length, greaterThanOrEqualTo(4), reason: name);
      final object = model.blockDiagrams.expand((diagram) => diagram.objects).firstWhere((o) => o.oid == oid);
      expect(object.textStyleRuns.first.fontId, fontId, reason: '$name $oid');
      final entry = object.labelFont!;
      expect(identical(entry, table.entryForRunFontId(fontId)), isTrue);
      expect(entry.isBold, bold, reason: '$name $oid bold');
      expect(entry.resolvedSize, sizePx, reason: '$name $oid size');
      expect(entry.isPredefinedRef ? null : entry.name, family, reason: '$name $oid family');
    }
  });
}
