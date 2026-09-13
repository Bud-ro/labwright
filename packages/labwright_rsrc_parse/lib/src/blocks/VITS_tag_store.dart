/// `VITS` — VI tag store: named tags whose values are flattened LabVIEW variants.
///
/// Each entry is a length-prefixed name followed by the value. Files saved by LabVIEW 15
/// and later prefix the value with its byte length; LabVIEW 8 through 14 store the
/// variant bare, so its extent comes from walking it; LabVIEW 7 prefixes a length that
/// counts its own four bytes and stores the variant without a version word or type count.
///
/// A flattened variant is `[u32 version][u32 typeCount][typeCount type descriptors]
/// [u2p2 hasValue][u2p2 typeIndex][value][u32 attributeCount][attributes]`, an attribute
/// being a length-prefixed name and another flattened variant.
///
/// ```text
/// offset  size  field                      type     meaning
/// 0       4     count                      u32      number of tags
/// 4       rest  entries                    entry[count] count tags
///   +0    4     nameLength                 u32      bytes of name
///   +4    rest  name                       u8[nameLength] tag name such as `NI.LV.All.SourceOnly`
///   +4    4     valueLength                u32      bytes of value, after name; absent in LabVIEW
///                                                   8 to 14 files, counts itself in LabVIEW 7
///                                                   files
///   +8    rest  value                      variant  flattened variant, after name
/// ```
///
/// [ViTagStore] is a view over the payload; each [ViTagEntry] is a view over one entry;
/// [decodeTagStore] requires the entries to tile the payload exactly.
library;

import 'dart:typed_data';

import '../block_layout.dart';
import '../block_record.dart';

const _count = BlockField(0, 4, 'count', 'u32', 'number of tags');
const _nameLength = BlockField(0, 4, 'nameLength', 'u32', 'bytes of name');
const _name = BlockField(4, null, 'name', 'u8[nameLength]', 'tag name such as `NI.LV.All.SourceOnly`');
const _valueLength = BlockField(
  4,
  4,
  'valueLength',
  'u32',
  'bytes of value, after name; absent in LabVIEW 8 to 14 files, counts itself in LabVIEW 7 files',
);
const _value = BlockField(8, null, 'value', 'variant', 'flattened variant, after name');
const _entries = BlockField(
  4,
  null,
  'entries',
  'entry[count]',
  'count tags',
  entry: [_nameLength, _name, _valueLength, _value],
);

const BlockLayout vitsLayout = [_count, _entries];

/// How one tag's value is framed.
enum ViTagValueFraming {
  /// `[u32 length][variant]`, the length excluding itself.
  lengthPrefixed,

  /// `[u32 length][variant]`, the length including its own four bytes and the variant
  /// carrying no version word.
  lengthPrefixedInclusive,

  /// The variant alone; its extent comes from walking it.
  bare,
}

/// A view over one entry of a [ViTagStore].
class ViTagEntry {
  const ViTagEntry._(this.store, this.offset, this.valueOffset, this.end, this.framing);

  final ViTagStore store;

  final int offset;

  /// Where the flattened variant starts.
  final int valueOffset;

  /// Where the entry ends.
  final int end;

  final ViTagValueFraming framing;

  int get _nameBytes => store._view.getUint32(offset + _nameLength.offset);

  String get name => String.fromCharCodes(store.bytes, offset + _name.offset, offset + _name.offset + _nameBytes);

  Uint8List get value => Uint8List.sublistView(store.bytes, valueOffset, end);
}

/// A view over a `VITS` payload.
class ViTagStore implements BlockRecord {
  ViTagStore._(this.bytes) : _view = ByteData.sublistView(bytes);

  final Uint8List bytes;

  final ByteData _view;

  late final List<ViTagEntry> entries;

  int get declaredCount => _view.getUint32(_count.offset);

  @override
  Uint8List serialize() => bytes;
}

ViTagStore decodeTagStore(Uint8List bytes) {
  assert(bytes.length >= _entries.offset, 'a tag store starts with its count');
  final store = ViTagStore._(bytes);
  final view = store._view;
  final count = view.getUint32(_count.offset);
  assert(count <= (bytes.length - _entries.offset) ~/ 8, 'the count fits the payload');
  final entries = <ViTagEntry>[];
  var at = _entries.offset;
  for (var i = 0; i < count; i++) {
    assert(at + 8 <= bytes.length, 'tag $i has a name length and a value word');
    final nameEnd = at + _name.offset + view.getUint32(at + _nameLength.offset);
    assert(nameEnd + 4 <= bytes.length, 'tag $i name fits the payload');
    final word = view.getUint32(nameEnd);
    final ViTagValueFraming framing;
    final int valueOffset, end;
    if (word > bytes.length - nameEnd) {
      framing = ViTagValueFraming.bare;
      valueOffset = nameEnd;
      end = _variantEnd(view, bytes, valueOffset);
    } else if (bytes[nameEnd + 4] == 0) {
      framing = ViTagValueFraming.lengthPrefixedInclusive;
      valueOffset = nameEnd + 4;
      end = nameEnd + word;
    } else {
      framing = ViTagValueFraming.lengthPrefixed;
      valueOffset = nameEnd + 4;
      end = valueOffset + word;
    }
    assert(end <= bytes.length, 'tag $i value fits the payload');
    entries.add(ViTagEntry._(store, at, valueOffset, end, framing));
    at = end;
  }
  assert(at == bytes.length, 'the tags tile the payload');
  store.entries = entries;
  return store;
}

/// Where the flattened variant starting at [at] ends.
int _variantEnd(ByteData view, Uint8List bytes, int at) {
  assert(at + 8 <= bytes.length, 'a flattened variant has a version word and a type count');
  at += 4;
  final typeCount = view.getUint32(at);
  at += 4;
  assert(typeCount <= (bytes.length - at) ~/ 4, 'the type count fits the payload');
  final typeOffsets = List<int>.filled(typeCount, 0);
  for (var i = 0; i < typeCount; i++) {
    typeOffsets[i] = at;
    assert(at + 4 <= bytes.length && view.getUint16(at) >= 4, 'type descriptor $i has a length and a type');
    at += view.getUint16(at);
  }
  assert(at + 2 <= bytes.length, 'the variant says whether it holds a value');
  final hasValue = _u2p2(view, at);
  at += hasValue.width;
  if (hasValue.value != 0) {
    assert(at + 2 <= bytes.length, 'the variant names its value type');
    final typeIndex = _u2p2(view, at);
    at += typeIndex.width;
    assert(typeIndex.value < typeCount, 'the value type is one of the descriptors');
    at = _valueEnd(view, bytes, typeOffsets, typeIndex.value, at);
  }
  assert(at + 4 <= bytes.length, 'the variant has an attribute count');
  final attributeCount = view.getUint32(at);
  at += 4;
  for (var i = 0; i < attributeCount; i++) {
    assert(at + 4 <= bytes.length, 'attribute $i has a name length');
    at += 4 + view.getUint32(at);
    at = _variantEnd(view, bytes, at);
  }
  assert(at <= bytes.length, 'the variant fits the payload');
  return at;
}

({int value, int width}) _u2p2(ByteData view, int at) {
  final head = view.getUint16(at);
  return head & 0x8000 != 0 ? (value: view.getUint32(at) & 0x7fffffff, width: 4) : (value: head, width: 2);
}

/// Where the flattened value of type descriptor [typeIndex] starting at [at] ends.
int _valueEnd(ByteData view, Uint8List bytes, List<int> typeOffsets, int typeIndex, int at) {
  final td = typeOffsets[typeIndex];
  final type = view.getUint16(td + 2) & 0xff;
  switch (type) {
    case 0x01 || 0x05 || 0x21:
      return at + 1;
    case 0x02 || 0x06:
      return at + 2;
    case 0x03 || 0x07 || 0x09:
      return at + 4;
    case 0x04 || 0x08 || 0x0a:
      return at + 8;
    case 0x30:
      assert(at + 4 <= bytes.length, 'a string value has a length');
      return at + 4 + view.getUint32(at);
    case 0x32:
      assert(at + 8 <= bytes.length, 'a path value has a tag and a length');
      return at + 8 + view.getUint32(at + 4);
    case 0x40:
      final dimCount = view.getUint16(td + 4);
      var elements = 1;
      for (var d = 0; d < dimCount; d++) {
        assert(at + 4 <= bytes.length, 'array dimension $d has a size');
        elements *= view.getUint32(at);
        at += 4;
      }
      final elementIndex = view.getUint16(td + 6 + 4 * dimCount);
      for (var i = 0; i < elements; i++) {
        at = _valueEnd(view, bytes, typeOffsets, elementIndex, at);
      }
      return at;
    case 0x50:
      final memberCount = view.getUint16(td + 4);
      for (var m = 0; m < memberCount; m++) {
        at = _valueEnd(view, bytes, typeOffsets, view.getUint16(td + 6 + 2 * m), at);
      }
      return at;
    case 0x53:
      return _variantEnd(view, bytes, at);
    default:
      assert(false, 'flattened value of type 0x${type.toRadixString(16)} has a known size');
      return at;
  }
}
