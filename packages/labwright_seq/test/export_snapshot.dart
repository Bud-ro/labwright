import 'dart:io';

import 'package:labwright_seq/labwright_seq.dart';

import 'corpus_dirs.dart';

const exportSnapshotPath = 'test/export_snapshots';

final _saveFormatSuffix = RegExp(r'_(BIN|XML)(?=\.seq$)');

Iterable<File> _seqFiles(Directory dir) =>
    dir.listSync(recursive: true).whereType<File>().where((f) => f.path.toLowerCase().endsWith('.seq'));

String _relative(Directory dir, File file) => file.path.substring(dir.path.length + 1).replaceAll(r'\', '/');

Map<String, String> exportSnapshotFiles() {
  final files = <String, String>{};
  void add(String folder, Map<String, SeqFile> byPath) =>
      exportSeqProjectToLabwright(byPath).files.forEach((name, source) {
        final path = '$folder/$name';
        if (files[path] case final other? when other != source) {
          throw StateError('$path: the sources sharing $folder export differently');
        }
        files[path] = source;
      });
  SeqFile parse(File f) => parseSeqFile(f.readAsBytesSync());
  final corpus = Directory('${corpusSeqDir.path}/seq-corpus');
  for (final source in Directory('${corpus.path}/sources').listSync().whereType<Directory>()) {
    add(corpusSeqRelativePath(source.path), {for (final f in _seqFiles(source)) _relative(source, f): parse(f)});
  }
  final rosetta = Directory('${corpus.path}/rosetta');
  for (final f in _seqFiles(rosetta)) {
    final name = _relative(rosetta, f).replaceFirst(_saveFormatSuffix, '');
    add('seq-corpus/rosetta/${name.substring(0, name.length - '.seq'.length)}', {name: parse(f)});
  }
  return files;
}

void writeExportSnapshots(Directory root) {
  if (root.existsSync()) root.deleteSync(recursive: true);
  exportSnapshotFiles().forEach(
    (path, source) => File('${root.path}/$path')
      ..createSync(recursive: true)
      ..writeAsStringSync(source),
  );
  final format = Process.runSync(Platform.resolvedExecutable, ['format', root.path]);
  if (format.exitCode != 0) throw ProcessException('dart', ['format', root.path], '${format.stderr}', format.exitCode);
}

Map<String, String> readExportSnapshots(Directory root) => {
  for (final f in root.listSync(recursive: true).whereType<File>()) _relative(root, f): f.readAsStringSync(),
};
