import 'dart:convert';
import 'dart:io';

import 'package:labwright_traceability/labwright_traceability.dart';

/// CLI: `dart run labwright_traceability:trace <requirements.json> <record.json>...`
/// Prints the trace report and exits non-zero if it doesn't pass (drift,
/// unknown references, or incomplete coverage).
Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('usage: dart run labwright_traceability:trace <requirements.json> <record.json>...');
    exitCode = 64;
    return;
  }

  final reqFile = File(args.first);
  if (!reqFile.existsSync()) {
    stderr.writeln('no such file: ${args.first}');
    exitCode = 66;
    return;
  }
  final specs = parseRequirements(jsonDecode(await reqFile.readAsString()));

  final records = <Map<String, Object?>>[];
  for (final path in args.skip(1)) {
    final f = File(path);
    if (!f.existsSync()) {
      stderr.writeln('no such file: $path');
      exitCode = 66;
      return;
    }
    records.add((jsonDecode(await f.readAsString()) as Map).cast<String, Object?>());
  }

  final matrix = buildTraceMatrixFromRecordJson(specs, records);
  stdout.write(traceReport(matrix));
  if (!matrix.ok()) exitCode = 1;
}
