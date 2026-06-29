import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

void main() {
  group('decodeDataTypeHeap', () {
    test('the dominant 4-byte form is a [u16 field0][u16 field1] header', () {
      final h = decodeDataTypeHeap(Uint8List.fromList([0x00, 0x17, 0x00, 0x04]))!;
      expect(h.field0, 0x17);
      expect(h.field1, 0x04);
      expect(h.isExtended, isFalse);
      expect(h.names, isEmpty);
      expect(h.rawLength, 4);
    });

    test('the extended form recovers 40xx-tagged item names', () {
      final b = Uint8List.fromList([
        0x00, 0x00, 0x00, 0x40,
        0x00, 0x0e,
        0x40, 0x21, 0x09,
        ...'Auto Stop'.codeUnits,
      ]);
      final h = decodeDataTypeHeap(b)!;
      expect(h.isExtended, isTrue);
      expect(h.names, contains('Auto Stop'));
    });

    test('too short for the header yields null', () {
      expect(decodeDataTypeHeap(Uint8List.fromList([0, 1, 2])), isNull);
    });

    test('the DTHP catalog entry is type-info', () {
      expect(blockInfo('DTHP').category, ViBlockCategory.typeInfo);
    });
  });
}
