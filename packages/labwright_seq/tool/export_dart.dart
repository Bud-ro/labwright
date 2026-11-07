import 'dart:io';

import 'package:labwright_seq/labwright_seq.dart';

void main(List<String> args) {
  if (args.length != 2) {
    stderr.writeln('usage: dart run tool/export_dart.dart <input.seq | directory> <output directory>');
    exit(64);
  }
  final input = args[0];
  final files = FileSystemEntity.isDirectorySync(input)
      ? Directory(input).listSync(recursive: true).whereType<File>().where((f) => f.path.toLowerCase().endsWith('.seq'))
      : [File(input)];
  final root = FileSystemEntity.isDirectorySync(input) ? input : File(input).parent.path;
  final byPath = {
    for (final f in files) f.path.substring(root.length + 1).replaceAll(r'\', '/'): parseSeqFile(f.readAsBytesSync()),
  };
  exportSeqProjectToDart(byPath).files.forEach(
    (name, source) => File('${args[1]}/$name')
      ..createSync(recursive: true)
      ..writeAsStringSync(source),
  );
}
