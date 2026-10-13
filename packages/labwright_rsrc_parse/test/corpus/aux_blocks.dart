import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import '../corpus_dirs.dart';

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

bool _cpmp(Uint8List b) => ViConnectorPaneMap(b).length >= 0;
bool _ipsr(Uint8List b) => ViOffsetTable(b).serialize().length == b.length;
bool _gcdi(Uint8List b) => ViGcdiRecord(b).recordCount >= 0;
bool _bkmk(Uint8List b) => ViBookmarkList(b).serialize().length == b.length;
bool _vits(Uint8List b) => ViTagStore(b).entries.length == ViTagStore(b).declaredCount;
bool _vicd(Uint8List b) => ViCompiledCode(b).codeSize >= 0;
bool _dsim(Uint8List b) => ViDataSpaceImage(b).width >= 0;
bool _mngi(Uint8List b) => ViPngStream(b).chunkCount > 0;
bool _bdpw(Uint8List b) => ViPasswordRecord(b).passwordDigest.length == 16;
bool _rtsg(Uint8List b) => ViSignature(b).digest.length == 16;
bool _scsr(Uint8List b) => ViSourceSignature(b).digest.length == 16;
bool _picc(Uint8List b) => ViPiccRecord(b).serialize().length == 12;
bool _prt(Uint8List b) => ViPrintRecord(b).length >= 32;
bool _sectionMarker(Uint8List b) => ViSectionEntry(b).value >= 0;
bool _muid(Uint8List b) => ViMaxUid(b).maxUid >= 0;
bool _extendedState(Uint8List b) => ViLinkEntryWords(b).count >= 0;
bool _gcpr(Uint8List b) => ViConstantRecord.gcpr(b).isZero;
bool _dldr(Uint8List b) => ViDldrRecord(b).length == 7;
bool _trec(Uint8List b) => ViTextRecord(b).runCount >= 0;

const _linkInfoTags = {'LIvi', 'LIbd', 'LIfp', 'LIds'};

Map<String, int> _undecoded(CorpusVi vi) {
  final c = <String, int>{};
  final sections = vi.decoded;
  if (sections == null) return c;
  final vers = sections.where((section) => section.tag == 'vers').firstOrNull;
  final version = vers == null ? null : ViVersBlock(vers.bytes).versionWord;
  for (final section in sections) {
    for (final (key, probe) in _probes[section.tag] ?? const <(String, bool Function(Uint8List))>[]) {
      if (!probe(section.bytes)) c[key] = (c[key] ?? 0) + 1;
    }
    if (_linkInfoTags.contains(section.tag) && !ViLinkInfo(section.bytes, version: version).isWalked) {
      c['LI**'] = (c['LI**'] ?? 0) + 1;
    }
  }
  return c;
}

// TODO: link-info walks stop early in XControl test VIs, .NET-calling VIs and the LabVIEW 7.0 save.
const kUndecodedAuxSections = <String, Map<String, int>>{
  'vi-corpus/sources/NEVSTOP-LAB__LabVIEW-UI-XCtl/LabVIEW-UI-GaussfitGraph/GaussfitGraph/_test/Demo.vi': {'LI**': 1},
  'vi-corpus/sources/NEVSTOP-LAB__LabVIEW-UI-XCtl/LabVIEW-UI-XListGraph/src/_Test/UI-XListGraph-Example.vi': {
    'LI**': 1,
  },
  'vi-corpus/sources/NEVSTOP-LAB__LabVIEW-UI-XCtl/XTriPhaseGraph/_test/_TestMain.vi': {'LI**': 1},
  'vi-corpus/sources/NJKirchner__LabVIEW-Evaluation-Hands-On/Evaluate LabVIEW/01 - Calling NET.vi': {'LI**': 2},
  'vi-corpus/sources/NJKirchner__LabVIEW-Evaluation-Hands-On/Evaluate LabVIEW/NETCallback FileWatcher Broadcast.vi': {
    'LI**': 2,
  },
  'vi-corpus/sources/NJKirchner__LabVIEW-Evaluation-Hands-On/Evaluate LabVIEW/WebVideoGuide.vi': {'LI**': 1},
  'vi-corpus/sources/jdnichollsc__Automated-classrooms/LABORATORIOS.vi': {'LI**': 3},
};

const auxBlocksLaw = CorpusLaw('aux_blocks', _undecoded);

void auxBlocksTests() {
  test('every aux block instance decodes', () async {
    final keys = {
      for (final probes in _probes.values)
        for (final (key, _) in probes) key,
      'LI**',
    };
    expect(await auxBlocksLaw.nonzero(keys), kUndecodedAuxSections);
  });
}
