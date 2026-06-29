import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

/// Builds a minimal section carrying a 2×2 RGB icon in the validated header
/// form: u32 flags@0 = 0, width@4 = 2, height@6 = 2, depth@8 = 24, doubled
/// rect@30/@32 = 2×2, then the trailing w*h*3 RGB pixel bytes.
Uint8List _iconSection(List<int> pixels) {
  final b = Uint8List(40 + pixels.length);
  b[5] = 2;
  b[7] = 2;
  b[9] = 24;
  b[31] = 2;
  b[33] = 2;
  b.setRange(b.length - pixels.length, b.length, pixels);
  return b;
}

void main() {
  const px = [255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 0];

  test('extractRgbIcon decodes a well-formed 2×2 RGB bitmap', () {
    final icon = extractRgbIcon(_iconSection(px))!;
    expect(icon.width, 2);
    expect(icon.height, 2);
    expect(icon.rgb, px);
  });

  test('rejects non-icon sections', () {
    final wrongDepth = _iconSection(px)..[9] = 8;
    expect(extractRgbIcon(wrongDepth), isNull);
    final badRect = _iconSection(px)..[31] = 9;
    expect(extractRgbIcon(badRect), isNull);
    final badFlags = _iconSection(px)..[0] = 1;
    expect(extractRgbIcon(badFlags), isNull);
    expect(extractRgbIcon(Uint8List(10)), isNull, reason: 'too short');
    expect(extractRgbIcon(Uint8List.fromList(List.filled(60, 0x41))), isNull,
        reason: 'arbitrary bytes');
  });

  test('decodeViIcon finds the icon across sections regardless of tag', () {
    DecodedSection sec(String tag, Uint8List bytes) => DecodedSection(
          section: ViSection(tag: tag, index: 0, dataOffset: 0, bytes: bytes),
          bytes: bytes,
          wasCompressed: false,
        );
    final sections = [
      sec('LVSR', Uint8List.fromList(List.filled(20, 0))),
      sec('PICC', _iconSection(px)),
    ];
    final icon = decodeViIcon(sections)!;
    expect(icon.width, 2);
    expect(icon.rgb, px);
    expect(decodeViIcon([sec('LVSR', Uint8List(8))]), isNull);
  });
}
