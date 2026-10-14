/// `STRG` / `HLPT` - VI Description and Help Tag: [ViStringBlock]
///
/// The two text fields of VI Properties » Documentation: `STRG` is the VI description, `HLPT`
/// the help tag that names the VI's topic in the help file `HLPP` points at. The text is 8-bit
/// in the saving platform's code page, Windows-1252 in the corpus, never UTF-8; line breaks are
/// CR LF, CR or LF.
///
/// ```text
/// offset  size   field    type       meaning
/// 0       4      length   u32        Bytes of text.
/// 4       length text     u8[length] The text bytes.
/// ```
library;

import 'dart:convert';
import 'dart:typed_data';

import '../byte_layout.dart';
import '../byte_record.dart';

final class ViStringBlock extends ByteRecord {
  ViStringBlock(Uint8List bytes) : super(bytes, layout) {
    assert(_text.endIn(view) == view.lengthInBytes, 'the text fills the payload');
  }

  /// The text, decoded byte for byte; bytes 0x80 to 0x9F are Windows-1252 punctuation.
  String get text => latin1.decode(body);

  /// The text bytes.
  Uint8List get body => _text.read(view);

  /// The block of [text], one byte per character.
  static Uint8List encode(String text) {
    final body = latin1.encode(text);
    final out = Uint8List(_text.offset + body.length);
    final view = ByteData.sublistView(out);
    _length.write(view, body.length);
    _text.write(view, body);
    return out;
  }

  static const _length = U32(0); // Bytes of text.
  static const _text = Bytes(4, count: _length);

  static const layout = ByteLayout([_length, _text]);
}
