// CLI for the TestStand → Dart exporter: parses a `.seq` file (XML, INI, or
// binary TOF1 — binary yields the partial skeleton) and writes the exported
// Dart source. Run:
//   dart run tool/export_dart.dart <input.seq> [output.dart] [--e2e]
// With no output path the generated source prints to stdout; --e2e emits a
// labwright E2E program (exportSeqFileToLabwright) instead of plain logic —
// run it with `dart run` or the `labwright` runner, never `dart test`.
import 'dart:io';

import 'package:labwright_seq/labwright_seq.dart';

void main(List<String> args) {
  final asE2e = args.contains('--e2e');
  final rest = [for (final a in args) if (a != '--e2e') a];
  if (rest.isEmpty) {
    stderr.writeln('usage: dart run tool/export_dart.dart <input.seq> '
        '[output.dart] [--e2e]');
    exit(64);
  }
  final input = File(rest[0]);
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
  final name = input.uri.pathSegments.last;
  final source = asE2e
      ? exportSeqFileToLabwright(file, sourceName: name)
      : exportSeqFileToDart(file, sourceName: name);
  if (rest.length > 1) {
    File(rest[1]).writeAsStringSync(source);
    stderr.writeln('wrote ${rest[1]} (${source.split('\n').length} lines, '
        '${file.sequences.length} sequences)');
  } else {
    stdout.write(source);
  }
}
