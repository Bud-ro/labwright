import 'dart:convert';
import 'dart:typed_data';

String? decodeStringBlock(Uint8List bytes) {
  if (bytes.length < 4) return null;
  final len = ByteData.sublistView(bytes).getUint32(0);
  final end = (4 + len).clamp(4, bytes.length);
  return utf8.decode(bytes.sublist(4, end), allowMalformed: true);
}

class ViStringBlock {
  const ViStringBlock({required this.declaredLength, required this.body});

  final int declaredLength;

  final Uint8List body;

  Uint8List serialize() {
    final out = Uint8List(4 + body.length);
    ByteData.sublistView(out).setUint32(0, declaredLength);
    out.setRange(4, 4 + body.length, body);
    return out;
  }
}

ViStringBlock? decodeStringBlockRaw(Uint8List bytes) {
  if (bytes.length < 4) return null;
  final declaredLength = ByteData.sublistView(bytes).getUint32(0);
  return ViStringBlock(declaredLength: declaredLength, body: Uint8List.sublistView(bytes, 4));
}
