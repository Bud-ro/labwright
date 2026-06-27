import 'dart:typed_data';

import 'package:labwright_vi_parse/labwright_vi_parse.dart';
import 'package:test/test.dart';

/// Builds a minimal section carrying a 2×2 RGB icon in the validated header form.
Uint8List _iconSection(List<int> pixels) {
  final b = Uint8List(40 + pixels.length);
  // u32@0 flags = 0 (already); width@4=2, height@6=2, depth@8=24
  b[5] = 2;
  b[7] = 2;
  b[9] = 24;
  // doubled rect @30 width=2, @32 height=2
  b[31] = 2;
  b[33] = 2;
  // pixels are the trailing w*h*3 bytes
  b.setRange(b.length - pixels.length, b.length, pixels);
  return b;
}

void main() {
  const px = [255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 0]; // R G B Y

  test('extractRgbIcon decodes a well-formed 2×2 RGB bitmap', () {
    final icon = extractRgbIcon(_iconSection(px))!;
    expect(icon.width, 2);
    expect(icon.height, 2);
    expect(icon.rgb, px);
  });

  test('rejects non-icon sections', () {
    // wrong depth
    final wrongDepth = _iconSection(px)..[9] = 8;
    expect(extractRgbIcon(wrongDepth), isNull);
    // doubled-rect mismatch
    final badRect = _iconSection(px)..[31] = 9;
    expect(extractRgbIcon(badRect), isNull);
    // non-zero flags
    final badFlags = _iconSection(px)..[0] = 1;
    expect(extractRgbIcon(badFlags), isNull);
    // too short
    expect(extractRgbIcon(Uint8List(10)), isNull);
    // arbitrary bytes
    expect(extractRgbIcon(Uint8List.fromList(List.filled(60, 0x41))), isNull);
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
