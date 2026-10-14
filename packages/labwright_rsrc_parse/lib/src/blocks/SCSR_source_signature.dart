/// `SCSR` - Source Signature: [ViSourceSignature]
///
/// A little-endian version word, 1 in all but two LabVIEW 8.6 files, and a 16-byte digest that
/// does not sign the VI: it is one constant in 3217 of 3304 files across LabVIEW 11 to 25, zero
/// before LabVIEW 11, and one of a few other values in VIs saved for RT and FPGA targets.
///
/// ```text
/// offset  size  field    type   meaning
/// 0       4     version  u32le  Always 1.
/// 4       16    digest   u8[16] The digest; what it signs is not decoded.
/// ```
library;

import 'dart:typed_data';

import '../byte_layout.dart';
import '../byte_record.dart';

final class ViSourceSignature extends ByteRecord {
  ViSourceSignature(Uint8List bytes) : super(bytes, layout);

  /// Always 1.
  int get version => _version.read(view);

  /// The digest; what it signs is not decoded.
  Uint8List get digest => _digest.read(view);

  static Uint8List encode({int version = 1, required List<int> digest}) {
    final out = Uint8List(layout.size!);
    final view = ByteData.sublistView(out);
    _version.write(view, version);
    _digest.write(view, digest);
    return out;
  }

  static const _version = U32(0, endian: Endian.little);
  static const _digest = Bytes(4, size: 16);

  static const layout = ByteLayout([_version, _digest]);
}
