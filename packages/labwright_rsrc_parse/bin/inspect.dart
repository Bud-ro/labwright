import 'dart:io';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run labwright_rsrc_parse:inspect <file.vi>');
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
