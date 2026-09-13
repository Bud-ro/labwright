/// `TRec` — type record: a 72-byte header followed by length-prefixed text runs to the end of
/// the payload.
///
/// ```text
/// offset  size  field                      type     meaning
/// 0       72    TODO                                retained; not decoded
/// 72      rest  runs                       entry[]  runs to the end of the payload
///   +0    4     runLength                  u32      bytes of text
///   +4    rest  text                       u8[runLength] text bytes
/// ```
///
/// [ViTextRecord] is a view over the payload that records where each run starts;
/// [decodeTextRecord] requires the header and the runs to tile the payload exactly.
library;

import 'dart:typed_data';

import '../block_layout.dart';

const _header = BlockField.undecoded(0, 72);
const _runLength = BlockField(0, 4, 'runLength', 'u32', 'bytes of text');
const _runText = BlockField(4, null, 'text', 'u8[runLength]', 'text bytes');
const _runs = BlockField(72, null, 'runs', 'entry[]', 'runs to the end of the payload', entry: [_runLength, _runText]);

const BlockLayout trecLayout = [_header, _runs];

/// A view over a `TRec` payload.
class ViTextRecord {
  ViTextRecord._(this.bytes, this._runOffsets) : _view = ByteData.sublistView(bytes);

  final Uint8List bytes;

  final ByteData _view;

  final List<int> _runOffsets;

  Uint8List get header => Uint8List.sublistView(bytes, _header.offset, _header.end);

  int get runCount => _runOffsets.length;

  Uint8List runAt(int index) {
    final at = _runOffsets[index];
    return Uint8List.sublistView(
      bytes,
      at + _runText.offset,
      at + _runText.offset + _view.getUint32(at + _runLength.offset),
    );
  }

  Uint8List serialize() => bytes;
}

ViTextRecord decodeTextRecord(Uint8List bytes) {
  assert(bytes.length >= _header.end, 'a type record starts with its 72-byte header');
  final view = ByteData.sublistView(bytes);
  final offsets = <int>[];
  var at = _runs.offset;
  while (at < bytes.length) {
    assert(at + 4 <= bytes.length, 'run ${offsets.length} has a length word');
    offsets.add(at);
    at += 4 + view.getUint32(at);
  }
  assert(at == bytes.length, 'the runs tile the payload');
  return ViTextRecord._(bytes, offsets);
}
