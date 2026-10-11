/// `RTSG` / `OBSG` / `CCSG` - Run-Time, Object and Compiled-Code Signatures: [ViSignature]
///
/// One 16-byte digest each; none is the MD5 of any block or of the file. `RTSG` is in every VI:
/// zero in 657 of 8315, otherwise near-unique per VI, though sibling VIs with the same data
/// space can share it. `OBSG` (LabVIEW 8 to 13) is unique per VI. `CCSG` (LabVIEW 8 to 12)
/// takes only six values over 594 files, one per compiler build, so it signs the compiler rather
/// than the VI.
///
/// ```text
/// offset  size  field    type   meaning
/// 0       16    digest   u8[16] The digest; how it is derived is not decoded.
/// ```
library;

import 'dart:typed_data';

import '../byte_layout.dart';
import '../byte_record.dart';

final class ViSignature extends ByteRecord {
  ViSignature(Uint8List bytes) : super(bytes, layout);

  /// The digest; how it is derived is not decoded.
  Uint8List get digest => _digest.read(view);

  static const _digest = Bytes(0, size: 16);

  static const layout = ByteLayout([_digest]);
}
