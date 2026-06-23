import 'dart:convert';
import 'dart:io';

import 'package:labwright_tdms/labwright_tdms.dart';

/// CLI: `dart run labwright_tdms:summary <file.tdms>` — prints a JSON summary.
Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run labwright_tdms:summary <file.tdms>');
    exitCode = 64;
    return;
  }
  final file = File(args.first);
  if (!file.existsSync()) {
    stderr.writeln('no such file: ${args.first}');
    exitCode = 66;
    return;
  }
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(tdmsSummary(await file.readAsBytes())));
}
