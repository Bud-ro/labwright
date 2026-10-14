/// `BDPW` - Block-Diagram Password: [ViPasswordRecord]
///
/// The MD5 digest of the block-diagram password and two additional unknown digests.
/// Can be 2 or 3 digests (32/48) bytes.
///
/// ```text
/// offset  size  field          type    meaning
/// 0       16    passwordDigest u8[16]  MD5 of the password, MD5("") when unprotected.
/// 16      16    digest2        u8[16]  Derived digest; derivation TODO.
/// 32      16    digest3        u8[16]? Derived digest; derivation TODO; null in the 32-byte form.
/// ```
library;

import 'dart:typed_data';

import '../byte_layout.dart';
import '../byte_record.dart';

/// MD5 of the empty string, the password digest of an unprotected VI.
const List<int> emptyPasswordDigest = [
  0xd4, 0x1d, 0x8c, 0xd9, 0x8f, 0x00, 0xb2, 0x04, //
  0xe9, 0x80, 0x09, 0x98, 0xec, 0xf8, 0x42, 0x7e,
];

final class ViPasswordRecord extends ByteRecord {
  ViPasswordRecord(Uint8List bytes) : super(bytes, layout) {
    assert(
      view.lengthInBytes == _digest3.end || view.lengthInBytes == _digest2.end,
      'BDPW holds three digests, or two',
    );
  }

  /// MD5 of the password, MD5("") when unprotected.
  Uint8List get passwordDigest => _passwordDigest.read(view);

  /// Derived digest; derivation TODO.
  Uint8List get digest2 => _digest2.read(view);

  /// Derived digest; derivation TODO; null in the 32-byte form.
  Uint8List? get digest3 => _digest3.isIn(view) ? _digest3.read(view) : null;

  bool get isUnprotected {
    final digest = passwordDigest;
    for (var i = 0; i < digest.length; i++) {
      if (digest[i] != emptyPasswordDigest[i]) return false;
    }
    return true;
  }

  /// The record of three digests, or of two when [digest3] is null.
  static Uint8List encode({required List<int> passwordDigest, required List<int> digest2, List<int>? digest3}) {
    final out = Uint8List(digest3 == null ? _digest2.end : _digest3.end);
    final view = ByteData.sublistView(out);
    _passwordDigest.write(view, passwordDigest);
    _digest2.write(view, digest2);
    if (digest3 != null) _digest3.write(view, digest3);
    return out;
  }

  static const _passwordDigest = Bytes(0, size: 16);
  static const _digest2 = Bytes(16, size: 16);
  static const _digest3 = Bytes(32, size: 16, optional: true);

  static const layout = ByteLayout([_passwordDigest, _digest2, _digest3]);
}
