/// Decoder for the `STRG` block — a length-prefixed text blob holding the VI's
/// **description** (the prose shown in NI's example browser / Context Help).
///
/// Corpus-confirmed (2980/2980 = 100%): the layout is `[u32 byteLength][bytes]`,
/// where `byteLength == sectionLength - 4` and the body is UTF-8/ASCII text
/// (>90% printable in 100% of corpus STRG). Clean-room.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'viparse.dart' show ViSection;

/// Decodes a `STRG` body (`[u32 len][len bytes UTF-8]`) into its text. Returns
/// null when the buffer can't hold the length prefix. UTF-8 is decoded leniently
/// (malformed bytes become U+FFFD) so a stray byte never throws.
String? decodeStringBlock(Uint8List b) {
  if (b.length < 4) return null;
  final len = ByteData.sublistView(b).getUint32(0);
  final end = (4 + len) <= b.length ? 4 + len : b.length;
  return utf8.decode(b.sublist(4, end), allowMalformed: true);
}

/// Finds the `STRG` section and decodes its text. Null if absent. (`STRG` is
/// uncompressed, so raw [ViSection] bytes suffice.)
String? stringBlockFromSections(Iterable<ViSection> sections) {
  for (final s in sections) {
    if (s.tag == 'STRG') return decodeStringBlock(s.bytes);
  }
  return null;
}

/// Finds the `HLPT` (help tag/text) section and decodes its text. `HLPT` uses the
/// SAME `[u32 len][UTF-8 text]` layout as `STRG` — corpus-confirmed (200/200:
/// len == sectionLen-4, printable body) — so it reuses [decodeStringBlock]. The
/// text is the markdown-ish context help (e.g. `### Format Timestamp.vi`). Null
/// if absent.
String? helpTextFromSections(Iterable<ViSection> sections) {
  for (final s in sections) {
    if (s.tag == 'HLPT') return decodeStringBlock(s.bytes);
  }
  return null;
}
