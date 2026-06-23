import 'dart:typed_data';

import 'decode.dart';

/// A length-prefixed **`C4` opcode record** in a decompressed VI heap.
///
/// The heap is a stream of opcode-serialized objects. Records introduced by the
/// byte `0xC4` are **length-prefixed** — `C4 <op> <u8 len> <len payload bytes>` —
/// confirmed across the corpus (see `docs/vi-rsrc-and-heap-format.md`): e.g.
/// `C4 2D` always carries `len == 8` (an 11-byte record) and skipping `3 + len`
/// lands on the next record's opcode byte in 99.97% of cases. So each `C4` record
/// can be **framed and skipped without knowing its semantics** — the seed of a
/// real heap walker.
///
/// Note on confidence: the *framing* is confirmed, but most opcodes' *meanings*
/// are still undecoded. Only `C4 2E` (string table) is interpreted today
/// (see `HeapStringTable`). [opcode] is the raw selector byte; [payload] is the
/// raw operand bytes — no semantic interpretation is applied here.
class HeapRecord {
  const HeapRecord({
    required this.sectionTag,
    required this.offset,
    required this.opcode,
    required this.payload,
  });

  /// The 4-char tag of the section this record lives in (e.g. `BDEx`, `FPHb`).
  final String sectionTag;

  /// Byte offset of the introducing `0xC4` within the decompressed section.
  final int offset;

  /// The opcode selector byte (the byte after `0xC4`), e.g. `0x2D`, `0x2E`, `0x1F`.
  final int opcode;

  /// The raw payload bytes (`<len>` bytes after the length byte).
  final Uint8List payload;

  /// Total bytes this record occupies: `0xC4` + opcode + length byte + payload.
  int get byteLength => 3 + payload.length;
}

/// Scan-based inventory of the **`C4` length-prefixed records** in a VI's heaps.
///
/// Walks each decompressed section: at a `0xC4` it frames the record by its `u8`
/// length prefix and skips its payload (so a `0xC4` *inside* a framed record's
/// payload is not re-scanned); non-`C4` records — whose length rules are not yet
/// decoded — are stepped over one byte at a time. **Total** (never throws; all
/// records are in-bounds).
///
/// Best-effort, not a complete walker: until the non-`C4` opcode lengths are
/// decoded, a `0xC4` that occurs inside a non-`C4` record's payload can frame a
/// spurious record (the scan resynchronizes afterward). The dominant opcodes
/// (`C4 2D`, `C4 1F`, `C4 5F`, …) are framed reliably.
List<HeapRecord> heapC4Records(Uint8List viBytes) => heapC4RecordsFromDecoded(decodeSections(viBytes));

/// [heapC4Records] over already-decoded sections.
List<HeapRecord> heapC4RecordsFromDecoded(Iterable<DecodedSection> decoded) {
  final out = <HeapRecord>[];
  for (final d in decoded) {
    final h = d.bytes;
    final n = h.length;
    var i = 0;
    while (i < n) {
      if (h[i] == 0xc4 && i + 3 <= n) {
        final op = h[i + 1];
        final len = h[i + 2];
        if (i + 3 + len <= n) {
          out.add(HeapRecord(
            sectionTag: d.tag,
            offset: i,
            opcode: op,
            payload: Uint8List.sublistView(h, i + 3, i + 3 + len),
          ));
          i += 3 + len;
          continue;
        }
      }
      i++;
    }
  }
  return out;
}

/// Frequency of each `C4` opcode across a VI's heaps — the opcode census that
/// maps the heap's record types (e.g. `0x2D` dominant, `0x2E` = string table).
/// Total.
Map<int, int> heapOpcodeHistogram(Uint8List viBytes) {
  final hist = <int, int>{};
  for (final r in heapC4Records(viBytes)) {
    hist[r.opcode] = (hist[r.opcode] ?? 0) + 1;
  }
  return hist;
}
