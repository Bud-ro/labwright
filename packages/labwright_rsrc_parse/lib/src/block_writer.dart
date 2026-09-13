import 'dart:typed_data';

import 'blocks/BFAL_align_table.dart';
import 'blocks/CONP_CPC2_connector_pane.dart';
import 'blocks/DTHP_data_type_heap.dart';
import 'blocks/FTAB_font_table.dart';
import 'blocks/HIST_history.dart';
import 'blocks/HLPP_DLLP_help_path.dart';
import 'blocks/LIvi_LIbd_LIfp_LIds_link_info.dart';
import 'blocks/LVSR_save_record.dart';
import 'blocks/NUID_SUID_BNID_id_table.dart';
import 'blocks/STRG_HLPT_string_block.dart';
import 'blocks/TM80_type_map.dart';
import 'blocks/VITS_tag_store.dart';
import 'blocks/aux_records.dart';
import 'blocks/icl8_icl4_ICON_icon.dart';
import 'blocks/small_records.dart';
import 'blocks/vers_version.dart';

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
  'BFAL' ||
  'PRT ' ||
  'FPTD' ||
  'HLPT' ||
  'HLPP' ||
  'FTAB' ||
  'BKMK' ||
  'TRec' ||
  'CCST' ||
  'CPST' ||
  'CPSP' ||
  'BDTS' => true,
  _ => false,
};

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
    'PRT ' => decodePrintRecord(payload)?.serialize(),
    'FPTD' => decodeU16Grid(payload)?.serialize(),
    'HLPT' => decodeStringBlockRaw(payload)?.serialize(),
    'HLPP' => decodeHelpPath(payload)?.serialize(),
    'FTAB' => _serializeFontTable(payload),
    'BKMK' => decodeBookmarkList(payload)?.serialize(),
    'TRec' => decodeTextRecord(payload)?.serialize(),
    'CCST' => decodeKeyValueTable(payload)?.serialize(),
    'CPST' || 'CPSP' => decodePascalStringTable(payload)?.serialize(),
    'BDTS' => decodeWordGrid(payload)?.serialize(),
    _ => null,
  };
  if (out == null || out.length != payload.length) return null;
  for (var i = 0; i < out.length; i++) {
    if (out[i] != payload[i]) return null;
  }
  return out;
}

Uint8List? _serializeFontTable(Uint8List payload) {
  final ft = decodeFontTable(payload);
  return ft != null && ft.nameTableComplete ? ft.serialize() : null;
}

Uint8List? _serializeLinkInfo(Uint8List payload, ViVersionWord? version) {
  final info = decodeLinkInfoRaw(payload, version: version);
  return info != null && info.tiled ? info.serialize() : null;
}
