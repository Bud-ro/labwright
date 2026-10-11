/// `LIBN` - Library Names: [ViLibraryNames]
///
/// The names of the libraries owning the VI, outermost first: one `.lvlib`, `.lvclass` or
/// `.xnode`, or a library followed by the class it contains. Stored in the embedded section
/// namespace, once per VI; [readOwningLibraryNames] collects them from a whole VI. Files
/// outside any library have no `LIBN`.
///
/// ```text
/// offset  size  field    type        meaning
/// 0       4     count    u32         Number of names, outermost library first.
/// 4       …     names    pstr[count] Library names such as `Caraya.lvlib`, a class after its library.
/// ```
library;

import 'dart:typed_data';

import '../byte_layout.dart';
import '../byte_record.dart';
import '../viparse.dart';

final class ViLibraryNames extends ByteRecord {
  ViLibraryNames(Uint8List bytes) : super(bytes, layout) {
    final count = _count.read(view);
    assert(count <= view.lengthInBytes - _names.offset, 'the count fits the payload');
    _nameOffsets = List<int>.filled(count, 0);
    var at = _names.offset;
    for (var i = 0; i < count; i++) {
      assert(at < view.lengthInBytes, 'name $i has a length byte');
      _nameOffsets[i] = at;
      at = PStr.endAt(view, at);
    }
    assert(at == view.lengthInBytes, 'the names tile the payload');
  }

  int get length => _nameOffsets.length;

  String operator [](int index) => PStr.readAt(view, _nameOffsets[index]);

  late final List<int> _nameOffsets;

  static const _count = U32(0); // Number of names, outermost library first.
  static const _names = PStrList(4, count: _count); // Library names such as `Caraya.lvlib`, a class after its library.

  static const layout = ByteLayout([_count, _names]);
}

/// Every distinct library name in the VI's `LIBN` sections, in section order.
List<String> readOwningLibraryNames(Uint8List viBytes) {
  final out = <String>[];
  for (final section in embeddedSectionsOrEmpty(viBytes)) {
    if (section.tag != 'LIBN') continue;
    final names = ViLibraryNames(section.bytes);
    for (var i = 0; i < names.length; i++) {
      if (!out.contains(names[i])) out.add(names[i]);
    }
  }
  return out;
}
