/// Decoder for LabVIEW's 4-byte **binary version word** — the `u32` that heads
/// both the `vers` block and the `LVSR` save record.
///
/// Layout (corpus-confirmed): `[BCD major][minor<<4 | patch][stage][build]`.
/// - byte0 = **BCD major** (`0x08`→8, `0x10`→10, `0x20`→20). Two BCD digits, so
///   it spans LabVIEW 8…22+.
/// - byte1 = **minor** in the high nibble, **patch/fix** in the low nibble
///   (`0x50`→ minor 5, patch 0 → "8.5"). NOT a BCD of the whole byte.
/// - byte2 = **stage** (`0x80` = release across 100% of the corpus).
/// - byte3 = **build/phase** counter.
///
/// Cross-checks: the BCD major matches the `vers` ASCII string in 7579/7583 and
/// the `LVSR` version word in 7583/7583. Clean-room; major/minor/patch/stage are
/// CONFIRMED, the build byte's exact meaning is TENTATIVE.
library;

import 'dart:typed_data';

import '../viparse.dart' show ViSection;
import 'block_catalog.dart' show BlockConfidence;

/// A decoded LabVIEW binary version word.
class ViVersionWord {
  const ViVersionWord({
    required this.major,
    required this.minor,
    required this.patch,
    required this.stage,
    required this.build,
  });

  /// BCD major version (e.g. 8, 10, 20). CONFIRMED.
  final int major;

  /// Minor version (high nibble of byte1). CONFIRMED.
  final int minor;

  /// Patch/fix (low nibble of byte1). CONFIRMED.
  final int patch;

  /// Release stage (`0x80` = release in 100% of the corpus). CONFIRMED.
  final int stage;

  /// Build/phase counter. TENTATIVE.
  final int build;

  /// `"major.minor"` or `"major.minor.patch"` when patch is non-zero —
  /// matches the `vers` ASCII string.
  String get version => patch == 0 ? '$major.$minor' : '$major.$minor.$patch';

  static const BlockConfidence confidence = BlockConfidence.confirmed;
}

/// Decodes the version word from the first 4 bytes of [b] (vers/LVSR header).
/// Null if fewer than 4 bytes.
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

/// Finds the `vers` section and decodes its binary version word. Null if absent.
/// (`vers` is uncompressed, so raw [ViSection] bytes suffice.)
ViVersionWord? versionWordFromSections(Iterable<ViSection> sections) {
  for (final section in sections) {
    if (section.tag == 'vers') return decodeVersBlock(section.bytes)?.versionWord;
  }
  return null;
}

/// A decoded `vers` block body.
///
/// Layout (corpus-confirmed, accounts for every byte of every corpus `vers`):
/// `[u32 version word][u16 flags][Pascal versionText][Pascal infoText]`, where a
/// Pascal string is `[u8 len][len bytes]`. The block length equals
/// `8 + versionText.length + infoText.length`. `versionText` is the ASCII
/// version (`"16.0"`, `"13.0.1"`); `infoText` is a usually-empty descriptive
/// string (e.g. `"Oldest compatible LabVIEW."`). The [flags] u16 is `0` across
/// the corpus; its meaning is not decoded.
class ViVersBlock {
  const ViVersBlock({
    required this.rawLength,
    required this.versionWordBytes,
    required this.flags,
    required this.versionText,
    required this.infoText,
  });

  /// The block length in bytes.
  final int rawLength;

  /// The raw 4 bytes of the version word `@0`, re-emitted verbatim (so the
  /// re-serialization is exact regardless of the BCD interpretation).
  final Uint8List versionWordBytes;

  /// The decoded version word (`@0`).
  ViVersionWord get versionWord => decodeVersionWord(versionWordBytes)!;

  /// The `u16 @4` field (`0` across the corpus; meaning not decoded).
  final int flags;

  /// The ASCII version string (Pascal-encoded `@6`), e.g. `"16.0"`.
  final String versionText;

  /// The trailing Pascal string, usually empty; e.g. `"Oldest compatible
  /// LabVIEW."`.
  final String infoText;

  /// Re-emits `[version word][u16 flags][Pascal versionText][Pascal infoText]`
  /// — the exact inverse of [decodeVersBlock]. Byte-identical to the parsed
  /// body for every corpus `vers`.
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

/// Decodes a `vers` block body ([ViVersBlock]); null when the bytes do not fit
/// the `[u32][u16][Pascal][Pascal]` grammar exactly (too short, a Pascal length
/// overruns, or trailing bytes remain past the second string). Total.
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
