import 'dart:io';

/// Resolves this package's gitignored TestStand corpus (`<pkg>/corpus/seq/`),
/// checked out by `tool/fetch_seq_corpus.dart`. Tests run from either the repo
/// root or the package dir, so walk up from CWD checking both the package-relative
/// location and the package-local one.
Directory _corpusSeqRoot() {
  const pkgRel = 'packages/labwright_seq/corpus';
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    for (final base in ['${dir.path}/$pkgRel', '${dir.path}/corpus']) {
      if (File('$base/seq-sources.json').existsSync()) {
        return Directory('$base/seq');
      }
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return Directory('corpus/seq');
}

/// The fetched TestStand corpus (every pinned source). Empty/absent until
/// fetched — corpus tests skip when it does not exist.
final Directory corpusSeqDir = _corpusSeqRoot();
