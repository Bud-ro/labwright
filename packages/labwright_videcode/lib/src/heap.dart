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

  /// If this is a **`C4 2D` object-bounds record** (opcode `0x2D`, 8-byte
  /// payload), the object's bounding rectangle — four big-endian `s16` fields
  /// `top, left, bottom, right`, in pixels; otherwise null.
  ///
  /// Confirmed across the corpus: 99% of `C4 2D` records are valid rectangles
  /// (`bottom ≥ top ∧ right ≥ left`, derived height/width in `[0, 2000)` px) —
  /// these are the position/size of diagram & front-panel objects.
  HeapRect? get bounds => opcode == 0x2d ? HeapRect.fromPayload(payload) : null;

  /// If this is a **`C4 1F` size record** (opcode `0x1F`, 8-byte payload), the
  /// object's origin-anchored size/extent rectangle (same 4× `s16` layout, but
  /// `top == left == 0`, so it encodes a height×width); otherwise null.
  ///
  /// Confirmed across the corpus: 100% of `C4 1F` records are valid rectangles
  /// and origin-anchored (e.g. `(0, 0, 12, 12)`, `(0, 0, 20, 20)`). Kept distinct
  /// from [bounds] so positional layout data is not polluted by these sizes.
  HeapRect? get sizeRect => opcode == 0x1f ? HeapRect.fromPayload(payload) : null;

  /// If this is a **`C4 22` caption record** (opcode `0x22`), the payload decoded
  /// as text — a single control caption / name / label; otherwise null. Unlike
  /// the `C4 2E` string *table*, this is one string whose length is the record's
  /// own length byte (no inner prefix). Returns null when the payload is empty or
  /// not fully printable ASCII (drops the ~3% binary captions).
  ///
  /// Confirmed across the corpus: 97% of `C4 22` payloads are printable text
  /// (e.g. `Conversion time`, `Amplitude (mV)`, `error out`).
  String? get text {
    if (opcode != 0x22 || payload.isEmpty) return null;
    for (final b in payload) {
      if (b < 32 || b >= 127) return null;
    }
    return String.fromCharCodes(payload);
  }

  /// If this is a **`C4 19` description record** (opcode `0x19`), the embedded
  /// help/tooltip text — often HTML-ish (`<B>…</B>`) and multi-line — extracted as
  /// its printable text runs joined by spaces; null if none.
  ///
  /// **Heuristic**: `C4 19`'s inner framing is a not-yet-decoded count-prefixed
  /// set of strings, so this recovers the *readable text* rather than the exact
  /// field structure. Confirmed across the corpus to hold VI documentation text
  /// (e.g. `<B>source</B> describes the origin of the error…`). Total.
  String? get descriptionText {
    if (opcode != 0x19) return null;
    bool isText(int start, int len) {
      for (var j = start; j < start + len; j++) {
        final c = payload[j];
        if (c >= 32 && c < 127) continue;
        if (c == 9 || c == 10 || c == 13) continue; // tab/newline/CR
        return false;
      }
      return true;
    }

    final runs = <String>[];
    var i = 0;
    while (i < payload.length) {
      final len = payload[i]; // u8 length prefix
      if (len >= 6 && i + 1 + len <= payload.length && isText(i + 1, len)) {
        runs.add(String.fromCharCodes(payload.sublist(i + 1, i + 1 + len)));
        i += 1 + len;
      } else {
        i++;
      }
    }
    return runs.isEmpty ? null : runs.join('\n');
  }
}

/// A bounding rectangle in LabVIEW's field order (`top, left, bottom, right`),
/// in pixels. The position/size of a VI object (control, node, decoration).
class HeapRect {
  const HeapRect({required this.top, required this.left, required this.bottom, required this.right});

  /// Decodes an 8-byte heap payload as four big-endian `s16` fields
  /// (`top, left, bottom, right`). Returns null if [payload] is not 8 bytes.
  /// Total/bounds-safe.
  static HeapRect? fromPayload(Uint8List payload) {
    if (payload.length != 8) return null;
    int s16(int i) {
      final v = (payload[i] << 8) | payload[i + 1];
      return v >= 0x8000 ? v - 0x10000 : v;
    }

    return HeapRect(top: s16(0), left: s16(2), bottom: s16(4), right: s16(6));
  }

  final int top;
  final int left;
  final int bottom;
  final int right;

  /// Height in pixels (`bottom - top`).
  int get height => bottom - top;

  /// Width in pixels (`right - left`).
  int get width => right - left;

  /// Whether this is a well-formed rectangle (`bottom ≥ top ∧ right ≥ left`).
  bool get isValid => bottom >= top && right >= left;

  @override
  String toString() => 'HeapRect(t:$top l:$left b:$bottom r:$right ${width}x$height)';
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
