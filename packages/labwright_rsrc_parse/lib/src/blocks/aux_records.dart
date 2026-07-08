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
class ViBookmarkList {
  const ViBookmarkList({required this.declaredCount, required this.texts});

  final int declaredCount;

  /// The bookmark texts recovered from the records (`#TODO: …`).
  final List<String> texts;

  bool get isEmpty => declaredCount == 0;
}

/// Decodes a `BKMK` list; null when [bytes] cannot hold the count. Total.
ViBookmarkList? decodeBookmarkList(Uint8List bytes) {
  if (bytes.length < 4) return null;
  final view = ByteData.sublistView(bytes);
  final declaredCount = view.getUint32(0);
  final texts = <String>[];
  // Scan for [u32 len][printable text] runs — the bookmark strings.
  for (var pos = 4; pos + 4 <= bytes.length && texts.length < 4096; pos++) {
    final len = view.getUint32(pos);
    if (len < 2 || len > 4096 || pos + 4 + len > bytes.length) continue;
    var printable = true;
    for (var i = pos + 4; i < pos + 4 + len; i++) {
      final byte = bytes[i];
      if ((byte < 0x20 && byte != 0x09 && byte != 0x0a && byte != 0x0d) || byte >= 0x7f) {
        printable = false;
        break;
      }
    }
    if (!printable) continue;
    final text = String.fromCharCodes(bytes.sublist(pos + 4, pos + 4 + len));
    if (text.contains('#') || text.length >= 8) {
      texts.add(text);
      pos += 3 + len;
    }
  }
  return ViBookmarkList(declaredCount: declaredCount, texts: texts);
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
