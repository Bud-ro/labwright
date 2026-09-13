import 'dart:typed_data';

class ViPictImage {
  const ViPictImage({
    required this.top,
    required this.left,
    required this.bottom,
    required this.right,
    required this.byteLength,
  });
  final int top, left, bottom, right;
  final int byteLength;
  int get width => right - left;
  int get height => bottom - top;
}

ViPictImage? decodePictEnvelope(Uint8List bytes) {
  if (bytes.length < 14) return null;
  final view = ByteData.sublistView(bytes);
  if (view.getUint16(10) != 0x0011 || view.getUint16(12) != 0x02ff) return null;
  return ViPictImage(
    top: view.getUint16(2),
    left: view.getUint16(4),
    bottom: view.getUint16(6),
    right: view.getUint16(8),
    byteLength: bytes.length,
  );
}

class ViEmfImage {
  const ViEmfImage({required this.boundsRight, required this.boundsBottom, required this.byteLength});
  final int boundsRight;
  final int boundsBottom;
  final int byteLength;
}

ViEmfImage? decodeEmfEnvelope(Uint8List bytes) {
  if (bytes.length < 48) return null;
  final view = ByteData.sublistView(bytes);
  if (view.getUint32(0, Endian.little) != 1) return null;
  if (String.fromCharCodes(bytes.sublist(40, 44)) != ' EMF') return null;
  return ViEmfImage(
    boundsRight: view.getUint32(16, Endian.little),
    boundsBottom: view.getUint32(20, Endian.little),
    byteLength: bytes.length,
  );
}
