/// `CPST` / `CPSP` — boolean text tables: a counted run of Pascal strings.
///
/// ```text
/// offset  size  field                      type     meaning
/// 0       4     count                      u32      number of strings
/// 4       rest  strings                    pstr[count] the strings
/// ```
///
/// [ViPascalStringTable] is a view over the payload that records where each string starts;
/// [decodePascalStringTable] requires the strings to tile the payload exactly.
library;

import 'dart:typed_data';

import '../block_layout.dart';
import '../block_record.dart';

const _count = BlockField(0, 4, 'count', 'u32', 'number of strings');
const _strings = BlockField(4, null, 'strings', 'pstr[count]', 'the strings');

const BlockLayout pascalStringTableLayout = [_count, _strings];

/// A view over a `CPST` or `CPSP` payload.
class ViPascalStringTable implements BlockRecord {
  const ViPascalStringTable._(this.bytes, this._stringOffsets);

  final Uint8List bytes;

  final List<int> _stringOffsets;

  int get length => _stringOffsets.length;

  Uint8List operator [](int index) {
    final at = _stringOffsets[index];
    return Uint8List.sublistView(bytes, at + 1, at + 1 + bytes[at]);
  }

  String textAt(int index) => String.fromCharCodes(this[index]);

  @override
  Uint8List serialize() => bytes;
}

ViPascalStringTable decodePascalStringTable(Uint8List bytes) {
  assert(bytes.length >= _strings.offset, 'a string table starts with its count');
  final count = ByteData.sublistView(bytes).getUint32(_count.offset);
  assert(count <= bytes.length - _strings.offset, 'the count fits the payload');
  final offsets = List<int>.filled(count, 0);
  var at = _strings.offset;
  for (var i = 0; i < count; i++) {
    assert(at < bytes.length, 'string $i has a length byte');
    offsets[i] = at;
    at += 1 + bytes[at];
  }
  assert(at == bytes.length, 'the strings tile the payload');
  return ViPascalStringTable._(bytes, offsets);
}
