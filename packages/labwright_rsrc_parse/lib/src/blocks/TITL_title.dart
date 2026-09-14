/// `TITL` — VI title: one Pascal string.
///
/// ```text
/// offset  size  field                      type     meaning
/// 0       rest  title                      pstr     the VI title
/// ```
///
/// [ViTitle] is a view over the payload; [decodeTitle] requires the string to end the
/// payload exactly.
library;

import 'dart:typed_data';

import '../block_layout.dart';

const _title = BlockField(0, null, 'title', 'pstr', 'the VI title');

const BlockLayout titlLayout = [_title];

/// A view over a `TITL` payload.
class ViTitle {
  const ViTitle._(this.bytes);

  final Uint8List bytes;

  String get text => String.fromCharCodes(bytes, 1);

  Uint8List serialize() => bytes;
}

ViTitle decodeTitle(Uint8List bytes) {
  assert(bytes.isNotEmpty && 1 + bytes[0] == bytes.length, 'a title is one Pascal string');
  return ViTitle._(bytes);
}
