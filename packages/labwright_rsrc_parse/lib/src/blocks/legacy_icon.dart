import 'dart:typed_data';

class ViLegacyIcon {
  const ViLegacyIcon({required this.bpp, required this.pixels});

  static const int width = 32;
  static const int height = 32;

  final int bpp;

  final List<int> pixels;

  int get byteLength => width * height * bpp ~/ 8;

  Uint8List serialize() {
    final out = Uint8List(byteLength);
    switch (bpp) {
      case 8:
        out.setAll(0, pixels);
      case 4:
        for (var j = 0; j < out.length; j++) {
          out[j] = ((pixels[2 * j] & 0xf) << 4) | (pixels[2 * j + 1] & 0xf);
        }
      case 1:
        for (var j = 0; j < out.length; j++) {
          var packed = 0;
          for (var k = 0; k < 8; k++) {
            packed |= (pixels[8 * j + k] & 1) << (7 - k);
          }
          out[j] = packed;
        }
    }
    return out;
  }
}

int? legacyIconBpp(String tag) => switch (tag) {
  'icl8' => 8,
  'icl4' => 4,
  'ICON' => 1,
  _ => null,
};

ViLegacyIcon? decodeLegacyIcon(Uint8List body, int bpp) {
  const pixelCount = ViLegacyIcon.width * ViLegacyIcon.height;
  final expectBytes = pixelCount * bpp ~/ 8;
  if (body.length != expectBytes) return null;
  final pixels = List<int>.filled(pixelCount, 0);
  switch (bpp) {
    case 8:
      pixels.setAll(0, body);
    case 4:
      for (var j = 0; j < expectBytes; j++) {
        pixels[2 * j] = body[j] >> 4;
        pixels[2 * j + 1] = body[j] & 0x0f;
      }
    case 1:
      for (var j = 0; j < expectBytes; j++) {
        for (var k = 0; k < 8; k++) {
          pixels[8 * j + k] = (body[j] >> (7 - k)) & 1;
        }
      }
    default:
      return null;
  }
  return ViLegacyIcon(bpp: bpp, pixels: pixels);
}
