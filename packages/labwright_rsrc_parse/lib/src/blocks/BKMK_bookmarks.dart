/// `BKMK` — bookmarks: two counted tables of text entries, the first with an extra word per
/// entry.
///
/// ```text
/// offset  size  field                      type     meaning
/// 0       4     countA                     u32      entries in table A
/// 4       rest  tableA                     entry[countA] countA entries
///   +0    4     wordA                      u32      role TODO
///   +4    4     wordB                      u32      role TODO
///   +8    4     textLength                 u32      bytes of text
///   +12   rest  text                       u8[textLength] text bytes
/// …       4     countB                     u32      entries in table B, after table A
/// …       rest  tableB                     entry[countB] countB entries
///   +0    4     wordB                      u32      role TODO
///   +4    4     textLength                 u32      bytes of text
///   +8    rest  text                       u8[textLength] text bytes
/// ```
///
/// [ViBookmarkList] holds a [ViBookmarkTable] view over each table; [decodeBookmarkList]
/// requires the two tables to tile the payload exactly.
library;

import 'dart:typed_data';

import '../block_layout.dart';

const _countA = BlockField(0, 4, 'countA', 'u32', 'entries in table A');
const _wordA = BlockField(0, 4, 'wordA', 'u32', 'role TODO');
const _wordB = BlockField(4, 4, 'wordB', 'u32', 'role TODO');
const _textLength = BlockField(8, 4, 'textLength', 'u32', 'bytes of text');
const _text = BlockField(12, null, 'text', 'u8[textLength]', 'text bytes');
const _tableA = BlockField(
  4,
  null,
  'tableA',
  'entry[countA]',
  'countA entries',
  entry: [_wordA, _wordB, _textLength, _text],
);
const _countB = BlockField(4, 4, 'countB', 'u32', 'entries in table B, after table A');
const _bWordB = BlockField(0, 4, 'wordB', 'u32', 'role TODO');
const _bTextLength = BlockField(4, 4, 'textLength', 'u32', 'bytes of text');
const _bText = BlockField(8, null, 'text', 'u8[textLength]', 'text bytes');
const _tableB = BlockField(
  8,
  null,
  'tableB',
  'entry[countB]',
  'countB entries',
  entry: [_bWordB, _bTextLength, _bText],
);

const BlockLayout bkmkLayout = [_countA, _tableA, _countB, _tableB];

/// A view over one bookmark table.
class ViBookmarkTable {
  ViBookmarkTable._(this.bytes, this._entryOffsets, this.hasWordA) : _view = ByteData.sublistView(bytes);

  final Uint8List bytes;

  final ByteData _view;

  final List<int> _entryOffsets;

  /// True for table A, whose entries start with `wordA`.
  final bool hasWordA;

  int get _headBytes => hasWordA ? _text.offset : _bText.offset;

  int get length => _entryOffsets.length;

  /// Null for table B.
  int? wordAAt(int index) => hasWordA ? _view.getUint32(_entryOffsets[index] + _wordA.offset) : null;

  int wordBAt(int index) => _view.getUint32(_entryOffsets[index] + _headBytes - 8);

  Uint8List textAt(int index) {
    final at = _entryOffsets[index] + _headBytes;
    return Uint8List.sublistView(bytes, at, at + _view.getUint32(at - 4));
  }
}

/// The two tables of a `BKMK` payload.
class ViBookmarkList {
  const ViBookmarkList._(this.bytes, this.tableA, this.tableB);

  final Uint8List bytes;

  final ViBookmarkTable tableA;

  final ViBookmarkTable tableB;

  bool get isEmpty => tableA.length == 0 && tableB.length == 0;

  Uint8List serialize() => bytes;
}

ViBookmarkList decodeBookmarkList(Uint8List bytes) {
  assert(bytes.length >= _tableA.offset, 'a bookmark list starts with the count of table A');
  final view = ByteData.sublistView(bytes);
  var at = _tableA.offset;
  List<int> table(int headBytes) {
    final count = view.getUint32(at - 4);
    assert(count <= (bytes.length - at) ~/ headBytes, 'the count fits the payload');
    final offsets = List<int>.filled(count, 0);
    for (var i = 0; i < count; i++) {
      offsets[i] = at;
      assert(at + headBytes <= bytes.length, 'entry $i has its words and length');
      at += headBytes + view.getUint32(at + headBytes - 4);
    }
    return offsets;
  }

  final a = table(_text.offset);
  assert(at + 4 <= bytes.length, 'table B has a count');
  at += 4;
  final b = table(_bText.offset);
  assert(at == bytes.length, 'the two tables tile the payload');
  return ViBookmarkList._(bytes, ViBookmarkTable._(bytes, a, true), ViBookmarkTable._(bytes, b, false));
}
