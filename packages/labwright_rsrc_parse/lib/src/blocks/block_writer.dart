/// The **block-payload writer registry** — the inverse of the block decoders.
///
/// `ViVi.serialize` re-emits every container/info-area struct from its typed
/// model, but each section's *payload* is copied verbatim from the input. This
/// registry re-emits a payload from its decoded model instead: it decodes the
/// payload with the block's decoder and re-serializes it, returning the
/// reconstructed bytes.
///
/// The registry is **defensive**: [serializeBlockPayload] returns null unless
/// the round-trip reproduces the payload byte-for-byte, so a caller adopts the
/// model-sourced bytes when they match and falls back to the verbatim payload
/// otherwise — the file stays byte-exact regardless. A mismatch on a block that
/// *should* round-trip is a model bug (a dropped/lossy field); the per-block
/// corpus round-trip tests assert N/N so such a regression is loud.
///
/// Payloads stored **compressed** (the zlib heap sections) are not modelable
/// here — NI's deflate is not bit-reproducible by Dart's zlib, so those
/// payloads stay copy-verbatim. Only payloads whose *stored* bytes equal a
/// decoder's re-serialization are model-sourced.
///
/// Covered blocks (byte-exact for every corpus instance):
///   * `icl8` / `icl4` / `ICON` — legacy 32×32 icon bitmaps ([ViLegacyIcon]).
///   * `NUID` / `SUID` / `BNID` — `[u32 count][u32…]` id tables ([ViIdTable]).
library;

import 'dart:typed_data';

import 'id_table.dart';
import 'legacy_icon.dart';

/// Whether [tag] has a byte-exact payload writer registered (i.e. its decoded
/// model can re-emit the stored payload). Independent of any specific payload —
/// use it to census which block types are model-sourceable.
bool hasBlockWriter(String tag) => switch (tag) {
  'icl8' || 'icl4' || 'ICON' || 'NUID' || 'SUID' || 'BNID' => true,
  _ => false,
};

/// Re-serializes a block [payload] from its decoded model and returns the bytes
/// **iff** they reproduce [payload] exactly; otherwise null (no writer for
/// [tag], the decode failed, or the round-trip was not byte-exact). The exact
/// check makes adoption safe: model-source the payload when non-null, else keep
/// it verbatim. `serializeBlockPayload(tag, p) == p` for every corpus instance
/// of a covered [tag].
Uint8List? serializeBlockPayload(String tag, Uint8List payload) {
  final out = switch (tag) {
    'icl8' || 'icl4' || 'ICON' => decodeLegacyIcon(payload, legacyIconBpp(tag)!)?.serialize(),
    'NUID' || 'SUID' || 'BNID' => decodeIdTable(payload)?.serialize(),
    _ => null,
  };
  if (out == null || out.length != payload.length) return null;
  for (var i = 0; i < out.length; i++) {
    if (out[i] != payload[i]) return null;
  }
  return out;
}
