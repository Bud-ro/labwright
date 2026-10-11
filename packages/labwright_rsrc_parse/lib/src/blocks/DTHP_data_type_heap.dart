/// `DTHP` - Data-Type Heap Table: [ViDataTypeHeap]
///
/// Where the heap's type-descriptor indices start within the `VCTP` top-level list. The
/// common form is two words; saves before the type pool existed hold the heap's types
/// inline instead: a zero word, a count, that many descriptors in the `VCTP` grammar, then
/// a counted list of indices into those descriptors.
///
/// ```text
/// DTHP:
/// offset  size  field              type   meaning
/// 0       2     heapTypeCount      u16    Number of heap types.
/// 2       2     firstTopLevelIndex u16    1-based top-level index of the first heap type.
/// ViDataTypeHeapWord:
/// offset  size  field    type   meaning
/// 0       2     word     u16    Role TODO.
/// ViDataTypeHeapInline:
/// offset  size         field       type                  meaning
/// 0       2            zero        u16                   Zero; selects the inline form.
/// 2       2            count       u16                   Number of inline descriptors.
/// 4       …            descriptors VctpDescriptor[count] Descriptors in the VCTP grammar.
///   +0    2            length      u16                   Bytes of the descriptor.
///   +2    1            flags       u8                    Bit set, see ViTypeFlag.
///   +3    1            typeCode    u8                    See TypeCode and ViDataType.
///   +4    rest         body        u8[]                  Shape selected by typeCode, see the ViType
///                                                        subclasses.
///   +…    …            label       pstr                  After the body when flag 0x40 is set, padded to an
///                                                        even length.
/// …       2            entryCount  u16                   Number of heap entries, after the descriptors.
/// …       2·entryCount entries     u16[entryCount]       Inline type index per heap entry.
/// ViDataTypeHeapRetained:
/// offset  size  field    type   meaning
/// 0       rest  body            not decoded
/// ```
library;

import 'dart:typed_data';

import '../byte_layout.dart';
import '../byte_record.dart';
import 'VCTP_type_pool.dart';

sealed class ViDataTypeHeap extends ByteRecord {
  ViDataTypeHeap._(super.bytes, super.layout);

  factory ViDataTypeHeap(Uint8List bytes) {
    assert(bytes.length >= ViDataTypeHeapWord.layout.size!, 'a data-type heap table holds at least one word');
    if (bytes.length == ViDataTypeHeapWord.layout.size) return ViDataTypeHeapWord(bytes);
    if (bytes.length == ViDataTypeHeapCompact.layout.size) return ViDataTypeHeapCompact(bytes);
    if (ViDataTypeHeapInline._entryCountOffsetIn(ByteData.sublistView(bytes)) == null) {
      return ViDataTypeHeapRetained(bytes);
    }
    return ViDataTypeHeapInline(bytes);
  }
}

/// The two-word form.
final class ViDataTypeHeapCompact extends ViDataTypeHeap {
  ViDataTypeHeapCompact(Uint8List bytes) : super._(bytes, layout);

  /// Number of heap types.
  int get heapTypeCount => _heapTypeCount.read(view);

  /// 1-based top-level index of the first heap type.
  int get firstTopLevelIndex => _firstTopLevelIndex.read(view);

  /// A heap typeDescIndex is 1-based within the run that starts at the 1-based [firstTopLevelIndex].
  int get viTypeIndexBase => firstTopLevelIndex - 2;

  static const _heapTypeCount = U16(0);
  static const _firstTopLevelIndex = U16(2);

  static const layout = ByteLayout([_heapTypeCount, _firstTopLevelIndex]);
}

/// A single word.
final class ViDataTypeHeapWord extends ViDataTypeHeap {
  ViDataTypeHeapWord(Uint8List bytes) : super._(bytes, layout);

  /// Role TODO.
  int get word => _word.read(view);

  static const _word = U16(0);

  static const layout = ByteLayout([_word]);
}

/// The inline form: the heap's types in the `VCTP` descriptor grammar, and the heap entries
/// that index them.
final class ViDataTypeHeapInline extends ViDataTypeHeap {
  ViDataTypeHeapInline(Uint8List bytes) : super._(bytes, layout) {
    final entryCountOffset = _entryCountOffsetIn(view);
    assert(entryCountOffset != null, 'the inline form tiles the payload');
    _entryCountOffset = entryCountOffset!;
    final pool = Uint8List.sublistView(view);
    types = [
      for (final at in descriptorOffsets(pool, _descriptors.offset, _count.read(view)))
        ViType.at(pool, at, view.getUint16(at), legacy: true),
    ];
    assert(
      Iterable<int>.generate(count).every((i) => typeIndexAt(i) < types.length),
      'every entry indexes an inline type',
    );
  }

  late final List<ViType> types;

  /// Number of heap entries.
  int get count => view.getUint16(_entryCountOffset);

  int typeIndexAt(int index) => view.getUint16(_entryCountOffset + 2 + 2 * index);

  late final int _entryCountOffset;

  /// The offset of the entry count when the inline form tiles [view], else null.
  static int? _entryCountOffsetIn(ByteData view) {
    if (view.lengthInBytes < _descriptors.offset || _zero.read(view) != 0) return null;
    var at = _descriptors.offset;
    for (var i = _count.read(view); i > 0; i--) {
      if (at + VctpDescriptor.body.offset > view.lengthInBytes) return null;
      final length = view.getUint16(at + VctpDescriptor.length.offset);
      if (length < VctpDescriptor.body.offset) return null;
      at += length;
    }
    if (at + 2 > view.lengthInBytes || at + 2 + 2 * view.getUint16(at) != view.lengthInBytes) return null;
    return at;
  }

  static const _zero = U16(0); // Zero; selects the inline form.
  static const _count = U16(2); // Number of inline descriptors.
  static const _descriptors = Entries(4, VctpDescriptor.layout, count: _count); // Descriptors in the VCTP grammar.
  static const _entryCount = U16(4); // Number of heap entries, after the descriptors.
  static const _entries = U16List(6, count: _entryCount); // Inline type index per heap entry.

  static const layout = ByteLayout([_zero, _count, _descriptors, _entryCount, _entries]);
}

/// A body no form covers, retained undecoded.
final class ViDataTypeHeapRetained extends ViDataTypeHeap {
  ViDataTypeHeapRetained(Uint8List bytes) : super._(bytes, layout);

  static const _body = Unknown(0);

  static const layout = ByteLayout([_body]);
}
