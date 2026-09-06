import 'dart:typed_data';

import 'align_table.dart';
import 'aux_records.dart';
import 'connector_pane.dart';
import 'data_type_heap.dart';
import 'font_table.dart';
import 'help_path.dart';
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
