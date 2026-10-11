/// `PICC` - Kind and Rectangle Records: [ViPiccRecord]
///
/// One section per record, up to 28 in a VI: a kind word, a flag word and four i16 coordinates.
/// Kind 3 comes with horizontal spans two or four pixels wide, kind 12 with vertical ones, and
/// kinds 146 and 2 with free rectangles, not always normalised. The coordinates fall inside a
/// label or chrome object of the front panel or block diagram in half the records and match no
/// object's bounds. What the records place is TODO.
///
/// ```text
/// offset  size  field    type   meaning
/// 0       2     kind     u16    146, 3, 12, 2, 1 or 0 in the corpus.
/// 2       2     flags    u16    2306 with kind 146, 1 with kinds 3 and 12, 257 with kind 2; role TODO.
/// 4       2     top      i16
/// 6       2     left     i16
/// 8       2     bottom   i16    Below top in most records, above it in some.
/// 10      2     right    i16    Right of left in most records, left of it in some.
/// ```
library;

import 'dart:typed_data';

import '../byte_layout.dart';
import '../byte_record.dart';

final class ViPiccRecord extends ByteRecord {
  ViPiccRecord(Uint8List bytes) : super(bytes, layout);

  /// 146, 3, 12, 2, 1 or 0 in the corpus.
  int get kind => _kind.read(view);

  /// 2306 with kind 146, 1 with kinds 3 and 12, 257 with kind 2; role TODO.
  int get flags => _flags.read(view);

  int get top => _top.read(view);

  int get left => _left.read(view);

  /// Below [top] in most records, above it in some.
  int get bottom => _bottom.read(view);

  /// Right of [left] in most records, left of it in some.
  int get right => _right.read(view);

  static const _kind = U16(0);
  static const _flags = U16(2);
  static const _top = I16(4);
  static const _left = I16(6);
  static const _bottom = I16(8);
  static const _right = I16(10);

  static const layout = ByteLayout([_kind, _flags, _top, _left, _bottom, _right]);
}
