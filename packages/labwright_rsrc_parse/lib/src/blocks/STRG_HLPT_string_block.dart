/// `STRG` / `HLPT` — the VI description and the context-help text: a length-prefixed UTF-8
/// string.
///
/// ```text
/// offset  size  field                      type     meaning
/// 0       4     length                     u32      bytes of text
/// 4       rest  text                       u8[length] UTF-8 text
/// ```
///
/// [ViStringBlock] is a view over the payload; [decodeStringBlock] requires the length word
/// to cover the payload exactly.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../block_layout.dart';
import '../block_record.dart';

const _length = BlockField(0, 4, 'length', 'u32', 'bytes of text');
const _text = BlockField(4, null, 'text', 'u8[length]', 'UTF-8 text');

const BlockLayout stringBlockLayout = [_length, _text];

/// A view over an `STRG` or `HLPT` payload.
class ViStringBlock implements BlockRecord {
  const ViStringBlock._(this.bytes);

  final Uint8List bytes;

  Uint8List get body => Uint8List.sublistView(bytes, _text.offset);

  String get text => utf8.decode(body, allowMalformed: true);

  @override
  Uint8List serialize() => bytes;
}

ViStringBlock decodeStringBlock(Uint8List bytes) {
  assert(bytes.length >= _text.offset, 'a string block starts with its length word');
  assert(
    _text.offset + ByteData.sublistView(bytes).getUint32(_length.offset) == bytes.length,
    'the text fills the payload',
  );
  return ViStringBlock._(bytes);
}
