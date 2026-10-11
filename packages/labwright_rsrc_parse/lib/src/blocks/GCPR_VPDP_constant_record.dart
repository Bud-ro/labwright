/// `GCPR` / `VPDP` - Generated-Code Properties and VI Property Data: [ViConstantRecord]
///
/// Two fixed records that carry almost nothing: `GCPR` is 13 zero bytes in all 3835 files that
/// have it (LabVIEW 11 and later); `VPDP` is a 4-byte word, present in every file from LabVIEW
/// 14 on, zero in all but 15 web-snippet PNGs where it is 1.
///
/// ```text
/// GCPR:
/// offset  size  field    type   meaning
/// 0       13    gcprBody        Zero in every file; roles TODO.
/// VPDP:
/// offset  size  field    type   meaning
/// 0       4     vpdpWord        Zero, or 1 in 15 snippet PNGs; role TODO.
/// ```
library;

import 'dart:typed_data';

import '../byte_layout.dart';
import '../byte_record.dart';

final class ViConstantRecord extends ByteRecord {
  ViConstantRecord.gcpr(Uint8List bytes) : super(bytes, gcprLayout);

  ViConstantRecord.vpdp(Uint8List bytes) : super(bytes, vpdpLayout);

  bool get isZero {
    for (var i = 0; i < view.lengthInBytes; i++) {
      if (view.getUint8(i) != 0) return false;
    }
    return true;
  }

  static const _gcprBody = Unknown(0, size: 13); // Zero in every file; roles TODO.
  static const _vpdpWord = Unknown(0, size: 4); // Zero, or 1 in 15 snippet PNGs; role TODO.

  static const gcprLayout = ByteLayout([_gcprBody]);
  static const vpdpLayout = ByteLayout([_vpdpWord]);
}
