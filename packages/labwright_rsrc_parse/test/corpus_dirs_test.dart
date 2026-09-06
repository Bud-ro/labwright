@Tags(['corpus'])
library;

import 'package:test/test.dart';

import 'corpus_dirs.dart';

void main() {
  final all = corpusVis();
  if (all.isEmpty) {
    test('corpus enumeration (skipped: corpus not fetched — run tool/fetch_corpus.dart)', () {}, skip: true);
    return;
  }

  test('corpusVis yields each VI exactly once (no symlink duplicates)', () {
    final canonical = <String>{};
    final duplicates = <String>[
      for (final f in all)
        if (!canonical.add(f.resolveSymbolicLinksSync())) f.path,
    ];
    expect(duplicates, isEmpty, reason: 'symlink-duplicated corpus entries: ${duplicates.take(5).toList()}');
    expect(canonical.length, all.length);
  });
}
