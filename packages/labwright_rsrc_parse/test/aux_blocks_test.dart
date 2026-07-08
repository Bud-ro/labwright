@Tags(['corpus'])
library;

import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

/// Whole-corpus decode-rate floors for the auxiliary-block decoders. Each floor is the rate measured
/// when the decoder was written — a drop below it means corpus drift or a decoder break; investigate,
/// never re-pin.
void main() {
  final all = corpusVis();
  if (all.isEmpty) {
    test('aux block decoders (skipped: corpus not fetched)', () {}, skip: true);
    return;
  }

  // tag pattern -> (rate key, floor, decode probe)
  final probes = <String, List<(String, double, bool Function(Uint8List))>>{
    'CPMp': [('CPMp', 1.0, (b) => decodeConnectorPaneMap(b) != null)],
    'IPSR': [('IPSR', 1.0, (b) => decodeOffsetTable(b) != null)],
    'GCDI': [('GCDI', 1.0, (b) => decodeGcdiRecord(b) != null)],
    'BKMK': [('BKMK', 1.0, (b) => decodeBookmarkList(b) != null)],
    'VITS': [
      ('VITS', 1.0, (b) => decodeTagStore(b) != null),
      ('VITS-complete', 0.70, (b) => decodeTagStore(b)?.walkComplete ?? false),
    ],
    'VICD': [('VICD', 1.0, (b) => decodeCompiledCode(b) != null)],
    'DSIM': [('DSIM', 1.0, (b) => decodeDataSpaceImage(b) != null)],
    'MNGI': [('MNGI', 0.99, (b) => decodePngEnvelope(b) != null)], // rare MNG variant returns null
    'LIbd': [('LI**', 1.0, (b) => decodeLinkInfo(b)?.version == 1)],
    'LIvi': [('LI**', 1.0, (b) => decodeLinkInfo(b)?.version == 1)],
    'LIfp': [('LI**', 1.0, (b) => decodeLinkInfo(b)?.version == 1)],
    'LIds': [('LI**', 1.0, (b) => decodeLinkInfo(b)?.version == 1)],
    'BDPW': [('BDPW', 1.0, (b) => decodePasswordRecord(b) != null)],
    'RTSG': [('RTSG', 1.0, (b) => decodeRuntimeSignature(b) != null)],
    'SCSR': [('SCSR', 1.0, (b) => decodeScsrRecord(b) != null)],
    'PICC': [('PICC', 1.0, (b) => decodeIconPlacement(b) != null)],
    'PRT ': [('PRT ', 1.0, (b) => decodePrintRecord(b) != null)],
    'BDSE': [('xxSE', 0.99, (b) => decodeSectionMarker(b) != null)],
    'FPSE': [('xxSE', 0.99, (b) => decodeSectionMarker(b) != null)],
    'MUID': [('MUID', 0.99, (b) => decodeModifiedUid(b) != null)],
    'BDEx': [('xxEx', 0.99, (b) => decodeExtendedState(b) != null)],
    'FPEx': [('xxEx', 0.99, (b) => decodeExtendedState(b) != null)],
    'GCPR': [('GCPR', 1.0, (b) => decodeGcprRecord(b)?.matchesCorpusConstant ?? false)],
    'DLDR': [('DLDR', 1.0, (b) => decodeDldrRecord(b) != null)],
    'TRec': [('TRec', 1.0, (b) => decodeTextRecord(b) != null)],
  };

  test('aux block decoders hold their corpus-measured decode rates', () {
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
        for (final (key, _, probe) in probes[section.tag] ?? const <(String, double, bool Function(Uint8List))>[]) {
          total[key] = (total[key] ?? 0) + 1;
          if (probe(section.bytes)) decoded[key] = (decoded[key] ?? 0) + 1;
        }
      }
    }
    final floors = {
      for (final list in probes.values)
        for (final (key, floor, _) in list) key: floor,
    };
    floors.forEach((key, floor) {
      expect(total[key], isNotNull, reason: 'no $key sections seen in corpus');
      expect(
        (decoded[key] ?? 0) / total[key]!,
        greaterThanOrEqualTo(floor),
        reason: '$key decode rate ${decoded[key] ?? 0}/${total[key]} fell below $floor',
      );
    });
  });

  test('link info surfaces real dependency names', () {
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
    expect(linkSections, greaterThan(100));
    // Many VIs have no sub-VI dependencies; just require a healthy fraction.
    expect(
      withNames,
      greaterThan(linkSections ~/ 10),
      reason: 'dependency-name recovery collapsed ($withNames/$linkSections)',
    );
  });
}
