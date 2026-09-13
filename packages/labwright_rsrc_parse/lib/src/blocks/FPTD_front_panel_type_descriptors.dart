/// `FPTD` — front-panel type descriptors: a run of u16 words, one in the common form.
///
/// ```text
/// offset  size  field                      type     meaning
/// 0       rest  words                      u16[]    roles TODO
/// ```
///
/// [ViU16Grid] is a view over the payload; [decodeU16Grid] requires a non-empty whole number
/// of u16 words.
library;

import 'dart:typed_data';

import '../block_layout.dart';
import '../block_record.dart';

const _words = BlockField(0, null, 'words', 'u16[]', 'roles TODO');

const BlockLayout fptdLayout = [_words];

/// A view over a payload made of u16 words.
class ViU16Grid implements BlockRecord {
  ViU16Grid._(this.bytes) : _view = ByteData.sublistView(bytes);

  final Uint8List bytes;

  final ByteData _view;

  int get length => bytes.length ~/ 2;

  int operator [](int index) => _view.getUint16(2 * index);

  @override
  Uint8List serialize() => bytes;
}

ViU16Grid decodeU16Grid(Uint8List bytes) {
  assert(bytes.isNotEmpty && bytes.length % 2 == 0, 'a u16 grid is a non-empty run of u16 words');
  return ViU16Grid._(bytes);
}
