import 'dart:io';

import 'package:labwright_teststand/labwright_teststand.dart';

/// Prints a sequence-editor-like view of a TestStand `.seq` file.
///
/// Run: `dart run tool/dump.dart [path/to/file.seq]`
/// With no path, picks the first XML `.seq` found under `corpus/seq/`.
void main(List<String> args) {
  final path = args.isNotEmpty ? args.first : _firstCorpusXml();
  if (path == null) {
    stderr.writeln('usage: dart run tool/dump.dart <file.seq>  '
        '(no corpus/seq found to auto-pick from)');
    exit(1);
  }
  final bytes = File(path).readAsBytesSync();
  stdout.writeln('# $path');
  try {
    stdout.write(dumpSeqFile(parseSeqFile(bytes)));
  } on UnsupportedError catch (e) {
    // Binary TOF1: the typed tree isn't decoded yet, but show the header and a
    // recon view of the recovered string/name pool.
    stdout.writeln('${detectSeqHeader(bytes)}\n(${e.message})');
    final names = binaryBodyStrings(bytes);
    if (names.isNotEmpty) {
      stdout.writeln('binary body: ${names.length} strings recovered, e.g.:');
      for (final s in names.take(30)) {
        stdout.writeln('    @0x${s.offset.toRadixString(16)}  ${s.text}');
      }
    }
  }
}

String? _firstCorpusXml() {
  var d = Directory.current;
  for (var i = 0; i < 8; i++) {
    final root = Directory('${d.path}/corpus/seq');
    if (root.existsSync()) {
      final files = root
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.seq'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final f in files) {
        if (detectSeqFormat(f.readAsBytesSync()) == SeqFormat.xml) return f.path;
      }
    }
    final p = d.parent;
    if (p.path == d.path) break;
    d = p;
  }
  return null;
}
