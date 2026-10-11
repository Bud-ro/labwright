/// `BFAL` - Align Table: [ViAlignTable]
///
/// A counted run of 9-byte entries pairing a rising heap offset with a value and a kind byte.
/// The name reads the tag letters as "BF align"; nothing external attests it, and the entries'
/// roles are not decoded.
///
/// ```text
/// offset  size    field    type                meaning
/// 0       4       count    u32                 Number of entries.
/// 4       9·count entries  ViAlignEntry[count] Entries of 9 bytes.
///   +0    4       unknown0                     offset? Always rises and always <= BD's inflated heap size.
///   +4    4       unknown4                     value? A u32, never zero.
///   +8    1       unknown8                     kind? Odd in 96% of entries, so possibly a bitmap.
/// ```
library;

import 'dart:typed_data';

import '../byte_layout.dart';
import '../byte_record.dart';

final class ViAlignTable extends ByteRecord {
  ViAlignTable(Uint8List bytes) : super(bytes, layout) {
    assert(_at(count) == view.lengthInBytes, 'the entries tile the payload');
  }

  /// Number of entries.
  int get count => _count.read(view);

  ViAlignEntry operator [](int index) {
    final at = _at(index);
    return ViAlignEntry(
      view.getUint32(at + ViAlignEntry._unknown0.offset),
      view.getUint32(at + ViAlignEntry._unknown4.offset),
      view.getUint8(at + ViAlignEntry._unknown8.offset),
    );
  }

  int _at(int index) => _entries.offset + ViAlignEntry.layout.size! * index;

  static const _count = U32(0);
  static const _entries = Entries(4, ViAlignEntry.layout, count: _count); // Entries of 9 bytes.

  static const layout = ByteLayout([_count, _entries]);
}

/// One entry of a [ViAlignTable]; the names are working guesses.
final class ViAlignEntry {
  const ViAlignEntry(this.offset, this.value, this.kind);

  final int offset;
  final int value;
  final int kind;

  static const _unknown0 = Unknown(0, size: 4); // offset? Always rises and always <= BD's inflated heap size.
  static const _unknown4 = Unknown(4, size: 4); // value? A u32, never zero.
  static const _unknown8 = Unknown(8, size: 1); // kind? Odd in 96% of entries, so possibly a bitmap.

  static const layout = ByteLayout([_unknown0, _unknown4, _unknown8]);
}
