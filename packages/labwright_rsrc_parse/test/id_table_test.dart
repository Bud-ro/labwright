import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

Uint8List _idtab(List<int> entries) {
  final b = Uint8List(4 + 4 * entries.length);
  final bd = ByteData.sublistView(b);
  bd.setUint32(0, entries.length);
  for (var i = 0; i < entries.length; i++) {
    bd.setUint32(4 + 4 * i, entries[i]);
  }
  return b;
}

void main() {
  group('decodeIdTable', () {
    test('reads [u32 count][count u32 ids]', () {
      final t = decodeIdTable(_idtab([0x1234, 0, 0x7]))!;
      expect(t.count, 3);
      expect(t.entries, [0x1234, 0, 0x7]);
      expect(t.rawLength, 16);
    });

    test('a corrupt over-large count reads only what is present (no over-read)', () {
      final b = Uint8List(12);
      ByteData.sublistView(b).setUint32(0, 9999);
      final t = decodeIdTable(b)!;
      expect(t.count, 9999);
      expect(t.entries.length, 2, reason: 'min(count, available): 2 u32 present');
    });

    test('too short for the count word yields null', () {
      expect(decodeIdTable(Uint8List.fromList([0, 1])), isNull);
    });

    test('empty table (count 0) is valid', () {
      final t = decodeIdTable(_idtab([]))!;
      expect(t.count, 0);
      expect(t.entries, isEmpty);
    });

    test('catalog: NUID/SUID/BNID are confirmed id tables', () {
      for (final tag in ['NUID', 'SUID', 'BNID']) {
        expect(blockInfo(tag).category, ViBlockCategory.identifier, reason: tag);
        expect(blockInfo(tag).confidence, BlockConfidence.confirmed, reason: tag);
      }
    });
  });
}
