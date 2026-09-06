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

File corpusSeqSnapshotFile() => File('${corpusSeqDir.parent.path}/snapshot.json');
