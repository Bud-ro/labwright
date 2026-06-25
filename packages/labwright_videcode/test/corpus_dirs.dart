import 'dart:io';

/// Resolves the gitignored VI corpus checked out at the repo root by
/// `tool/fetch_corpus.dart` (`<repoRoot>/vi-corpus/`). The repo root is found by
/// walking up to the directory that holds `corpus/sources.json`, so this works
/// regardless of the test runner's CWD. Falls back to a cwd-relative path.
Directory _corpusRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    if (File('${dir.path}/corpus/sources.json').existsSync()) {
      return Directory('${dir.path}/vi-corpus');
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return Directory('vi-corpus');
}

/// The whole diverse corpus (every pinned source). Empty/absent until fetched —
/// corpus tests skip when it does not exist.
final Directory corpusDiverseDir = _corpusRoot();

/// The deterministic baseline sample (the pinned picotech examples), a subset of
/// the diverse corpus. Drives `corpus/baseline.json` (picotech first-60).
final Directory corpusSampleDir =
    Directory('${_corpusRoot().path}/picotech_picosdk-ni-labview-examples');
