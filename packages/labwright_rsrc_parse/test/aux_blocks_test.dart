@Tags(['corpus'])
library;

import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';
import 'snapshot_check.dart';

void main() {
  final all = corpusVis();

  final probes = <String, List<(String, bool Function(Uint8List))>>{
    'CPMp': [('CPMp', (b) => decodeConnectorPaneMap(b) != null)],
    'IPSR': [('IPSR', (b) => decodeOffsetTable(b) != null)],
    'GCDI': [('GCDI', (b) => decodeGcdiRecord(b) != null)],
    'BKMK': [('BKMK', (b) => decodeBookmarkList(b) != null)],
    'VITS': [
      ('VITS', (b) => decodeTagStore(b) != null),
      ('VITS-complete', (b) => decodeTagStore(b)?.walkComplete ?? false),
    ],
    'VICD': [('VICD', (b) => decodeCompiledCode(b) != null)],
    'DSIM': [('DSIM', (b) => decodeDataSpaceImage(b) != null)],
    'MNGI': [('MNGI', (b) => decodePngEnvelope(b) != null)],
    'LIbd': [('LI**', (b) => decodeLinkInfo(b)?.version == 1)],
    'LIvi': [('LI**', (b) => decodeLinkInfo(b)?.version == 1)],
    'LIfp': [('LI**', (b) => decodeLinkInfo(b)?.version == 1)],
    'LIds': [('LI**', (b) => decodeLinkInfo(b)?.version == 1)],
    'BDPW': [('BDPW', (b) => decodePasswordRecord(b) != null)],
    'RTSG': [('RTSG', (b) => decodeRuntimeSignature(b) != null)],
    'SCSR': [('SCSR', (b) => decodeScsrRecord(b) != null)],
    'PICC': [('PICC', (b) => decodeIconPlacement(b) != null)],
    'PRT ': [('PRT ', (b) => decodePrintRecord(b) != null)],
    'BDSE': [('xxSE', (b) => decodeSectionMarker(b) != null)],
    'FPSE': [('xxSE', (b) => decodeSectionMarker(b) != null)],
    'MUID': [('MUID', (b) => decodeModifiedUid(b) != null)],
    'BDEx': [('xxEx', (b) => decodeExtendedState(b) != null)],
    'FPEx': [('xxEx', (b) => decodeExtendedState(b) != null)],
    'GCPR': [('GCPR', (b) => decodeGcprRecord(b)?.matchesCorpusConstant ?? false)],
    'DLDR': [('DLDR', (b) => decodeDldrRecord(b) != null)],
    'TRec': [('TRec', (b) => decodeTextRecord(b) != null)],
  };

  test('aux block decoders match their corpus-measured decode censuses', () {
    final total = <String, int>{};
    final decoded = <String, int>{};
    for (final file in all) {
      final Iterable<DecodedSection> sections;
      try {
        sections = decodeSections(file.readAsBytesSync());
      } catch (_) {
        continue;
      }
      for (final section in sections) {
        for (final (key, probe) in probes[section.tag] ?? const <(String, bool Function(Uint8List))>[]) {
          total[key] = (total[key] ?? 0) + 1;
          if (probe(section.bytes)) decoded[key] = (decoded[key] ?? 0) + 1;
        }
      }
    }
    expectCorpusSnapshot('aux', {
      for (final e in total.entries) '${e.key}.sections': e.value,
      for (final e in total.entries) '${e.key}.decoded': decoded[e.key] ?? 0,
    });
  });

  test('link info surfaces real dependency names (first 400 VIs)', () {
    var linkSections = 0, withNames = 0;
    for (final file in all.take(400)) {
      try {
        for (final section in decodeSections(file.readAsBytesSync())) {
          if (section.tag != 'LIbd' && section.tag != 'LIvi') continue;
          linkSections++;
          final info = decodeLinkInfo(section.bytes);
          if (info != null && info.linkedNames.isNotEmpty) withNames++;
        }
      } catch (_) {}
    }
    expectCorpusSnapshot('link_info', {'linkSections': linkSections, 'withNames': withNames});
  });
}
