@Tags(['corpus'])
library;

import 'package:test/test.dart';

import 'corpus_dirs.dart';

/// Guards the corpus enumeration itself: the corpus contains symlinked
/// directories (picotech's `PS5000E` → `PS5000`, `ps3000E` → `ps3000`), and an
/// enumeration that follows them counts the same VI twice — skewing every
/// corpus metric and the baseline. [corpusVis] must therefore yield each VI
/// exactly once by canonical path.
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
    expect(
      duplicates,
      isEmpty,
      reason: 'symlink-duplicated corpus entries: ${duplicates.take(5).toList()}',
    );
    expect(canonical.length, all.length);
  });
}
