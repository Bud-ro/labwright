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
/// - **structural** — payload *shape* known (e.g. it is a rectangle), but the
///   semantic role is not yet determined, so it is intentionally not given a
///   meaning-specific accessor.
/// - **unknown** — not catalogued.
///
/// See `docs/vi-rsrc-and-heap-format.md` for the full evidence and probe history.
enum HeapOpcode {
  /// `0x2D` — **object bounds rectangle** (decoded). Payload is 8 bytes = four
  /// big-endian `s16` fields `top, left, bottom, right`, in pixels: the position
  /// and size of a control / node / decoration. Corpus: 99% are valid rectangles
  /// with sane dimensions. Decoded by [HeapRecord.bounds].
  bounds(0x2d, HeapShape.rectangle, isDecoded: true),

  /// `0x1F` — **origin-anchored size rectangle** (decoded). Same 8-byte 4× `s16`
  /// layout as [bounds] but `top == left == 0`, so it encodes a height×width
  /// extent rather than a position. Corpus: 100% valid, origin-anchored. Decoded
  /// by [HeapRecord.sizeRect].
  size(0x1f, HeapShape.rectangle, isDecoded: true),

  /// `0x2E` — **string table** (decoded). The only variable-length confirmed
  /// opcode: the payload is `len` bytes of packed `[u8 strlen][chars]` Pascal
  /// strings (a `u16` length is used when the table exceeds 255 bytes). Holds a
  /// group of related labels (enum/ring items, captions). Decoded by
  /// [HeapStringTable] / the string-table parser.
  stringTable(0x2e, HeapShape.stringTable, isDecoded: true),

  /// `0x22` — **caption** (decoded). A single control / parameter name; the
  /// payload *is* the text, sized by the record's own length byte. Corpus: 97%
  /// printable. Decoded by [HeapRecord.text].
  caption(0x22, HeapShape.string, isDecoded: true),

  /// `0x27` — **plot / legend name** (decoded). A single string naming a plot or
  /// series, e.g. `Plot 0`, `Plot 1`. Same single-string payload as [caption]
  /// (100% printable across the corpus). Decoded by [HeapRecord.text].
  plotName(0x27, HeapShape.string, isDecoded: true),

  /// `0x74` — **numeric format string** (decoded). A single string holding a
  /// display format specifier, e.g. `%020b`, `%016b`, `%#_6g`. Single-string
  /// payload (96% printable). Decoded by [HeapRecord.text].
  formatString(0x74, HeapShape.string, isDecoded: true),

  /// `0x20` — **item / label string** (decoded). A single identifier or
  /// enum/ring item label, e.g. `Line 0`..`Line 7`, `stringLength`, `<None>`.
  /// Single-string payload (100% printable across the corpus). Decoded by
  /// [HeapRecord.text].
  itemLabel(0x20, HeapShape.string, isDecoded: true),

  /// `0xC4` — **symbol / C-function name** (decoded). A single string holding a
  /// Call-Library function or decorated C entry-point name, e.g.
  /// `ps2000aRunStreaming`, `_ps5000SetEts@20`. Lives mostly in the `DTHP` type
  /// heap (93% printable). Decoded by [HeapRecord.text]. (The opcode byte here is
  /// `0xC4`, distinct from the record-prefix [kHeapRecordPrefix].)
  symbolName(0xc4, HeapShape.string, isDecoded: true),

  /// `0x19` — **description / help text** (decoded, heuristic). HTML-ish
  /// (`<B>…</B>`), multi-line tooltip/help text stored as length-prefixed text
  /// segments. The inner multi-segment framing is not fully decoded, so the text
  /// is recovered heuristically by [HeapRecord.descriptionText].
  description(0x19, HeapShape.helpText, isDecoded: true),

  /// `0xA4` — **filesystem path** (decoded). A LabVIEW `PTH0` path record:
  /// `'PTH0' <u32 len> <u16 type> <u16 nComponents>` then packed Pascal-string
  /// components — a DLL / library reference (e.g. `ps5000.dll`,
  /// `Program Files\Pico Technology\…`). Mostly in `DTHP` (100% start with
  /// `PTH0`). Decoded by [HeapRecord.path].
  path(0xa4, HeapShape.path, isDecoded: true),

  /// `0x4A` — **type / terminal bounds rectangle** (decoded). 8-byte 4× `s16`
  /// rectangle (100% valid), in the `DTHP` type heap — the bounds of a terminal /
  /// type element. Decoded by the generic [HeapRecord.rect].
  typeBounds(0x4a, HeapShape.rectangle, isDecoded: true),

  /// `0x44` — **composite container** (structural). A wrapper whose payload holds
  /// complete nested `C4` children (bounds `2D` + origin/size `1F` + caption `22`,
  /// interleaved with non-`C4` style/color tuples) — a control/decoration
  /// cluster. Children via [HeapRecord.children].
  container44(0x44, HeapShape.container),

  /// `0x64` — **composite container** (structural). Like [container44] but richer
  /// (bounds + captions + format strings + nested type tokens). Children via
  /// [HeapRecord.children].
  container64(0x64, HeapShape.container),

  /// `0x24` — **composite container** (structural). A bounds-rect-dominant cluster
  /// with captions; payload holds nested `C4` children. Children via
  /// [HeapRecord.children].
  container24(0x24, HeapShape.container),

  /// `0x5F` — **rectangle, role undetermined** (structural). Decodes as a 4× `s16`
  /// rectangle (97% valid) but allows negative coordinates and degenerate points,
  /// so its semantic role (offset? sub-region? connector extent?) is unknown.
  /// Readable via the generic [HeapRecord.rect]; no meaning-specific accessor.
  rect5f(0x5f, HeapShape.rectangle),

  /// `0x4C` — **rectangle, role undetermined** (structural). 8-byte 4× `s16`
  /// rectangle (100% valid), often all-zero or with negative coordinates. Role
  /// not yet determined. Readable via [HeapRecord.rect].
  rect4c(0x4c, HeapShape.rectangle),

  /// `0xD6` — **rectangle, role undetermined** (structural). 8-byte 4× `s16`
  /// rectangle (100% valid), frequently origin-anchored like [size]. Role not yet
  /// determined. Readable via [HeapRecord.rect].
  rectD6(0xd6, HeapShape.rectangle),

  /// `0x62` — **rectangle, role undetermined** (structural). 8-byte 4× `s16`
  /// rectangle (100% valid), typically positive coordinates like [bounds]. Role
  /// not yet determined. Readable via [HeapRecord.rect].
  rect62(0x62, HeapShape.rectangle),

  /// `0x26` — **rectangle, role undetermined** (structural). 8-byte 4× `s16`
  /// rectangle (100% valid). Role not yet determined. Readable via
  /// [HeapRecord.rect].
  rect26(0x26, HeapShape.rectangle),

  /// A heap opcode that is not (yet) catalogued. Its [byte] is -1; use
  /// [HeapRecord.opcode] for the actual byte value.
  unknown(-1, HeapShape.none);

  const HeapOpcode(this.byte, this.shape, {this.isDecoded = false});

  /// The opcode byte (the value after [kHeapRecordPrefix]); -1 for [unknown].
  final int byte;

  /// The shape of this opcode's payload (rectangle / string / …) — drives the
  /// generic accessors on [HeapRecord].
  final HeapShape shape;

  /// Whether this opcode has a confirmed *semantic* meaning (a meaning-specific
  /// accessor), vs. merely a known shape (structural) or unknown.
  final bool isDecoded;

  /// Maps a raw opcode byte to its [HeapOpcode], or [unknown] if not catalogued.
  static HeapOpcode fromByte(int b) {
    for (final op in values) {
      if (op != unknown && op.byte == b) return op;
    }
    return unknown;
  }
}

/// The shape of a heap record's payload — what kind of value it holds, used to
/// drive the generic decoders on [HeapRecord]. See [HeapOpcode.shape].
enum HeapShape {
  /// An 8-byte 4× big-endian `s16` rectangle (`top, left, bottom, right`).
  rectangle,

  /// A single string occupying the whole payload (sized by the record length).
  string,

  /// A table of packed Pascal strings (the `C4 2E` form).
  stringTable,

  /// Length-prefixed help/description text segments (the `C4 19` form).
  helpText,

  /// A `PTH0` filesystem-path record (the `C4 A4` form).
  path,

  /// A composite record whose payload holds nested `C4` children.
  container,

  /// No known shape (uncatalogued opcode).
  none,
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

  /// The 4× `s16` rectangle for any [HeapShape.rectangle] opcode (`bounds`,
  /// `size`, `rect5f`, `rect4c`, …); null otherwise. The generic accessor — see
  /// [bounds] / [sizeRect] for the meaning-specific specializations.
  HeapRect? get rect => kind.shape == HeapShape.rectangle ? HeapRect.fromPayload(payload) : null;

  /// If this is a [HeapOpcode.bounds] record, the object's bounding rectangle —
  /// four big-endian `s16` fields `top, left, bottom, right`, in pixels; else null.
  /// (Position/size of a control/node/decoration.)
  HeapRect? get bounds => kind == HeapOpcode.bounds ? HeapRect.fromPayload(payload) : null;

  /// If this is a [HeapOpcode.size] record, the origin-anchored size/extent
  /// rectangle (same 4× `s16` layout, `top == left == 0`); else null. Kept
  /// distinct from [bounds] so positional layout data is not polluted by sizes.
  HeapRect? get sizeRect => kind == HeapOpcode.size ? HeapRect.fromPayload(payload) : null;

  /// If this is a single-string opcode ([HeapShape.string]: caption, plot name,
  /// or format string), the payload decoded as text — the whole payload is the
  /// string (no inner prefix); else null. Null when empty or not fully printable
  /// ASCII.
  String? get text {
    if (kind.shape != HeapShape.string || payload.isEmpty) return null;
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

  /// If this is a [HeapOpcode.path] record, the filesystem path it encodes — the
  /// `PTH0` record's packed Pascal-string components joined with `/`; null if not
  /// a valid `PTH0`. (A DLL / library reference.) Total/bounds-safe.
  String? get path {
    if (kind != HeapOpcode.path) return null;
    final p = payload;
    if (p.length < 12 || p[0] != 0x50 || p[1] != 0x54 || p[2] != 0x48 || p[3] != 0x30) {
      return null; // not 'PTH0'
    }
    final nComp = (p[10] << 8) | p[11];
    final parts = <String>[];
    var i = 12;
    for (var c = 0; c < nComp && i < p.length; c++) {
      final len = p[i];
      if (i + 1 + len > p.length) break;
      var ok = true;
      for (var j = i + 1; j < i + 1 + len; j++) {
        if (p[j] < 32 || p[j] >= 127) {
          ok = false;
          break;
        }
      }
      if (!ok) break;
      parts.add(String.fromCharCodes(p.sublist(i + 1, i + 1 + len)));
      i += 1 + len;
    }
    return parts.isEmpty ? null : parts.join('/');
  }

  /// If this is a [HeapShape.container] record (e.g. a `C4 44` cluster), the
  /// nested `C4` child records inside its payload (offsets relative to this
  /// record's payload); otherwise empty. Total.
  List<HeapRecord> get children =>
      kind.shape == HeapShape.container ? scanC4Records(payload, sectionTag) : const <HeapRecord>[];
}

/// Frames the `C4 <op> <u8 len> <payload>` records in [h] (a decompressed heap or
/// a container payload), tagging each with [sectionTag]. Non-`C4` bytes are
/// stepped over one at a time. Total/bounds-safe.
List<HeapRecord> scanC4Records(Uint8List h, String sectionTag) {
  final out = <HeapRecord>[];
  final n = h.length;
  var i = 0;
  while (i < n) {
    if (h[i] == kHeapRecordPrefix && i + 3 <= n) {
      final op = h[i + 1];
      final len = h[i + 2];
      if (i + 3 + len <= n) {
        out.add(HeapRecord(
          sectionTag: sectionTag,
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
  return out;
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
    out.addAll(scanC4Records(d.bytes, d.tag));
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
