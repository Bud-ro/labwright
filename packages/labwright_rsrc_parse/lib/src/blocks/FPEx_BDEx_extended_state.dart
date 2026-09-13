/// `FPEx` / `BDEx` — front-panel and block-diagram extended state: a run of u32 words.
///
/// ```text
/// offset  size  field                      type     meaning
/// 0       rest  words                      u32[]    state words; roles TODO
/// ```
///
/// [decodeExtendedState] requires a non-empty whole number of u32 words and returns a
/// [ViWordGrid].
library;

import 'dart:typed_data';

import '../block_layout.dart';
import 'CNST_LPIN_BDTS_word_grid.dart';

const _words = BlockField(0, null, 'words', 'u32[]', 'state words; roles TODO');

const BlockLayout extendedStateLayout = [_words];

ViWordGrid decodeExtendedState(Uint8List bytes) {
  assert(bytes.isNotEmpty && bytes.length % 4 == 0, 'extended state is a non-empty run of u32 words');
  return ViWordGrid(bytes);
}
