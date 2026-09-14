/// `GCPR` / `VPDP` — generated-code property and VI property data: fixed-size records that
/// are all zero in every file seen.
///
/// ```text
/// GCPR:
/// offset  size  field                      type     meaning
/// 0       13    body                       u8[13]   zero; roles TODO
/// VPDP:
/// offset  size  field                      type     meaning
/// 0       4     body                       u8[4]    zero; roles TODO
/// ```
///
/// [ViConstantRecord] is a view over the payload; [decodeGcprRecord] requires 13 bytes and
/// [decodeVpdpRecord] 4.
library;

import 'dart:typed_data';

import '../block_layout.dart';

const _gcprBody = BlockField(0, 13, 'body', 'u8[13]', 'zero; roles TODO');
const _vpdpBody = BlockField(0, 4, 'body', 'u8[4]', 'zero; roles TODO');

const BlockLayout gcprLayout = [_gcprBody];

const BlockLayout vpdpLayout = [_vpdpBody];

/// A view over a `GCPR` or `VPDP` payload.
class ViConstantRecord {
  const ViConstantRecord._(this.bytes);

  final Uint8List bytes;

  bool get isZero => bytes.every((b) => b == 0);

  Uint8List serialize() => bytes;
}

ViConstantRecord decodeGcprRecord(Uint8List bytes) {
  assert(bytes.length == _gcprBody.end, 'GCPR is 13 bytes');
  return ViConstantRecord._(bytes);
}

ViConstantRecord decodeVpdpRecord(Uint8List bytes) {
  assert(bytes.length == _vpdpBody.end, 'VPDP is 4 bytes');
  return ViConstantRecord._(bytes);
}
