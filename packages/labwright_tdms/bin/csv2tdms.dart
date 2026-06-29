import 'dart:io';

import 'package:labwright_tdms/labwright_tdms.dart';

/// CLI: `dart run labwright_tdms:csv2tdms <in.csv> [--out f.tdms] [--group G]`
Future<void> main(List<String> args) async {
  var group = 'Imported';
  String? outPath;
  String? input;
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == '--group' && i + 1 < args.length) {
      group = args[++i];
    } else if (a == '--out' && i + 1 < args.length) {
      outPath = args[++i];
    } else if (!a.startsWith('--')) {
      input = a;
    }
  }

  if (input == null) {
    stderr.writeln('usage: dart run labwright_tdms:csv2tdms <in.csv> [--out f.tdms] [--group G]');
    exitCode = 64;
    return;
  }
  final inFile = File(input);
  if (!inFile.existsSync()) {
    stderr.writeln('no such file: $input');
    exitCode = 66;
    return;
  }

  final out = outPath ?? '$input.tdms';
  await File(out).writeAsBytes(csvToTdms(await inFile.readAsString(), group: group));
  stdout.writeln('wrote $out');
}
