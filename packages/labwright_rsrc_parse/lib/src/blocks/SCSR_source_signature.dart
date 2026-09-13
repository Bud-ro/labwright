/// `SCSR` — source signature: a marker word followed by a 16-byte digest.
///
/// ```text
/// offset  size  field                      type     meaning
/// 0       4     marker                     u32      role TODO
/// 4       16    digest                     u8[16]   signature digest; derivation TODO
/// ```
///
/// [ViSourceSignature] is a view over the payload; [decodeSourceSignature] requires exactly
/// 20 bytes.
library;

import 'dart:typed_data';

import '../block_layout.dart';

const _marker = BlockField(0, 4, 'marker', 'u32', 'role TODO');
const _digest = BlockField(4, 16, 'digest', 'u8[16]', 'signature digest; derivation TODO');

const BlockLayout scsrLayout = [_marker, _digest];

/// A view over an `SCSR` payload.
class ViSourceSignature {
  ViSourceSignature._(this.bytes) : _view = ByteData.sublistView(bytes);

  final Uint8List bytes;

  final ByteData _view;

  int get marker => _view.getUint32(_marker.offset);

  Uint8List get digest => Uint8List.sublistView(bytes, _digest.offset, _digest.end);

  Uint8List serialize() => bytes;
}

ViSourceSignature decodeSourceSignature(Uint8List bytes) {
  assert(bytes.length == _digest.end, 'SCSR is a marker word and a 16-byte digest');
  return ViSourceSignature._(bytes);
}
