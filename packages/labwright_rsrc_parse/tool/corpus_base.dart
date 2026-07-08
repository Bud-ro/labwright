import 'dart:io';

/// Resolves this package's corpus dir (`<pkg>/corpus/`), which holds the
/// committed JSON indices (`sources.json`, `snapshot.json`) and the
/// gitignored `vi/` checkout from `tool/fetch_corpus.dart`.
///
/// Callers (the corpus tools and the corpus tests) may run from the repo root or
/// the package dir, so walk up from CWD checking both the package-relative
/// location (CWD at/above the repo root) and the package-local one (CWD ==
/// package root). Falls back to a cwd-relative `corpus`. The single resolver
/// shared by `tool/coverage.dart`, `tool/snapshot.dart`,
/// `tool/undecoded_bytes.dart`, and `test/corpus_dirs.dart`.
Directory corpusBaseDir() {
  const pkgRel = 'packages/labwright_rsrc_parse/corpus';
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    for (final rel in const [pkgRel, 'corpus']) {
      if (File('${dir.path}/$rel/sources.json').existsSync()) {
        return Directory('${dir.path}/$rel');
      }
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return Directory('corpus');
}

/// Every `.vi` file under [root], enumerated recursively **without following
/// symlinks** and sorted by path (deterministic). The corpus contains symlinked
/// directories (e.g. picotech's `PS5000E` → `PS5000`); following them would
/// count the same file twice, skewing every corpus metric — so symlinks are
/// excluded and each VI appears exactly once.
List<File> listCorpusVis(Directory root) {
  if (!root.existsSync()) return <File>[];
  return root
      .listSync(recursive: true, followLinks: false)
      .whereType<File>()
      .where((f) => f.path.toLowerCase().endsWith('.vi'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
}
