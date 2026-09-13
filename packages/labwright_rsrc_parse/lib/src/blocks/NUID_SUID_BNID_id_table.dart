/// `NUID` / `SUID` / `BNID` — new, saved and block-name id tables: a counted run of u32 ids.
///
/// ```text
/// offset  size  field                      type     meaning
/// 0       4     count                      u32      number of ids
/// 4       rest  ids                        u32[count] the ids; roles TODO
/// ```
///
/// [ViIdTable] is a view over the payload; [decodeIdTable] requires the count to tile the
/// payload exactly.
library;

import 'dart:typed_data';

import '../block_layout.dart';

const _count = BlockField(0, 4, 'count', 'u32', 'number of ids');
const _ids = BlockField(4, null, 'ids', 'u32[count]', 'the ids; roles TODO');

const BlockLayout idTableLayout = [_count, _ids];

/// A view over an `NUID`, `SUID` or `BNID` payload.
class ViIdTable {
  ViIdTable._(this.bytes) : _view = ByteData.sublistView(bytes);

  final Uint8List bytes;

  final ByteData _view;

  int get count => _view.getUint32(_count.offset);

  int operator [](int index) => _view.getUint32(_ids.offset + 4 * index);

  Uint8List serialize() => bytes;
}

ViIdTable decodeIdTable(Uint8List bytes) {
  assert(bytes.length >= _ids.offset, 'an id table starts with its count');
  assert(
    _ids.offset + 4 * ByteData.sublistView(bytes).getUint32(_count.offset) == bytes.length,
    'the ids tile the payload',
  );
  return ViIdTable._(bytes);
}
