import 'dart:typed_data';

import '../viparse.dart' show ViSection;
import 'version_word.dart' show decodeVersionWord;

const List<int> emptyPasswordHash = [
  0xd4, 0x1d, 0x8c, 0xd9, 0x8f, 0x00, 0xb2, 0x04, //
  0xe9, 0x80, 0x09, 0x98, 0xec, 0xf8, 0x42, 0x7e,
];

/// Bits of the `u16` flag word at offset 4 of `LVSR`.
enum ViSaveFlag {
  /// `0x0800`: last saved by an evaluation-license LabVIEW, whose block-diagram
  /// images carry the "LabVIEW Evaluation Software" watermark.
  evaluationLicense(0x0800),

  /// `0x1000`: last saved by a Home or Student edition, whose block-diagram
  /// images carry the "Student Edition" watermark.
  homeStudentEdition(0x1000)
  ;

  const ViSaveFlag(this.mask);

  final int mask;
}

class ViSaveRecord {
  const ViSaveRecord({
    required this.rawLength,
    required this.versionMajor,
    required this.versionMinor,
    required this.stage,
    required this.build,
    this.saveFlagWord = 0,
    this.blockDiagramPasswordHash,
    this.secondaryHash,
  });

  final int rawLength;

  final int saveFlagWord;

  Set<ViSaveFlag> get saveFlags => {
    for (final flag in ViSaveFlag.values)
      if (saveFlagWord & flag.mask != 0) flag,
  };

  final int versionMajor;

  final int versionMinor;

  final int stage;

  final int build;

  final List<int>? blockDiagramPasswordHash;

  final List<int>? secondaryHash;

  String get version => '$versionMajor.$versionMinor';

  bool get isBlockDiagramPasswordProtected {
    final hash = blockDiagramPasswordHash;
    return hash != null && !_bytesEqual(hash, emptyPasswordHash);
  }

  static const String unknownNote =
      'Undecoded: the @4 flag word beyond bits 0x0800 and 0x1000, the '
      'small flag/count words near the start (@36 = -1 sentinel, @68, @72), '
      'three 16-byte id/checksum fields (@52, @80, @120), and the exact role '
      'of the secondary @144 hash.';
}

ViSaveRecord? decodeSaveRecord(Uint8List bytes) {
  if (bytes.length < 4) return null;
  final versionWord = decodeVersionWord(bytes)!;
  return ViSaveRecord(
    rawLength: bytes.length,
    versionMajor: versionWord.major,
    versionMinor: versionWord.minor,
    stage: versionWord.stage,
    build: versionWord.build,
    saveFlagWord: bytes.length >= 6 ? ByteData.sublistView(bytes).getUint16(4) : 0,
    blockDiagramPasswordHash: bytes.length >= 112 ? List.unmodifiable(bytes.sublist(96, 112)) : null,
    secondaryHash: bytes.length >= 160 ? List.unmodifiable(bytes.sublist(144, 160)) : null,
  );
}

class ViSaveRecordRaw {
  const ViSaveRecordRaw({required this.words});

  final List<int> words;

  Uint8List serialize() {
    final out = Uint8List(words.length * 4);
    final data = ByteData.sublistView(out);
    for (var i = 0; i < words.length; i++) {
      data.setUint32(i * 4, words[i]);
    }
    return out;
  }
}

ViSaveRecordRaw? decodeSaveRecordRaw(Uint8List bytes) {
  if (bytes.isEmpty || bytes.length % 4 != 0) return null;
  final data = ByteData.sublistView(bytes);
  return ViSaveRecordRaw(words: [for (var i = 0; i < bytes.length; i += 4) data.getUint32(i)]);
}

ViSaveRecord? saveRecordFromSections(Iterable<ViSection> sections) {
  for (final section in sections) {
    if (section.tag == 'LVSR') return decodeSaveRecord(section.bytes);
  }
  return null;
}

bool _bytesEqual(List<int> a, List<int> b) {
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
