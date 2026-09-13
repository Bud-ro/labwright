/// `COUT` — compiled output: three u32 words.
///
/// ```text
/// offset  size  field                      type     meaning
/// 0       12    words                      u32[3]   roles TODO
/// ```
///
/// [decodeCoutRecord] requires exactly 12 bytes and returns a [ViWordGrid].
library;

import 'dart:typed_data';

import '../block_layout.dart';
import 'CNST_LPIN_BDTS_word_grid.dart';

const _words = BlockField(0, 12, 'words', 'u32[3]', 'roles TODO');

const BlockLayout coutLayout = [_words];

ViWordGrid decodeCoutRecord(Uint8List bytes) {
  assert(bytes.length == _words.end, 'COUT is three u32 words');
  return ViWordGrid(bytes);
}
