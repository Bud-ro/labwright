@Tags(['corpus'])
library;

import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

const _probes = <String, List<(String, bool Function(Uint8List))>>{
  'CPMp': [('CPMp', _cpmp)],
  'IPSR': [('IPSR', _ipsr)],
  'GCDI': [('GCDI', _gcdi)],
  'BKMK': [('BKMK', _bkmk)],
  'VITS': [('VITS', _vits)],
  'VICD': [('VICD', _vicd)],
  'DSIM': [('DSIM', _dsim)],
  'MNGI': [('MNGI', _mngi)],
  'BDPW': [('BDPW', _bdpw)],
  'RTSG': [('RTSG', _rtsg)],
  'SCSR': [('SCSR', _scsr)],
  'PICC': [('PICC', _picc)],
  'PRT ': [('PRT ', _prt)],
  'BDSE': [('xxSE', _sectionMarker)],
  'FPSE': [('xxSE', _sectionMarker)],
  'MUID': [('MUID', _muid)],
  'BDEx': [('xxEx', _extendedState)],
  'FPEx': [('xxEx', _extendedState)],
  'GCPR': [('GCPR', _gcpr)],
  'DLDR': [('DLDR', _dldr)],
  'TRec': [('TRec', _trec)],
};

bool _cpmp(Uint8List b) => decodeConnectorPaneMap(b).length >= 0;
bool _ipsr(Uint8List b) => decodeOffsetTable(b).serialize().length == b.length;
bool _gcdi(Uint8List b) => decodeGcdiRecord(b).value >= 0;
bool _bkmk(Uint8List b) => decodeBookmarkList(b).tableA.length >= 0;
bool _vits(Uint8List b) => decodeTagStore(b).entries.length == decodeTagStore(b).declaredCount;
bool _vicd(Uint8List b) => decodeCompiledCode(b).codeSize >= 0;
bool _dsim(Uint8List b) => decodeDataSpaceImage(b).width >= 0;
bool _mngi(Uint8List b) => decodePngStream(b).chunkCount > 0;
bool _bdpw(Uint8List b) => decodePasswordRecord(b).passwordDigest.length == 16;
bool _rtsg(Uint8List b) => decodeSignature(b).digest.length == 16;
bool _scsr(Uint8List b) => decodeSourceSignature(b).digest.length == 16;
bool _picc(Uint8List b) => decodeIconPlacement(b).bytes.length == 12;
bool _prt(Uint8List b) => decodePrintRecord(b).length >= 32;
bool _sectionMarker(Uint8List b) => decodeSectionEntry(b).value >= 0;
bool _muid(Uint8List b) => decodeModifiedUid(b).value >= 0;
bool _extendedState(Uint8List b) => decodeExtendedState(b).length >= 1;
bool _gcpr(Uint8List b) => decodeGcprRecord(b).isZero;
bool _dldr(Uint8List b) => decodeDldrRecord(b).length == 7;
bool _trec(Uint8List b) => decodeTextRecord(b).runCount >= 0;

const _linkInfoTags = {'LIvi', 'LIbd', 'LIfp', 'LIds'};

Map<String, int> _undecoded(Uint8List bytes, String path) {
  final c = <String, int>{};
  final Iterable<DecodedSection> sections;
  try {
    sections = decodeSections(bytes);
  } catch (_) {
    return c;
  }
  final version = versionWordFromSections([for (final section in sections) section.section]);
  for (final section in sections) {
    for (final (key, probe) in _probes[section.tag] ?? const <(String, bool Function(Uint8List))>[]) {
      if (!probe(section.bytes)) c[key] = (c[key] ?? 0) + 1;
    }
    if (_linkInfoTags.contains(section.tag) && !decodeLinkInfo(section.bytes, version: version).isWalked) {
      c['LI**'] = (c['LI**'] ?? 0) + 1;
    }
  }
  return c;
}

const kUndecodedAuxSections = <String, Map<String, int>>{
  'Bud-ro_vi-snippets/Bud-ro-vi-snippets-03f6778/developpez/original_49b367.png': {'LI**': 1},
  'Bud-ro_vi-snippets/Bud-ro-vi-snippets-03f6778/labviewwiki/Constructor_Node_Trivia_(Terminals).png': {'LI**': 2},
  'Bud-ro_vi-snippets/Bud-ro-vi-snippets-03f6778/ni-kb/Accessing_Shared_Variables_From_a_LabVIEW_Web_Service.png': {
    'LI**': 1,
  },
  'Bud-ro_vi-snippets/Bud-ro-vi-snippets-03f6778/ni-kb/Accessing_Shared_Variables_From_a_LabVIEW_Web_Service_2.png': {
    'LI**': 1,
  },
  'Bud-ro_vi-snippets/Bud-ro-vi-snippets-03f6778/ni-kb/Acquiring_Large_Datasets_with_FlexRIO_Integrated_IO_Modules.png':
      {'LI**': 1},
  'Bud-ro_vi-snippets/Bud-ro-vi-snippets-03f6778/ni-kb/Call_a_Dynamic_Link_Library_DLL_From_LabVIEW.png': {'LI**': 2},
  'Bud-ro_vi-snippets/Bud-ro-vi-snippets-03f6778/ni-kb/Can_LabVIEW_Call_the_Windows_10_Touch_Keyboard.png': {'LI**': 2},
  'Bud-ro_vi-snippets/Bud-ro-vi-snippets-03f6778/ni-kb/Change_Sampling_Rate_When_Using_LabVIEW_FPGA_I_O_Node.png': {
    'LI**': 2,
  },
  'Bud-ro_vi-snippets/Bud-ro-vi-snippets-03f6778/ni-kb/Change_Sampling_Rate_When_Using_LabVIEW_FPGA_I_O_Node_2.png': {
    'LI**': 2,
  },
  'Bud-ro_vi-snippets/Bud-ro-vi-snippets-03f6778/ni-kb/Configure_Waveform_Chart_Displaying_NI_DAQmx_Data_to_Start_From_Zero_2.png':
      {'LI**': 2},
  'Bud-ro_vi-snippets/Bud-ro-vi-snippets-03f6778/ni-kb/Dragging_Individual_Curves_Up_and_Down_in_LabVIEW_Waveform_Graph.png':
      {'LI**': 2},
  'Bud-ro_vi-snippets/Bud-ro-vi-snippets-03f6778/ni-kb/Editing_the_Header_of_Multicolumn_Listbox_Control_While_VI_is_Running.png':
      {'LI**': 2},
  'Bud-ro_vi-snippets/Bud-ro-vi-snippets-03f6778/ni-kb/Errors_2147138411_or_77055_SoftMotion_Communication_or_Not_Responding_2.png':
      {'LI**': 1},
  'Bud-ro_vi-snippets/Bud-ro-vi-snippets-03f6778/ni-kb/Generate_Software_Timed_Trigger_with_NI_DAQmx_in_LabVIEW.png': {
    'LI**': 1,
  },
  'Bud-ro_vi-snippets/Bud-ro-vi-snippets-03f6778/ni-kb/Generating_Data_on_a_Simulated_FPGA_Target_From_LabVIEW.png': {
    'LI**': 1,
  },
  'Bud-ro_vi-snippets/Bud-ro-vi-snippets-03f6778/ni-kb/Generating_Data_on_a_Simulated_FPGA_Target_From_LabVIEW_2.png': {
    'LI**': 2,
  },
  'Bud-ro_vi-snippets/Bud-ro-vi-snippets-03f6778/ni-kb/Get_Multiple_Inspection_Images_with_The_Vision_Builder_for_Automated_I.png':
      {'LI**': 2},
  'Bud-ro_vi-snippets/Bud-ro-vi-snippets-03f6778/ni-kb/Getting_the_Windows_User_Name_in_LabVIEW_2.png': {'LI**': 1},
  'Bud-ro_vi-snippets/Bud-ro-vi-snippets-03f6778/ni-kb/How_Can_I_generate_PWM_Signal_on_FPGA.png': {'LI**': 2},
  'Bud-ro_vi-snippets/Bud-ro-vi-snippets-03f6778/ni-kb/How_to_Create_a_Map_With_Non_Default_Data_Type_in_Register_vi.png':
      {'LI**': 2},
  'Bud-ro_vi-snippets/Bud-ro-vi-snippets-03f6778/ni-kb/How_to_Display_a_PWM_Signal_in_LabVIEW.png': {'LI**': 2},
  'Bud-ro_vi-snippets/Bud-ro-vi-snippets-03f6778/ni-kb/How_to_Get_Sequence_File_Version_Programmatically_in_LabVIEW.png':
      {'LI**': 2},
  'Bud-ro_vi-snippets/Bud-ro-vi-snippets-03f6778/ni-kb/How_to_Programmatically_Acquire_a_Full_Screenshot_in_LabVIEW.png':
      {'LI**': 2},
  'Bud-ro_vi-snippets/Bud-ro-vi-snippets-03f6778/ni-kb/How_to_Programmatically_Acquire_a_Full_Screenshot_in_LabVIEW_2.png':
      {'LI**': 2},
  'Bud-ro_vi-snippets/Bud-ro-vi-snippets-03f6778/ni-kb/How_to_Swap_Registers_for_Modbus_Floating_Point_Values.png': {
    'LI**': 3,
  },
  'Bud-ro_vi-snippets/Bud-ro-vi-snippets-03f6778/ni-kb/LabVIEW_UI.png': {'LI**': 3},
  'Bud-ro_vi-snippets/Bud-ro-vi-snippets-03f6778/ni-kb/Llamar_a_una_biblioteca_de_v_nculos_din_micos_DLL_desde_LabVIEW.png':
      {'LI**': 2},
  'Bud-ro_vi-snippets/Bud-ro-vi-snippets-03f6778/ni-kb/Performing_Analog_Output_Software_timed_Waveform_Generation_in_LabVIEW.png':
      {'LI**': 2},
  'Bud-ro_vi-snippets/Bud-ro-vi-snippets-03f6778/ni-kb/Prevent_LabVIEW_Executable_to_Run_by_Different_Windows_Users_2.png':
      {'LI**': 2},
  'Bud-ro_vi-snippets/Bud-ro-vi-snippets-03f6778/ni-kb/Programmatically_Access_Metadata_From_a_TIFF_File_with_LabVIEW.png':
      {'LI**': 1},
  'Bud-ro_vi-snippets/Bud-ro-vi-snippets-03f6778/ni-kb/Saving_and_Reading_Complex_Image_to_AIPD_File_in_LabVIEW_2.png':
      {'LI**': 2},
  'Bud-ro_vi-snippets/Bud-ro-vi-snippets-03f6778/ni-kb/Segmenting_Periodic_Signal_using_Trigger_and_Gate_Express_VI_in_LabVIE.png':
      {'LI**': 2},
  'Bud-ro_vi-snippets/Bud-ro-vi-snippets-03f6778/ni-kb/Testing_a_DUT_Breakdown_Voltage_Using_NI_Digital.png': {
    'LI**': 2,
  },
  'Bud-ro_vi-snippets/Bud-ro-vi-snippets-03f6778/ni-kb/VI.png': {'LI**': 2},
  'Bud-ro_vi-snippets/Bud-ro-vi-snippets-03f6778/stackoverflow/18659244_v9FWt.png': {'LI**': 2},
  'Bud-ro_vi-snippets/Bud-ro-vi-snippets-03f6778/stackoverflow/18727533_6bdpe.png': {'LI**': 2},
  'Bud-ro_vi-snippets/Bud-ro-vi-snippets-03f6778/stackoverflow/31005336_LI8Uz.png': {'LI**': 2},
  'Bud-ro_vi-snippets/Bud-ro-vi-snippets-03f6778/stackoverflow/31519152_6YCug.png': {'LI**': 1},
  'Bud-ro_vi-snippets/Bud-ro-vi-snippets-03f6778/stackoverflow/31803852_82HZV.png': {'LI**': 2},
  'Bud-ro_vi-snippets/Bud-ro-vi-snippets-03f6778/stackoverflow/33862024_ctBR2.png': {'LI**': 2},
  'Bud-ro_vi-snippets/Bud-ro-vi-snippets-03f6778/stackoverflow/34109337_OCxvL.png': {'LI**': 2},
  'Bud-ro_vi-snippets/Bud-ro-vi-snippets-03f6778/stackoverflow/36650444_WEuIS.png': {'LI**': 2},
  'Bud-ro_vi-snippets/Bud-ro-vi-snippets-03f6778/stackoverflow/36857051_qLHm0.png': {'LI**': 2},
  'Bud-ro_vi-snippets/Bud-ro-vi-snippets-03f6778/stackoverflow/38628300_YH2YU.png': {'LI**': 2},
  'Bud-ro_vi-snippets/Bud-ro-vi-snippets-03f6778/stackoverflow/48375096_LaIbB.png': {'LI**': 2},
  'Bud-ro_vi-snippets/Bud-ro-vi-snippets-03f6778/stackoverflow/54816771_hARjO.png': {'LI**': 1},
  'Bud-ro_vi-snippets/Bud-ro-vi-snippets-03f6778/stackoverflow/55417854_NngaM.png': {'LI**': 2},
  'Bud-ro_vi-snippets/Bud-ro-vi-snippets-03f6778/stackoverflow/57898106_DbvGc.png': {'LI**': 2},
  'Bud-ro_vi-snippets/Bud-ro-vi-snippets-03f6778/stackoverflow/58054284_lzWR4.png': {'LI**': 2},
  'Bud-ro_vi-snippets/Bud-ro-vi-snippets-03f6778/stackoverflow/63563672_qPrsL.png': {'LI**': 1},
  'Bud-ro_vi-snippets/Bud-ro-vi-snippets-03f6778/stackoverflow/66709115_HWDF3.png': {'LI**': 2},
  'Bud-ro_vi-snippets/Bud-ro-vi-snippets-03f6778/stackoverflow/67526873_PVAWL.png': {'LI**': 3},
  'Bud-ro_vi-snippets/Bud-ro-vi-snippets-03f6778/stackoverflow/68005472_b9Hm2.png': {'LI**': 2},
  'Bud-ro_vi-snippets/Bud-ro-vi-snippets-03f6778/stackoverflow/73977725_ms0rf.png': {'LI**': 1},
  'Bud-ro_vi-snippets/Bud-ro-vi-snippets-03f6778/stackoverflow/74131160_O8ioW.png': {'LI**': 2},
  'Bud-ro_vi-snippets/Bud-ro-vi-snippets-03f6778/stackoverflow/74265065_hd6ua.png': {'LI**': 2},
  'rcpacini_VI-Snippets/rcpacini-VI-Snippets-1662bd7/Export Palette Image WMF.png': {'LI**': 2},
};

void main() {
  final all = corpusVis();

  test('every aux block instance decodes', () async {
    final res = await corpusParallel(all, _undecoded);
    final keys = {
      for (final probes in _probes.values)
        for (final (key, _) in probes) key,
      'LI**',
    };
    expect(perFileNonzero(all, res, keys), kUndecodedAuxSections);
  });
}
