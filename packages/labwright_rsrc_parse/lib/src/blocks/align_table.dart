/// Decoder for the `BFAL` **align table**.
///
/// Corpus-confirmed framing (2028/2028 sections, 0 desyncs): the body is
/// `[u32 count]` followed by `count` fixed 9-byte records, so
/// `length == 4 + 9*count` on every instance (e.g. 121 B = 4 + 9·13, 85 B =
/// 4 + 9·9, 31477 B = 4 + 9·3497). Each record is `[u32 offset][u32 value]
/// [u8 kind]`: [offset] rises monotonically within a table (a position into the
/// block-diagram/front-panel heap the entry aligns to), [value] and [kind] carry
/// the alignment payload. The three fields are retained verbatim so [serialize]
/// re-emits the body byte-identically; their finer semantics are open.
library;

import 'dart:typed_data';

import 'block_catalog.dart' show BlockConfidence;

/// One `BFAL` record: a heap [offset] paired with an alignment [value]/[kind].
class ViAlignEntry {
  const ViAlignEntry({required this.offset, required this.value, required this.kind});

  /// Big-endian u32 at the record's byte 0 — a position into the aligned heap.
  final int offset;

  /// Big-endian u32 at byte 4 — the alignment value (semantics open).
  final int value;

  /// The record's trailing byte — an alignment kind/flag (semantics open).
  final int kind;
}

/// A decoded `BFAL` align table: `[u32 count][count × 9-byte record]`.
class ViAlignTable {
  const ViAlignTable({required this.count, required this.entries});

  /// The declared `u32` record count at offset 0.
  final int count;

  /// The `count` fixed-width records, retained field-for-field.
  final List<ViAlignEntry> entries;

  /// Confidence in the `[u32 count][count × 9B]` framing (corpus: 100%).
  static const BlockConfidence framingConfidence = BlockConfidence.confirmed;

  /// Re-emits `[u32 count][entries…]` — byte-identical to the parsed body when it
  /// was the canonical `length == 4 + 9·count` (100% of the corpus, where
  /// [count] equals `entries.length`). A truncated body (clamped [count] >
  /// `entries.length`) or one with trailing bytes re-emits at a different length;
  /// the writer's round-trip guard keeps such a payload copied.
  Uint8List serialize() {
    final out = Uint8List(4 + 9 * entries.length);
    final bd = ByteData.sublistView(out);
    bd.setUint32(0, count);
    var p = 4;
    for (final e in entries) {
      bd.setUint32(p, e.offset);
      bd.setUint32(p + 4, e.value);
      out[p + 8] = e.kind;
      p += 9;
    }
    return out;
  }
}

/// Decodes a `BFAL` body. Total: returns null when too short for the count word;
/// reads `min(count, available)` records so a corrupt count never over-reads.
ViAlignTable? decodeAlignTable(Uint8List bytes) {
  if (bytes.length < 4) return null;
  final bd = ByteData.sublistView(bytes);
  final count = bd.getUint32(0);
  final available = (bytes.length - 4) ~/ 9;
  final n = count.clamp(0, available);
  final entries = <ViAlignEntry>[
    for (var i = 0; i < n; i++)
      ViAlignEntry(
        offset: bd.getUint32(4 + 9 * i),
        value: bd.getUint32(4 + 9 * i + 4),
        kind: bytes[4 + 9 * i + 8],
      ),
  ];
  return ViAlignTable(count: count, entries: entries);
}
