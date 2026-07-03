/// Decoder for the `STRG` block — a length-prefixed text blob holding the VI's
/// **description** (the prose shown in NI's example browser / Context Help).
///
/// Corpus-confirmed (2980/2980 = 100%): the layout is `[u32 byteLength][bytes]`,
/// where `byteLength == sectionLength - 4` and the body is UTF-8/ASCII text
/// (>90% printable in 100% of corpus STRG). Clean-room.
library;

import 'dart:convert';
import 'dart:typed_data';

/// Decodes a `STRG` body (`[u32 len][len bytes UTF-8]`) into its text. Returns
/// null when the buffer can't hold the length prefix. UTF-8 is decoded leniently
/// (malformed bytes become U+FFFD) so a stray byte never throws.
String? decodeStringBlock(Uint8List b) {
  if (b.length < 4) return null;
  final len = ByteData.sublistView(b).getUint32(0);
  final end = (4 + len) <= b.length ? 4 + len : b.length;
  return utf8.decode(b.sublist(4, end), allowMalformed: true);
}
