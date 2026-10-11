import 'byte_layout.dart';
import 'byte_record.dart';

/// A payload that is a run of u32 words: the base of the `CNST`, `LPIN`, `FPEx`, `BDEx`,
/// `COUT` and `DLDR` models, which differ only in their layouts.
base class ViWordGrid extends ByteRecord {
  ViWordGrid(super.bytes, super.layout) {
    assert(view.lengthInBytes % 4 == 0, 'a word grid is a run of u32 words');
  }

  int get length => _words.lengthIn(view);

  int operator [](int index) => _words.at(view, index);

  static const _words = U32List(0);
}
