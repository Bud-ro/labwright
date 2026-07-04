// CLI for the TestStand → Dart exporter: parses a `.seq` file (XML, INI, or
// binary TOF1 — binary yields the partial skeleton) and writes the exported
// Dart source. Run:
//   dart run tool/export_dart.dart <input.seq> [output.dart]
// With no output path the generated source prints to stdout.
import 'dart:io';

import 'package:labwright_seq/labwright_seq.dart';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/export_dart.dart <input.seq> [output.dart]');
    exit(64);
  }
  final input = File(args[0]);
  if (!input.existsSync()) {
    stderr.writeln('not found: ${input.path}');
    exit(66);
  }
  final SeqFile file;
  try {
    file = parseSeqFile(input.readAsBytesSync());
  } on Exception catch (e) {
    stderr.writeln('cannot parse ${input.path}: $e');
    exit(65);
  }
  final source = exportSeqFileToDart(file,
      sourceName: input.uri.pathSegments.last);
  if (args.length > 1) {
    File(args[1]).writeAsStringSync(source);
    stderr.writeln('wrote ${args[1]} (${source.split('\n').length} lines, '
        '${file.sequences.length} sequences)');
  } else {
    stdout.write(source);
  }
}
