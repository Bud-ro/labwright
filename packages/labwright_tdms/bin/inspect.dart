import 'dart:io';

import 'package:labwright_tdms/labwright_tdms.dart';

const int _exUsage = 64;

const int _exNoInput = 66;

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
