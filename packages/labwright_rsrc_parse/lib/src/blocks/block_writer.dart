/// The **block-payload writer registry** — the inverse of the block decoders.
///
/// Milestone 1 of the byte-exact `.vi` writer. `ViVi.serialize` already re-emits
/// every container/info-area struct from its typed model, but each section's
/// *payload* is copied verbatim from the input. This registry converts a
/// payload from copied → model-sourced: it decodes the payload with the block's
/// existing decoder and re-serializes it, returning the reconstructed bytes.
///
/// The registry is deliberately **defensive**: [serializeBlockPayload] returns
/// null unless the round-trip reproduces the payload byte-for-byte. So a caller
/// (the writer scoreboard, a future editor) can adopt the model-sourced bytes
/// when they match and fall back to the verbatim payload otherwise — the whole
/// file stays byte-exact regardless, while the fraction of payload bytes proven
/// to be model-sourced climbs as more block writers are added. A mismatch on a
/// block that *should* round-trip is a model bug (a dropped/lossy field); the
/// per-block corpus round-trip tests assert N/N so such a regression is loud.
///
/// Payloads stored **compressed** (the zlib heap sections) are intentionally not
/// modelable here — NI's deflate is not bit-reproducible by Dart's zlib, so
/// those payloads must stay copy-verbatim permanently. Only payloads whose
/// *stored* bytes equal a decoder's re-serialization are model-sourced.
///
/// Covered so far (all byte-exact for every corpus instance):
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
