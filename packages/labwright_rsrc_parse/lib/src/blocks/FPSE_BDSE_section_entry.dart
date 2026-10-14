/// `FPSE` / `BDSE` - Front-Panel and Block-Diagram Section Entries: [ViSectionEntry]
///
/// One u32 per heap section, present in every corpus file. It is never zero and matches no size
/// or count of any block; `FPSE` never exceeds `MUID` but `BDSE` does in 133 files. It names an
/// object id of its own heap in a fifth of the files, and the values cluster on a few numbers
/// that many unrelated files share. Files saved by LabVIEW 8.0 to 8.5 add a second word. Role
/// TODO.
///
/// ```text
/// offset  size  field    type   meaning
/// 0       4     value    u32    Never zero; an object id of this section's heap in a fifth of the corpus;
///                               role TODO.
/// 4       4     extra    u32?   The LabVIEW 8.0 to 8.5 word: zero in 31 of the 49 files that carry it; null
///                               otherwise.
/// ```
library;

import 'dart:typed_data';

import '../byte_layout.dart';
import '../byte_record.dart';

final class ViSectionEntry extends ByteRecord {
  ViSectionEntry(Uint8List bytes) : super(bytes, layout) {
    assert(
      view.lengthInBytes == _value.end || view.lengthInBytes == _extra.end,
      'a section entry is one or two u32 words',
    );
  }

  /// Never zero; an object id of this section's heap in a fifth of the
  /// corpus; role TODO.
  int get value => _value.read(view);

  /// The LabVIEW 8.0 to 8.5 word: zero in 31 of the 49 files that carry it; null otherwise.
  int? get extra => _extra.isIn(view) ? _extra.read(view) : null;

  /// One word, or two when [extra] is given.
  static Uint8List encode(int value, {int? extra}) {
    final out = Uint8List(extra == null ? _value.end : _extra.end);
    final view = ByteData.sublistView(out);
    _value.write(view, value);
    if (extra != null) _extra.write(view, extra);
    return out;
  }

  static const _value = U32(0);
  static const _extra = U32(4, optional: true);

  static const layout = ByteLayout([_value, _extra]);
}
