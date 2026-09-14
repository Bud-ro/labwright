/// `DLDR` — default-data loader record: seven u32 words.
///
/// ```text
/// offset  size  field                      type     meaning
/// 0       28    words                      u32[7]   roles TODO
/// ```
///
/// [decodeDldrRecord] requires exactly 28 bytes and returns a [ViWordGrid].
library;

import 'dart:typed_data';

import '../block_layout.dart';
import 'CNST_LPIN_BDTS_word_grid.dart';

const _words = BlockField(0, 28, 'words', 'u32[7]', 'roles TODO');

const BlockLayout dldrLayout = [_words];

ViWordGrid decodeDldrRecord(Uint8List bytes) {
  assert(bytes.length == _words.end, 'DLDR is seven u32 words');
  return ViWordGrid(bytes);
}
