import 'dart:typed_data';

import '../labwright_rsrc_parse.dart';

/// The LabVIEW version a VI was saved in, plus its embedded title/description.
class ViVersionInfo {
  const ViVersionInfo({this.version, this.title});

  /// The LabVIEW version string from the `vers` block, e.g. `10.0` (null if not
  /// recoverable).
  final String? version;

  /// The VI's embedded title/description (from the `vers` block's `VIDS`
  /// record), if present.
  final String? title;
}

final RegExp _versionPattern = RegExp(r'^\d{1,2}\.\d');

/// Decodes the LabVIEW version + title from a `.vi`'s `vers` block. Reliable:
/// every VI in the validation corpus yields both.
ViVersionInfo decodeVersion(Uint8List viBytes) => versionFromSections(readViSections(viBytes));

/// [decodeVersion] over already-read sections (the `vers` block is uncompressed,
/// so raw [ViSection] bytes suffice). Total — never throws.
ViVersionInfo versionFromSections(Iterable<ViSection> sections) {
  String? version, title;
  for (final s in sections) {
    if (s.tag != 'vers') continue;
    for (final str in _pascalStrings(s.bytes)) {
      if (version == null && _versionPattern.hasMatch(str)) version = str;
    }
    title ??= _vidsTitle(s.bytes);
  }
  return ViVersionInfo(version: version, title: title);
}

/// A VI block summarized by size — its component footprint. Reliable (just
/// section sizes), regardless of whether the heap's logic can be parsed.
class BlockComponent {
  const BlockComponent({
    required this.tag,
    required this.sectionCount,
    required this.rawBytes,
    required this.decompressedBytes,
    required this.compressed,
  });

  /// The 4-char block tag (e.g. `BDEx`, `FPHb`, `DTHP`).
  final String tag;

  /// Number of sections in this block.
  final int sectionCount;

  /// Total stored (possibly compressed) bytes across the block's sections.
  final int rawBytes;

  /// Total bytes after inflation (== [rawBytes] for uncompressed blocks).
  final int decompressedBytes;

  /// Whether any section in the block was zlib-compressed.
  final bool compressed;
}

/// Per-block size summary for a VI (largest decompressed first) — the VI's
/// "components" view (how heavy the block diagram / front panel / type data are).
/// Reliable and total.
List<BlockComponent> blockComponents(Uint8List viBytes) => componentsFromDecoded(decodeSections(viBytes));

/// [blockComponents] over already-decoded sections.
List<BlockComponent> componentsFromDecoded(Iterable<DecodedSection> decoded) {
  final byTag = <String, List<DecodedSection>>{};
  for (final d in decoded) {
    (byTag[d.tag] ??= <DecodedSection>[]).add(d);
  }
  final out = <BlockComponent>[];
  byTag.forEach((tag, list) {
    out.add(BlockComponent(
      tag: tag,
      sectionCount: list.length,
      rawBytes: list.fold<int>(0, (a, d) => a + d.section.bytes.length),
      decompressedBytes: list.fold<int>(0, (a, d) => a + d.bytes.length),
      compressed: list.any((d) => d.wasCompressed),
    ));
  });
  out.sort((a, b) => b.decompressedBytes.compareTo(a.decompressedBytes));
  return out;
}

/// A **string table** in a VI heap: one contiguous run of Pascal strings.
///
/// LabVIEW packs the strings that belong to a single owning object — an enum/ring
/// control's item labels, a control's caption + parts, a help string set — as a
/// back-to-back `[u8 len][chars]` run. The *grouping* is real structure: these
/// strings share an owner, so keeping them together (rather than flattening to a
/// bag of strings) is genuine graph-relevant progress. [offset] is the run's byte
/// position within its **decompressed** section.
///
/// [framed] distinguishes confidence:
/// - `true` — the table was delimited by the confirmed **`C4 2E <len>` opcode**
///   (the 2-byte `C4 2E`, then a `u8` byte-length, or a `u16` when >255, then
///   exactly that many bytes of packed Pascal strings). This is a structurally
///   exact boundary, not a guess — across the corpus `0xC4` precedes `0x2E` in
///   100% of tables and the length field matches the table size with zero
///   exceptions (see the format doc).
/// - `false` — the table was located by the heuristic run-scan fallback (a run of
///   ≥2 consecutive valid Pascal strings). Used for tables not introduced by
///   `0x2E` (e.g. long help-text tables, which use a different, not-yet-decoded
///   framing). Best-effort: may occasionally merge adjacent tables or clip.
class HeapStringTable {
  const HeapStringTable({
    required this.sectionTag,
    required this.offset,
    required this.strings,
    this.framed = false,
  });

  /// The 4-char tag of the section this table lives in (e.g. `BDEx`, `FPHb`).
  final String sectionTag;

  /// Byte offset of the run's start within the decompressed section bytes.
  final int offset;

  /// The useful (wordy, deduped, order-preserving) labels in this table.
  final List<String> strings;

  /// Whether this table was delimited by the confirmed `0x2E <len>` opcode
  /// (exact), versus the heuristic run-scan fallback.
  final bool framed;
}

/// Best-effort human-readable strings embedded in a VI's heaps (control labels,
/// help/tooltip text, value lists). **Heuristic**, not authoritative: the heap
/// is an opcode-serialized object tree, so this scans for length-prefixed
/// printable runs and may include occasional fragments. Useful for "what does
/// this VI contain"; deduplicated, order-preserving.
List<String> extractHeapStrings(Uint8List viBytes, {int minLength = 4}) =>
    heapStringsFromDecoded(decodeSections(viBytes), minLength: minLength);

/// The located, grouped [HeapStringTable]s in a VI's heaps — the structured
/// primitive [extractHeapStrings] flattens. Order-preserving and total.
List<HeapStringTable> heapStringTables(Uint8List viBytes, {int minLength = 4, int minRun = 2}) =>
    heapStringTablesFromDecoded(decodeSections(viBytes), minLength: minLength, minRun: minRun);

/// [heapStringTables] over already-decoded sections.
///
/// Strings live in the heap as **contiguous Pascal-string tables** (`[u8 len]
/// [chars]` packed back-to-back, no per-string opcode tag). Most are introduced
/// by the confirmed **`C4 2E <len>` opcode** — those are parsed structurally
/// (exact boundary, [HeapStringTable.framed] == true). Bytes not covered by a
/// framed table fall back to a **heuristic run-scan**: a run of at least [minRun]
/// consecutive valid Pascal strings (rejecting coincidental single length-byte
/// matches), emitted with `framed == false`. Within a table the strings are
/// filtered to wordy ones of length ≥ [minLength] and deduped (preserving order);
/// a table with no useful strings is dropped. Single forward pass and total.
List<HeapStringTable> heapStringTablesFromDecoded(Iterable<DecodedSection> decoded,
    {int minLength = 4, int minRun = 2}) {
  final out = <HeapStringTable>[];

  List<String> filt(List<String> raw) {
    final seen = <String>{};
    return [for (final s in raw) if (s.length >= minLength && _looksWordy(s) && seen.add(s)) s];
  }

  for (final d in decoded) {
    final h = d.bytes;
    final n = h.length;
    var i = 0;
    var heurStart = -1;
    final heur = <String>[];

    void emit(List<String> raw, int offset, {bool framed = false}) {
      final keep = filt(raw);
      if (keep.isNotEmpty) {
        out.add(HeapStringTable(sectionTag: d.tag, offset: offset, strings: keep, framed: framed));
      }
    }

    void flushHeur() {
      if (heur.length >= minRun) emit(heur, heurStart);
      heur.clear();
      heurStart = -1;
    }

    while (i < n) {
      final framed = _tryFramedTable(h, i);
      if (framed != null) {
        flushHeur();
        emit(framed.strings, i + framed.headerLen, framed: true);
        i += framed.consumed;
        continue;
      }
      final len = h[i];
      if (len >= 1 && i + 1 + len <= n && _allPrintable(h, i + 1, len)) {
        if (heur.isEmpty) heurStart = i;
        heur.add(String.fromCharCodes(h.sublist(i + 1, i + 1 + len)));
        i += 1 + len;
      } else {
        flushHeur();
        i++;
      }
    }
    flushHeur();
  }
  return out;
}

class _FramedTable {
  const _FramedTable(this.strings, this.headerLen, this.consumed);

  final List<String> strings;

  final int headerLen;

  final int consumed;
}

/// If [h] at [i] is a `C4 2E` string table — `<region>` is exactly `<len>` bytes
/// of packed `[u8 len][printable]` Pascal strings (≥2 of them) — returns it;
/// otherwise null. The opcode is the **2-byte `C4 2E`** (`0xC4` precedes `0x2E`
/// in 100% of corpus tables). Length is a `u8`, or the extended-length escape
/// `C4 2E FF <u16 len>` for tables >255 bytes (header 5 bytes). Total/bounds-safe.
_FramedTable? _tryFramedTable(Uint8List h, int i) {
  final n = h.length;
  if (i + 3 > n || h[i] != kHeapRecordPrefix || h[i + 1] != HeapOpcode.stringTable.byte) {
    return null;
  }
  final int header, l;
  if (h[i + 2] == 0xff) {
    if (i + 5 > n) return null;
    header = 5;
    l = (h[i + 3] << 8) | h[i + 4];
  } else {
    header = 3;
    l = h[i + 2];
  }
  if (l < 2 || i + header + l > n) return null;
  final strs = _packedPascals(h, i + header, l);
  if (strs != null && strs.length >= 2) return _FramedTable(strs, header, header + l);
  return null;
}

/// Parses exactly [len] bytes at [start] as packed `[u8 L][L printable]` Pascal
/// strings. Returns the strings only if the region is consumed exactly (no
/// trailing bytes, no zero-length or non-printable entry); otherwise null. Total.
List<String>? _packedPascals(Uint8List h, int start, int len) {
  final end = start + len;
  final out = <String>[];
  var i = start;
  while (i < end) {
    final l = h[i];
    if (l == 0 || i + 1 + l > end || !_allPrintable(h, i + 1, l)) return null;
    out.add(String.fromCharCodes(h.sublist(i + 1, i + 1 + l)));
    i += 1 + l;
  }
  return out;
}

/// [extractHeapStrings] over already-decoded sections — the flat, globally
/// deduped view of [heapStringTablesFromDecoded]. Total.
List<String> heapStringsFromDecoded(Iterable<DecodedSection> decoded, {int minLength = 4, int minRun = 2}) {
  final seen = <String>{};
  return [
    for (final t in heapStringTablesFromDecoded(decoded, minLength: minLength, minRun: minRun))
      for (final s in t.strings)
        if (seen.add(s)) s
  ];
}

bool _allPrintable(Uint8List h, int start, int len) {
  for (var j = start; j < start + len; j++) {
    if (h[j] < 32 || h[j] >= 127) return false;
  }
  return true;
}

/// Extracts `[u8 len][len printable bytes]` runs from [h]. Total.
List<String> _pascalStrings(Uint8List h) {
  final out = <String>[];
  var i = 0;
  while (i < h.length) {
    final len = h[i];
    if (len >= 1 && len <= 120 && i + 1 + len <= h.length && _allPrintable(h, i + 1, len)) {
      out.add(String.fromCharCodes(h.sublist(i + 1, i + 1 + len)));
      i += 1 + len;
      continue;
    }
    i++;
  }
  return out;
}

/// True if [s] contains at least one ASCII letter (filters numeric/byte noise).
bool _looksWordy(String s) =>
    s.codeUnits.any((c) => (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a));

/// The VI's top-level **description / help text**, from the `CPC2` block, stored
/// as `[u32 len][ASCII]` (e.g. "This closes the device…"). Returns null when the
/// `CPC2` block is a compiled-cache/empty variant rather than a description.
/// Total.
String? cpc2Description(Iterable<ViSection> sections) {
  for (final s in sections) {
    if (s.tag != 'CPC2') continue;
    final b = s.bytes;
    if (b.length < 5) continue;
    final len = ByteData.sublistView(b).getUint32(0);
    if (len <= 0 || 4 + len > b.length) continue;
    final ok = b.getRange(4, 4 + len).every((c) => c == 9 || c == 10 || c == 13 || (c >= 32 && c < 127));
    if (ok) return String.fromCharCodes(b.sublist(4, 4 + len));
  }
  return null;
}

/// Reads the `VIDS` record's title (`'VIDS'` then `[u8 len][string]`) from a
/// `vers` section, or null.
String? _vidsTitle(Uint8List b) {
  for (var i = 0; i + 5 <= b.length; i++) {
    if (b[i] == 0x56 && b[i + 1] == 0x49 && b[i + 2] == 0x44 && b[i + 3] == 0x53) {
      final len = b[i + 4];
      if (len > 0 && i + 5 + len <= b.length && _allPrintable(b, i + 5, len)) {
        return String.fromCharCodes(b.sublist(i + 5, i + 5 + len));
      }
    }
  }
  return null;
}
