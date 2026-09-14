/// `DTHP` — the data-type heap table: where the heap's type-descriptor indices start within
/// the `VCTP` top-level list.
///
/// The common form is two words. Saves before the type pool existed hold the heap's types
/// inline instead: a zero word, a count, that many descriptors in the `VCTP` grammar, then
/// a counted list of indices into those descriptors.
///
/// ```text
/// offset  size  field                      type     meaning
/// 0       2     heapTypeCount              u16      number of heap types
/// 2       2     firstTopLevelIndex         u16      1-based top-level index of the first heap type
/// 0       2     zero                       u16      the inline form
/// 2       2     count                      u16      number of inline descriptors
/// 4       rest  descriptors                entry[count] descriptors in the VCTP grammar
/// …       2     entryCount                 u16      number of heap entries, after the descriptors
/// …       rest  entries                    u16[entryCount] inline type index per heap entry
/// ```
///
/// [ViDataTypeHeapCompact] is the two-word form; [ViDataTypeHeapWord] the single-word form;
/// [ViDataTypeHeapInline] holds inline descriptors and the entries indexing them;
/// [ViDataTypeHeapRetained] keeps a body no form covers; [decodeDataTypeHeap] requires at
/// least one word.
library;

import 'dart:typed_data';

import '../block_layout.dart';
import 'VCTP_type_pool.dart';

const _heapTypeCount = BlockField(0, 2, 'heapTypeCount', 'u16', 'number of heap types');
const _firstTopLevelIndex = BlockField(
  2,
  2,
  'firstTopLevelIndex',
  'u16',
  '1-based top-level index of the first heap type',
);
const _inlineZero = BlockField(0, 2, 'zero', 'u16', 'the inline form');
const _inlineCount = BlockField(2, 2, 'count', 'u16', 'number of inline descriptors');
const _inlineDescriptors = BlockField(4, null, 'descriptors', 'entry[count]', 'descriptors in the VCTP grammar');
const _inlineEntryCount = BlockField(4, 2, 'entryCount', 'u16', 'number of heap entries, after the descriptors');
const _inlineEntries = BlockField(6, null, 'entries', 'u16[entryCount]', 'inline type index per heap entry');

const BlockLayout dthpLayout = [
  _heapTypeCount,
  _firstTopLevelIndex,
  _inlineZero,
  _inlineCount,
  _inlineDescriptors,
  _inlineEntryCount,
  _inlineEntries,
];

/// A view over a `DTHP` payload.
sealed class ViDataTypeHeap {
  const ViDataTypeHeap._(this.bytes);

  final Uint8List bytes;

  Uint8List serialize() => bytes;
}

/// The two-word form.
final class ViDataTypeHeapCompact extends ViDataTypeHeap {
  ViDataTypeHeapCompact._(super.bytes) : _view = ByteData.sublistView(bytes), super._();

  final ByteData _view;

  int get heapTypeCount => _view.getUint16(_heapTypeCount.offset);

  int get firstTopLevelIndex => _view.getUint16(_firstTopLevelIndex.offset);

  /// A heap typeDescIndex is 1-based within the run that starts at the 1-based [firstTopLevelIndex].
  int get viTypeIndexBase => firstTopLevelIndex - 2;
}

/// A single word.
final class ViDataTypeHeapWord extends ViDataTypeHeap {
  ViDataTypeHeapWord._(super.bytes) : _view = ByteData.sublistView(bytes), super._();

  final ByteData _view;

  int get word => _view.getUint16(0);
}

/// The inline form: the heap's types in the `VCTP` descriptor grammar, and the heap entries
/// that index them.
final class ViDataTypeHeapInline extends ViDataTypeHeap {
  ViDataTypeHeapInline._(super.bytes, this.types, this._entryCountOffset)
    : _view = ByteData.sublistView(bytes),
      super._();

  final ByteData _view;

  final List<ViType> types;

  final int _entryCountOffset;

  int get count => _view.getUint16(_entryCountOffset);

  int typeIndexAt(int index) => _view.getUint16(_entryCountOffset + 2 + 2 * index);
}

/// A body no form covers, retained undecoded.
final class ViDataTypeHeapRetained extends ViDataTypeHeap {
  const ViDataTypeHeapRetained._(super.bytes) : super._();
}

/// The offset of the entry count when the inline form tiles [bytes], else null.
int? _inlineEntryCountOffset(Uint8List bytes) {
  final view = ByteData.sublistView(bytes);
  var at = _inlineDescriptors.offset;
  for (var i = view.getUint16(_inlineCount.offset); i > 0; i--) {
    if (at + 4 > bytes.length) return null;
    final length = view.getUint16(at);
    if (length < 4) return null;
    at += length;
  }
  if (at + 2 > bytes.length || at + 2 + 2 * view.getUint16(at) != bytes.length) return null;
  return at;
}

ViDataTypeHeap decodeDataTypeHeap(Uint8List bytes) {
  assert(bytes.length >= _heapTypeCount.end, 'a data-type heap table holds at least one word');
  if (bytes.length == _heapTypeCount.end) return ViDataTypeHeapWord._(bytes);
  if (bytes.length == _firstTopLevelIndex.end) return ViDataTypeHeapCompact._(bytes);
  final view = ByteData.sublistView(bytes);
  final entryCountOffset = view.getUint16(_inlineZero.offset) == 0 ? _inlineEntryCountOffset(bytes) : null;
  if (entryCountOffset == null) return ViDataTypeHeapRetained._(bytes);
  final offsets = descriptorOffsets(bytes, _inlineDescriptors.offset, view.getUint16(_inlineCount.offset));
  final heap = ViDataTypeHeapInline._(bytes, [
    for (final at in offsets) ViType.at(bytes, at, view.getUint16(at), legacy: true),
  ], entryCountOffset);
  assert(
    Iterable<int>.generate(heap.count).every((i) => heap.typeIndexAt(i) < heap.types.length),
    'every entry indexes an inline type',
  );
  return heap;
}
