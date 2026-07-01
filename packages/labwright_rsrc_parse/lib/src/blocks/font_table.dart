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

/// A decoded `FTAB` font table.
class ViFontTable {
  const ViFontTable({
    required this.rawLength,
    required this.version,
    required this.fontCount,
    required this.nameTableOffset,
    required this.names,
  });

  /// The block length in bytes.
  final int rawLength;

  /// `u16 @0` — table version (always `1` in the corpus). CONFIRMED.
  final int version;

  /// `u16 @6` — the number of name entries in the table. LIKELY.
  final int fontCount;

  /// `u32 @8` — byte offset of the packed Pascal-string name table. LIKELY.
  final int nameTableOffset;

  /// The recovered name entries (font face names + short style strings), in
  /// order. LIKELY (recovered count matches [fontCount] when self-consistent).
  final List<String> names;

}

/// Decodes an `FTAB` body. Null when too short for the header (version + count +
/// name-table offset).
ViFontTable? decodeFontTable(Uint8List b) {
  if (b.length < 12) return null;
  final bd = ByteData.sublistView(b);
  final version = bd.getUint16(0);
  final fontCount = bd.getUint16(6);
  final nameOff = bd.getUint32(8);
  final names = <String>[];
  var p = nameOff;
  for (var i = 0; i < fontCount; i++) {
    if (p >= b.length) break;
    final len = b[p];
    p++;
    if (p + len > b.length) break;
    names.add(String.fromCharCodes(b.sublist(p, p + len)));
    p += len;
  }
  return ViFontTable(
    rawLength: b.length,
    version: version,
    fontCount: fontCount,
    nameTableOffset: nameOff,
    names: names,
  );
}
