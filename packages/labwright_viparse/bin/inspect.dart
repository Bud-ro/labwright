import 'dart:io';

import 'package:labwright_viparse/labwright_viparse.dart';

/// CLI: `dart run labwright_viparse:inspect <file.vi>` — prints a VI summary.
Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run labwright_viparse:inspect <file.vi>');
    exitCode = 64;
    return;
  }
  final file = File(args.first);
  if (!file.existsSync()) {
    stderr.writeln('no such file: ${args.first}');
    exitCode = 66;
    return;
  }
  try {
    final vi = parseVi(await file.readAsBytes());
    stdout.writeln(vi.describe());
    stdout.writeln('  type=${vi.fileType} creator=${vi.creator} format=v${vi.formatVersion}');
    stdout.writeln('  blocks: ${vi.blocks.join(', ')}');
  } on ViFormatException catch (e) {
    stderr.writeln(e);
    exitCode = 65;
  }
}
