/// `IPSR` - Code Offset Table: [ViOffsetTable]
///
/// A strictly rising run of byte offsets into the VI's compiled code: every one of 12875 offsets
/// in 686 files lies below the `VICD` code size but one, and every file that has the table has
/// `VICD`. Saved by LabVIEW 9 to 13 only. The tag letters suggest an instruction-pointer source
/// record; what each offset marks is not decoded.
///
/// ```text
/// offset  size  field    type   meaning
/// 0       rest  offsets  u32[]  Rising byte offsets below the VICD code size; targets TODO.
/// ```
library;

import 'dart:typed_data';

import '../byte_layout.dart';
import '../byte_record.dart';

final class ViOffsetTable extends ByteRecord {
  ViOffsetTable(Uint8List bytes) : super(bytes, layout) {
    assert(view.lengthInBytes % 4 == 0, 'an offset table is a run of u32 words');
    assert(() {
      for (var i = 1; i < length; i++) {
        if (this[i] <= this[i - 1]) return false;
      }
      return true;
    }(), 'the offsets rise strictly');
  }

  /// Number of offsets, 0 to 63.
  int get length => _offsets.lengthIn(view);

  /// A byte offset into the compiled code; never zero.
  int operator [](int index) => _offsets.at(view, index);

  static const _offsets = U32List(0); // Rising byte offsets below the VICD code size; targets TODO.

  static const layout = ByteLayout([_offsets]);
}
