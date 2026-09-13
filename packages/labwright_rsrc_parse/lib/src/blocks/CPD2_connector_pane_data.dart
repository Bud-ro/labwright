/// `CPD2` — connector-pane data: one u16.
///
/// ```text
/// offset  size  field                      type     meaning
/// 0       2     value                      u16      role TODO
/// ```
///
/// [ViConnectorPaneData] is a view over the payload; [decodeCpd2Record] requires exactly
/// 2 bytes.
library;

import 'dart:typed_data';

import '../block_layout.dart';
import '../block_record.dart';

const _value = BlockField(0, 2, 'value', 'u16', 'role TODO');

const BlockLayout cpd2Layout = [_value];

/// A view over a `CPD2` payload.
class ViConnectorPaneData implements BlockRecord {
  ViConnectorPaneData._(this.bytes) : _view = ByteData.sublistView(bytes);

  final Uint8List bytes;

  final ByteData _view;

  int get value => _view.getUint16(_value.offset);

  @override
  Uint8List serialize() => bytes;
}

ViConnectorPaneData decodeCpd2Record(Uint8List bytes) {
  assert(bytes.length == _value.end, 'CPD2 is one u16');
  return ViConnectorPaneData._(bytes);
}
