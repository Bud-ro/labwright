import 'dart:io';

import 'package:labwright_seq/labwright_seq.dart';

import '../../../tool/corpus.dart';

void main(List<String> args) {
  final path = args.isNotEmpty ? args.first : _firstCorpusXml();
  if (path == null) {
    stderr.writeln(
      'usage: dart run tool/dump.dart <file.seq>  '
      '(no corpus/seq found to auto-pick from)',
    );
    exit(1);
  }
  final bytes = File(path).readAsBytesSync();
  stdout.writeln('# $path');
  try {
    stdout.write(dumpSeqFile(parseSeqFile(bytes)));
  } on FormatException catch (e) {
    stdout.writeln('${detectSeqHeader(bytes)}\n($e)');
  }
}

String? _firstCorpusXml() {
  for (final f in corpusFiles(corpusSeq, '.seq')) {
    if (detectSeqFormat(f.readAsBytesSync()) == SeqFormat.xml) return f.path;
  }
  return null;
}
