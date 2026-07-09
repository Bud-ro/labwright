/// Decoders for the auxiliary record blocks: the compiled-code envelope, the
/// connector-pane terminal map, bookmarks, offset tables, image envelopes, and
/// the data-space image header. Every decoder is total (never throws) and
/// corpus-verified; fields that are not yet decoded say so instead of guessing.
library;

import 'dart:typed_data';

/// A decoded `VICD` **compiled-code envelope**: the header framing the VI's
/// machine-code image. The code body itself is target machine code and is
/// deliberately not interpreted (that would be disassembly, not file-format
/// decoding) — it is *recognized opaque*.
class ViCompiledCode {
  const ViCompiledCode({
    required this.flags,
    required this.architecture,
    required this.codeSize,
    required this.bodyLength,
  });

  /// The u32 at offset 0 (0x40000000 dominates; high bits vary — flag word,
  /// meaning not yet decoded).
  final int flags;

  /// The 4-char target architecture tag at offset 4 (`i386`, `wx64`, …).
  final String architecture;

  /// The u32 (little-endian) code size at offset 8.
  final int codeSize;

  /// Total body bytes after the 16-byte header (the opaque machine code).
  final int bodyLength;
}

/// Decodes a `VICD` envelope; null when [bytes] is shorter than the header.
ViCompiledCode? decodeCompiledCode(Uint8List bytes) {
  if (bytes.length < 16) return null;
  final view = ByteData.sublistView(bytes);
  return ViCompiledCode(
    flags: view.getUint32(0),
    architecture: String.fromCharCodes(bytes.sublist(4, 8)),
    codeSize: view.getUint32(8, Endian.little),
    bodyLength: bytes.length - 16,
  );
}

/// A decoded `CPMp` **connector-pane map**: which front-panel object each
/// connector-pane terminal is wired to.
///
/// Corpus-verified layout (3531/3531 exact): `[u16le terminalCount]` then
/// `terminalCount` little-endian u16 entries; `0xFFFF` marks an unassigned
/// terminal, any other value is the linked object's index.
class ViConnectorPaneMap {
  const ViConnectorPaneMap({required this.terminals});

  /// Per-terminal assignment; null = unassigned (`0xFFFF` on disk).
  final List<int?> terminals;

  int get terminalCount => terminals.length;
  int get assignedCount => terminals.where((t) => t != null).length;

  /// Re-emits `[u16le terminalCount]` then the little-endian u16 entries
  /// (`0xFFFF` for an unassigned terminal) — reproducing the stored body.
  Uint8List serialize() {
    final out = Uint8List(2 + 2 * terminals.length);
    out[0] = terminals.length & 0xff;
    out[1] = (terminals.length >> 8) & 0xff;
    for (var i = 0; i < terminals.length; i++) {
      final value = terminals[i] ?? 0xFFFF;
      out[2 + 2 * i] = value & 0xff;
      out[3 + 2 * i] = (value >> 8) & 0xff;
    }
    return out;
  }
}

/// Decodes a `CPMp` map; null when the declared count does not exactly fill
/// the body (0/3531 in corpus).
ViConnectorPaneMap? decodeConnectorPaneMap(Uint8List bytes) {
  if (bytes.length < 2) return null;
  final count = bytes[0] | (bytes[1] << 8);
  if (2 + 2 * count != bytes.length) return null;
  final terminals = <int?>[];
  for (var i = 0; i < count; i++) {
    final value = bytes[2 + 2 * i] | (bytes[3 + 2 * i] << 8);
    terminals.add(value == 0xFFFF ? null : value);
  }
  return ViConnectorPaneMap(terminals: terminals);
}

/// A decoded `BKMK` **bookmark list**: `[u32 count]` then bookmark records
/// carrying `#tag` texts. An empty list is the 8-byte all-zero body
/// (743/988 in corpus). The per-record grammar beyond the texts is not yet
/// decoded; [texts] recovers the length-prefixed printable strings.
/// One `BKMK` entry: two leading u32 words ([wordA] present only in the first
/// table) plus a length-prefixed [text] run. The word semantics (a bookmark's
/// object id / position within the diagram) are not decoded; the values and the
/// text bytes are retained so the entry re-emits exactly.
class ViBookmarkEntry {
  const ViBookmarkEntry({required this.wordA, required this.wordB, required this.text});

  /// The first u32 (`tableA` entries only; null for `tableB` entries).
  final int? wordA;

  /// The second u32 (present on every entry).
  final int wordB;

  /// The length-prefixed text bytes (a `#`-anchor bookmark string).
  final Uint8List text;
}

/// A byte-exact `BKMK` bookmark block: two back-to-back record tables. Table A
/// is `[u32 countA]` then `countA × (u32 a, u32 b, u32 len, text[len])`; table B
/// is `[u32 countB]` then `countB × (u32 b, u32 len, text[len])` (no leading
/// `a`). The empty block is `[u32 0][u32 0]` (743/988). The walk tiles the body
/// exactly for every corpus instance (988/988), so [serialize] reproduces it.
class ViBookmarkList {
  const ViBookmarkList({required this.tableA, required this.tableB});

  /// The first table's entries (each carries [ViBookmarkEntry.wordA]).
  final List<ViBookmarkEntry> tableA;

  /// The second table's entries.
  final List<ViBookmarkEntry> tableB;

  /// Count of first-table entries (the `u32 @0`).
  int get declaredCount => tableA.length;

  bool get isEmpty => tableA.isEmpty && tableB.isEmpty;

  /// The printable bookmark strings from both tables (diagnostic; [serialize]
  /// re-emits the retained bytes).
  List<String> get texts => [
    for (final e in [...tableA, ...tableB])
      if (_printable(e.text)) String.fromCharCodes(e.text),
  ];

  /// Re-emits `[u32 countA] tableA [u32 countB] tableB` — the whole block.
  Uint8List serialize() {
    var n = 8;
    for (final e in tableA) {
      n += 12 + e.text.length;
    }
    for (final e in tableB) {
      n += 8 + e.text.length;
    }
    final out = Uint8List(n);
    final d = ByteData.sublistView(out);
    var pos = 0;
    d.setUint32(pos, tableA.length);
    pos += 4;
    for (final e in tableA) {
      d.setUint32(pos, e.wordA ?? 0);
      d.setUint32(pos + 4, e.wordB);
      d.setUint32(pos + 8, e.text.length);
      pos += 12;
      out.setRange(pos, pos + e.text.length, e.text);
      pos += e.text.length;
    }
    d.setUint32(pos, tableB.length);
    pos += 4;
    for (final e in tableB) {
      d.setUint32(pos, e.wordB);
      d.setUint32(pos + 4, e.text.length);
      pos += 8;
      out.setRange(pos, pos + e.text.length, e.text);
      pos += e.text.length;
    }
    return out;
  }
}

bool _printable(Uint8List b) {
  if (b.isEmpty) return false;
  for (final c in b) {
    if ((c < 0x20 && c != 0x09 && c != 0x0a && c != 0x0d) || c >= 0x7f) return false;
  }
  return true;
}

/// Decodes a `BKMK` block into a byte-exact [ViBookmarkList]; null when the
/// two-table walk does not tile the body exactly to its end. Total.
ViBookmarkList? decodeBookmarkList(Uint8List bytes) {
  if (bytes.length < 8) return null;
  final view = ByteData.sublistView(bytes);
  var pos = 0;
  List<ViBookmarkEntry>? readTable(bool withWordA) {
    if (pos + 4 > bytes.length) return null;
    final count = view.getUint32(pos);
    pos += 4;
    if (count > 100000) return null;
    final entries = <ViBookmarkEntry>[];
    for (var i = 0; i < count; i++) {
      final head = withWordA ? 12 : 8;
      if (pos + head > bytes.length) return null;
      final int? a = withWordA ? view.getUint32(pos) : null;
      final b = view.getUint32(pos + (withWordA ? 4 : 0));
      final len = view.getUint32(pos + head - 4);
      pos += head;
      if (len > bytes.length - pos) return null;
      entries.add(ViBookmarkEntry(wordA: a, wordB: b, text: Uint8List.sublistView(bytes, pos, pos + len)));
      pos += len;
    }
    return entries;
  }

  final tableA = readTable(true);
  if (tableA == null) return null;
  final tableB = readTable(false);
  if (tableB == null || pos != bytes.length) return null;
  return ViBookmarkList(tableA: tableA, tableB: tableB);
}

/// A decoded `IPSR` **offset table**: the body is a monotonically ascending
/// list of big-endian u32 offsets (549/549 in corpus). What the offsets index
/// is not yet decoded.
class ViOffsetTable {
  const ViOffsetTable({required this.offsets});
  final List<int> offsets;

  /// Re-emits the big-endian u32 offsets in order — the whole table.
  Uint8List serialize() {
    final out = Uint8List(offsets.length * 4);
    final d = ByteData.sublistView(out);
    for (var i = 0; i < offsets.length; i++) {
      d.setUint32(i * 4, offsets[i]);
    }
    return out;
  }
}

/// Decodes an `IPSR` table; null when the body is not a whole number of
/// ascending u32s.
ViOffsetTable? decodeOffsetTable(Uint8List bytes) {
  if (bytes.isEmpty || bytes.length % 4 != 0) return null;
  final view = ByteData.sublistView(bytes);
  final offsets = <int>[];
  var previous = -1;
  for (var pos = 0; pos < bytes.length; pos += 4) {
    final value = view.getUint32(pos);
    if (value < previous) return null;
    previous = value;
    offsets.add(value);
  }
  return ViOffsetTable(offsets: offsets);
}

/// A decoded PNG envelope (`MNGI` blocks, and the image embedded in `DSIM`):
/// the magic plus the IHDR dimensions. Pixel data is delegated to any PNG
/// codec; this decode is the file-format understanding of the block.
class ViPngImage {
  const ViPngImage({required this.width, required this.height, required this.byteLength});
  final int width;
  final int height;
  final int byteLength;
}

const _pngMagic = [0x89, 0x50, 0x4e, 0x47];

/// Decodes the PNG envelope at [start]; null when no PNG-with-IHDR is there.
ViPngImage? decodePngEnvelope(Uint8List bytes, [int start = 0]) {
  if (start + 24 > bytes.length) return null;
  for (var i = 0; i < 4; i++) {
    if (bytes[start + i] != _pngMagic[i]) return null;
  }
  // IHDR is the first chunk: length(4) type("IHDR") width(4) height(4).
  if (String.fromCharCodes(bytes.sublist(start + 12, start + 16)) != 'IHDR') return null;
  final view = ByteData.sublistView(bytes);
  return ViPngImage(
    width: view.getUint32(start + 16),
    height: view.getUint32(start + 20),
    byteLength: bytes.length - start,
  );
}

/// A decoded `DSIM` **data-space image** header. Corpus-verified: the u32 at
/// offset 0 is 0 in 18654/18654 sections; the u16 pairs that follow carry
/// small geometry-like values (0x14/0x14/0x18 dominate). 15620/18654 sections
/// embed a PNG (the VI's colour icon image lives here); [png] decodes its
/// envelope when present. The remaining header semantics are not yet decoded.
class ViDataSpaceImage {
  const ViDataSpaceImage({required this.headerWords, required this.pngOffset, required this.png});

  /// The first four big-endian u16s after the leading zero u32.
  final List<int> headerWords;

  /// Offset of the embedded PNG magic, or null when the section has none.
  final int? pngOffset;

  /// The embedded PNG envelope, when present.
  final ViPngImage? png;
}

/// Decodes a `DSIM` header; null when [bytes] is shorter than the 12-byte
/// header or the leading u32 is nonzero (0/18654 in corpus).
ViDataSpaceImage? decodeDataSpaceImage(Uint8List bytes) {
  if (bytes.length < 12) return null;
  final view = ByteData.sublistView(bytes);
  if (view.getUint32(0) != 0) return null;
  final headerWords = [for (var i = 0; i < 4; i++) view.getUint16(4 + 2 * i)];
  int? pngOffset;
  for (var pos = 0; pos + 4 <= bytes.length; pos++) {
    if (bytes[pos] == 0x89 && bytes[pos + 1] == 0x50 && bytes[pos + 2] == 0x4e && bytes[pos + 3] == 0x47) {
      pngOffset = pos;
      break;
    }
  }
  return ViDataSpaceImage(
    headerWords: headerWords,
    pngOffset: pngOffset,
    png: pngOffset == null ? null : decodePngEnvelope(bytes, pngOffset),
  );
}

/// A decoded `GCDI` record: `[u32 value][u8 version==1]` then a payload whose
/// format is not yet decoded (mostly empty: 9-byte bodies dominate, 477/868).
/// Version byte verified 868/868.
class ViGcdiRecord {
  const ViGcdiRecord({required this.value, required this.payloadLength});
  final int value;
  final int payloadLength;
}

/// Decodes a `GCDI` record; null when shorter than 5 bytes or version != 1.
ViGcdiRecord? decodeGcdiRecord(Uint8List bytes) {
  if (bytes.length < 5 || bytes[4] != 0x01) return null;
  return ViGcdiRecord(
    value: ByteData.sublistView(bytes).getUint32(0),
    payloadLength: bytes.length - 5,
  );
}

/// A byte-exact `CCST` **compiled-code-state** key/value table: `[u32 count]`
/// then `count × ([u32 keyLen][key][u32 valLen][value])`. The dominant 4-byte
/// all-zero body is `count == 0` (2977/3011); the larger bodies carry build
/// settings (`TARGET_TYPE=Windows`, `RUN_TIME_ENGINE=False`). Both key and value
/// are length-prefixed byte runs retained verbatim; the walk tiles the body
/// exactly (3011/3011), so [serialize] reproduces it.
class ViKeyValueTable {
  const ViKeyValueTable({required this.entries});

  /// The `(key, value)` byte-run pairs, in order.
  final List<(Uint8List, Uint8List)> entries;

  /// Re-emits `[u32 count]` then each `[u32 keyLen][key][u32 valLen][value]`.
  Uint8List serialize() {
    var n = 4;
    for (final (k, v) in entries) {
      n += 8 + k.length + v.length;
    }
    final out = Uint8List(n);
    final d = ByteData.sublistView(out);
    d.setUint32(0, entries.length);
    var pos = 4;
    for (final (k, v) in entries) {
      d.setUint32(pos, k.length);
      pos += 4;
      out.setRange(pos, pos + k.length, k);
      pos += k.length;
      d.setUint32(pos, v.length);
      pos += 4;
      out.setRange(pos, pos + v.length, v);
      pos += v.length;
    }
    return out;
  }
}

/// Decodes a `CCST` body into a byte-exact [ViKeyValueTable]; null when the
/// key/value walk does not tile the body exactly to its end. Total.
ViKeyValueTable? decodeKeyValueTable(Uint8List bytes) {
  if (bytes.length < 4) return null;
  final d = ByteData.sublistView(bytes);
  final count = d.getUint32(0);
  if (count > 100000) return null;
  var pos = 4;
  final entries = <(Uint8List, Uint8List)>[];
  for (var i = 0; i < count; i++) {
    final runs = <Uint8List>[];
    for (var f = 0; f < 2; f++) {
      if (pos + 4 > bytes.length) return null;
      final len = d.getUint32(pos);
      pos += 4;
      if (len > bytes.length - pos) return null;
      runs.add(Uint8List.sublistView(bytes, pos, pos + len));
      pos += len;
    }
    entries.add((runs[0], runs[1]));
  }
  if (pos != bytes.length) return null;
  return ViKeyValueTable(entries: entries);
}

/// A byte-exact `CPST`/`CPSP` **caption/boolean-text table**: `[u32 count]` then
/// `count ×` packed Pascal strings `[u8 len][text]` (the True/False strings and
/// comparison-mode captions of a polymorphic node). The walk tiles the body
/// exactly (CPST 56/56, CPSP 53/53), so [serialize] reproduces it.
class ViPascalStringTable {
  const ViPascalStringTable({required this.strings});

  /// The string byte runs, in order (each `<= 255` bytes).
  final List<Uint8List> strings;

  /// The printable strings decoded as text (diagnostic; [serialize] uses the
  /// retained bytes).
  List<String> get texts => [
    for (final s in strings)
      if (_printable(s)) String.fromCharCodes(s),
  ];

  /// Re-emits `[u32 count]` then each `[u8 len][text]`.
  Uint8List serialize() {
    var n = 4;
    for (final s in strings) {
      n += 1 + s.length;
    }
    final out = Uint8List(n);
    ByteData.sublistView(out).setUint32(0, strings.length);
    var pos = 4;
    for (final s in strings) {
      out[pos++] = s.length & 0xff;
      out.setRange(pos, pos + s.length, s);
      pos += s.length;
    }
    return out;
  }
}

/// Decodes a `CPST`/`CPSP` body into a byte-exact [ViPascalStringTable]; null
/// when a string length runs past the buffer, a string exceeds 255 bytes, or the
/// walk does not tile the body exactly to its end. Total.
ViPascalStringTable? decodePascalStringTable(Uint8List bytes) {
  if (bytes.length < 4) return null;
  final count = ByteData.sublistView(bytes).getUint32(0);
  if (count > 100000) return null;
  var pos = 4;
  final strings = <Uint8List>[];
  for (var i = 0; i < count; i++) {
    if (pos >= bytes.length) return null;
    final len = bytes[pos++];
    if (pos + len > bytes.length) return null;
    strings.add(Uint8List.sublistView(bytes, pos, pos + len));
    pos += len;
  }
  if (pos != bytes.length) return null;
  return ViPascalStringTable(strings: strings);
}
