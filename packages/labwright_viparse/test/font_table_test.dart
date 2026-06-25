import 'dart:typed_data';

import 'package:labwright_viparse/labwright_viparse.dart';
import 'package:test/test.dart';

void main() {
  group('decodeFontTable', () {
    test('reads version, count, and the packed font-name strings', () {
      // header: ver=1, w@2=2, w@4=3, count=2, nameOffset=16; then 4 filler bytes;
      // names at 16: [8]"Segoe UI" [6]"Tahoma".
      final b = BytesBuilder();
      void u16(int v) => b.add([(v >> 8) & 0xff, v & 0xff]);
      void u32(int v) => b.add([(v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff]);
      u16(1); // version @0
      u16(2); // @2
      u16(3); // @4
      u16(2); // count @6
      u32(16); // name offset @8
      b.add([0, 0, 0, 0]); // @12 filler (font metrics region)
      b.add([8, ...'Segoe UI'.codeUnits]); // @16
      b.add([6, ...'Tahoma'.codeUnits]);
      final t = decodeFontTable(Uint8List.fromList(b.toBytes()))!;
      expect(t.version, 1);
      expect(t.fontCount, 2);
      expect(t.nameTableOffset, 16);
      expect(t.names, ['Segoe UI', 'Tahoma']);
    });

    test('too short for the header yields null', () {
      expect(decodeFontTable(Uint8List(8)), isNull);
    });

    test('a bogus name offset does not throw, just yields fewer names', () {
      final b = Uint8List(12);
      ByteData.sublistView(b)
        ..setUint16(0, 1)
        ..setUint16(6, 3)
        ..setUint32(8, 9999); // out of range
      final t = decodeFontTable(b)!;
      expect(t.names, isEmpty);
    });

    test('the FTAB catalog entry is a confirmed name table', () {
      expect(blockInfo('FTAB').category, ViBlockCategory.nameTable);
      expect(blockInfo('FTAB').confidence, BlockConfidence.confirmed);
    });
  });
}
