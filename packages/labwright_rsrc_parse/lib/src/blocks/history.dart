/// Decoder for the `HIST` block — the VI's **revision-history** record.
///
/// Corpus-confirmed: `HIST` is a fixed **40-byte** record (7583/7583) of ten
/// big-endian u32 words. Per-word analysis over the corpus:
/// - `@0` = **format version**, always `2` (CONFIRMED).
/// - `@4` = **flags**, `0x400` in 99.5% (the default history config). LIKELY.
/// - `@8` = a small varying count (7/10/11/13…) — the **revision/entry count**.
///   LIKELY.
/// - `@12`, `@28`, `@32` = always `0` — **reserved** (CONFIRMED).
/// - `@20`, `@24` = `0` for ~97.6%, otherwise a timestamp/id-like pair — TENTATIVE.
/// - `@16`, `@36` = small flags (mostly `0`).
///
/// Clean-room; every byte is accounted for via [words].
library;

import 'dart:typed_data';

import 'block_catalog.dart' show BlockConfidence;

/// A decoded `HIST` revision-history record (10 u32 words).
class ViHistory {
  const ViHistory({required this.rawLength, required this.words});

  /// The block length (40 for every corpus HIST).
  final int rawLength;

  /// The ten big-endian u32 words (`@0`..`@36`). Source of every byte.
  final List<int> words;

  /// `@0` — record format version (always `2`). CONFIRMED.
  int get formatVersion => words[0];

  /// `@4` — history flags (`0x400` default). LIKELY.
  int get flags => words[1];

  /// `@8` — the revision/entry count. LIKELY.
  int get entryCount => words[2];

  /// `@20`/`@24` — a timestamp/id-like pair, non-zero for a minority. TENTATIVE.
  int get stampA => words[5];
  int get stampB => words[6];

  /// True when the three reserved words (`@12`,`@28`,`@32`) are zero, as in 100%
  /// of the corpus — a cheap integrity signal.
  bool get reservedAreZero => words[3] == 0 && words[7] == 0 && words[8] == 0;

  /// Confidence in the version + reserved-word layout (corpus-constant).
  static const BlockConfidence layoutConfidence = BlockConfidence.confirmed;
}

/// Decodes a `HIST` body. Null when shorter than the 40-byte record.
ViHistory? decodeHistory(Uint8List b) {
  if (b.length < 40) return null;
  final bd = ByteData.sublistView(b);
  return ViHistory(
    rawLength: b.length,
    words: [for (var w = 0; w < 10; w++) bd.getUint32(w * 4)],
  );
}
