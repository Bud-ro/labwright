/// `MUID` — modified UID: one u32.
///
/// ```text
/// offset  size  field                      type     meaning
/// 0       4     value                      u32      the UID
/// ```
///
/// [ViModifiedUid] is a view over the payload; [decodeModifiedUid] requires exactly 4 bytes.
library;

import 'dart:typed_data';

import '../block_layout.dart';

const _value = BlockField(0, 4, 'value', 'u32', 'the UID');

const BlockLayout muidLayout = [_value];

/// A view over an `MUID` payload.
class ViModifiedUid {
  ViModifiedUid._(this.bytes) : _view = ByteData.sublistView(bytes);

  final Uint8List bytes;

  final ByteData _view;

  int get value => _view.getUint32(_value.offset);

  Uint8List serialize() => bytes;
}

ViModifiedUid decodeModifiedUid(Uint8List bytes) {
  assert(bytes.length == _value.end, 'MUID is one u32');
  return ViModifiedUid._(bytes);
}
