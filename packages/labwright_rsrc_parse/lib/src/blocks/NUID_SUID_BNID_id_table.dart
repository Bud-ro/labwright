/// `NUID` / `SUID` / `BNID` - New, Saved and Block-Name UID Tables: [ViIdTable], [ViUidValueTable]
///
/// Counted u32 runs about block-diagram objects. `NUID` is a list of object ids led by a zero:
/// the first id is a wire and the rest are diagram objects of many classes, unsorted, about 6%
/// of the diagram. `SUID` and `BNID` are lists of (uid, value) pairs led by (0, 0): `SUID`'s
/// uids are terminal objects (kinds 0x15 and 0x16) and every terminal of one wire or node
/// carries the same value; `BNID`'s uids are wires sitting directly in a frame and its values
/// are distinct within a table. The values are small integers whose role is TODO. `SUID` and
/// `BNID` always travel together.
///
/// ```text
/// NUID:
/// offset  size    field    type       meaning
/// 0       4       count    u32        Number of ids.
/// 4       4·count ids      u32[count] Object ids; the first is always zero and the second a wire.
/// SUID / BNID:
/// offset  size    field    type       meaning
/// 0       4       count    u32        Number of words, twice the number of pairs.
/// 4       4·count words    u32[count] (uid, value) pairs; the first pair is (0, 0).
/// ```
library;

import 'dart:typed_data';

import '../byte_layout.dart';
import '../byte_record.dart';

/// `NUID`: a zero, a wire id, then block-diagram object ids.
final class ViIdTable extends ByteRecord {
  ViIdTable(Uint8List bytes) : super(bytes, layout) {
    assert(_ids.endIn(view) == view.lengthInBytes, 'the ids tile the payload');
  }

  /// Number of ids.
  int get count => _count.read(view);

  /// Object ids; the first is always zero and the second a wire.
  int operator [](int index) => _ids.at(view, index);

  static const _count = U32(0);
  static const _ids = U32List(4, count: _count);

  static const layout = ByteLayout([_count, _ids]);
}

/// `SUID` and `BNID`: (uid, value) pairs, the first (0, 0).
final class ViUidValueTable extends ByteRecord {
  ViUidValueTable(Uint8List bytes) : super(bytes, layout) {
    assert(_words.endIn(view) == view.lengthInBytes, 'the words tile the payload');
    assert(count.isEven, 'the words pair up');
  }

  /// Number of words, twice the number of pairs.
  int get count => _count.read(view);

  int get pairCount => count ~/ 2;

  ViUidValue operator [](int index) => ViUidValue(_words.at(view, 2 * index), _words.at(view, 2 * index + 1));

  static const _count = U32(0);
  static const _words = U32List(4, count: _count); // (uid, value) pairs; the first pair is (0, 0).

  static const layout = ByteLayout([_count, _words]);
}

/// One pair of a [ViUidValueTable].
final class ViUidValue {
  const ViUidValue(this.uid, this.value);

  /// A block-diagram object id.
  final int uid;

  /// A small integer; role TODO.
  final int value;
}
