/// `PRT ` — print settings: a 128-byte record of u32 words, occasionally with one or two
/// more.
///
/// ```text
/// offset  size  field                      type     meaning
/// 0       128   words                      u32[32]  roles TODO; words 23 to 26 read as
///                                                   little-endian float32
/// optional, when the record exceeds 128 bytes:
/// 128     rest  extra                      u32[]    roles TODO
/// ```
///
/// [ViPrintRecord] is a view over the payload; [decodePrintRecord] requires at least
/// 128 bytes in whole u32 words.
library;

import 'dart:typed_data';

import '../block_layout.dart';
import '../block_record.dart';

const _words = BlockField(0, 128, 'words', 'u32[32]', 'roles TODO; words 23 to 26 read as little-endian float32');
const _extra = BlockField(128, null, 'extra', 'u32[]', 'roles TODO', optional: 'the record exceeds 128 bytes');

const BlockLayout prtLayout = [_words, _extra];

/// A view over a `PRT ` payload.
class ViPrintRecord implements BlockRecord {
  ViPrintRecord._(this.bytes) : _view = ByteData.sublistView(bytes);

  final Uint8List bytes;

  final ByteData _view;

  int get length => bytes.length ~/ 4;

  int operator [](int index) => _view.getUint32(4 * index);

  @override
  Uint8List serialize() => bytes;
}

ViPrintRecord decodePrintRecord(Uint8List bytes) {
  assert(bytes.length >= _words.end && bytes.length % 4 == 0, 'PRT is at least 32 u32 words');
  return ViPrintRecord._(bytes);
}
