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
library;

import 'dart:typed_data';

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

  /// True when the three reserved words (`@12`,`@28`,`@32`) are zero, as in 100%
  /// of the corpus — a cheap integrity signal.
  bool get reservedAreZero => words[3] == 0 && words[7] == 0 && words[8] == 0;
}

/// The ten big-endian u32 words that make up a fixed HIST record.
const int _histWords = 10;

/// Bytes per u32 word — the 40-byte record is `_histWords * _wordBytes`.
const int _wordBytes = 4;

/// Decodes a `HIST` body. Null when shorter than the 40-byte record.
ViHistory? decodeHistory(Uint8List bytes) {
  if (bytes.length < _histWords * _wordBytes) return null;
  final data = ByteData.sublistView(bytes);
  return ViHistory(
    rawLength: bytes.length,
    words: [for (var w = 0; w < _histWords; w++) data.getUint32(w * _wordBytes)],
  );
}
