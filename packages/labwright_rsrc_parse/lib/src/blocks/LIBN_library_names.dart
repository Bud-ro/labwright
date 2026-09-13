/// `LIBN` — the qualified names of the libraries owning the VI, stored in the embedded
/// section namespace.
///
/// ```text
/// offset  size  field                      type     meaning
/// 0       4     count                      u32      number of names, outermost library first
/// 4       rest  names                      pstr[count] library names such as `Caraya.lvlib`
/// ```
///
/// [ViLibraryNames] is a view over the payload; [decodeLibraryNames] requires the names to
/// tile the payload exactly; [readOwningLibraryNames] collects them from a whole VI.
library;

import 'dart:typed_data';

import '../block_layout.dart';
import '../block_record.dart';
import '../viparse.dart';

const _count = BlockField(0, 4, 'count', 'u32', 'number of names, outermost library first');
const _names = BlockField(4, null, 'names', 'pstr[count]', 'library names such as `Caraya.lvlib`');

const BlockLayout libnLayout = [_count, _names];

/// A view over an `LIBN` payload.
class ViLibraryNames implements BlockRecord {
  const ViLibraryNames._(this.bytes, this._nameOffsets);

  final Uint8List bytes;

  final List<int> _nameOffsets;

  int get length => _nameOffsets.length;

  String operator [](int index) {
    final at = _nameOffsets[index];
    return String.fromCharCodes(bytes, at + 1, at + 1 + bytes[at]);
  }

  @override
  Uint8List serialize() => bytes;
}

ViLibraryNames decodeLibraryNames(Uint8List bytes) {
  assert(bytes.length >= _names.offset, 'a library-name block starts with its count');
  final count = ByteData.sublistView(bytes).getUint32(_count.offset);
  assert(count <= bytes.length - _names.offset, 'the count fits the payload');
  final offsets = List<int>.filled(count, 0);
  var at = _names.offset;
  for (var i = 0; i < count; i++) {
    assert(at < bytes.length, 'name $i has a length byte');
    offsets[i] = at;
    at += 1 + bytes[at];
  }
  assert(at == bytes.length, 'the names tile the payload');
  return ViLibraryNames._(bytes, offsets);
}

/// Every distinct library name in the VI's `LIBN` sections, in section order.
List<String> readOwningLibraryNames(Uint8List viBytes) {
  final out = <String>[];
  for (final section in embeddedSectionsOrEmpty(viBytes)) {
    if (section.tag != 'LIBN') continue;
    final names = decodeLibraryNames(section.bytes);
    for (var i = 0; i < names.length; i++) {
      if (!out.contains(names[i])) out.add(names[i]);
    }
  }
  return out;
}
