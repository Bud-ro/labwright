/// Decoder for the `NUID` / `SUID` / `BNID` **id tables**.
///
/// Corpus-confirmed (100% of all three): the body is `[u32 count][count × u32]`
/// — `length == 4 + 4*count` (e.g. NUID 436 B = 4 + 4·108, SUID 1084 = 4 + 4·270,
/// BNID 92 = 4 + 4·22). The u32 entries are id/handle values (the role each table
/// plays — new/saved/block-name ids — and what the ids reference is not yet
/// decoded). Clean-room: the framing is CONFIRMED; the entry semantics are open.
library;

import 'dart:typed_data';

import 'block_catalog.dart' show BlockConfidence;

/// A decoded `[u32 count][count × u32]` id table.
class ViIdTable {
  const ViIdTable({required this.rawLength, required this.count, required this.entries});

  /// The block length in bytes.
  final int rawLength;

  /// The declared `u32` entry count (`@0`).
  final int count;

  /// The `count` u32 id/handle values. Values are opaque (role not yet decoded).
  final List<int> entries;

  /// Confidence in the `[u32 count][count u32]` framing (corpus: 100%).
  static const BlockConfidence framingConfidence = BlockConfidence.confirmed;

  /// Re-emits `[u32 count][entries…]` — the exact inverse of [decodeIdTable]
  /// when the body was the canonical `length == 4 + 4·count` (100% of the
  /// corpus, where [count] equals `entries.length`). Byte-identical to the
  /// parsed body, so an `NUID`/`SUID`/`BNID` payload re-emits from the typed
  /// model rather than being copied verbatim. A body that was truncated (a
  /// clamped [count] `> entries.length`) or carried trailing bytes re-emits at
  /// a different length; the writer's round-trip guard keeps such a payload
  /// copied (see `serializeBlockPayload`).
  Uint8List serialize() {
    final out = Uint8List(4 + 4 * entries.length);
    final bd = ByteData.sublistView(out);
    bd.setUint32(0, count);
    for (var i = 0; i < entries.length; i++) {
      bd.setUint32(4 + 4 * i, entries[i]);
    }
    return out;
  }
}

/// Decodes an `NUID`/`SUID`/`BNID` body. Total: returns null when too short for
/// the count word; reads min(count, available) entries so a corrupt count never
/// over-reads.
ViIdTable? decodeIdTable(Uint8List bytes) {
  if (bytes.length < 4) return null;
  final bd = ByteData.sublistView(bytes);
  final count = bd.getUint32(0);
  final available = (bytes.length - 4) ~/ 4;
  final entryCount = count.clamp(0, available);
  return ViIdTable(
    rawLength: bytes.length,
    count: count,
    entries: [for (var i = 0; i < entryCount; i++) bd.getUint32(4 + 4 * i)],
  );
}
