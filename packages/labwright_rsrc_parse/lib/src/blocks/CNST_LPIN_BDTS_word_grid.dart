/// `CNST` / `LPIN` / `BDTS` — runs of u32 words whose roles are not decoded.
///
/// ```text
/// offset  size  field                      type     meaning
/// 0       rest  words                      u32[]    roles TODO
/// ```
///
/// [ViWordGrid] is a view over any whole-word payload and also backs `FPEx`, `BDEx`, `COUT`
/// and `DLDR`; [decodeWordGrid] requires a whole number of u32 words, possibly none.
library;

import 'dart:typed_data';

import '../block_layout.dart';
import '../block_record.dart';

const _words = BlockField(0, null, 'words', 'u32[]', 'roles TODO');

const BlockLayout wordGridLayout = [_words];

/// A view over a payload made of u32 words.
class ViWordGrid implements BlockRecord {
  ViWordGrid(this.bytes) : _view = ByteData.sublistView(bytes);

  final Uint8List bytes;

  final ByteData _view;

  int get length => bytes.length ~/ 4;

  int operator [](int index) => _view.getUint32(4 * index);

  @override
  Uint8List serialize() => bytes;
}

ViWordGrid decodeWordGrid(Uint8List bytes) {
  assert(bytes.length % 4 == 0, 'a word grid is a run of u32 words');
  return ViWordGrid(bytes);
}
