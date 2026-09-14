/// `BFAL` — align table: a counted run of 9-byte entries pairing an offset with a value and
/// a kind byte.
///
/// ```text
/// offset  size  field                      type     meaning
/// 0       4     count                      u32      number of entries
/// 4       rest  entries                    entry[count] count entries of 9 bytes
///   +0    4     offset                     u32      role TODO
///   +4    4     value                      u32      role TODO
///   +8    1     kind                       u8       role TODO
/// ```
///
/// [ViAlignTable] is a view over the payload; [decodeAlignTable] requires the count to tile
/// the payload exactly.
library;

import 'dart:typed_data';

import '../block_layout.dart';
import '../block_record.dart';

const _count = BlockField(0, 4, 'count', 'u32', 'number of entries');
const _entryOffset = BlockField(0, 4, 'offset', 'u32', 'role TODO');
const _entryValue = BlockField(4, 4, 'value', 'u32', 'role TODO');
const _entryKind = BlockField(8, 1, 'kind', 'u8', 'role TODO');
const _entries = BlockField(
  4,
  null,
  'entries',
  'entry[count]',
  'count entries of 9 bytes',
  entry: [_entryOffset, _entryValue, _entryKind],
);

const _entrySize = 9;

const BlockLayout bfalLayout = [_count, _entries];

/// A view over a `BFAL` payload.
class ViAlignTable implements BlockRecord {
  ViAlignTable._(this.bytes) : _view = ByteData.sublistView(bytes);

  final Uint8List bytes;

  final ByteData _view;

  int get count => _view.getUint32(_count.offset);

  int _at(int index) => _entries.offset + _entrySize * index;

  int offsetAt(int index) => _view.getUint32(_at(index) + _entryOffset.offset);

  int valueAt(int index) => _view.getUint32(_at(index) + _entryValue.offset);

  int kindAt(int index) => bytes[_at(index) + _entryKind.offset];

  @override
  Uint8List serialize() => bytes;
}

ViAlignTable decodeAlignTable(Uint8List bytes) {
  assert(bytes.length >= _entries.offset, 'an align table starts with its count');
  assert(
    _entries.offset + _entrySize * ByteData.sublistView(bytes).getUint32(_count.offset) == bytes.length,
    'the entries tile the payload',
  );
  return ViAlignTable._(bytes);
}
