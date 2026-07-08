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
String? decodeStringBlock(Uint8List bytes) {
  if (bytes.length < 4) return null;
  final len = ByteData.sublistView(bytes).getUint32(0);
  final end = (4 + len).clamp(4, bytes.length);
  return utf8.decode(bytes.sublist(4, end), allowMalformed: true);
}

/// A byte-exact `STRG` model: the `u32` length prefix and the description text
/// bytes retained verbatim. The `[u32 len][len bytes]` framing is understood
/// (`len == body.length` across the corpus); the text bytes are a leaf retained
/// as-is so [serialize] reproduces the body exactly, including any non-UTF-8
/// bytes the lossy [decodeStringBlock] would fold to U+FFFD.
class ViStringBlock {
  const ViStringBlock({required this.declaredLength, required this.body});

  /// The `u32` at offset 0 — the declared body byte length.
  final int declaredLength;

  /// The description text bytes (`body.length == declaredLength` in the corpus).
  final Uint8List body;

  /// Re-emits `[u32 declaredLength][body]`.
  Uint8List serialize() {
    final out = Uint8List(4 + body.length);
    ByteData.sublistView(out).setUint32(0, declaredLength);
    out.setRange(4, 4 + body.length, body);
    return out;
  }
}

/// Decodes a `STRG` body into a byte-exact [ViStringBlock]; null when the buffer
/// cannot hold the `u32` length prefix. Total.
ViStringBlock? decodeStringBlockRaw(Uint8List bytes) {
  if (bytes.length < 4) return null;
  final declaredLength = ByteData.sublistView(bytes).getUint32(0);
  return ViStringBlock(declaredLength: declaredLength, body: Uint8List.sublistView(bytes, 4));
}
