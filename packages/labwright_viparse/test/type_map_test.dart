import 'dart:typed_data';

import 'package:labwright_viparse/labwright_viparse.dart';
import 'package:test/test.dart';

void main() {
  group('decodeTypeMap', () {
    test('parses the short form [count][field1][count u16 entries]', () {
      // count=4, field1=2, entries 0x1000 0x1001 0x2000 0x1000 -> len 12
      final b = Uint8List.fromList([
        0x00, 0x04, 0x00, 0x02, //
        0x10, 0x00, 0x10, 0x01, 0x20, 0x00, 0x10, 0x00,
      ]);
      final m = decodeTypeMap(b)!;
      expect(m.isShortForm, isTrue);
      expect(m.count, 4);
      expect(m.field1, 2);
      expect(m.entries, [0x1000, 0x1001, 0x2000, 0x1000]);
      expect(m.rawLength, 12);
    });

    test('a buffer whose length != 4 + 2*count is flagged as the large form', () {
      // count says 50 but buffer is short -> not short form, entries empty.
      final b = Uint8List.fromList([0x00, 0x32, 0x00, 0x60, 1, 2, 3, 4]);
      final m = decodeTypeMap(b)!;
      expect(m.isShortForm, isFalse);
      expect(m.entries, isEmpty);
      expect(m.rawLength, 8);
    });

    test('too short for the header yields null', () {
      expect(decodeTypeMap(Uint8List.fromList([0, 1])), isNull);
    });

    test('the TM80 catalog entry is the type-info category', () {
      expect(blockInfo('TM80').category, ViBlockCategory.typeInfo);
      expect(isRecordHeapTag('TM80'), isFalse);
    });
  });
}
