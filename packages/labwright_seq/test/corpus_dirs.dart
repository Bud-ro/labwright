import 'dart:io';

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

final Directory corpusSeqDir = _corpusSeqRoot();

String corpusSeqRelativePath(String path) {
  final root = '${corpusSeqDir.path}/';
  final normalized = path.replaceAll(r'\', '/');
  return normalized.startsWith(root) ? normalized.substring(root.length) : normalized;
}

class Tally {
  final Map<String, int> _counts = {};
  final Map<String, Map<String, int>> _byFile = {};
  String? file;

  void bump(String name, [int by = 1]) {
    _counts[name] = (_counts[name] ?? 0) + by;
    final current = file;
    if (current == null) return;
    final counts = _byFile[current] ??= {};
    counts[name] = (counts[name] ?? 0) + by;
  }

  int operator [](String name) => _counts[name] ?? 0;

  Map<String, int> nonzero(String name) => {
    for (final MapEntry(key: path, value: counts) in _byFile.entries)
      if ((counts[name] ?? 0) != 0) path: counts[name]!,
  };

  Map<String, int> mismatches(String left, String right) => {
    for (final MapEntry(key: path, value: counts) in _byFile.entries)
      if ((counts[left] ?? 0) != (counts[right] ?? 0)) path: (counts[left] ?? 0) - (counts[right] ?? 0),
  };
}
