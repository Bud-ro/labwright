import 'dart:typed_data';

import 'package:labwright_vi_parse/labwright_vi_parse.dart';
import 'package:test/test.dart';

void main() {
  group('decodeVersionWord', () {
    test('decodes [BCD major][minor<<4|patch][stage][build]', () {
      // 08 50 80 02 -> 8.5 (minor=5 from the HIGH nibble, not BCD 50), build 2
      final v = decodeVersionWord(Uint8List.fromList([0x08, 0x50, 0x80, 0x02]))!;
      expect(v.major, 8);
      expect(v.minor, 5);
      expect(v.patch, 0);
      expect(v.stage, 0x80);
      expect(v.build, 2);
      expect(v.version, '8.5');
    });

    test('BCD major spans 2-digit versions; patch shows when non-zero', () {
      expect(decodeVersionWord(Uint8List.fromList([0x20, 0x00, 0x80, 0x00]))!.version, '20.0');
      expect(decodeVersionWord(Uint8List.fromList([0x10, 0x00, 0x80, 0x00]))!.major, 10);
      // minor 1, patch 3 -> "21.1.3"
      final v = decodeVersionWord(Uint8List.fromList([0x21, 0x13, 0x80, 0x05]))!;
      expect(v.version, '21.1.3');
    });

    test('too short yields null', () {
      expect(decodeVersionWord(Uint8List.fromList([1, 2, 3])), isNull);
    });

    test('LVSR reuses the same word decode (minor is the high nibble, not BCD)', () {
      // an LVSR whose byte1 is 0x50 must report minor 5, not 50.
      final b = Uint8List(160);
      b[0] = 0x08;
      b[1] = 0x50;
      b[2] = 0x80;
      final r = decodeSaveRecord(b)!;
      expect(r.versionMajor, 8);
      expect(r.versionMinor, 5); // regression guard: was BCD(0x50)=50
      expect(r.version, '8.5');
    });
  });
}
