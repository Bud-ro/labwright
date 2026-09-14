/// `FTAB` — font table: the fonts the heaps' text runs refer to by id, one 16-byte metric
/// record per font followed by the packed Pascal names.
///
/// The first record's `nameOffset` doubles as the offset of the name table, so the header
/// is 8 bytes and the records begin at 8. Heap text runs address fonts by `fontId + 3`,
/// the three leading slots being the predefined application, system and dialog fonts.
///
/// ```text
/// offset  size  field                      type     meaning
/// 0       2     version                    u16      table format version
/// 2       2     TODO                       u16      retained; not decoded
/// 4       2     TODO                       u16      retained; not decoded
/// 6       2     fontCount                  u16      number of fonts
/// 8       rest  records                    entry[fontCount] fontCount records of 16 bytes
///   +0    4     nameOffset                 u32      offset of the name within the payload
///   +4    2     size                       u16      point size; 0x8000 when unset
///   +6    1     flagsByte                  u8       role TODO
///   +7    1     styleFlags                 u8       style bits; roles TODO
///   +8    2     weight                     u16      weight, 1000 for bold
///   +10   2     resolvedSize               u16      pixel size the run renders at
///   +12   2     metricA                    u16      role TODO
///   +14   2     metricB                    u16      role TODO
/// …       rest  names                      pstr[fontCount] font names, packed, in record order
/// ```
///
/// [ViFontTable] is a view over the payload; each [ViFontEntry] is a view over one record
/// and its name; [decodeFontTable] requires the records and names to tile the payload.
library;

import 'dart:typed_data';

import '../block_layout.dart';
import '../block_record.dart';

const _version = BlockField(0, 2, 'version', 'u16', 'table format version');
const _word2 = BlockField.undecoded(2, 2, type: 'u16');
const _word4 = BlockField.undecoded(4, 2, type: 'u16');
const _fontCount = BlockField(6, 2, 'fontCount', 'u16', 'number of fonts');
const _nameOffset = BlockField(0, 4, 'nameOffset', 'u32', 'offset of the name within the payload');
const _size = BlockField(4, 2, 'size', 'u16', 'point size; 0x8000 when unset');
const _flagsByte = BlockField(6, 1, 'flagsByte', 'u8', 'role TODO');
const _styleFlags = BlockField(7, 1, 'styleFlags', 'u8', 'style bits; roles TODO');
const _weight = BlockField(8, 2, 'weight', 'u16', 'weight, 1000 for bold');
const _resolvedSize = BlockField(10, 2, 'resolvedSize', 'u16', 'pixel size the run renders at');
const _metricA = BlockField(12, 2, 'metricA', 'u16', 'role TODO');
const _metricB = BlockField(14, 2, 'metricB', 'u16', 'role TODO');
const _records = BlockField(
  8,
  null,
  'records',
  'entry[fontCount]',
  'fontCount records of 16 bytes',
  entry: [_nameOffset, _size, _flagsByte, _styleFlags, _weight, _resolvedSize, _metricA, _metricB],
);
const _names = BlockField(24, null, 'names', 'pstr[fontCount]', 'font names, packed, in record order');

const _recordSize = 16;

const BlockLayout ftabLayout = [_version, _word2, _word4, _fontCount, _records, _names];

/// A view over one font record of a [ViFontTable] and its name.
class ViFontEntry {
  ViFontEntry._(this.table, this.index);

  final ViFontTable table;

  final int index;

  int get _at => _records.offset + _recordSize * index;

  int get nameOffset => table._view.getUint32(_at + _nameOffset.offset);

  int get size => table._view.getUint16(_at + _size.offset);

  int get flagsByte => table.bytes[_at + _flagsByte.offset];

  int get styleFlags => table.bytes[_at + _styleFlags.offset];

  int get weight => table._view.getUint16(_at + _weight.offset);

  int get resolvedSize => table._view.getUint16(_at + _resolvedSize.offset);

  int get metricA => table._view.getUint16(_at + _metricA.offset);

  int get metricB => table._view.getUint16(_at + _metricB.offset);

  String get name => String.fromCharCodes(table.bytes, nameOffset + 1, nameOffset + 1 + table.bytes[nameOffset]);

  static const int sizeUnset = 0x8000;

  static const int weightBold = 1000;

  bool get isBold => weight == weightBold;

  /// A one-character name `0`, `1` or `2` refers to a predefined font instead of a face.
  bool get isPredefinedRef {
    final at = nameOffset;
    return table.bytes[at] == 1 && table.bytes[at + 1] >= 0x30 && table.bytes[at + 1] <= 0x32;
  }
}

/// A view over an `FTAB` payload.
class ViFontTable implements BlockRecord {
  ViFontTable._(this.bytes) : _view = ByteData.sublistView(bytes) {
    entries = List.generate(fontCount, (i) => ViFontEntry._(this, i), growable: false);
  }

  final Uint8List bytes;

  final ByteData _view;

  late final List<ViFontEntry> entries;

  int get version => _view.getUint16(_version.offset);

  int get fontCount => _view.getUint16(_fontCount.offset);

  int get nameTableOffset => _records.offset + _recordSize * fontCount;

  /// Run font ids index past the three leading predefined-font slots.
  ViFontEntry? entryForRunFontId(int fontId) {
    final index = fontId + 3;
    return index >= 0 && index < entries.length ? entries[index] : null;
  }

  @override
  Uint8List serialize() => bytes;
}

ViFontTable decodeFontTable(Uint8List bytes) {
  assert(bytes.length >= _records.offset, 'a font table starts with its 8-byte header');
  final view = ByteData.sublistView(bytes);
  final count = view.getUint16(_fontCount.offset);
  var at = _records.offset + _recordSize * count;
  assert(at <= bytes.length, 'the records fit the payload');
  for (var i = 0; i < count; i++) {
    assert(view.getUint32(_records.offset + _recordSize * i) == at, 'record $i names the next packed name');
    assert(at < bytes.length, 'name $i has a length byte');
    at += 1 + bytes[at];
  }
  assert(at == bytes.length, 'the names tile the payload');
  return ViFontTable._(bytes);
}
