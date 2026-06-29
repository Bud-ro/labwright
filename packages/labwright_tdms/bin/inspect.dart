import 'dart:io';

import 'package:labwright_tdms/labwright_tdms.dart';

/// Exit code for a usage error (`EX_USAGE` from sysexits.h).
const int _exUsage = 64;

/// Exit code for a missing input file (`EX_NOINPUT` from sysexits.h).
const int _exNoInput = 66;

/// CLI: `dart run labwright_tdms:inspect <file.tdms>` — prints a summary of a
/// TDMS file (groups, channels, stats, properties).
Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run labwright_tdms:inspect <file.tdms>');
    exitCode = _exUsage;
    return;
  }
  final file = File(args.first);
  if (!file.existsSync()) {
    stderr.writeln('no such file: ${args.first}');
    exitCode = _exNoInput;
    return;
  }
  stdout.write(inspectTdms(await file.readAsBytes()));
}
