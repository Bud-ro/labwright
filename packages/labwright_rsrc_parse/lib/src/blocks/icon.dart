import 'dart:typed_data';

import '../decode.dart';

class ViIcon {
  const ViIcon({required this.width, required this.height, required this.rgb});

  final int width;

  final int height;

  final Uint8List rgb;
}

const int _maxIconEdge = 512;

ViIcon? extractRgbIcon(Uint8List bytes) {
  if (bytes.length < 36) return null;
  final view = ByteData.sublistView(bytes);
  if (view.getUint32(0) != 0) return null;
  final width = view.getUint16(4), height = view.getUint16(6), depth = view.getUint16(8);
  if (depth != 24 || width < 1 || height < 1 || width > _maxIconEdge || height > _maxIconEdge) {
    return null;
  }
  if (view.getUint16(30) != width || view.getUint16(32) != height) return null;
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
