/// `BDPW` — block-diagram password: the MD5 digest of the password and two digests derived
/// from it.
///
/// ```text
/// offset  size  field                      type     meaning
/// 0       16    passwordDigest             u8[16]   MD5 of the password, MD5("") when unprotected
/// 16      16    digest2                    u8[16]   derived digest; derivation TODO
/// optional, when the record is 48 bytes:
/// 32      16    digest3                    u8[16]   derived digest; derivation TODO
/// ```
///
/// [ViPasswordRecord] is a view over the payload; [decodePasswordRecord] requires 48 bytes,
/// or 32 for the two-digest form.
library;

import 'dart:typed_data';

import '../block_layout.dart';

/// MD5 of the empty string, the password digest of an unprotected VI.
const List<int> emptyPasswordDigest = [
  0xd4, 0x1d, 0x8c, 0xd9, 0x8f, 0x00, 0xb2, 0x04, //
  0xe9, 0x80, 0x09, 0x98, 0xec, 0xf8, 0x42, 0x7e,
];

const _passwordDigest = BlockField(0, 16, 'passwordDigest', 'u8[16]', 'MD5 of the password, MD5("") when unprotected');
const _digest2 = BlockField(16, 16, 'digest2', 'u8[16]', 'derived digest; derivation TODO');
const _digest3 = BlockField(
  32,
  16,
  'digest3',
  'u8[16]',
  'derived digest; derivation TODO',
  optional: 'the record is 48 bytes',
);

const BlockLayout bdpwLayout = [_passwordDigest, _digest2, _digest3];

/// A view over a `BDPW` payload.
class ViPasswordRecord {
  const ViPasswordRecord._(this.bytes);

  final Uint8List bytes;

  Uint8List get passwordDigest => Uint8List.sublistView(bytes, _passwordDigest.offset, _passwordDigest.end);

  Uint8List get digest2 => Uint8List.sublistView(bytes, _digest2.offset, _digest2.end);

  /// Null in the 32-byte form.
  Uint8List? get digest3 =>
      bytes.length >= _digest3.end ? Uint8List.sublistView(bytes, _digest3.offset, _digest3.end) : null;

  bool get isUnprotected {
    final digest = passwordDigest;
    for (var i = 0; i < digest.length; i++) {
      if (digest[i] != emptyPasswordDigest[i]) return false;
    }
    return true;
  }

  Uint8List serialize() => bytes;
}

ViPasswordRecord decodePasswordRecord(Uint8List bytes) {
  assert(bytes.length == _digest3.end || bytes.length == _digest2.end, 'BDPW holds three digests, or two');
  return ViPasswordRecord._(bytes);
}
