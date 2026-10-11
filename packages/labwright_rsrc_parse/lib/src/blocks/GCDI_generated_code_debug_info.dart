/// `GCDI` - Generated-Code Debug Info: [ViGcdiRecord]
///
/// A record count and a run of records, always in the zlib envelope that [inflateHeapPayload]
/// opens; the layout is the inflated body. Each record starts with a kind byte, and the first is
/// kind 1 in every file. Reading kinds 1 and 2 as a u32 and kind 3 as a byte then a u32 tiles the
/// 422 single-record bodies with the count; the other 570 bodies hold further kinds, 0 and 0xaf
/// among them, of sizes not decoded. Present in 992 files from LabVIEW 8 to 25.
///
/// ```text
/// offset  size  field       type   meaning
/// 0       4     recordCount u32    Number of records; 1 in 422 files, up to 263.
/// 4       rest  records            Records led by a kind byte: 1 and 2 take a u32, 3 a byte and a u32,
///                                  others TODO.
/// ```
library;

import 'dart:typed_data';

import '../byte_layout.dart';
import '../byte_record.dart';
import '../decode.dart' show inflateHeapPayload;

final class ViGcdiRecord extends ByteRecord {
  ViGcdiRecord(Uint8List bytes) : super(bytes, layout) {
    assert(view.lengthInBytes > _records.offset && view.getUint8(_records.offset) == 1, 'the first record is kind 1');
  }

  /// Number of records; 1 in 422 files, up to 263.
  int get recordCount => _recordCount.read(view);

  /// The records, not decoded.
  Uint8List get records => _records.read(view);

  // dart format off
  static const _recordCount = U32(0);
  static const _records = Unknown(4); // Records led by a kind byte: 1 and 2 take a u32, 3 a byte and a u32, others TODO.

  static const layout = ByteLayout([_recordCount, _records]);
  // dart format on
}
