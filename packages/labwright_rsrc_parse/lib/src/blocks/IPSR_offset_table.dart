/// `IPSR` — a non-decreasing run of u32 offsets.
///
/// ```text
/// offset  size  field                      type     meaning
/// 0       rest  offsets                    u32[]    non-decreasing offsets; target TODO
/// ```
///
/// [ViOffsetTable] is a view over the payload; [decodeOffsetTable] requires a whole number
/// of u32 words, possibly none, that never decrease.
library;

import 'dart:typed_data';

import '../block_layout.dart';
import '../block_record.dart';

const _offsets = BlockField(0, null, 'offsets', 'u32[]', 'non-decreasing offsets; target TODO');

const BlockLayout ipsrLayout = [_offsets];

/// A view over an `IPSR` payload.
class ViOffsetTable implements BlockRecord {
  ViOffsetTable._(this.bytes) : _view = ByteData.sublistView(bytes);

  final Uint8List bytes;

  final ByteData _view;

  int get length => bytes.length ~/ 4;

  int operator [](int index) => _view.getUint32(4 * index);

  @override
  Uint8List serialize() => bytes;
}

ViOffsetTable decodeOffsetTable(Uint8List bytes) {
  assert(bytes.length % 4 == 0, 'an offset table is a run of u32 words');
  assert(() {
    final view = ByteData.sublistView(bytes);
    for (var at = 4; at < bytes.length; at += 4) {
      if (view.getUint32(at) < view.getUint32(at - 4)) return false;
    }
    return true;
  }(), 'the offsets never decrease');
  return ViOffsetTable._(bytes);
}
