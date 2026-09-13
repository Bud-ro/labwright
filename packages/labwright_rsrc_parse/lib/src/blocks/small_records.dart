import 'dart:typed_data';

String? decodeTitle(Uint8List bytes) {
  if (bytes.isEmpty) return null;
  final len = bytes[0];
  if (1 + len > bytes.length) return null;
  for (var i = 1; i <= len; i++) {
    if (bytes[i] < 0x20 || bytes[i] >= 0x7f) return null;
  }
  return String.fromCharCodes(bytes.sublist(1, 1 + len));
}

class ViTitleRaw {
  const ViTitleRaw({required this.text});
  final Uint8List text;

  Uint8List serialize() {
    final out = Uint8List(1 + text.length);
    out[0] = text.length;
    out.setRange(1, out.length, text);
    return out;
  }
}

ViTitleRaw? decodeTitleRaw(Uint8List bytes) {
  if (bytes.isEmpty || 1 + bytes[0] != bytes.length) return null;
  return ViTitleRaw(text: Uint8List.sublistView(bytes, 1));
}

const _trecHeaderLen = 72;

class ViTextRecord {
  const ViTextRecord({required this.header, required this.runs});

  final Uint8List header;

  final List<Uint8List> runs;

  int get length => header.length + runs.fold(0, (a, r) => a + 4 + r.length);

  List<String> get texts {
    final out = <String>[];
    for (final r in runs) {
      var printable = r.isNotEmpty;
      for (final b in r) {
        if ((b < 0x20 && b != 0x09 && b != 0x0a && b != 0x0d) || b >= 0x7f) {
          printable = false;
          break;
        }
      }
      if (printable) out.add(String.fromCharCodes(r));
    }
    return out;
  }

  Uint8List serialize() {
    final out = Uint8List(length);
    out.setRange(0, header.length, header);
    final d = ByteData.sublistView(out);
    var pos = header.length;
    for (final r in runs) {
      d.setUint32(pos, r.length);
      pos += 4;
      out.setRange(pos, pos + r.length, r);
      pos += r.length;
    }
    return out;
  }
}

ViTextRecord? decodeTextRecord(Uint8List bytes) {
  if (bytes.length < _trecHeaderLen) return null;
  final view = ByteData.sublistView(bytes);
  final runs = <Uint8List>[];
  var pos = _trecHeaderLen;
  while (pos < bytes.length) {
    if (pos + 4 > bytes.length) return null;
    final len = view.getUint32(pos);
    pos += 4;
    if (len > bytes.length - pos) return null;
    runs.add(Uint8List.sublistView(bytes, pos, pos + len));
    pos += len;
  }
  return ViTextRecord(header: Uint8List.sublistView(bytes, 0, _trecHeaderLen), runs: runs);
}

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
