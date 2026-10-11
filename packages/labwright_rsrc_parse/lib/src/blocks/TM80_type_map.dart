/// `TM80` - Data-Space Type Map: [ViTypeMap]
///
/// One flag word per top-level `VCTP` type, selecting its data-space role. Words are 2
/// bytes, or 4 with the high bit set to carry the value in the low 31 bits. Saves before the
/// type pool existed hold the types inline instead: a zero word, a count, that many
/// descriptors in the `VCTP` grammar, then the map itself as a count of (type index, flags)
/// word pairs. The section usually stores the payload in the zlib envelope that
/// [inflateHeapPayload] opens, and sometimes plain; the layout is the inflated body.
///
/// ```text
/// TM80:
/// offset  size  field      type          meaning
/// 0       …     count      packed        Number of flag words; a leading zero word selects the inline form,
///                                        see ViTypeMapInline.
/// …       …     indexShift packed        The top-level index of the first flag word, after count.
/// …       …     flags      packed[count] Role bits per type; bit 13 marks a saved default value.
/// ViTypeMapInline:
/// offset  size  field       type                  meaning
/// 0       2     zero        u16                   Zero; selects the inline form.
/// 2       2     count       u16                   Number of inline descriptors.
/// 4       …     descriptors VctpDescriptor[count] Descriptors in the VCTP grammar.
///   +0    2     length      u16                   Bytes of the descriptor.
///   +2    1     flags       u8                    Bit set, see ViTypeFlag.
///   +3    1     typeCode    u8                    See TypeCode and ViDataType.
///   +4    rest  body        u8[]                  Shape selected by typeCode, see the ViType subclasses.
///   +…    …     label       pstr                  After the body when flag 0x40 is set, padded to an even
///                                                 length.
/// …       …     entryCount  packed                Number of map entries, after the descriptors.
/// …       …     entries     Tm80Entry[entryCount] Inline type index and flags per entry.
///   +0    …     typeIndex   packed                Index into the inline descriptors.
///   +…    …     flags       packed                Data-space role bits, after typeIndex.
/// ```
library;

import 'dart:typed_data';

import '../byte_layout.dart';
import '../byte_record.dart';
import '../decode.dart' show inflateHeapPayload;
import 'VCTP_type_pool.dart';

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
  hasSaveData(1 << 13);

  const TypeMapFlag(this.mask);

  final int mask;

  bool isSetIn(int flags) => flags & mask != 0;
}

sealed class ViTypeMap extends ByteRecord {
  ViTypeMap._(super.bytes, super.layout);

  factory ViTypeMap(Uint8List bytes) {
    assert(bytes.length >= 2, 'a type map starts with a word');
    final view = ByteData.sublistView(bytes);
    if (ViTypeMapInline._zero.read(view) == 0 && bytes.length >= ViTypeMapInline._descriptors.offset) {
      return ViTypeMapInline(bytes);
    }
    return ViTypeMapIndexed(bytes);
  }

  int get count;

  int flagsAt(int index);
}

/// The word-list form: flags indexed by top-level type.
final class ViTypeMapIndexed extends ViTypeMap {
  ViTypeMapIndexed(Uint8List bytes) : super._(bytes, layout) {
    assert(_count.endIn(view) <= view.lengthInBytes, 'the count word lies inside the payload');
    final count = _count.read(view);
    assert(count <= view.lengthInBytes ~/ 2, 'the count fits the payload');
    final (offsets, end) = _walkWords(view, _count.offset, count + 2);
    assert(end == view.lengthInBytes, 'the words tile the payload');
    _wordOffsets = offsets;
  }

  /// Number of flag words; a leading zero word selects the inline form, see [ViTypeMapInline].
  @override
  int get count => _wordOffsets.length - 2;

  /// The top-level index of the first flag word, after count.
  int get indexShift => PackedWord.readAt(view, _wordOffsets[1]);

  /// Data-space role bits of a top-level type; bit 13 marks a saved default value.
  @override
  int flagsAt(int index) => PackedWord.readAt(view, _wordOffsets[index + 2]);

  /// Offsets of the count word, the shift word and each flag word.
  late final List<int> _wordOffsets;

  static const _count = PackedWord(0);
  static const _indexShift = PackedWord(2);
  static const _flags = PackedWordList(4, count: _count); // Role bits per type; bit 13 marks a saved default value.

  static const layout = ByteLayout([_count, _indexShift, _flags]);
}

/// The inline form: the types themselves in the `VCTP` descriptor grammar, and the map
/// entries that index them.
final class ViTypeMapInline extends ViTypeMap {
  ViTypeMapInline(Uint8List bytes) : super._(bytes, layout) {
    final pool = Uint8List.sublistView(view);
    types = [
      for (final at in descriptorOffsets(pool, _descriptors.offset, _count.read(view)))
        ViType.at(pool, at, view.getUint16(at), legacy: true),
    ];
    final countOffset = types.isEmpty ? _descriptors.offset : types.last.end;
    assert(countOffset + 2 <= view.lengthInBytes, 'the entry count follows the descriptors');
    assert(_wordEnd(view, countOffset) <= view.lengthInBytes, 'the entry count lies inside the payload');
    final entryCount = PackedWord.readAt(view, countOffset);
    assert(entryCount <= (view.lengthInBytes - countOffset) ~/ 4, 'the entry count fits the payload');
    final (words, end) = _walkWords(view, _wordEnd(view, countOffset), 2 * entryCount);
    assert(end == view.lengthInBytes, 'the entries tile the payload');
    _entryOffsets = [for (var i = 0; i < words.length; i += 2) words[i]];
    assert(
      Iterable<int>.generate(entryCount).every((i) => typeIndexAt(i) < types.length),
      'every entry indexes an inline type',
    );
  }

  late final List<ViType> types;

  /// Number of map entries.
  @override
  int get count => _entryOffsets.length;

  int typeIndexAt(int index) => PackedWord.readAt(view, _entryOffsets[index]);

  @override
  int flagsAt(int index) => PackedWord.readAt(view, _wordEnd(view, _entryOffsets[index]));

  /// Offsets of each entry's type-index word; its flags word follows.
  late final List<int> _entryOffsets;

  static const _zero = U16(0); // Zero; selects the inline form.
  static const _count = U16(2); // Number of inline descriptors.
  static const _descriptors = Entries(4, VctpDescriptor.layout, count: _count); // Descriptors in the VCTP grammar.
  static const _entryCount = PackedWord(4); // Number of map entries, after the descriptors.
  static const _entries = Entries(6, Tm80Entry.layout, count: _entryCount); // Inline type index and flags per entry.

  static const layout = ByteLayout([_zero, _count, _descriptors, _entryCount, _entries]);
}

/// One map entry of the inline form.
abstract final class Tm80Entry {
  static const typeIndex = PackedWord(0); // Index into the inline descriptors.
  static const flags = PackedWord(2); // Data-space role bits, after typeIndex.

  static const layout = ByteLayout([typeIndex, flags]);
}

int _wordEnd(ByteData view, int offset) => offset + PackedWord.sizeAt(view, offset);

/// Walks [count] words from [start], asserting each lies inside [view]; returns their
/// offsets and the offset after the last.
(List<int>, int) _walkWords(ByteData view, int start, int count) {
  final offsets = List<int>.filled(count, 0);
  var at = start;
  for (var i = 0; i < count; i++) {
    assert(at + 2 <= view.lengthInBytes, 'word $i has its first two bytes');
    offsets[i] = at;
    at = _wordEnd(view, at);
    assert(at <= view.lengthInBytes, 'word $i lies inside the payload');
  }
  return (offsets, at);
}
