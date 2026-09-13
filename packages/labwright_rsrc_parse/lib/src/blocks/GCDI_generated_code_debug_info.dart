/// `GCDI` — generated-code debug info: a value word, a marker byte and an undecoded body.
///
/// ```text
/// offset  size  field                      type     meaning
/// 0       4     value                      u32      role TODO
/// 4       1     marker                     u8       always 1
/// 5       rest  TODO                                retained; not decoded
/// ```
///
/// [ViGcdiRecord] is a view over the payload; [decodeGcdiRecord] requires at least 5 bytes
/// with the marker byte set to 1.
library;

import 'dart:typed_data';

import '../block_layout.dart';

const _value = BlockField(0, 4, 'value', 'u32', 'role TODO');
const _marker = BlockField(4, 1, 'marker', 'u8', 'always 1');
const _body = BlockField.undecoded(5, null);

const BlockLayout gcdiLayout = [_value, _marker, _body];

/// A view over a `GCDI` payload.
class ViGcdiRecord {
  ViGcdiRecord._(this.bytes) : _view = ByteData.sublistView(bytes);

  final Uint8List bytes;

  final ByteData _view;

  int get value => _view.getUint32(_value.offset);

  Uint8List get body => Uint8List.sublistView(bytes, _body.offset);

  Uint8List serialize() => bytes;
}

ViGcdiRecord decodeGcdiRecord(Uint8List bytes) {
  assert(bytes.length >= _body.offset && bytes[_marker.offset] == 1, 'GCDI carries a value word and the marker byte 1');
  return ViGcdiRecord._(bytes);
}
