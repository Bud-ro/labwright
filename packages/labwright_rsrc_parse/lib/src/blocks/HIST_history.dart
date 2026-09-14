/// `HIST` — revision history record: the format version and the number of revision
/// entries kept for the VI.
///
/// ```text
/// offset  size  field                      type     meaning
/// 0       4     formatVersion              u32      history record format version
/// 4       4     flags                      u32      history settings; bits TODO
/// 8       4     entryCount                 u32      revision entries recorded
/// 12      4     reserved                   u32      zero
/// 16      12    TODO                       u32[3]   retained; not decoded
/// 28      8     reserved                   u32[2]   zero
/// 36      4     TODO                       u32      retained; not decoded
/// ```
///
/// [ViHistory] is a view over the payload; [decodeHistory] requires exactly 40 bytes.
library;

import 'dart:typed_data';

import '../block_layout.dart';

const _formatVersion = BlockField(0, 4, 'formatVersion', 'u32', 'history record format version');
const _flags = BlockField(4, 4, 'flags', 'u32', 'history settings; bits TODO');
const _entryCount = BlockField(8, 4, 'entryCount', 'u32', 'revision entries recorded');
const _reserved12 = BlockField(12, 4, 'reserved', 'u32', 'zero');
const _todo16 = BlockField.undecoded(16, 12, type: 'u32[3]');
const _reserved28 = BlockField(28, 8, 'reserved', 'u32[2]', 'zero');
const _todo36 = BlockField.undecoded(36, 4, type: 'u32');

const BlockLayout histLayout = [_formatVersion, _flags, _entryCount, _reserved12, _todo16, _reserved28, _todo36];

/// A view over a `HIST` payload.
class ViHistory {
  ViHistory._(this.bytes) : _view = ByteData.sublistView(bytes);

  final Uint8List bytes;

  final ByteData _view;

  int get formatVersion => _view.getUint32(_formatVersion.offset);

  int get flags => _view.getUint32(_flags.offset);

  int get entryCount => _view.getUint32(_entryCount.offset);

  bool get reservedAreZero =>
      _view.getUint32(_reserved12.offset) == 0 &&
      _view.getUint32(_reserved28.offset) == 0 &&
      _view.getUint32(_reserved28.offset + 4) == 0;

  Uint8List serialize() => bytes;
}

ViHistory decodeHistory(Uint8List bytes) {
  assert(bytes.length == _todo36.end, 'HIST is a 40-byte record');
  return ViHistory._(bytes);
}
