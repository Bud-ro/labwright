import 'dart:io';

Directory repoRoot() {
  var dir = Directory.current;
  while (!File('${dir.path}/corpus/sources.json').existsSync()) {
    final parent = dir.parent;
    if (parent.path == dir.path) throw StateError('no corpus/sources.json at or above ${Directory.current.path}');
    dir = parent;
  }
  return dir;
}

final Directory corpusVi = Directory('${repoRoot().path}/corpus/vi');

final Directory corpusSeq = Directory('${repoRoot().path}/corpus/seq');

List<File> corpusFiles(Directory root, String extension) =>
    root
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .where((file) => file.path.toLowerCase().endsWith(extension))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

final Map<String, File> _pngsByName = {
  for (final file in corpusFiles(corpusVi, '.png')) file.uri.pathSegments.last: file,
};

File snippetPng(String fileName) {
  final file = _pngsByName[fileName];
  if (file == null) throw StateError('no $fileName under ${corpusVi.path}');
  return file;
}
