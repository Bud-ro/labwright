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
/// Covered blocks:
///   * `icl8` / `icl4` / `ICON` — legacy 32×32 icon bitmaps ([ViLegacyIcon]).
///   * `NUID` / `SUID` / `BNID` — `[u32 count][u32…]` id tables ([ViIdTable]).
///   * `vers` — version block ([ViVersBlock]); every corpus instance.
///   * `VITS` — VI tag store ([ViTagStore]); the sections whose entry walk
///     consumes the whole body (the flat `[nameLen][name][payloadLen][payload]`
///     grammar). Sections carrying a nested per-entry interior (notably the
///     `NI_IconEditor` editor-state entry) do not re-serialize and stay copied.
///   * `DTHP` — data-type heap ([ViDataTypeHeap]); the 4-byte header-only form.
///   * `CONP` / `CPC2` — connector-pane index ([ViConnectorPane]); the 2-byte
///     index form (the inline form stays copied).
///   * `STRG` — VI description string ([ViStringBlock]); `[u32 len][text]`,
///     every corpus instance.
///   * `HIST` — revision-history record ([ViHistory]); the fixed 40-byte
///     ten-word form, every corpus instance.
///   * `LVSR` — LabVIEW save record ([ViSaveRecordRaw]); the word-aligned
///     lengths read as a u32 grid (a handful of non-aligned records stay copied).
///   * `MUID` — modified-UID ([ViModifiedUid]); the 4-byte u32.
///   * `BDSE` / `FPSE` — block-diagram/front-panel section markers
///     ([ViSectionMarker]); the 4- or 8-byte u32 form.
///   * `BDEx` / `FPEx` — extended-state flag-word grids ([ViExtendedState]).
///   * `IPSR` — offset table ([ViOffsetTable]); a big-endian u32 grid.
///   * `PICC` — icon-placement record ([ViIconPlacement]); six u16s.
///   * `CPMp` — connector-pane map ([ViConnectorPaneMap]); `[u16le count]` +
///     u16le entries.
///   * `GCPR` — generated-code property ([ViConstantRecord]); the 13-byte
///     all-zero constant.
///   * `RTSG` — run-time signature ([ViSignature]); a 16-byte identity value.
///   * `SCSR` — source signature ([ViScsrRecord]); `[u32 marker][16-byte sig]`.
///   * `BDPW` — block-diagram password ([ViPasswordRecord]); two or three
///     16-byte digests.
///   * `LIbd` / `LIvi` / `LIfp` / `LIds` — link-info ([ViLinkInfoRaw]); the
///     header/terminator framing with the entry region retained, for the
///     deterministically-bounded ≤1-entry sections (many-entry sections stay
///     copied — see [ViLinkInfoRaw.tiled]).
library;

import 'dart:typed_data';

import 'aux_records.dart';
import 'connector_pane.dart';
import 'data_type_heap.dart';
import 'history.dart';
import 'id_table.dart';
import 'legacy_icon.dart';
import 'link_info.dart';
import 'save_record.dart';
import 'small_records.dart';
import 'string_block.dart';
import 'tag_store.dart';
import 'version_word.dart';

/// Whether [tag] has a byte-exact payload writer registered (i.e. its decoded
/// model can re-emit the stored payload). Independent of any specific payload —
/// use it to census which block types are model-sourceable.
bool hasBlockWriter(String tag) => switch (tag) {
  'icl8' ||
  'icl4' ||
  'ICON' ||
  'NUID' ||
  'SUID' ||
  'BNID' ||
  'vers' ||
  'VITS' ||
  'DTHP' ||
  'CONP' ||
  'CPC2' ||
  'STRG' ||
  'HIST' ||
  'LVSR' ||
  'MUID' ||
  'BDSE' ||
  'FPSE' ||
  'BDEx' ||
  'FPEx' ||
  'IPSR' ||
  'PICC' ||
  'CPMp' ||
  'GCPR' ||
  'RTSG' ||
  'SCSR' ||
  'BDPW' ||
  'LIbd' ||
  'LIvi' ||
  'LIfp' ||
  'LIds' => true,
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
    'vers' => decodeVersBlock(payload)?.serialize(),
    'VITS' => decodeTagStore(payload)?.serialize(),
    'DTHP' => decodeDataTypeHeap(payload)?.serialize(),
    'CONP' || 'CPC2' => decodeConnectorPane(payload)?.serialize(),
    'STRG' => decodeStringBlockRaw(payload)?.serialize(),
    'HIST' => decodeHistory(payload)?.serialize(),
    'LVSR' => decodeSaveRecordRaw(payload)?.serialize(),
    'MUID' => decodeModifiedUid(payload)?.serialize(),
    'BDSE' || 'FPSE' => decodeSectionMarker(payload)?.serialize(),
    'BDEx' || 'FPEx' => decodeExtendedState(payload)?.serialize(),
    'IPSR' => decodeOffsetTable(payload)?.serialize(),
    'PICC' => decodeIconPlacement(payload)?.serialize(),
    'CPMp' => decodeConnectorPaneMap(payload)?.serialize(),
    'GCPR' => decodeGcprRecord(payload)?.serialize(),
    'RTSG' => decodeRuntimeSignature(payload)?.serialize(),
    'SCSR' => decodeScsrRecord(payload)?.serialize(),
    'BDPW' => decodePasswordRecord(payload)?.serialize(),
    'LIbd' || 'LIvi' || 'LIfp' || 'LIds' => _serializeLinkInfo(payload),
    _ => null,
  };
  if (out == null || out.length != payload.length) return null;
  for (var i = 0; i < out.length; i++) {
    if (out[i] != payload[i]) return null;
  }
  return out;
}

/// Re-emits a `LI*` payload from [ViLinkInfoRaw] only when the section is
/// deterministically bounded ([ViLinkInfoRaw.tiled] — a ≤1-entry section);
/// many-entry sections return null so they stay copied.
Uint8List? _serializeLinkInfo(Uint8List payload) {
  final info = decodeLinkInfoRaw(payload);
  return info != null && info.tiled ? info.serialize() : null;
}
