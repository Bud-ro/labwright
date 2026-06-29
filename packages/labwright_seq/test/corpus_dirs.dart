import 'dart:io';

/// Resolves the gitignored TestStand corpus checked out by
/// `tool/fetch_seq_corpus.dart` (`<repoRoot>/corpus/seq/`). The repo root is
/// found by walking up to the directory holding `corpus/seq-sources.json`, so
/// this works regardless of the test runner's CWD.
Directory _corpusSeqRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    if (File('${dir.path}/corpus/seq-sources.json').existsSync()) {
      return Directory('${dir.path}/corpus/seq');
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
