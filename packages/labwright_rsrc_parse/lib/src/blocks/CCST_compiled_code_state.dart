/// `CCST` — compiled-code state: a counted table of length-prefixed key/value byte strings.
///
/// ```text
/// offset  size  field                      type     meaning
/// 0       4     count                      u32      number of entries
/// 4       rest  entries                    entry[count] count entries, each a key then a value
///   +0    4     keyLength                  u32      bytes of key
///   +4    rest  key                        u8[keyLength] key bytes
///   +0    4     valueLength                u32      bytes of value, after key
///   +4    rest  value                      u8[valueLength] value bytes
/// ```
///
/// [ViKeyValueTable] is a view over the payload that records where each entry starts;
/// [decodeKeyValueTable] requires the entries to tile the payload exactly.
library;

import 'dart:typed_data';

import '../block_layout.dart';
import '../block_record.dart';

const _count = BlockField(0, 4, 'count', 'u32', 'number of entries');
const _keyLength = BlockField(0, 4, 'keyLength', 'u32', 'bytes of key');
const _key = BlockField(4, null, 'key', 'u8[keyLength]', 'key bytes');
const _valueLength = BlockField(0, 4, 'valueLength', 'u32', 'bytes of value, after key');
const _value = BlockField(4, null, 'value', 'u8[valueLength]', 'value bytes');
const _entries = BlockField(
  4,
  null,
  'entries',
  'entry[count]',
  'count entries, each a key then a value',
  entry: [_keyLength, _key, _valueLength, _value],
);

const BlockLayout ccstLayout = [_count, _entries];

/// A view over a `CCST` payload.
class ViKeyValueTable implements BlockRecord {
  ViKeyValueTable._(this.bytes, this._entryOffsets) : _view = ByteData.sublistView(bytes);

  final Uint8List bytes;

  final ByteData _view;

  final List<int> _entryOffsets;

  int get length => _entryOffsets.length;

  Uint8List keyAt(int index) {
    final at = _entryOffsets[index];
    return Uint8List.sublistView(bytes, at + _key.offset, at + _key.offset + _view.getUint32(at + _keyLength.offset));
  }

  Uint8List valueAt(int index) {
    final at = _entryOffsets[index] + _key.offset + _view.getUint32(_entryOffsets[index] + _keyLength.offset);
    return Uint8List.sublistView(
      bytes,
      at + _value.offset,
      at + _value.offset + _view.getUint32(at + _valueLength.offset),
    );
  }

  @override
  Uint8List serialize() => bytes;
}

ViKeyValueTable decodeKeyValueTable(Uint8List bytes) {
  assert(bytes.length >= _entries.offset, 'a key/value table starts with its count');
  final view = ByteData.sublistView(bytes);
  final count = view.getUint32(_count.offset);
  assert(count <= (bytes.length - _entries.offset) ~/ 8, 'the count fits the payload');
  final offsets = List<int>.filled(count, 0);
  var at = _entries.offset;
  for (var i = 0; i < count; i++) {
    offsets[i] = at;
    for (var field = 0; field < 2; field++) {
      assert(at + 4 <= bytes.length, 'entry $i has a length word');
      at += 4 + view.getUint32(at);
    }
  }
  assert(at == bytes.length, 'the entries tile the payload');
  return ViKeyValueTable._(bytes, offsets);
}
