import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import '../corpus_dirs.dart';

Map<String, int> _totality(CorpusVi vi) {
  final bytes = vi.bytes;
  final path = vi.path;
  final c = <String, int>{};
  try {
    parseVi(bytes);
    final decoded = vi.decoded;
    if (decoded == null) throw vi.error!;
    for (final s in decoded) {
      if (!(BlockTag.of(s.tag)?.isRecordHeap ?? false) || s.bytes.length < 6) continue;
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

const corpusCoverageLaw = CorpusLaw('corpus_coverage', _totality);

void corpusCoverageTests() {
  test('every corpus VI parses, decodes, and walks without throwing', () async {
    expect(await corpusCoverageLaw.nonzero(const {'throws', 'walkOutOfBounds'}), kTotalityBreaks);
  });
}
