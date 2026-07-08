/// Decoder for the `LVSR` block — the **LabVIEW Save Record**, a fixed-size
/// settings/flags blob written once per VI. Length is era-dependent
/// (predominantly 160 B modern, then 136 B / 144 B older; a handful of records
/// use other lengths — 120/137/116/96 B). The version word is universal; the
/// password/hash slots are part of the 160-byte layout.
///
/// Clean-room, corpus-grounded. Every asserted field is labelled with a
/// [BlockConfidence]; bytes whose meaning is not yet decoded are left as honest
/// gaps, not invented.
library;

import 'dart:typed_data';

import '../viparse.dart' show ViSection;
import 'block_catalog.dart' show BlockConfidence;
import 'version_word.dart' show decodeVersionWord;

/// The MD5-style hash LabVIEW stores for an **empty** (unset) password. Both the
/// `BDPW` block and the `LVSR` password slot hold this when no password is set
/// (corpus: 100% of 160-byte LVSRs at offset 96). A different value ⇒ protected.
const List<int> emptyPasswordHash = [
  0xd4, 0x1d, 0x8c, 0xd9, 0x8f, 0x00, 0xb2, 0x04, //
  0xe9, 0x80, 0x09, 0x98, 0xec, 0xf8, 0x42, 0x7e,
];

/// The decoded `LVSR` save record.
///
/// Field evidence (probed over the 7583-VI corpus):
/// - **version word** `@0` (u32): byte0 is the **BCD major** LabVIEW version,
///   byte1 the BCD minor; byte2 is a **stage** byte (`0x80` = release, 100% of
///   corpus); byte3 a build/phase counter. CONFIRMED: byte0 BCD equals the `vers`
///   string major in 7579/7583 VIs.
/// - **block-diagram password hash** `@96` (16 B, 160-byte layout): CONFIRMED ==
///   the `BDPW` block in 5707/5710 VIs; equals [emptyPasswordHash] when unset.
/// - **secondary hash** `@144` (16 B, 160-byte layout): a second hash/checksum
///   slot (80% the empty hash). LIKELY a password/integrity field; exact role not
///   yet decoded.
/// The remaining words (small flag/count fields near the start, and three
/// 16-byte high-entropy id/checksum fields) are not yet decoded — see
/// [unknownNote].
class ViSaveRecord {
  const ViSaveRecord({
    required this.rawLength,
    required this.versionMajor,
    required this.versionMinor,
    required this.stage,
    required this.build,
    this.blockDiagramPasswordHash,
    this.secondaryHash,
  });

  final int rawLength;

  /// BCD-decoded major version (e.g. `20` for LabVIEW 2020). CONFIRMED.
  final int versionMajor;

  /// BCD-decoded minor version. CONFIRMED.
  final int versionMinor;

  /// The `@2` stage byte (`0x80` = release across 100% of the corpus). CONFIRMED.
  final int stage;

  /// The `@3` build/phase byte. Tentative.
  final int build;

  /// The 16-byte block-diagram password hash (`@96`), present only in the
  /// 160-byte layout. CONFIRMED to mirror the `BDPW` block. Null when the record
  /// is too short to contain it.
  final List<int>? blockDiagramPasswordHash;

  /// The 16-byte secondary hash slot (`@144`, 160-byte layout). LIKELY a
  /// password/checksum; role not yet decoded. Null when absent.
  final List<int>? secondaryHash;

  /// `"major.minor"`, e.g. `"20.0"`. Matches the `vers` string for ~99.95% of VIs.
  String get version => '$versionMajor.$versionMinor';

  /// Whether the block diagram is password-protected: the `@96` hash is present
  /// and differs from [emptyPasswordHash]. False when unset or the hash is absent.
  bool get isBlockDiagramPasswordProtected {
    final hash = blockDiagramPasswordHash;
    return hash != null && !_bytesEqual(hash, emptyPasswordHash);
  }

  /// Honest summary of what remains undecoded in the record.
  static const String unknownNote =
      'Undecoded: small flag/count words near the start (@36 = -1 sentinel, '
      '@68, @72), three 16-byte id/checksum fields (@52, @80, @120), and the '
      'exact role of the secondary @144 hash.';
}

/// Decodes an `LVSR` section body into a [ViSaveRecord]. Total: returns null only
/// when the buffer is too short to hold the universal version word.
ViSaveRecord? decodeSaveRecord(Uint8List bytes) {
  if (bytes.length < 4) return null;
  final versionWord = decodeVersionWord(bytes)!;
  return ViSaveRecord(
    rawLength: bytes.length,
    versionMajor: versionWord.major,
    versionMinor: versionWord.minor,
    stage: versionWord.stage,
    build: versionWord.build,
    blockDiagramPasswordHash: bytes.length >= 112 ? List.unmodifiable(bytes.sublist(96, 112)) : null,
    secondaryHash: bytes.length >= 160 ? List.unmodifiable(bytes.sublist(144, 160)) : null,
  );
}

/// A byte-exact `LVSR` model: the record read as its grid of big-endian u32
/// words. The record is a word-aligned settings/flags table (the [ViSaveRecord]
/// accessors name the decoded fields — version word `@0`, password hashes
/// `@96`/`@144`); the remaining flag/count/id words are retained verbatim so
/// [serialize] reproduces the record exactly without inventing meaning for the
/// undecoded slots. Only the word-aligned lengths are modeled ([decodeSaveRecordRaw]
/// returns null otherwise), so a non-aligned record stays copied.
class ViSaveRecordRaw {
  const ViSaveRecordRaw({required this.words});

  /// The record's big-endian u32 words, in order (`length ~/ 4` of them).
  final List<int> words;

  /// Re-emits the words as a big-endian u32 grid — the whole record.
  Uint8List serialize() {
    final out = Uint8List(words.length * 4);
    final data = ByteData.sublistView(out);
    for (var i = 0; i < words.length; i++) {
      data.setUint32(i * 4, words[i]);
    }
    return out;
  }
}

/// Decodes an `LVSR` body into a byte-exact [ViSaveRecordRaw]; null when the
/// buffer is empty or its length is not a whole number of u32 words. Total.
ViSaveRecordRaw? decodeSaveRecordRaw(Uint8List bytes) {
  if (bytes.isEmpty || bytes.length % 4 != 0) return null;
  final data = ByteData.sublistView(bytes);
  return ViSaveRecordRaw(words: [for (var i = 0; i < bytes.length; i += 4) data.getUint32(i)]);
}

/// Finds the `LVSR` section among [sections] and decodes it. Null if absent.
/// (`LVSR` is uncompressed, so raw [ViSection] bytes suffice.)
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
