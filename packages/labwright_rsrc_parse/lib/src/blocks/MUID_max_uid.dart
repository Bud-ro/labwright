/// `MUID` - Maximum UID: [ViMaxUid]
///
/// The highest object id the VI's heaps use: equal to the largest `FPHb` or `BDHb` object id in
/// 8297 of 8315 corpus files. Of the rest, 14 LabVIEW 8.6 files keep their heaps in the `FPHc`
/// and `BDHc` form, which is not decoded; three have block-diagram heaps the walk leaves mostly
/// unread; and one LabVIEW 8.5 file's ids stop 6 short of it.
///
/// ```text
/// offset  size  field    type   meaning
/// 0       4     maxUid   u32    The highest object id in the heaps.
/// ```
library;

import 'dart:typed_data';

import '../byte_layout.dart';
import '../byte_record.dart';

final class ViMaxUid extends ByteRecord {
  ViMaxUid(Uint8List bytes) : super(bytes, layout);

  /// The highest object id in the heaps.
  int get maxUid => _maxUid.read(view);

  set maxUid(int value) => _maxUid.write(view, value);

  static const _maxUid = U32(0);

  static const layout = ByteLayout([_maxUid]);
}
