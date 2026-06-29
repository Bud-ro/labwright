import 'dart:io';

import 'package:labwright_tdms/labwright_tdms.dart';

/// CLI: `dart run labwright_tdms:inspect <file.tdms>` — prints a summary of a
/// TDMS file (groups, channels, stats, properties).
Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run labwright_tdms:inspect <file.tdms>');
    exitCode = 64; // EX_USAGE
    return;
  }
  final file = File(args.first);
  if (!file.existsSync()) {
    stderr.writeln('no such file: ${args.first}');
    exitCode = 66; // EX_NOINPUT
    return;
  }
  stdout.write(inspectTdms(await file.readAsBytes()));
}
