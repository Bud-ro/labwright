import 'dart:typed_data';

import '../decode.dart';

class ViIcon {
  const ViIcon({required this.width, required this.height, required this.rgb});

  final int width;

  final int height;

  final Uint8List rgb;
}

int _u16(Uint8List bytes, int at) => (bytes[at] << 8) | bytes[at + 1];

const int _maxIconEdge = 512;

ViIcon? extractRgbIcon(Uint8List bytes) {
  if (bytes.length < 36) return null;
  if (bytes[0] != 0 || bytes[1] != 0 || bytes[2] != 0 || bytes[3] != 0) {
    return null;
  }
  final width = _u16(bytes, 4), height = _u16(bytes, 6), depth = _u16(bytes, 8);
  if (depth != 24 || width < 1 || height < 1 || width > _maxIconEdge || height > _maxIconEdge) {
    return null;
  }
  if (_u16(bytes, 30) != width || _u16(bytes, 32) != height) return null;
  final need = width * height * 3;
  if (bytes.length - need < 30) return null;
  return ViIcon(width: width, height: height, rgb: bytes.sublist(bytes.length - need));
}

ViIcon? decodeViIcon(List<DecodedSection> sections) {
  for (final section in sections) {
    final icon = extractRgbIcon(section.bytes);
    if (icon != null) return icon;
  }
  return null;
}
