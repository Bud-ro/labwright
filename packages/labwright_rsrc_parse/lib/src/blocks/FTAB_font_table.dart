/// `FTAB` - Font Table: [ViFontTable]
///
/// The fonts the heaps' text runs refer to by id: a platform word, the three predefined-font
/// slots that lead every table, one 16-byte metric record per font, then the packed Pascal
/// names, which the first record's `nameOffset` locates. Heap text runs address fonts by
/// `fontId + 3`, past the three leading slots, in every one of 171822 corpus runs. A one-character
/// name `0`, `1` or `2` refers back to one of those slots instead of naming a face.
///
/// ```text
/// offset         size         field           type                   meaning
/// 0              2            version         u16                    Always 1.
/// 2              2            platform        u16                    1 in the 522 files whose fonts are
///                                                                    Lucida Grande, 2 in the 7741 whose
///                                                                    fonts are Windows faces, 4 in the 53
///                                                                    whose fonts are System Font Regular:
///                                                                    the saving platform.
/// 4              2            predefinedSlots u16                    Always 3: the predefined slots that
///                                                                    lead the table.
/// 6              2            fontCount       u16                    Number of fonts, 4 to 14, the first
///                                                                    three being the predefined slots.
/// 8              16·fontCount records         ViFontEntry[fontCount] fontCount records of 16 bytes.
///   +0           4            nameOffset      u32                    Offset of the name within the payload.
///   +4           2            size            u16                    Point size, 15 in most entries; 0x8000
///                                                                    when unset, which a reference to a
///                                                                    predefined slot always is.
///   +6           1            flagsByte       u8                     Bit 0x04 in 55 percent of entries, bit
///                                                                    0x80 in most entries whose size is
///                                                                    unset, bit 0x02 in 174; roles TODO.
///   +7           1            styleFlags      u8                     Style bits: zero in all but 409
///                                                                    entries, which set 1, 2, 4 or 16; roles
///                                                                    TODO.
///   +8           2            weight          u16                    1000 for bold, 0 otherwise; 0x8000 when
///                                                                    unset.
///   +10          2            resolvedSize    u16                    Pixel size the run renders at, 15 for
///                                                                    Segoe UI.
///   +12          2            metricA         u16                    Rises with the pixel size and exceeds
///                                                                    metricB in all but 33 entries, 217 for
///                                                                    Segoe UI at 15 pixels; 32767 in 1341
///                                                                    unresolved entries; role TODO.
///   +14          2            metricB         u16                    Rises with the pixel size, 212 for
///                                                                    Segoe UI at 15 pixels; 1 in the
///                                                                    unresolved entries; role TODO.
/// 8+16·fontCount …            names           pstr[fontCount]        Font names, packed, in record order.
/// ```
library;

import 'dart:typed_data';

import '../byte_layout.dart';
import '../byte_record.dart';

final class ViFontTable extends ByteRecord {
  ViFontTable(Uint8List bytes) : super(bytes, layout) {
    assert(namesTile(bytes), 'each record names the next packed name and the names tile the payload');
    entries = List.generate(fontCount, (i) => ViFontEntry(this, i), growable: false);
  }

  /// Whether [bytes] hold the records, each naming the next packed name, and names that end
  /// the payload.
  static bool namesTile(Uint8List bytes) {
    final view = ByteData.sublistView(bytes);
    if (!layout.fits(bytes.length)) return false;
    final count = _fontCount.read(view);
    var at = _records.offset + ViFontEntry.recordSize * count;
    for (var i = 0; i < count; i++) {
      if (at >= bytes.length || view.getUint32(_records.offset + ViFontEntry.recordSize * i) != at) return false;
      at = PStr.endAt(view, at);
    }
    return at == bytes.length;
  }

  late final List<ViFontEntry> entries;

  /// Always 1.
  int get version => _version.read(view);

  /// 1 in the 522 files whose fonts are Lucida Grande, 2 in the 7741 whose fonts are Windows
  /// faces, 4 in the 53 whose fonts are System Font Regular: the saving platform.
  int get platform => _platform.read(view);

  /// Always 3: the predefined slots that lead the table.
  int get predefinedSlots => _predefinedSlots.read(view);

  /// Number of fonts, 4 to 14, the first three being the predefined slots.
  int get fontCount => _fontCount.read(view);

  int get nameTableOffset => _records.offset + ViFontEntry.recordSize * fontCount;

  /// Run font ids index past the three leading predefined-font slots.
  ViFontEntry? entryForRunFontId(int fontId) {
    final index = fontId + 3;
    return index >= 0 && index < entries.length ? entries[index] : null;
  }

  /// A table of [fonts] in order, each record locating its packed name.
  static Uint8List encode({
    int version = 1,
    required int platform,
    int predefinedSlots = 3,
    required List<
      ({
        String name,
        int size,
        int flagsByte,
        int styleFlags,
        int weight,
        int resolvedSize,
        int metricA,
        int metricB,
      })
    >
    fonts,
  }) {
    final namesAt = _records.offset + ViFontEntry.recordSize * fonts.length;
    final out = Uint8List(namesAt + fonts.fold(0, (sum, font) => sum + 1 + font.name.length));
    final view = ByteData.sublistView(out);
    _version.write(view, version);
    _platform.write(view, platform);
    _predefinedSlots.write(view, predefinedSlots);
    _fontCount.write(view, fonts.length);
    var nameAt = namesAt;
    for (var i = 0; i < fonts.length; i++) {
      final font = fonts[i];
      final record = ByteData.sublistView(out, _records.offset + ViFontEntry.recordSize * i);
      ViFontEntry._nameOffset.write(record, nameAt);
      ViFontEntry._size.write(record, font.size);
      ViFontEntry._flagsByte.write(record, font.flagsByte);
      ViFontEntry._styleFlags.write(record, font.styleFlags);
      ViFontEntry._weight.write(record, font.weight);
      ViFontEntry._resolvedSize.write(record, font.resolvedSize);
      ViFontEntry._metricA.write(record, font.metricA);
      ViFontEntry._metricB.write(record, font.metricB);
      nameAt = PStr.writeAt(view, nameAt, font.name);
    }
    return out;
  }

  static const _version = U16(0);
  static const _platform = U16(2);
  static const _predefinedSlots = U16(4);
  static const _fontCount = U16(6);
  static const _records = Entries(8, ViFontEntry.layout, count: _fontCount); // fontCount records of 16 bytes.
  static const _names = PStrList(24, count: _fontCount); // Font names, packed, in record order.

  static const layout = ByteLayout([_version, _platform, _predefinedSlots, _fontCount, _records, _names]);
}

/// A view over one font record of a [ViFontTable] and its name.
final class ViFontEntry {
  ViFontEntry(this.table, this.index);

  final ViFontTable table;

  final int index;

  static final int recordSize = layout.size!;

  static const int sizeUnset = 0x8000;

  static const int weightBold = 1000;

  /// Offset of the name within the payload.
  int get nameOffset => _view.getUint32(_at + _nameOffset.offset);

  /// Point size, 15 in most entries; 0x8000 when unset, which a reference to a predefined slot
  /// always is.
  int get size => _view.getUint16(_at + _size.offset);

  /// Bit 0x04 in 55 percent of entries, bit 0x80 in most entries whose size is unset, bit 0x02
  /// in 174; roles TODO.
  int get flagsByte => _view.getUint8(_at + _flagsByte.offset);

  /// Style bits: zero in all but 409 entries, which set 1, 2, 4 or 16; roles TODO.
  int get styleFlags => _view.getUint8(_at + _styleFlags.offset);

  /// 1000 for bold, 0 otherwise; 0x8000 when unset.
  int get weight => _view.getUint16(_at + _weight.offset);

  /// Pixel size the run renders at, 15 for Segoe UI.
  int get resolvedSize => _view.getUint16(_at + _resolvedSize.offset);

  /// Rises with the pixel size and exceeds [metricB] in all but 33 entries, 217 for Segoe UI at
  /// 15 pixels; 32767 in 1341 unresolved entries; role TODO.
  int get metricA => _view.getUint16(_at + _metricA.offset);

  /// Rises with the pixel size, 212 for Segoe UI at 15 pixels; 1 in the unresolved entries;
  /// role TODO.
  int get metricB => _view.getUint16(_at + _metricB.offset);

  String get name => PStr.readAt(_view, nameOffset);

  bool get isBold => weight == weightBold;

  /// A one-character name `0`, `1` or `2` refers to a predefined font instead of a face.
  bool get isPredefinedRef {
    final at = nameOffset;
    return _view.getUint8(at) == 1 && _view.getUint8(at + 1) >= 0x30 && _view.getUint8(at + 1) <= 0x32;
  }

  ByteData get _view => table.view;

  int get _at => ViFontTable._records.offset + recordSize * index;

  // dart format off
  static const _nameOffset = U32(0);
  static const _size = U16(4);
  static const _flagsByte = U8(6);
  static const _styleFlags = U8(7);
  static const _weight = U16(8);
  static const _resolvedSize = U16(10);
  static const _metricA = U16(12);
  static const _metricB = U16(14);

  static const layout = ByteLayout([_nameOffset, _size, _flagsByte, _styleFlags, _weight, _resolvedSize, _metricA, _metricB]);
  // dart format on
}
