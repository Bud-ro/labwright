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
ViVersionWord? decodeVersionWord(Uint8List b) {
  if (b.length < 4) return null;
  return ViVersionWord(
    major: (b[0] >> 4) * 10 + (b[0] & 0x0f),
    minor: b[1] >> 4,
    patch: b[1] & 0x0f,
    stage: b[2],
    build: b[3],
  );
}

/// Finds the `vers` section and decodes its binary version word. Null if absent.
/// (`vers` is uncompressed, so raw [ViSection] bytes suffice.)
ViVersionWord? versionWordFromSections(Iterable<ViSection> sections) {
  for (final s in sections) {
    if (s.tag == 'vers') return decodeVersionWord(s.bytes);
  }
  return null;
}
