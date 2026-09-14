/// `RTSG` / `OBSG` / `CCSG` — run-time, object and compiled-code signatures: one 16-byte
/// digest each.
///
/// ```text
/// offset  size  field                      type     meaning
/// 0       16    digest                     u8[16]   signature digest; derivation TODO
/// ```
///
/// [ViSignature] is a view over the payload; [decodeSignature] requires exactly 16 bytes.
library;

import 'dart:typed_data';

import '../block_layout.dart';

const _digest = BlockField(0, 16, 'digest', 'u8[16]', 'signature digest; derivation TODO');

const BlockLayout signatureLayout = [_digest];

/// A view over an `RTSG`, `OBSG` or `CCSG` payload.
class ViSignature {
  const ViSignature._(this.bytes);

  final Uint8List bytes;

  Uint8List get digest => bytes;

  Uint8List serialize() => bytes;
}

ViSignature decodeSignature(Uint8List bytes) {
  assert(bytes.length == _digest.end, 'a signature block is one 16-byte digest');
  return ViSignature._(bytes);
}
