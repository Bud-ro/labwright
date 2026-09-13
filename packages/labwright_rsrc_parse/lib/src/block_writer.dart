import 'dart:typed_data';

import 'block_tag.dart';
import 'decode.dart';

/// Whether [serializeBlockPayload] has a model for the tag.
bool hasBlockWriter(String tag) => BlockTag.of(tag)?.hasWriter ?? false;

/// The payload re-emitted through the tag's model, or null when the tag has no writer, the
/// payload still carries the zlib envelope, or the re-emitted bytes differ.
Uint8List? serializeBlockPayload(String tag, Uint8List payload) {
  final blockTag = BlockTag.of(tag);
  if (blockTag == null || !blockTag.hasWriter) return null;
  if (blockTag.isEnveloped && isCompressedHeapPayload(payload)) return null;
  final out = blockTag.decodeRecord(payload)!.serialize();
  if (out.length != payload.length) return null;
  for (var i = 0; i < out.length; i++) {
    if (out[i] != payload[i]) return null;
  }
  return out;
}
