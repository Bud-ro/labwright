import 'dart:io';

import 'package:labwright_tdms/labwright_tdms.dart';

Future<void> main(List<String> args) async {
  var delimiter = ',';
  String? outPath;
  String? input;
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == '--delim' && i + 1 < args.length) {
      delimiter = args[++i];
    } else if (a == '--out' && i + 1 < args.length) {
      outPath = args[++i];
    } else if (!a.startsWith('--')) {
      input = a;
    }
  }

  if (input == null) {
    stderr.writeln('usage: dart run labwright_tdms:tdms2csv <file.tdms> [--out out.csv] [--delim ,]');
    exitCode = 64;
    return;
  }
  final file = File(input);
  if (!file.existsSync()) {
    stderr.writeln('no such file: $input');
    exitCode = 66;
    return;
  }

  final csv = tdmsToCsv(await file.readAsBytes(), delimiter: delimiter);
  if (outPath != null) {
    await File(outPath).writeAsString(csv);
  } else {
    stdout.write(csv);
  }
}
