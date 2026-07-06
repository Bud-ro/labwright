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
  for (final section in sections) {
    if (section.tag != 'vers') continue;
    for (final str in _pascalStrings(section.bytes)) {
      if (version == null && _versionPattern.hasMatch(str)) version = str;
    }
    title ??= _vidsTitle(section.bytes);
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
  for (final decodedSection in decoded) {
    (byTag[decodedSection.tag] ??= <DecodedSection>[]).add(decodedSection);
  }
  final out = [
    for (final entry in byTag.entries)
      BlockComponent(
        tag: entry.key,
        sectionCount: entry.value.length,
        rawBytes: entry.value.fold<int>(0, (a, d) => a + d.section.bytes.length),
        decompressedBytes: entry.value.fold<int>(0, (a, d) => a + d.bytes.length),
        compressed: entry.value.any((d) => d.wasCompressed),
      ),
  ];
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
///   `0x2E` (entry.g. long help-text tables, which use a different, not-yet-decoded
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
List<HeapStringTable> heapStringTablesFromDecoded(
  Iterable<DecodedSection> decoded, {
  int minLength = 4,
  int minRun = 2,
}) {
  final out = <HeapStringTable>[];

  for (final decodedSection in decoded) {
    final bytes = decodedSection.bytes;
    final byteCount = bytes.length;
    var i = 0;
    var runStart = -1;
    final run = <String>[];

    void emit(List<String> raw, int offset, {bool framed = false}) {
      final seen = <String>{};
      final keep = [
        for (final text in raw)
          if (text.length >= minLength && _looksWordy(text) && seen.add(text)) text,
      ];
      if (keep.isNotEmpty) {
        out.add(HeapStringTable(sectionTag: decodedSection.tag, offset: offset, strings: keep, framed: framed));
      }
    }

    void flushRun() {
      if (run.length >= minRun) emit(run, runStart);
      run.clear();
      runStart = -1;
    }

    while (i < byteCount) {
      final framed = _tryFramedTable(bytes, i);
      if (framed != null) {
        flushRun();
        emit(framed.strings, i + framed.headerLen, framed: true);
        i += framed.consumed;
        continue;
      }
      final len = bytes[i];
      if (len >= 1 && i + 1 + len <= byteCount && _allPrintable(bytes, i + 1, len)) {
        if (run.isEmpty) runStart = i;
        run.add(_pascalChars(bytes, i + 1, len));
        i += 1 + len;
      } else {
        flushRun();
        i++;
      }
    }
    flushRun();
  }
  return out;
}

/// If [h] at [i] is a `C4 2E` string table — `<region>` is exactly `<len>` bytes
/// of packed `[u8 len][printable]` Pascal strings (≥2 of them) — returns it;
/// otherwise null. The opcode is the **2-byte `C4 2E`** (`0xC4` precedes `0x2E`
/// in 100% of corpus tables). Length is a `u8`, or the extended-length escape
/// `C4 2E FF <u16 len>` for tables >255 bytes (header 5 bytes). Total/bounds-safe.
({List<String> strings, int headerLen, int consumed})? _tryFramedTable(Uint8List bytes, int start) {
  final byteCount = bytes.length;
  if (start + 3 > byteCount || bytes[start] != kHeapRecordPrefix || bytes[start + 1] != HeapOpcode.stringTable.byte) {
    return null;
  }
  final int headerLen, payloadLen;
  if (bytes[start + 2] == 0xff) {
    if (start + 5 > byteCount) return null;
    headerLen = 5;
    payloadLen = (bytes[start + 3] << 8) | bytes[start + 4];
  } else {
    headerLen = 3;
    payloadLen = bytes[start + 2];
  }
  if (payloadLen < 2 || start + headerLen + payloadLen > byteCount) return null;
  final strs = _packedPascals(bytes, start + headerLen, payloadLen);
  if (strs == null || strs.length < 2) return null;
  return (strings: strs, headerLen: headerLen, consumed: headerLen + payloadLen);
}

/// Parses exactly [len] bytes at [start] as packed `[u8 L][L printable]` Pascal
/// strings. Returns the strings only if the region is consumed exactly (no
/// trailing bytes, no zero-length or non-printable entry); otherwise null. Total.
List<String>? _packedPascals(Uint8List bytes, int start, int len) {
  final end = start + len;
  final out = <String>[];
  var i = start;
  while (i < end) {
    final len = bytes[i];
    if (len == 0 || i + 1 + len > end || !_allPrintable(bytes, i + 1, len)) return null;
    out.add(_pascalChars(bytes, i + 1, len));
    i += 1 + len;
  }
  return out;
}

/// [extractHeapStrings] over already-decoded sections — the flat, globally
/// deduped view of [heapStringTablesFromDecoded]. Total.
List<String> heapStringsFromDecoded(Iterable<DecodedSection> decoded, {int minLength = 4, int minRun = 2}) {
  final seen = <String>{};
  return [
    for (final table in heapStringTablesFromDecoded(decoded, minLength: minLength, minRun: minRun))
      for (final text in table.strings)
        if (seen.add(text)) text,
  ];
}

String _pascalChars(Uint8List bytes, int start, int len) => String.fromCharCodes(bytes.sublist(start, start + len));

bool _allPrintable(Uint8List bytes, int start, int len) {
  for (var j = start; j < start + len; j++) {
    if (bytes[j] < 32 || bytes[j] >= 127) return false;
  }
  return true;
}

/// Extracts `[u8 len][len printable bytes]` runs from [h]. Total.
List<String> _pascalStrings(Uint8List bytes) {
  final out = <String>[];
  var i = 0;
  while (i < bytes.length) {
    final len = bytes[i];
    if (len >= 1 && len <= 120 && i + 1 + len <= bytes.length && _allPrintable(bytes, i + 1, len)) {
      out.add(_pascalChars(bytes, i + 1, len));
      i += 1 + len;
      continue;
    }
    i++;
  }
  return out;
}

bool _isTextByte(int byte) =>
    byte == 9 || byte == 10 || byte == 13 || (byte >= 32 && byte < 127); // tab/LF/CR or printable ASCII

/// True if [s] contains at least one ASCII letter (filters numeric/byte noise).
bool _looksWordy(String text) =>
    text.codeUnits.any((byte) => (byte >= 0x41 && byte <= 0x5a) || (byte >= 0x61 && byte <= 0x7a));

/// The VI's top-level **description / help text**, from the `CPC2` block, stored
/// as `[u32 len][ASCII]` (e.g. "This closes the device…"). Returns null when the
/// `CPC2` block is a compiled-cache/empty variant rather than a description.
/// Total.
String? cpc2Description(Iterable<ViSection> sections) {
  for (final section in sections) {
    if (section.tag != 'CPC2') continue;
    final bytes = section.bytes;
    if (bytes.length < 5) continue;
    final len = ByteData.sublistView(bytes).getUint32(0);
    if (len == 0 || 4 + len > bytes.length) continue;
    final ok = bytes.getRange(4, 4 + len).every(_isTextByte);
    if (ok) return String.fromCharCodes(bytes.sublist(4, 4 + len));
  }
  return null;
}

/// Reads the `VIDS` record's title (`'VIDS'` then `[u8 len][string]`) from a
/// `vers` section, or null.
String? _vidsTitle(Uint8List bytes) {
  for (var i = 0; i + 5 <= bytes.length; i++) {
    if (bytes[i] == 0x56 && bytes[i + 1] == 0x49 && bytes[i + 2] == 0x44 && bytes[i + 3] == 0x53) {
      final len = bytes[i + 4];
      if (len > 0 && i + 5 + len <= bytes.length && _allPrintable(bytes, i + 5, len)) {
        return _pascalChars(bytes, i + 5, len);
      }
    }
  }
  return null;
}
