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
  'LIbd': [('LI**', _linkInfo)],
  'LIvi': [('LI**', _linkInfo)],
  'LIfp': [('LI**', _linkInfo)],
  'LIds': [('LI**', _linkInfo)],
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
bool _ipsr(Uint8List b) => decodeOffsetTable(b).length >= 1;
bool _gcdi(Uint8List b) => decodeGcdiRecord(b).value >= 0;
bool _bkmk(Uint8List b) => decodeBookmarkList(b).tableA.length >= 0;
bool _vits(Uint8List b) => decodeTagStore(b).entries.length == decodeTagStore(b).declaredCount;
bool _vicd(Uint8List b) => decodeCompiledCode(b).codeSize >= 0;
bool _dsim(Uint8List b) => decodeDataSpaceImage(b) != null;
bool _mngi(Uint8List b) => decodePngEnvelope(b) != null;
bool _linkInfo(Uint8List b) => decodeLinkInfo(b).version == 1;
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

Map<String, int> _undecoded(Uint8List bytes, String path) {
  final c = <String, int>{};
  final Iterable<DecodedSection> sections;
  try {
    sections = decodeSections(bytes);
  } catch (_) {
    return c;
  }
  for (final section in sections) {
    for (final (key, probe) in _probes[section.tag] ?? const <(String, bool Function(Uint8List))>[]) {
      if (!probe(section.bytes)) c[key] = (c[key] ?? 0) + 1;
    }
  }
  return c;
}

const kUndecodedAuxSections = <String, Map<String, int>>{
  'NEVSTOP-LAB_Communicable-State-Machine/NEVSTOP-LAB-Communicable-State-Machine-afe7d4d/src/user.lib/_NEVSTOP/Communicable State Machine(CSM)/_tool/_SubModules/CSM Batch Format Tool.vi':
      {'MNGI': 2},
  'NEVSTOP-LAB_Communicable-State-Machine/NEVSTOP-LAB-Communicable-State-Machine-afe7d4d/src/user.lib/_NEVSTOP/Communicable State Machine(CSM)/_tool/_SubModules/Interface Browser.vi':
      {'MNGI': 2},
  'NEVSTOP-LAB_Communicable-State-Machine/NEVSTOP-LAB-Communicable-State-Machine-afe7d4d/src/user.lib/_NEVSTOP/Communicable State Machine(CSM)/_tool/_debugConsole/Script-Window.vi':
      {'MNGI': 2},
  'ni_grpc-labview/ni-grpc-labview-2f07f03/labview source/Client Server Support New/gRPC Scripting Tools/Animation API/Animation.vi':
      {'MNGI': 1},
  'opengds_OpenGDS/opengds-OpenGDS-1945834/resource/Framework/Providers/Open_GDS/ClassProviders/Common/ConvertTextBasedCodeToLabVIEW.vi':
      {'MNGI': 1},
  'opengds_OpenGDS/opengds-OpenGDS-1945834/resource/Framework/Providers/Open_GDS/ClassProviders/Provider_LvNativeClass/ClassWriterNative_class/DialogCreateMethod.vi':
      {'MNGI': 1},
  'opengds_OpenGDS/opengds-OpenGDS-1945834/resource/Framework/Providers/Open_GDS/ClassProviders/Provider_LvNativeClass/ClassWriterNative_class/private/MethodSignatureDialogvi.vi':
      {'MNGI': 1},
};

void main() {
  final all = corpusVis();

  test('every aux block instance decodes', () async {
    final res = await corpusParallel(all, _undecoded);
    final keys = {
      for (final probes in _probes.values)
        for (final (key, _) in probes) key,
    };
    expect(perFileNonzero(all, res, keys), kUndecodedAuxSections);
  });
}
