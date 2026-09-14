/// `PICC` — icon placement: two words and a rectangle, one section per placed icon.
///
/// ```text
/// offset  size  field                      type     meaning
/// 0       2     TODO                       u16      retained; not decoded
/// 2       2     TODO                       u16      retained; not decoded
/// 4       2     top                        i16      rectangle top
/// 6       2     left                       i16      rectangle left
/// 8       2     bottom                     i16      rectangle bottom
/// 10      2     right                      i16      rectangle right
/// ```
///
/// [ViIconPlacement] is a view over the payload; [decodeIconPlacement] requires exactly
/// 12 bytes.
library;

import 'dart:typed_data';

import '../block_layout.dart';
import '../block_record.dart';

const _todo0 = BlockField.undecoded(0, 2, type: 'u16');
const _todo2 = BlockField.undecoded(2, 2, type: 'u16');
const _top = BlockField(4, 2, 'top', 'i16', 'rectangle top');
const _left = BlockField(6, 2, 'left', 'i16', 'rectangle left');
const _bottom = BlockField(8, 2, 'bottom', 'i16', 'rectangle bottom');
const _right = BlockField(10, 2, 'right', 'i16', 'rectangle right');

const BlockLayout piccLayout = [_todo0, _todo2, _top, _left, _bottom, _right];

/// A view over a `PICC` payload.
class ViIconPlacement implements BlockRecord {
  ViIconPlacement._(this.bytes) : _view = ByteData.sublistView(bytes);

  final Uint8List bytes;

  final ByteData _view;

  int get top => _view.getInt16(_top.offset);

  int get left => _view.getInt16(_left.offset);

  int get bottom => _view.getInt16(_bottom.offset);

  int get right => _view.getInt16(_right.offset);

  @override
  Uint8List serialize() => bytes;
}

ViIconPlacement decodeIconPlacement(Uint8List bytes) {
  assert(bytes.length == _right.end, 'PICC is six u16 words');
  return ViIconPlacement._(bytes);
}
