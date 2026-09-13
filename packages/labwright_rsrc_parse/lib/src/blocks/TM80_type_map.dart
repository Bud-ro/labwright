/// `TM80` — the data-space type map: one flag word per top-level `VCTP` type, selecting
/// its data-space role.
///
/// Words are 2 bytes, or 4 with the high bit set to carry the value in the low 31 bits.
/// Saves before the type pool existed hold the types inline instead: a zero word, a count,
/// that many descriptors in the `VCTP` grammar, then the map itself as a count of
/// (type index, flags) word pairs.
///
/// ```text
/// offset  size  field                      type     meaning
/// 0       rest  count                      u2p2     number of flag words; a leading zero word
///                                                   selects the inline form
/// …       rest  indexShift                 u2p2     top-level index of the first word, after count
/// …       rest  flags                      u2p2[count] data-space role bits per top-level type;
///                                                      bit 13 marks a saved default value
/// …       2     zero                       u16      the inline form
/// …       2     count                      u16      number of inline descriptors
/// …       rest  descriptors                entry[count] descriptors in the VCTP grammar
/// …       rest  entryCount                 u2p2     number of map entries, after the descriptors
/// …       rest  entries                    u2p2[2][entryCount] inline type index and flags per
///                                                              entry
/// ```
///
/// The section usually stores the payload in the zlib envelope that [inflateHeapPayload]
/// opens, and sometimes plain; the layout is the inflated body.
///
/// [ViTypeMapIndexed] is a view over the word list recording where each word starts;
/// [ViTypeMapInline] holds the inline descriptors and the entries indexing them;
/// [decodeTypeMap] requires either form to tile the payload exactly.
library;

import 'dart:typed_data';

import '../block_layout.dart';
import '../block_record.dart';
import '../decode.dart' show inflateHeapPayload;
import 'VCTP_type_pool.dart';

const _count = BlockField(
  0,
  null,
  'count',
  'u2p2',
  'number of flag words; a leading zero word selects the inline form',
);
const _indexShift = BlockField(2, null, 'indexShift', 'u2p2', 'top-level index of the first word, after count');
const _flagWords = BlockField(
  4,
  null,
  'flags',
  'u2p2[count]',
  'data-space role bits per top-level type; bit 13 marks a saved default value',
);
const _inlineZero = BlockField(0, 2, 'zero', 'u16', 'the inline form');
const _inlineCount = BlockField(2, 2, 'count', 'u16', 'number of inline descriptors');
const _inlineDescriptors = BlockField(4, null, 'descriptors', 'entry[count]', 'descriptors in the VCTP grammar');
const _inlineEntryCount = BlockField(4, null, 'entryCount', 'u2p2', 'number of map entries, after the descriptors');
const _inlineEntries = BlockField(6, null, 'entries', 'u2p2[2][entryCount]', 'inline type index and flags per entry');

const BlockLayout tm80Layout = [
  _count,
  _indexShift,
  _flagWords,
  _inlineZero,
  _inlineCount,
  _inlineDescriptors,
  _inlineEntryCount,
  _inlineEntries,
];

/// Bits of a flag word that decide what the default data space (`DFDS`) stores for the
/// entry's type.
enum TypeMapFlag {
  /// `0x0001`: the data space stores the whole value, as with [hasSaveData].
  storedValue0(1 << 0),

  /// `0x0004`: a front-panel operation cluster; the data space stores its member 1, or
  /// member 2 in saves before LabVIEW 10.
  frontPanelOperation(1 << 2),

  /// `0x0008`: nothing is stored.
  unstored3(1 << 3),

  /// `0x0010`: a chart history cluster; the data space stores members 1, 2 and 3.
  chartHistory(1 << 4),

  /// `0x0020`: a cluster whose member 3 alone is stored.
  member3Stored(1 << 5),

  /// `0x0040`: a cluster whose member 2 alone is stored.
  member2Stored(1 << 6),

  /// `0x0200`: the first member a special cluster would store is left out.
  firstMemberSkipped(1 << 9),

  /// `0x0400`: nothing is stored.
  unstored10(1 << 10),

  /// `0x0800`: nothing is stored.
  unstored11(1 << 11),

  /// `0x2000`: the data space stores the whole value.
  hasSaveData(1 << 13)
  ;

  const TypeMapFlag(this.mask);

  final int mask;

  bool isSetIn(int flags) => flags & mask != 0;
}

/// A view over a `TM80` payload.
sealed class ViTypeMap implements BlockRecord {
  const ViTypeMap._(this.bytes);

  final Uint8List bytes;

  int get count;

  int flagsAt(int index);

  @override
  Uint8List serialize() => bytes;
}

/// The word-list form: flags indexed by top-level type.
final class ViTypeMapIndexed extends ViTypeMap {
  ViTypeMapIndexed._(super.bytes, this._wordOffsets) : _view = ByteData.sublistView(bytes), super._();

  final ByteData _view;

  /// Offsets of the count word, the shift word and each flag word.
  final List<int> _wordOffsets;

  @override
  int get count => _wordOffsets.length - 2;

  /// The top-level index of the first flag word.
  int get indexShift => _wordAt(_view, _wordOffsets[1]);

  @override
  int flagsAt(int index) => _wordAt(_view, _wordOffsets[index + 2]);
}

/// The inline form: the types themselves in the `VCTP` descriptor grammar, and the map
/// entries that index them.
final class ViTypeMapInline extends ViTypeMap {
  ViTypeMapInline._(super.bytes, this.types, this._entryOffsets) : _view = ByteData.sublistView(bytes), super._();

  final ByteData _view;

  final List<ViType> types;

  /// Offsets of each entry's type-index word; its flags word follows.
  final List<int> _entryOffsets;

  @override
  int get count => _entryOffsets.length;

  int typeIndexAt(int index) => _wordAt(_view, _entryOffsets[index]);

  @override
  int flagsAt(int index) => _wordAt(_view, _wordEnd(_view, _entryOffsets[index]));
}

int _wordAt(ByteData view, int offset) {
  final hi = view.getUint16(offset);
  return hi & 0x8000 == 0 ? hi : view.getUint32(offset) & 0x7fffffff;
}

int _wordEnd(ByteData view, int offset) => view.getUint16(offset) & 0x8000 == 0 ? offset + 2 : offset + 4;

/// Walks [count] words from [start], asserting each lies inside [bytes]; returns their
/// offsets and the offset after the last.
(List<int>, int) _walkWords(Uint8List bytes, ByteData view, int start, int count) {
  final offsets = List<int>.filled(count, 0);
  var at = start;
  for (var i = 0; i < count; i++) {
    assert(at + 2 <= bytes.length, 'word $i has its first two bytes');
    offsets[i] = at;
    at = _wordEnd(view, at);
    assert(at <= bytes.length, 'word $i lies inside the payload');
  }
  return (offsets, at);
}

ViTypeMap decodeTypeMap(Uint8List bytes) {
  assert(bytes.length >= _inlineCount.offset, 'a type map starts with a word');
  final view = ByteData.sublistView(bytes);
  if (view.getUint16(_inlineZero.offset) == 0 && bytes.length >= _inlineDescriptors.offset) {
    final offsets = descriptorOffsets(bytes, _inlineDescriptors.offset, view.getUint16(_inlineCount.offset));
    final types = [for (final at in offsets) ViType.at(bytes, at, view.getUint16(at), legacy: true)];
    final countOffset = types.isEmpty ? _inlineDescriptors.offset : types.last.end;
    assert(countOffset + 2 <= bytes.length, 'the entry count follows the descriptors');
    assert(_wordEnd(view, countOffset) <= bytes.length, 'the entry count lies inside the payload');
    final entryCount = _wordAt(view, countOffset);
    assert(entryCount <= (bytes.length - countOffset) ~/ 4, 'the entry count fits the payload');
    final (words, end) = _walkWords(bytes, view, _wordEnd(view, countOffset), 2 * entryCount);
    assert(end == bytes.length, 'the entries tile the payload');
    final map = ViTypeMapInline._(bytes, types, [for (var i = 0; i < words.length; i += 2) words[i]]);
    assert(
      Iterable<int>.generate(entryCount).every((i) => map.typeIndexAt(i) < types.length),
      'every entry indexes an inline type',
    );
    return map;
  }
  assert(_wordEnd(view, 0) <= bytes.length, 'the count word lies inside the payload');
  final count = _wordAt(view, 0);
  assert(count <= bytes.length ~/ 2, 'the count fits the payload');
  final (offsets, end) = _walkWords(bytes, view, 0, count + 2);
  assert(end == bytes.length, 'the words tile the payload');
  return ViTypeMapIndexed._(bytes, offsets);
}
