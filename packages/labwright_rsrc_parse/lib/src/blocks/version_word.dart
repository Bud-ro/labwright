import 'dart:typed_data';

import '../viparse.dart' show ViSection;
import 'block_catalog.dart' show BlockConfidence;

class ViVersionWord {
  const ViVersionWord({
    required this.major,
    required this.minor,
    required this.patch,
    required this.stage,
    required this.build,
  });

  final int major;

  final int minor;

  final int patch;

  final int stage;

  final int build;

  String get version => patch == 0 ? '$major.$minor' : '$major.$minor.$patch';

  static const BlockConfidence confidence = BlockConfidence.confirmed;
}

ViVersionWord? decodeVersionWord(Uint8List bytes) {
  if (bytes.length < 4) return null;
  return ViVersionWord(
    major: (bytes[0] >> 4) * 10 + (bytes[0] & 0x0f),
    minor: bytes[1] >> 4,
    patch: bytes[1] & 0x0f,
    stage: bytes[2],
    build: bytes[3],
  );
}

ViVersionWord? versionWordFromSections(Iterable<ViSection> sections) {
  for (final section in sections) {
    if (section.tag == 'vers') return decodeVersBlock(section.bytes)?.versionWord;
  }
  return null;
}

class ViVersBlock {
  const ViVersBlock({
    required this.rawLength,
    required this.versionWordBytes,
    required this.flags,
    required this.versionText,
    required this.infoText,
  });

  final int rawLength;

  final Uint8List versionWordBytes;

  ViVersionWord get versionWord => decodeVersionWord(versionWordBytes)!;

  final int flags;

  final String versionText;

  final String infoText;

  Uint8List serialize() {
    final t = versionText.codeUnits;
    final i = infoText.codeUnits;
    final out = Uint8List(8 + t.length + i.length);
    final bd = ByteData.sublistView(out);
    out.setRange(0, 4, versionWordBytes);
    bd.setUint16(4, flags);
    out[6] = t.length;
    out.setRange(7, 7 + t.length, t);
    out[7 + t.length] = i.length;
    out.setRange(8 + t.length, 8 + t.length + i.length, i);
    return out;
  }
}

ViVersBlock? decodeVersBlock(Uint8List bytes) {
  if (bytes.length < 8) return null;
  final view = ByteData.sublistView(bytes);
  final flags = view.getUint16(4);
  final len1 = bytes[6];
  final pos = 7 + len1;
  if (pos >= bytes.length) return null;
  final versionText = String.fromCharCodes(bytes, 7, pos);
  final len2 = bytes[pos];
  final infoStart = pos + 1;
  final end = infoStart + len2;
  if (end != bytes.length) return null;
  final infoText = String.fromCharCodes(bytes, infoStart, end);
  return ViVersBlock(
    rawLength: bytes.length,
    versionWordBytes: Uint8List.sublistView(bytes, 0, 4),
    flags: flags,
    versionText: versionText,
    infoText: infoText,
  );
}
