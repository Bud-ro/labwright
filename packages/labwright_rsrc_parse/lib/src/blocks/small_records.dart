import 'dart:typed_data';

String _hexOf(Uint8List bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List _bytesFromHex(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(2 * i, 2 * i + 2), radix: 16);
  }
  return out;
}

class ViPasswordRecord {
  const ViPasswordRecord({required this.passwordHash, required this.extraHashes});

  final String passwordHash;

  final List<String> extraHashes;

  /// MD5 of the empty string.
  bool get isUnprotected => passwordHash == 'd41d8cd98f00b204e9800998ecf8427e';

  Uint8List serialize() {
    final digests = [passwordHash, ...extraHashes];
    final out = Uint8List(digests.length * 16);
    for (var i = 0; i < digests.length; i++) {
      out.setRange(i * 16, i * 16 + 16, _bytesFromHex(digests[i]));
    }
    return out;
  }
}

ViPasswordRecord? decodePasswordRecord(Uint8List bytes) {
  if (bytes.length != 48 && bytes.length != 32) return null;
  return ViPasswordRecord(
    passwordHash: _hexOf(Uint8List.sublistView(bytes, 0, 16)),
    extraHashes: [
      for (var at = 16; at + 16 <= bytes.length; at += 16) _hexOf(Uint8List.sublistView(bytes, at, at + 16)),
    ],
  );
}

class ViSignature {
  const ViSignature({required this.hex});
  final String hex;

  Uint8List serialize() => _bytesFromHex(hex);
}

ViSignature? decodeRuntimeSignature(Uint8List bytes) => bytes.length == 16 ? ViSignature(hex: _hexOf(bytes)) : null;

class ViScsrRecord {
  const ViScsrRecord({required this.marker, required this.signature});
  final int marker;
  final ViSignature signature;

  Uint8List serialize() {
    final out = Uint8List(20);
    ByteData.sublistView(out).setUint32(0, marker);
    out.setRange(4, 20, signature.serialize());
    return out;
  }
}

ViScsrRecord? decodeScsrRecord(Uint8List bytes) {
  if (bytes.length != 20) return null;
  return ViScsrRecord(
    marker: ByteData.sublistView(bytes).getUint32(0),
    signature: ViSignature(hex: _hexOf(Uint8List.sublistView(bytes, 4))),
  );
}

class ViIconPlacement {
  const ViIconPlacement({required this.words});

  final List<int> words;

  Uint8List serialize() {
    final out = Uint8List(12);
    final d = ByteData.sublistView(out);
    for (var i = 0; i < 6; i++) {
      d.setUint16(2 * i, words[i]);
    }
    return out;
  }
}

ViIconPlacement? decodeIconPlacement(Uint8List bytes) {
  if (bytes.length != 12) return null;
  final view = ByteData.sublistView(bytes);
  return ViIconPlacement(words: [for (var i = 0; i < 6; i++) view.getUint16(2 * i)]);
}

class ViPrintRecord {
  const ViPrintRecord({required this.words});

  final List<int> words;

  int get length => words.length * 4;

  int get version => words.length > 1 ? (words[1] >> 24) & 0xff : 0;

  bool get isDefaultLayout {
    for (var i = 0; i < words.length; i++) {
      final w = i == 1 ? words[i] & 0x00ffffff : words[i];
      if (w != 0) return false;
    }
    return true;
  }

  Uint8List serialize() {
    final out = Uint8List(words.length * 4);
    final d = ByteData.sublistView(out);
    for (var i = 0; i < words.length; i++) {
      d.setUint32(i * 4, words[i]);
    }
    return out;
  }
}

ViPrintRecord? decodePrintRecord(Uint8List bytes) {
  if (bytes.isEmpty || bytes.length % 4 != 0) return null;
  final view = ByteData.sublistView(bytes);
  return ViPrintRecord(words: [for (var i = 0; i < bytes.length; i += 4) view.getUint32(i)]);
}

class ViSectionMarker {
  const ViSectionMarker({required this.value, required this.extraWord});
  final int value;
  final int? extraWord;

  Uint8List serialize() {
    final extra = extraWord;
    final out = Uint8List(extra == null ? 4 : 8);
    final d = ByteData.sublistView(out);
    d.setUint32(0, value);
    if (extra != null) d.setUint32(4, extra);
    return out;
  }
}

ViSectionMarker? decodeSectionMarker(Uint8List bytes) {
  if (bytes.length != 4 && bytes.length != 8) return null;
  final view = ByteData.sublistView(bytes);
  return ViSectionMarker(
    value: view.getUint32(0),
    extraWord: bytes.length == 8 ? view.getUint32(4) : null,
  );
}

class ViModifiedUid {
  const ViModifiedUid({required this.value});
  final int value;

  Uint8List serialize() {
    final out = Uint8List(4);
    ByteData.sublistView(out).setUint32(0, value);
    return out;
  }
}

ViModifiedUid? decodeModifiedUid(Uint8List bytes) =>
    bytes.length == 4 ? ViModifiedUid(value: ByteData.sublistView(bytes).getUint32(0)) : null;

class ViExtendedState {
  const ViExtendedState({required this.words});
  final List<int> words;

  Uint8List serialize() {
    final out = Uint8List(words.length * 4);
    final d = ByteData.sublistView(out);
    for (var i = 0; i < words.length; i++) {
      d.setUint32(i * 4, words[i]);
    }
    return out;
  }
}

ViExtendedState? decodeExtendedState(Uint8List bytes) {
  if (bytes.isEmpty || bytes.length % 4 != 0) return null;
  final view = ByteData.sublistView(bytes);
  return ViExtendedState(
    words: [for (var at = 0; at < bytes.length; at += 4) view.getUint32(at)],
  );
}

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

class ViConstantRecord {
  const ViConstantRecord({required this.length, required this.matchesCorpusConstant});
  final int length;
  final bool matchesCorpusConstant;

  Uint8List? serialize() => matchesCorpusConstant ? Uint8List(length) : null;
}

ViConstantRecord? decodeGcprRecord(Uint8List bytes) {
  if (bytes.length != 13) return null;
  return ViConstantRecord(
    length: 13,
    matchesCorpusConstant: bytes.every((b) => b == 0),
  );
}

ViConstantRecord? decodeVpdpRecord(Uint8List bytes) {
  if (bytes.length != 4) return null;
  return ViConstantRecord(
    length: 4,
    matchesCorpusConstant: bytes.every((b) => b == 0),
  );
}

class ViWordGrid {
  const ViWordGrid({required this.words});
  final List<int> words;

  Uint8List serialize() {
    final out = Uint8List(words.length * 4);
    final d = ByteData.sublistView(out);
    for (var i = 0; i < words.length; i++) {
      d.setUint32(i * 4, words[i]);
    }
    return out;
  }
}

ViWordGrid? decodeWordGrid(Uint8List bytes, {int? words}) {
  if (bytes.isEmpty || bytes.length % 4 != 0) return null;
  if (words != null && bytes.length != words * 4) return null;
  final view = ByteData.sublistView(bytes);
  return ViWordGrid(words: [for (var at = 0; at < bytes.length; at += 4) view.getUint32(at)]);
}

ViWordGrid? decodeDldrRecord(Uint8List bytes) => decodeWordGrid(bytes, words: 7);

class ViU16Record {
  const ViU16Record({required this.value});
  final int value;

  Uint8List serialize() {
    final out = Uint8List(2);
    ByteData.sublistView(out).setUint16(0, value);
    return out;
  }
}

ViU16Record? decodeCpd2Record(Uint8List bytes) =>
    bytes.length == 2 ? ViU16Record(value: ByteData.sublistView(bytes).getUint16(0)) : null;

class ViU16Grid {
  const ViU16Grid({required this.words});
  final List<int> words;

  Uint8List serialize() {
    final out = Uint8List(words.length * 2);
    final d = ByteData.sublistView(out);
    for (var i = 0; i < words.length; i++) {
      d.setUint16(i * 2, words[i]);
    }
    return out;
  }
}

ViU16Grid? decodeU16Grid(Uint8List bytes) {
  if (bytes.isEmpty || bytes.length % 2 != 0) return null;
  final view = ByteData.sublistView(bytes);
  return ViU16Grid(words: [for (var at = 0; at < bytes.length; at += 2) view.getUint16(at)]);
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
