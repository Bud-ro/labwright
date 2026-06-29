import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

void main() {
  group('decodeLegacyIcon', () {
    test('bpp lookup by tag', () {
      expect(legacyIconBpp('icl8'), 8);
      expect(legacyIconBpp('icl4'), 4);
      expect(legacyIconBpp('ICON'), 1);
      expect(legacyIconBpp('STRG'), isNull);
    });

    test('1-bpp ICON expands each byte to 8 mask pixels (MSB first)', () {
      final b = Uint8List(32 * 32 ~/ 8);
      b[0] = 0xA0;
      final icon = decodeLegacyIcon(b, 1)!;
      expect(icon.bpp, 1);
      expect(icon.pixels.length, 1024);
      expect(icon.pixels.sublist(0, 8), [1, 0, 1, 0, 0, 0, 0, 0]);
    });

    test('4-bpp icl4 splits each byte into two nibbles', () {
      final b = Uint8List(512);
      b[0] = 0x3C;
      final icon = decodeLegacyIcon(b, 4)!;
      expect(icon.pixels.length, 1024);
      expect(icon.pixels[0], 3);
      expect(icon.pixels[1], 12);
    });

    test('8-bpp icl8 is one index per byte', () {
      final b = Uint8List(1024);
      b[5] = 200;
      final icon = decodeLegacyIcon(b, 8)!;
      expect(icon.pixels.length, 1024);
      expect(icon.pixels[5], 200);
    });

    test('a wrong-size buffer is rejected (no partial bitmap guess)', () {
      expect(decodeLegacyIcon(Uint8List(100), 1), isNull, reason: '1-bpp ICON must be exactly 128 bytes');
      expect(decodeLegacyIcon(Uint8List(1024), 4), isNull, reason: '4-bpp icl4 must be exactly 512 bytes');
    });

    test('catalog: icl8/icl4/ICON are confirmed icon bitmaps', () {
      for (final t in ['icl8', 'icl4', 'ICON']) {
        expect(blockInfo(t).category, ViBlockCategory.icon);
        expect(blockInfo(t).confidence, BlockConfidence.confirmed);
      }
    });
  });
}
