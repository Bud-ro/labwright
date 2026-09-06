import 'dart:io';

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

List<File> listCorpusVis(Directory root) {
  if (!root.existsSync()) return <File>[];
  return root
      .listSync(recursive: true, followLinks: false)
      .whereType<File>()
      .where((f) => f.path.toLowerCase().endsWith('.vi'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
}
