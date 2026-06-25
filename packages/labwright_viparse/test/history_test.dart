import 'dart:typed_data';

import 'package:labwright_viparse/labwright_viparse.dart';
import 'package:test/test.dart';

Uint8List _hist({int version = 2, int flags = 0x400, int count = 11}) {
  final b = Uint8List(40);
  final bd = ByteData.sublistView(b);
  bd.setUint32(0, version);
  bd.setUint32(4, flags);
  bd.setUint32(8, count);
  return b;
}

void main() {
  group('decodeHistory', () {
    test('decodes the 40-byte record into named fields', () {
      final h = decodeHistory(_hist())!;
      expect(h.formatVersion, 2);
      expect(h.flags, 0x400);
      expect(h.entryCount, 11);
      expect(h.reservedAreZero, isTrue);
      expect(h.words, hasLength(10));
      expect(h.rawLength, 40);
    });

    test('reservedAreZero is false when a reserved word is non-zero', () {
      final b = _hist();
      ByteData.sublistView(b).setUint32(12, 7); // @12 reserved -> non-zero
      expect(decodeHistory(b)!.reservedAreZero, isFalse);
    });

    test('a short buffer yields null', () {
      expect(decodeHistory(Uint8List(20)), isNull);
    });

    test('the HIST catalog entry is confirmed history', () {
      expect(blockInfo('HIST').category, ViBlockCategory.history);
      expect(blockInfo('HIST').confidence, BlockConfidence.confirmed);
    });
  });
}
