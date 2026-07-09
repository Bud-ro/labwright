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
///     consumes the whole body — the flat `[nameLen][name][payloadLen][payload]`
///     grammar and the nested flattened-variant entries (the `NI_IconEditor`
///     icon image, `_ni_LastKnownOwningLVClassCluster`, `SourceOnly`,
///     `VILastSavedTarget`, `Localized`) framed by their variant length. Sections
///     carrying a nested shape not framed there (a non-final multi-field
///     `goodSyntaxTargets`) stop the walk early and stay copied.
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
///     header/terminator framing with the entry region retained. The 0/1-entry
///     forms and the multi-entry sections whose version-gated entry walk tiles
///     to the terminator model-source; sections using an unhandled link kind or
///     version variant stay copied (see [ViLinkInfoRaw.tiled]).
///   * `DLDR` — default-data loader ([ViWordGrid] via [decodeDldrRecord]); the
///     fixed seven-word `u32` grid.
///   * `CNST` / `LPIN` — constants table / linked-instance info ([ViWordGrid]);
///     variable-length `u32` word grids.
///   * `VPDP` — VI property data ([ViConstantRecord]); the 4-byte all-zero
///     constant, every corpus instance.
///   * `TITL` — VI title ([ViTitleRaw]); the `[u8 len][text]` Pascal string.
///   * `OBSG` / `CCSG` — object / compiled-code signature ([ViSignature]); a
///     16-byte opaque identity value.
///   * `COUT` — compiled output ([ViWordGrid]); the fixed three-word `u32` grid.
///   * `CPD2` — connector-pane data ([ViU16Record]); the fixed 2-byte `u16`.
///   * `TM80` — data-space type map ([ViTypeMap]); the variable-field
///     `[count][indexShift][flags…]` form (the uncompressed instances; the
///     compressed ones re-emit through the heap-content writer instead).
///   * `BFAL` — align table ([ViAlignTable]); `[u32 count][count × 9-byte
///     record]`, every corpus instance.
library;

import 'dart:typed_data';

import 'align_table.dart';
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
import 'type_map.dart';
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
  'LIds' ||
  'DLDR' ||
  'CNST' ||
  'LPIN' ||
  'VPDP' ||
  'TITL' ||
  'OBSG' ||
  'CCSG' ||
  'COUT' ||
  'CPD2' ||
  'TM80' ||
  'BFAL' => true,
  _ => false,
};

/// Re-serializes a block [payload] from its decoded model and returns the bytes
/// **iff** they reproduce [payload] exactly; otherwise null (no writer for
/// [tag], the decode failed, or the round-trip was not byte-exact). The exact
/// check makes adoption safe: model-source the payload when non-null, else keep
/// it verbatim. `serializeBlockPayload(tag, p) == p` for every corpus instance
/// of a covered [tag].
///
/// [version] is the file's LabVIEW save version; the `LI*` link-info writer uses
/// it to recover multi-entry boundaries (its per-entry field widths are
/// version-gated). Absent it, only the 0/1-entry link-info forms model-source.
Uint8List? serializeBlockPayload(String tag, Uint8List payload, {ViVersionWord? version}) {
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
    'LIbd' || 'LIvi' || 'LIfp' || 'LIds' => _serializeLinkInfo(payload, version),
    'DLDR' => decodeDldrRecord(payload)?.serialize(),
    'CNST' || 'LPIN' => decodeWordGrid(payload)?.serialize(),
    'VPDP' => decodeVpdpRecord(payload)?.serialize(),
    'TITL' => decodeTitleRaw(payload)?.serialize(),
    'OBSG' || 'CCSG' => decodeRuntimeSignature(payload)?.serialize(),
    'COUT' => decodeWordGrid(payload, words: 3)?.serialize(),
    'CPD2' => decodeCpd2Record(payload)?.serialize(),
    'TM80' => reserializeTypeMap(payload),
    'BFAL' => decodeAlignTable(payload)?.serialize(),
    _ => null,
  };
  if (out == null || out.length != payload.length) return null;
  for (var i = 0; i < out.length; i++) {
    if (out[i] != payload[i]) return null;
  }
  return out;
}

/// Re-emits a `LI*` payload from [ViLinkInfoRaw] only when its entry boundaries
/// are recovered ([ViLinkInfoRaw.tiled]): the 0/1-entry forms, plus multi-entry
/// sections whose version-gated entry walk tiles to the terminator. Sections
/// using an unhandled link kind or version variant return null and stay copied.
Uint8List? _serializeLinkInfo(Uint8List payload, ViVersionWord? version) {
  final info = decodeLinkInfoRaw(payload, version: version);
  return info != null && info.tiled ? info.serialize() : null;
}
