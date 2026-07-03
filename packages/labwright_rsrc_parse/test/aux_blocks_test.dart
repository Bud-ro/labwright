@Tags(['corpus'])
library;

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

/// Whole-corpus invariants for the auxiliary-block decoders (link info, tag
/// store, compiled-code envelope, connector-pane map, bookmarks, offsets,
/// images, small records). Each floor is the rate measured when the decoder
/// was written — a regression below it means either corpus drift or a decoder
/// break, and must be investigated rather than re-pinned.
void main() {
  final all = corpusVis();
  if (all.isEmpty) {
    test('aux block decoders (skipped: corpus not fetched)', () {}, skip: true);
    return;
  }

  late final Map<String, ({int total, int decoded})> rates;
  setUpAll(() {
    final counts = <String, List<int>>{};
    void tally(String tag, bool ok) {
      final entry = counts.putIfAbsent(tag, () => [0, 0]);
      entry[0]++;
      if (ok) entry[1]++;
    }

    for (final file in all) {
      final Iterable<DecodedSection> sections;
      try {
        sections = decodeSections(file.readAsBytesSync());
      } catch (_) {
        continue;
      }
      for (final section in sections) {
        final bytes = section.bytes;
        switch (section.tag) {
          case 'CPMp':
            tally('CPMp', decodeConnectorPaneMap(bytes) != null);
          case 'IPSR':
            tally('IPSR', decodeOffsetTable(bytes) != null);
          case 'GCDI':
            tally('GCDI', decodeGcdiRecord(bytes) != null);
          case 'BKMK':
            tally('BKMK', decodeBookmarkList(bytes) != null);
          case 'VITS':
            final store = decodeTagStore(bytes);
            tally('VITS', store != null);
            tally('VITS-complete', store?.walkComplete ?? false);
          case 'VICD':
            tally('VICD', decodeCompiledCode(bytes) != null);
          case 'DSIM':
            tally('DSIM', decodeDataSpaceImage(bytes) != null);
          case 'MNGI':
            tally('MNGI', decodePngEnvelope(bytes) != null);
          case 'LIbd' || 'LIvi' || 'LIfp' || 'LIds':
            final info = decodeLinkInfo(bytes);
            tally('LI**', info != null && info.version == 1);
          case 'BDPW':
            tally('BDPW', decodePasswordRecord(bytes) != null);
          case 'RTSG':
            tally('RTSG', decodeRuntimeSignature(bytes) != null);
          case 'SCSR':
            tally('SCSR', decodeScsrRecord(bytes) != null);
          case 'PICC':
            tally('PICC', decodeIconPlacement(bytes) != null);
          case 'PRT ':
            tally('PRT ', decodePrintRecord(bytes) != null);
          case 'BDSE' || 'FPSE':
            tally('xxSE', decodeSectionMarker(bytes) != null);
          case 'MUID':
            tally('MUID', decodeModifiedUid(bytes) != null);
          case 'BDEx' || 'FPEx':
            tally('xxEx', decodeExtendedState(bytes) != null);
          case 'GCPR':
            final record = decodeGcprRecord(bytes);
            tally('GCPR', record != null && record.matchesCorpusConstant);
          case 'DLDR':
            tally('DLDR', decodeDldrRecord(bytes) != null);
          case 'TRec':
            tally('TRec', decodeTextRecord(bytes) != null);
        }
      }
    }
    rates = {
      for (final entry in counts.entries)
        entry.key: (total: entry.value[0], decoded: entry.value[1]),
    };
  });

  void expectFloor(String tag, double floor) {
    final rate = rates[tag];
    expect(rate, isNotNull, reason: 'no $tag sections seen in corpus');
    final fraction = rate!.decoded / rate.total;
    expect(fraction, greaterThanOrEqualTo(floor),
        reason: '$tag decode rate ${rate.decoded}/${rate.total} fell below $floor');
  }

  test('aux block decoders hold their corpus-measured decode rates', () {
    expectFloor('CPMp', 1.0); // 3531/3531 when written
    expectFloor('IPSR', 1.0); // 549/549
    expectFloor('GCDI', 1.0); // 868/868
    expectFloor('BKMK', 1.0);
    expectFloor('VITS', 1.0); // header always decodable
    expectFloor('VITS-complete', 0.70); // 5219/7203 full walks
    expectFloor('VICD', 1.0);
    expectFloor('DSIM', 1.0); // u32@0==0 was 18654/18654
    expectFloor('MNGI', 0.99); // rare MNG variant returns null
    expectFloor('LI**', 1.0);
    expectFloor('BDPW', 1.0);
    expectFloor('RTSG', 1.0);
    expectFloor('SCSR', 1.0);
    expectFloor('PICC', 1.0);
    expectFloor('PRT ', 1.0);
    expectFloor('xxSE', 0.99);
    expectFloor('MUID', 0.99);
    expectFloor('xxEx', 0.99);
    expectFloor('GCPR', 1.0);
    expectFloor('DLDR', 1.0);
    expectFloor('TRec', 1.0);
    // ignore: avoid_print
    print('aux decoders: ${rates.entries.map((e) => '${e.key} ${e.value.decoded}/${e.value.total}').join(' · ')}');
  });

  test('link info surfaces real dependency names', () {
    var linkSections = 0;
    var withNames = 0;
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
    expect(withNames, greaterThan(linkSections ~/ 10),
        reason: 'dependency-name recovery collapsed ($withNames/$linkSections)');
  });
}
