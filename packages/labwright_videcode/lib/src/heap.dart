import 'dart:typed_data';

import 'decode.dart';

/// The byte that introduces a length-prefixed heap record (`C4 op len payload`).
/// See [HeapOpcode] for the opcode catalog.
const int kHeapRecordPrefix = 0xc4;

/// The catalog of known LabVIEW heap-record **opcodes** — the byte after
/// [kHeapRecordPrefix] in a `C4 <op> <u8 len> <payload>` record.
///
/// This enhanced enum is the single source of truth for every opcode we have
/// reverse-engineered from the corpus. Each value documents the record's meaning,
/// its payload layout, the corpus evidence, and its decoding status. The raw byte
/// in a [HeapRecord] is mapped here via [HeapRecord.kind] / [HeapOpcode.fromByte];
/// any byte not catalogued maps to [HeapOpcode.unknown].
///
/// Status legend:
/// - **decoded** — payload semantics confirmed and exposed by a typed accessor.
/// - **structural** — record framing/shape known, but the semantic role is not
///   yet determined, so it is intentionally not interpreted.
/// - **unknown** — not catalogued.
///
/// See `docs/vi-rsrc-and-heap-format.md` for the full evidence and probe history.
enum HeapOpcode {
  /// `0x2D` — **object bounds rectangle** (decoded). Payload is 8 bytes = four
  /// big-endian `s16` fields `top, left, bottom, right`, in pixels: the position
  /// and size of a control / node / decoration. Corpus: 99% are valid rectangles
  /// with sane dimensions. Decoded by [HeapRecord.bounds].
  bounds(0x2d),

  /// `0x1F` — **origin-anchored size rectangle** (decoded). Same 8-byte 4× `s16`
  /// layout as [bounds] but `top == left == 0`, so it encodes a height×width
  /// extent rather than a position. Corpus: 100% valid, origin-anchored. Decoded
  /// by [HeapRecord.sizeRect].
  size(0x1f),

  /// `0x2E` — **string table** (decoded). The only variable-length confirmed
  /// opcode: the payload is `len` bytes of packed `[u8 strlen][chars]` Pascal
  /// strings (a `u16` length is used when the table exceeds 255 bytes). Holds a
  /// group of related labels (enum/ring items, captions). Decoded by
  /// [HeapStringTable] / the string-table parser.
  stringTable(0x2e),

  /// `0x22` — **caption** (decoded). A single control / parameter name; the
  /// payload *is* the text, sized by the record's own length byte (no inner
  /// prefix). Corpus: 97% printable. Decoded by [HeapRecord.text].
  caption(0x22),

  /// `0x19` — **description / help text** (decoded, heuristic). HTML-ish
  /// (`<B>…</B>`), multi-line tooltip/help text stored as length-prefixed text
  /// segments. The inner multi-segment framing is not fully decoded, so the text
  /// is recovered heuristically by [HeapRecord.descriptionText].
  description(0x19),

  /// `0x5F` — **rectangle, role undetermined** (structural). Decodes as a 4× `s16`
  /// rectangle (97% valid) but allows negative coordinates and degenerate points,
  /// so its semantic role (offset? sub-region? connector extent?) is unknown. Not
  /// interpreted, to avoid assigning a false meaning.
  rect5f(0x5f),

  /// A heap opcode that is not (yet) catalogued. Its [byte] is -1; use
  /// [HeapRecord.opcode] for the actual byte value.
  unknown(-1);

  const HeapOpcode(this.byte);

  /// The opcode byte (the value after [kHeapRecordPrefix]); -1 for [unknown].
  final int byte;

  /// Whether this opcode's payload semantics are decoded (vs. structural/unknown).
  bool get isDecoded => this != unknown && this != rect5f;

  /// Maps a raw opcode byte to its [HeapOpcode], or [unknown] if not catalogued.
  static HeapOpcode fromByte(int b) {
    for (final op in values) {
      if (op != unknown && op.byte == b) return op;
    }
    return unknown;
  }
}

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
  /// Prefer [kind] for matching against the known-opcode catalog.
  final int opcode;

  /// The raw payload bytes (`<len>` bytes after the length byte).
  final Uint8List payload;

  /// This record's catalogued [HeapOpcode] (or [HeapOpcode.unknown]).
  HeapOpcode get kind => HeapOpcode.fromByte(opcode);

  /// Total bytes this record occupies: `0xC4` + opcode + length byte + payload.
  int get byteLength => 3 + payload.length;

  /// If this is a [HeapOpcode.bounds] record, the object's bounding rectangle —
  /// four big-endian `s16` fields `top, left, bottom, right`, in pixels; else null.
  /// (Position/size of a control/node/decoration.)
  HeapRect? get bounds => kind == HeapOpcode.bounds ? HeapRect.fromPayload(payload) : null;

  /// If this is a [HeapOpcode.size] record, the origin-anchored size/extent
  /// rectangle (same 4× `s16` layout, `top == left == 0`); else null. Kept
  /// distinct from [bounds] so positional layout data is not polluted by sizes.
  HeapRect? get sizeRect => kind == HeapOpcode.size ? HeapRect.fromPayload(payload) : null;

  /// If this is a [HeapOpcode.caption] record, the payload decoded as text — a
  /// single control caption / name; else null. The whole payload is the string
  /// (no inner prefix). Null when empty or not fully printable ASCII.
  String? get text {
    if (kind != HeapOpcode.caption || payload.isEmpty) return null;
    for (final b in payload) {
      if (b < 32 || b >= 127) return null;
    }
    return String.fromCharCodes(payload);
  }

  /// If this is a [HeapOpcode.description] record, the embedded help/tooltip text
  /// (often HTML-ish, multi-line), recovered from its length-prefixed text
  /// segments; null if none. **Heuristic** — the inner multi-segment framing is
  /// not fully decoded, so this recovers readable text, not exact fields. Total.
  String? get descriptionText {
    if (kind != HeapOpcode.description) return null;
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
      if (h[i] == kHeapRecordPrefix && i + 3 <= n) {
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
