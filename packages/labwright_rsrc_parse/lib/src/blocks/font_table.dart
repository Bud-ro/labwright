/// Decoder for the `FTAB` block — the VI's **font table**.
///
/// Corpus finding (322 sections): the block opens with `u16 version == 1`
/// (322/322), then header words, a `u16 fontCount` at `@6`, and a `u32`
/// name-table offset at `@8`. At that offset sit `fontCount` packed Pascal
/// strings (`[u8 len][bytes]`) — the font face names (`Segoe UI`, `Tahoma`) plus
/// short style strings. The framing is self-consistent: reading `fontCount`
/// Pascal strings from the offset lands exactly at the block end (e.g. a 101-byte
/// FTAB has offset 72 + 4 strings = 101).
///
/// The per-font metric records between the header and the name table (size /
/// style / colour) are not yet decoded. Clean-room: version is CONFIRMED, the
/// count + names are LIKELY (self-consistent), metrics are open.
library;

import 'dart:typed_data';

/// The fixed `FTAB` header length: `u16 version@0`, two `u16` header words
/// `@2`/`@4`, `u16 fontCount@6`, `u32 nameTableOffset@8`.
const _ftabHeaderLen = 12;

/// A decoded `FTAB` font table. Byte-exact when [nameTableComplete]: the fixed
/// header, the per-font metric records (retained as the opaque [metrics] leaf),
/// and the packed Pascal-string name table together tile the block, so
/// [serialize] reproduces it.
class ViFontTable {
  const ViFontTable({
    required this.rawLength,
    required this.version,
    required this.headerWords,
    required this.fontCount,
    required this.nameTableOffset,
    required this.metrics,
    required this.nameBytes,
    required this.names,
    required this.nameTableComplete,
  });

  /// The block length in bytes.
  final int rawLength;

  /// `u16 @0` — table version (always `1` in the corpus). CONFIRMED.
  final int version;

  /// The two `u16` header words at `@2`/`@4` (retained; semantics not decoded).
  final List<int> headerWords;

  /// `u16 @6` — the number of name entries in the table. LIKELY.
  final int fontCount;

  /// `u32 @8` — byte offset of the packed Pascal-string name table. LIKELY.
  final int nameTableOffset;

  /// The per-font metric records between the header and the name table
  /// (`bytes[12..nameTableOffset)`), retained verbatim — an opaque leaf whose
  /// size/style/colour interior is not decoded.
  final Uint8List metrics;

  /// The packed name-table region (`bytes[nameTableOffset..]`), retained
  /// verbatim so re-emission is exact regardless of the names' encoding.
  final Uint8List nameBytes;

  /// The recovered name entries (font face names + short style strings), in
  /// order. LIKELY (recovered count matches [fontCount] when self-consistent).
  final List<String> names;

  /// Whether the header + metrics + name-table regions frame the block cleanly
  /// (`nameTableOffset` in range and `fontCount` Pascal strings tile
  /// `[nameTableOffset..end)` exactly). Only then is [serialize] byte-exact.
  final bool nameTableComplete;

  /// Re-emits the fixed header + metrics leaf + name-table region — the whole
  /// block. Byte-exact only when [nameTableComplete].
  Uint8List serialize() {
    final out = Uint8List(_ftabHeaderLen + metrics.length + nameBytes.length);
    final d = ByteData.sublistView(out);
    d.setUint16(0, version);
    d.setUint16(2, headerWords.isNotEmpty ? headerWords[0] : 0);
    d.setUint16(4, headerWords.length > 1 ? headerWords[1] : 0);
    d.setUint16(6, fontCount);
    d.setUint32(8, nameTableOffset);
    out.setRange(_ftabHeaderLen, _ftabHeaderLen + metrics.length, metrics);
    out.setRange(_ftabHeaderLen + metrics.length, out.length, nameBytes);
    return out;
  }
}

/// Decodes an `FTAB` body. Null when too short for the header (version + count +
/// name-table offset). Total — a bogus name-table offset yields fewer names and
/// [ViFontTable.nameTableComplete] `false` rather than a throw.
ViFontTable? decodeFontTable(Uint8List bytes) {
  if (bytes.length < _ftabHeaderLen) return null;
  final bd = ByteData.sublistView(bytes);
  final version = bd.getUint16(0);
  final headerWords = [bd.getUint16(2), bd.getUint16(4)];
  final fontCount = bd.getUint16(6);
  final nameOff = bd.getUint32(8);
  final inRange = nameOff >= _ftabHeaderLen && nameOff <= bytes.length;
  final metricsEnd = inRange ? nameOff : _ftabHeaderLen;
  final names = <String>[];
  var pos = nameOff;
  var complete = inRange;
  for (var i = 0; i < fontCount; i++) {
    if (pos >= bytes.length) {
      complete = false;
      break;
    }
    final len = bytes[pos++];
    if (pos + len > bytes.length) {
      complete = false;
      break;
    }
    names.add(String.fromCharCodes(bytes, pos, pos + len));
    pos += len;
  }
  if (complete && pos != bytes.length) complete = false;
  return ViFontTable(
    rawLength: bytes.length,
    version: version,
    headerWords: headerWords,
    fontCount: fontCount,
    nameTableOffset: nameOff,
    metrics: Uint8List.sublistView(bytes, _ftabHeaderLen, metricsEnd),
    nameBytes: Uint8List.sublistView(bytes, inRange ? nameOff : bytes.length),
    names: names,
    nameTableComplete: complete,
  );
}
