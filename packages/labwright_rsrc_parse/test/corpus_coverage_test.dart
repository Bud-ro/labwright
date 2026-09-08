@Tags(['corpus'])
library;

import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

Map<String, int> _totality(Uint8List bytes, String path) {
  final c = <String, int>{};
  try {
    parseVi(bytes);
    for (final s in decodeSections(bytes)) {
      if (!kHeapSectionTags.contains(s.tag) || s.bytes.length < 6) continue;
      for (final span in measureHeapTiers(s.bytes, s.tag).walk.spans) {
        if (span.offset + span.length > s.bytes.length) c['walkOutOfBounds'] = (c['walkOutOfBounds'] ?? 0) + 1;
      }
    }
  } catch (_) {
    if (!isNonRsrcFixture(path)) c['throws'] = 1;
  }
  return c;
}

const kTotalityBreaks = <String, Map<String, int>>{};

void main() {
  final all = corpusVis();

  test('every corpus VI parses, decodes, and walks without throwing', () async {
    final res = await corpusParallel(all, _totality);
    expect(perFileNonzero(all, res, const {'throws', 'walkOutOfBounds'}), kTotalityBreaks);
  });
}
