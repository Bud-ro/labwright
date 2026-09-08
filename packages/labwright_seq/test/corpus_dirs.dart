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
    final f = file;
    if (f != null) (_byFile[f] ??= {})[name] = ((_byFile[f] ??= {})[name] ?? 0) + by;
  }

  int operator [](String name) => _counts[name] ?? 0;

  Map<String, int> nonzero(String name) => {
    for (final e in _byFile.entries)
      if ((e.value[name] ?? 0) != 0) e.key: e.value[name]!,
  };

  Map<String, int> mismatches(String a, String b) => {
    for (final e in _byFile.entries)
      if ((e.value[a] ?? 0) != (e.value[b] ?? 0)) e.key: (e.value[a] ?? 0) - (e.value[b] ?? 0),
  };
}
