/// Decoder for the `FTAB` block — the VI's **font table**.
///
/// Corpus finding (322 sections): the block opens with three `u16` header
/// words `1, 2, 3` (322/322), a `u16 fontCount` at `@6`, then `fontCount`
/// 16-byte font records at `@8`, then `fontCount` packed Pascal strings
/// (`[u8 len][bytes]`) — the font names — tiling exactly to the block end
/// (322/322). Each record opens with the `u32` byte offset of its own name,
/// so record 0's `u32` doubles as the name-table offset ([nameTableOffset])
/// and the framing is self-checking.
///
/// Format documentation: the pylabview wiki's Font-Table-Format page
/// (https://github.com/mefistotelis/pylabview/wiki/Font-Table-Format)
/// describes the same 16-byte entries (it labels the leading `u32` "Font ID";
/// corpus probing shows the value is the name offset). Names are either real
/// typeface names (`Segoe UI`, `Tahoma`, `Arial`) or a single ASCII digit
/// `0`/`1`/`2` referencing the predefined application/system/dialog font.
///
/// Clean-room: header words + count + record framing + names are CONFIRMED
/// (corpus-exact); record field semantics per [ViFontEntry] docs.
library;

import 'dart:typed_data';

/// The fixed `FTAB` header length: three `u16` header words `1, 2, 3` at
/// `@0`/`@2`/`@4`, then `u16 fontCount@6`, `u32 nameTableOffset@8` (the
/// latter being record 0's name-offset word — see [ViFontEntry.nameOffset]).
const _ftabHeaderLen = 12;

/// Byte length of one font record ([ViFontEntry]).
const _ftabRecordLen = 16;

/// One 16-byte font record of an `FTAB` table.
///
/// Layout (offsets within the record):
///  * `u32 @0`  — [nameOffset]: block offset of this font's Pascal name.
///  * `u16 @4`  — [size]: point/pixel size, or `0x8000` when unset (the
///    entry inherits the predefined font's size). CONFIRMED (0x8000 rows
///    always carry a digit name referencing a predefined font).
///  * `u8 @6`   — [flagsByte]: corpus values 0x04/0x84/0x00/0x80; the 0x80
///    bit tracks size-unset rows. Semantics not decoded. // TODO(labwright)
///  * `u8 @7`   — [styleFlags]: 0x02 italic, 0x04 underline (per the wiki's
///    style-mask table; corpus shows only 0/2/4). LIKELY.
///  * `u16 @8`  — [weight]: 1000 on bold rows, 0 plain, `0x8000` unset.
///  * `u16 @10` — [resolvedSize]: the concrete size (equals [size] when set;
///    filled in for unset rows, 15 dominant — the default UI font).
///  * `u16 @12`/`u16 @14` — [metricA]/[metricB]: grow with size and weight
///    (line-height/extent-shaped); semantics not decoded. // TODO(labwright)
class ViFontEntry {
  const ViFontEntry({
    required this.nameOffset,
    required this.size,
    required this.flagsByte,
    required this.styleFlags,
    required this.weight,
    required this.resolvedSize,
    required this.metricA,
    required this.metricB,
    required this.name,
  });

  /// `u32 @0` — block offset of this font's Pascal name string. CONFIRMED
  /// (indexes the packed name table exactly, 322/322 sections).
  final int nameOffset;

  /// `u16 @4` — requested size; [sizeUnset] when `0x8000`.
  final int size;

  /// `u8 @6` — flag byte (0x04/0x84/0x00/0x80 observed); not decoded.
  final int flagsByte;

  /// `u8 @7` — style flag bits (0x02 italic, 0x04 underline). LIKELY.
  final int styleFlags;

  /// `u16 @8` — weight word (1000 bold, 0 plain, `0x8000` unset).
  final int weight;

  /// `u16 @10` — the concrete size the entry resolves to.
  final int resolvedSize;

  /// `u16 @12` — undecoded metric word (scales with size/weight).
  final int metricA;

  /// `u16 @14` — undecoded metric word (scales with size/weight).
  final int metricB;

  /// The font's name from the packed name table: a typeface name
  /// (`Segoe UI`) or an ASCII digit `0`/`1`/`2` naming a predefined
  /// application/system/dialog font.
  final String name;

  /// The [size]/[weight] sentinel meaning "unset — inherit the predefined
  /// font's value".
  static const int sizeUnset = 0x8000;

  /// The [weight] word value of a bold entry (`1000`; `0` plain, [sizeUnset]
  /// unset-inherit).
  static const int weightBold = 1000;

  /// Whether this entry renders bold ([weight] == [weightBold]). Corpus
  /// (7,523 `FTAB` tables, 38,655 entries): 1,720 bold — the only other
  /// weight words are `0` (23,563 plain) and [sizeUnset] (13,372
  /// inherit-the-predefined-font), so the word is a three-value field here,
  /// not a graded weight scale. 1,333 of the bold entries also name a
  /// predefined font ([isPredefinedRef]) — bold rides the reference.
  bool get isBold => weight == weightBold;

  /// Whether [name] is a predefined-font digit (`0` application / `1` system
  /// / `2` dialog) rather than a real typeface name. Corpus (38,655 entries):
  /// 14,705 predefined refs — `0` 9,524, `2` 3,135, `1` 2,046, no other digit
  /// — and 23,950 typeface names, led by `Segoe UI` (17,105),
  /// `Microsoft YaHei UI` (2,949), `Lucida Grande` (1,560), `Tahoma` (1,085),
  /// `Arial` (675) and `Calibri` (425).
  bool get isPredefinedRef => name.length == 1 && name.codeUnitAt(0) >= 0x30 && name.codeUnitAt(0) <= 0x32;
}

/// A decoded `FTAB` font table. Byte-exact when [nameTableComplete]: the fixed
/// header, the per-font records (retained as the [metrics] leaf), and the
/// packed Pascal-string name table together tile the block, so [serialize]
/// reproduces it.
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
    required this.entries,
    required this.nameTableComplete,
  });

  /// The block length in bytes.
  final int rawLength;

  /// `u16 @0` — first header word (always `1` in the corpus). CONFIRMED.
  final int version;

  /// The two `u16` header words at `@2`/`@4` (always `2, 3` in the corpus;
  /// retained verbatim).
  final List<int> headerWords;

  /// `u16 @6` — the number of font records / name entries. CONFIRMED.
  final int fontCount;

  /// `u32 @8` — byte offset of the packed Pascal-string name table; this is
  /// record 0's [ViFontEntry.nameOffset] word, and equals
  /// `12 + 16 * (fontCount - 1) + 12` (records tile `[8..offset)`). CONFIRMED.
  final int nameTableOffset;

  /// The record bytes between the header and the name table
  /// (`bytes[12..nameTableOffset)`), retained verbatim so [serialize] is
  /// byte-exact even for a malformed table. The decoded view is [entries].
  final Uint8List metrics;

  /// The packed name-table region (`bytes[nameTableOffset..]`), retained
  /// verbatim so re-emission is exact regardless of the names' encoding.
  final Uint8List nameBytes;

  /// The recovered name entries, in record order. CONFIRMED (tile the name
  /// region exactly when [nameTableComplete]).
  final List<String> names;

  /// The decoded 16-byte font records, in order — empty when the record
  /// region does not tile as `fontCount` records ending at [nameTableOffset].
  final List<ViFontEntry> entries;

  /// Whether the header + records + name-table regions frame the block cleanly
  /// (`nameTableOffset` in range and [fontCount] Pascal strings tile
  /// `[nameTableOffset..end)` exactly). Only then is [serialize] byte-exact.
  final bool nameTableComplete;

  /// The entry a heap text run's font id (the raw-`0x028` u8 inside a
  /// tag-`0x25` run group) selects: entry `[fontId + 3]`, past the three
  /// leading predefined application/system/dialog slots every corpus table
  /// opens with. Null when the id falls outside the table (the label then
  /// keeps the default face).
  ///
  /// Pixel-validated against 8 snippet references where byte-identical run
  /// records render differently per VI: MD5/Excel id 1 → a weight-1000
  /// entry (their bold headings); fg/large/PNG-CRC32 id 1 → an
  /// inherit-app-font entry (regular); crc32_lookup_table id 2 → a
  /// 21 px weight-1000 entry (its large bold heading) while VI Tree's id 2
  /// → an inherit entry (regular); Read VI Blocks id 3 → its
  /// `Courier New` entry (the monospace table label); Page1/Pages id 0 →
  /// entry [3] (default face).
  ViFontEntry? entryForRunFontId(int fontId) {
    final index = fontId + 3;
    return index >= 0 && index < entries.length ? entries[index] : null;
  }

  /// Re-emits the fixed header + record leaf + name-table region — the whole
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

/// Decodes an `FTAB` body. Null when too short for the header (words + count +
/// first record's name-offset word). Total — a bogus name-table offset yields
/// fewer names, no [ViFontTable.entries], and [ViFontTable.nameTableComplete]
/// `false` rather than a throw.
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
  // Records tile [8..nameOff) as fontCount 16-byte entries; decode them only
  // when that framing (and the name walk) holds exactly.
  const recordsStart = _ftabHeaderLen - 4;
  final entries = <ViFontEntry>[];
  if (complete && names.length == fontCount && nameOff == recordsStart + fontCount * _ftabRecordLen) {
    for (var i = 0; i < fontCount; i++) {
      final off = recordsStart + i * _ftabRecordLen;
      entries.add(
        ViFontEntry(
          nameOffset: bd.getUint32(off),
          size: bd.getUint16(off + 4),
          flagsByte: bd.getUint8(off + 6),
          styleFlags: bd.getUint8(off + 7),
          weight: bd.getUint16(off + 8),
          resolvedSize: bd.getUint16(off + 10),
          metricA: bd.getUint16(off + 12),
          metricB: bd.getUint16(off + 14),
          name: names[i],
        ),
      );
    }
  }
  return ViFontTable(
    rawLength: bytes.length,
    version: version,
    headerWords: headerWords,
    fontCount: fontCount,
    nameTableOffset: nameOff,
    metrics: Uint8List.sublistView(bytes, _ftabHeaderLen, metricsEnd),
    nameBytes: Uint8List.sublistView(bytes, inRange ? nameOff : bytes.length),
    names: names,
    entries: entries,
    nameTableComplete: complete,
  );
}
