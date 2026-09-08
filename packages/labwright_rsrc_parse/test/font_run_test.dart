@Tags(['corpus'])
library;

import 'dart:io';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

void main() {
  const cases = <(String, int, int, bool, int, String?)>[
    ('MD5.png', 401, 1, true, 15, null),
    ('fg.png', 170, 1, false, 15, null),
    ('fg.png', 85, 1, false, 15, null),
    ('crc32_lookup_table.png', 269, 1, false, 15, null),
    ('crc32_lookup_table.png', 296, 2, true, 21, null),
    ('VI Tree.png', 68, 2, false, 15, null),
    ('Read VI Blocks.png', 3483, 1, true, 20, null),
    ('Read VI Blocks.png', 2729, 3, false, 15, 'Courier New'),
  ];
  test('heap font runs resolve against the FTAB (fontId + 3 law)', () {
    final byName = <String, File>{};
    for (final f in corpusViDir.listSync(recursive: true).whereType<File>()) {
      if (f.path.endsWith('.png')) byName[f.path.split('/').last] = f;
    }
    for (final (name, oid, fontId, bold, sizePx, family) in cases) {
      final file = byName[name]!;
      final model = buildViModel(extractSnippetVi(file.readAsBytesSync())!);
      final table = model.fontTable!;
      expect(table.nameTableComplete, isTrue, reason: '$name FTAB complete');
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
