/// `VITS` - VI Tag Store: [ViTagStore]
///
/// The VI's persistent tags: (name, variant) pairs that VI Server's `Set Tag` attaches to the
/// VI and that LabVIEW's own tools use for their bookkeeping; the corpus holds 17 names, led by
/// `NI.LV.All.SourceOnly`, `NI_IconEditor`, `_ni_LastKnownOwningLVClassCluster`,
/// `NI.LV.ALL.VILastSavedTarget`, `NI.LV.ALL.goodSyntaxTargets`, `Localized` and `VIXML`. Names
/// are free strings, so no closed set exists; `BDTS` holds the tags of diagram objects the same
/// way. Files saved by LabVIEW 15 and later
/// prefix each value with its byte length; LabVIEW 8 through 14 store the variant bare, so its
/// extent comes from walking it; LabVIEW 7 prefixes a length that counts its own four bytes and
/// stores the variant without a version word or type count. A flattened variant is
/// `[u32 version][u32 typeCount][typeCount type descriptors][u2p2 hasValue][u2p2 typeIndex]`
/// `[value][u32 attributeCount][attributes]`, an attribute being a length-prefixed name and
/// another flattened variant.
///
/// ```text
/// offset          size       field       type             meaning
/// 0               4          count       u32              Number of tags.
/// 4               …          entries     VitsEntry[count]
///   +0            4          nameLength  u32
///   +4            nameLength name        u8[nameLength]   Tag name such as `NI.LV.All.SourceOnly`.
///   +4+nameLength 4          valueLength u32              Bytes of value, after name; absent in LabVIEW 8 to
///                                                         14 files, counts itself in LabVIEW 7 files.
///   +8+nameLength rest       value       u8[]             Flattened variant, after name.
/// ```
library;

import 'dart:typed_data';

import '../byte_layout.dart';
import '../byte_record.dart';

/// One tag entry.
abstract final class VitsEntry {
  // dart format off
  static const nameLength = U32(0);
  static const name = Bytes(4, count: nameLength); // Tag name such as `NI.LV.All.SourceOnly`.
  static const valueLength = U32(4); // Bytes of value, after name; absent in LabVIEW 8 to 14 files, counts itself in LabVIEW 7 files.
  static const value = Bytes(8); // Flattened variant, after name.

  static const layout = ByteLayout([nameLength, name, valueLength, value]);
  // dart format on
}

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

/// A view over one tag entry: a length-prefixed name and its framed value.
final class ViTagEntry {
  const ViTagEntry(this.view, this.offset, this.valueOffset, this.end, this.framing);

  /// The tag entry starting at [at], the [index]th of its store; requires its name and its
  /// framed value to fit [view].
  factory ViTagEntry.at(ByteData view, int at, int index) {
    assert(at + 8 <= view.lengthInBytes, 'tag $index has a name length and a value word');
    final nameEnd = at + VitsEntry.name.offset + view.getUint32(at + VitsEntry.nameLength.offset);
    assert(nameEnd + 4 <= view.lengthInBytes, 'tag $index name fits the payload');
    final word = view.getUint32(nameEnd);
    final ViTagValueFraming framing;
    final int valueOffset, end;
    if (word > view.lengthInBytes - nameEnd) {
      framing = ViTagValueFraming.bare;
      valueOffset = nameEnd;
      end = _variantEnd(view, valueOffset);
    } else if (view.getUint8(nameEnd + 4) == 0) {
      framing = ViTagValueFraming.lengthPrefixedInclusive;
      valueOffset = nameEnd + 4;
      end = nameEnd + word;
    } else {
      framing = ViTagValueFraming.lengthPrefixed;
      valueOffset = nameEnd + 4;
      end = valueOffset + word;
    }
    assert(end <= view.lengthInBytes, 'tag $index value fits the payload');
    return ViTagEntry(view, at, valueOffset, end, framing);
  }

  final ByteData view;

  final int offset;

  /// Where the flattened variant starts.
  final int valueOffset;

  /// Where the entry ends.
  final int end;

  final ViTagValueFraming framing;

  String get name {
    final start = offset + VitsEntry.name.offset;
    return String.fromCharCodes(
      Uint8List.sublistView(view, start, start + view.getUint32(offset + VitsEntry.nameLength.offset)),
    );
  }

  Uint8List get value => Uint8List.sublistView(view, valueOffset, end);
}

final class ViTagStore extends ByteRecord {
  ViTagStore(Uint8List bytes) : super(bytes, layout) {
    final count = declaredCount;
    assert(count <= (view.lengthInBytes - _entries.offset) ~/ 8, 'the count fits the payload');
    final entries = <ViTagEntry>[];
    var at = _entries.offset;
    for (var i = 0; i < count; i++) {
      final entry = ViTagEntry.at(view, at, i);
      entries.add(entry);
      at = entry.end;
    }
    assert(at == view.lengthInBytes, 'the tags tile the payload');
    this.entries = entries;
  }

  late final List<ViTagEntry> entries;

  /// A store of [tags] in order, each value framed as its entry says.
  static Uint8List encode(List<({String name, ViTagValueFraming framing, List<int> value})> tags) {
    var length = _entries.offset;
    for (final tag in tags) {
      length += VitsEntry.name.offset + tag.name.length + tag.value.length;
      if (tag.framing != ViTagValueFraming.bare) length += VitsEntry.valueLength.size;
    }
    final out = Uint8List(length);
    _count.write(ByteData.sublistView(out), tags.length);
    var at = _entries.offset;
    for (final (:name, :framing, :value) in tags) {
      final entry = ByteData.sublistView(out, at);
      VitsEntry.nameLength.write(entry, name.length);
      VitsEntry.name.write(entry, name.codeUnits);
      final unframed = framing == ViTagValueFraming.bare ? VitsEntry.valueLength.size : 0;
      final afterName = ByteData.sublistView(out, at + name.length - unframed);
      switch (framing) {
        case ViTagValueFraming.lengthPrefixed:
          VitsEntry.valueLength.write(afterName, value.length);
        case ViTagValueFraming.lengthPrefixedInclusive:
          VitsEntry.valueLength.write(afterName, VitsEntry.valueLength.size + value.length);
        case ViTagValueFraming.bare:
      }
      VitsEntry.value.write(afterName, value);
      at += name.length - unframed + VitsEntry.value.offset + value.length;
    }
    return out;
  }

  /// Number of tags.
  int get declaredCount => _count.read(view);

  static const _count = U32(0);
  static const _entries = Entries(4, VitsEntry.layout, count: _count);

  static const layout = ByteLayout([_count, _entries]);
}

/// Where the flattened variant starting at [at] ends.
int _variantEnd(ByteData view, int at) {
  assert(at + 8 <= view.lengthInBytes, 'a flattened variant has a version word and a type count');
  at += 4;
  final typeCount = view.getUint32(at);
  at += 4;
  assert(typeCount <= (view.lengthInBytes - at) ~/ 4, 'the type count fits the payload');
  final typeOffsets = List<int>.filled(typeCount, 0);
  for (var i = 0; i < typeCount; i++) {
    typeOffsets[i] = at;
    assert(at + 4 <= view.lengthInBytes && view.getUint16(at) >= 4, 'type descriptor $i has a length and a type');
    at += view.getUint16(at);
  }
  assert(at + 2 <= view.lengthInBytes, 'the variant says whether it holds a value');
  final hasValue = _u2p2(view, at);
  at += hasValue.width;
  if (hasValue.value != 0) {
    assert(at + 2 <= view.lengthInBytes, 'the variant names its value type');
    final typeIndex = _u2p2(view, at);
    at += typeIndex.width;
    assert(typeIndex.value < typeCount, 'the value type is one of the descriptors');
    at = _valueEnd(view, typeOffsets, typeIndex.value, at);
  }
  assert(at + 4 <= view.lengthInBytes, 'the variant has an attribute count');
  final attributeCount = view.getUint32(at);
  at += 4;
  for (var i = 0; i < attributeCount; i++) {
    assert(at + 4 <= view.lengthInBytes, 'attribute $i has a name length');
    at += 4 + view.getUint32(at);
    at = _variantEnd(view, at);
  }
  assert(at <= view.lengthInBytes, 'the variant fits the payload');
  return at;
}

({int value, int width}) _u2p2(ByteData view, int at) {
  final head = view.getUint16(at);
  return head & 0x8000 != 0 ? (value: view.getUint32(at) & 0x7fffffff, width: 4) : (value: head, width: 2);
}

/// Where the flattened value of type descriptor [typeIndex] starting at [at] ends.
int _valueEnd(ByteData view, List<int> typeOffsets, int typeIndex, int at) {
  final td = typeOffsets[typeIndex];
  final type = view.getUint16(td + 2) & 0xff;
  switch (type) {
    case 0x00:
      return at;
    case 0x01 || 0x05 || 0x21:
      return at + 1;
    case 0x02 || 0x06:
      return at + 2;
    case 0x03 || 0x07 || 0x09:
      return at + 4;
    case 0x04 || 0x08 || 0x0a:
      return at + 8;
    case 0x30:
      assert(at + 4 <= view.lengthInBytes, 'a string value has a length');
      return at + 4 + view.getUint32(at);
    case 0x32:
      assert(at + 8 <= view.lengthInBytes, 'a path value has a tag and a length');
      return at + 8 + view.getUint32(at + 4);
    case 0x40:
      final dimCount = view.getUint16(td + 4);
      var elements = 1;
      for (var d = 0; d < dimCount; d++) {
        assert(at + 4 <= view.lengthInBytes, 'array dimension $d has a size');
        elements *= view.getUint32(at);
        at += 4;
      }
      final elementIndex = view.getUint16(td + 6 + 4 * dimCount);
      for (var i = 0; i < elements; i++) {
        at = _valueEnd(view, typeOffsets, elementIndex, at);
      }
      return at;
    case 0x50:
      final memberCount = view.getUint16(td + 4);
      for (var m = 0; m < memberCount; m++) {
        at = _valueEnd(view, typeOffsets, view.getUint16(td + 6 + 2 * m), at);
      }
      return at;
    case 0x53:
      return _variantEnd(view, at);
    default:
      assert(false, 'flattened value of type 0x${type.toRadixString(16)} has a known size');
      return at;
  }
}
