/// `FPEx` / `BDEx` - Front-Panel and Block-Diagram Link Extras: [ViLinkEntryWords]
///
/// One u32 per entry of the section's link info, `LIfp` for `FPEx` and `LIbd` for `BDEx`: the
/// count repeats the link info's entry count in every one of the 4783 corpus files that carry
/// the pair, and every word is zero. Every file saved by LabVIEW 2019 or later carries both
/// blocks; earlier files rarely do.
///
/// ```text
/// offset  size    field    type       meaning
/// 0       4       count    u32        The link info's entry count.
/// 4       4·count words    u32[count] The entry's word, zero in every corpus file.
/// ```
library;

import 'dart:typed_data';

import '../byte_layout.dart';
import '../byte_record.dart';

final class ViLinkEntryWords extends ByteRecord {
  ViLinkEntryWords(Uint8List bytes) : super(bytes, layout) {
    assert(_words.endIn(view) == view.lengthInBytes, 'the words tile the payload');
  }

  /// The link info's entry count.
  int get count => _count.read(view);

  /// The entry's word, zero in every corpus file.
  int operator [](int index) => _words.at(view, index);

  static Uint8List encode(List<int> words) {
    final out = Uint8List(_words.offset + _words.wordSize * words.length);
    final view = ByteData.sublistView(out);
    _count.write(view, words.length);
    _words.write(view, words);
    return out;
  }

  static const _count = U32(0);
  static const _words = U32List(4, count: _count);

  static const layout = ByteLayout([_count, _words]);
}
