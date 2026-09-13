import 'dart:typed_data';

class ViPngImage {
  const ViPngImage({required this.width, required this.height, required this.byteLength});
  final int width;
  final int height;
  final int byteLength;
}

const _pngMagic = [0x89, 0x50, 0x4e, 0x47];

ViPngImage? decodePngEnvelope(Uint8List bytes, [int start = 0]) {
  if (start + 24 > bytes.length) return null;
  for (var i = 0; i < 4; i++) {
    if (bytes[start + i] != _pngMagic[i]) return null;
  }
  if (String.fromCharCodes(bytes.sublist(start + 12, start + 16)) != 'IHDR') return null;
  final view = ByteData.sublistView(bytes);
  return ViPngImage(
    width: view.getUint32(start + 16),
    height: view.getUint32(start + 20),
    byteLength: bytes.length - start,
  );
}

class ViDataSpaceImage {
  const ViDataSpaceImage({required this.headerWords, required this.pngOffset, required this.png});

  final List<int> headerWords;

  final int? pngOffset;

  final ViPngImage? png;
}

ViDataSpaceImage? decodeDataSpaceImage(Uint8List bytes) {
  if (bytes.length < 12) return null;
  final view = ByteData.sublistView(bytes);
  if (view.getUint32(0) != 0) return null;
  final headerWords = [for (var i = 0; i < 4; i++) view.getUint16(4 + 2 * i)];
  int? pngOffset;
  for (var pos = 0; pos + 4 <= bytes.length; pos++) {
    if (bytes[pos] == 0x89 && bytes[pos + 1] == 0x50 && bytes[pos + 2] == 0x4e && bytes[pos + 3] == 0x47) {
      pngOffset = pos;
      break;
    }
  }
  return ViDataSpaceImage(
    headerWords: headerWords,
    pngOffset: pngOffset,
    png: pngOffset == null ? null : decodePngEnvelope(bytes, pngOffset),
  );
}
