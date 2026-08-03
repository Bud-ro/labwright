/// Lowers a `.vi` file, or a VI-snippet PNG, to a Dart source file.
///
/// ```
/// dart run tool/generate.dart <input.vi|input.png> [output.dart]
/// ```
///
/// Without an output path the source goes to stdout. A diagram that cannot be
/// lowered prints its refusal and exits non-zero — the generator never writes
/// partial code.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_transpile/labwright_vi_transpile.dart';

void main(List<String> args) {
  if (args.isEmpty || args.length > 2) {
    stderr.writeln('usage: dart run tool/generate.dart <input.vi|input.png> [output.dart]');
    exit(64);
  }
  final input = File(args.first);
  final bytes = input.readAsBytesSync();
  final vi = extractSnippetVi(bytes) ?? bytes;
  final model = buildViModelFromDecoded(decodeSections(Uint8List.fromList(vi)));
  final diagram = lvBlockDiagramOf(model);
  final name = input.uri.pathSegments.last;
  if (diagram == null) {
    stderr.writeln('$name: no block diagram heap with content');
    exit(1);
  }
  final stem = name.replaceAll(RegExp(r'\.\w+$'), '');
  final result = emitLvFunction(diagram, functionName: lvFieldName(stem), sourceNote: '$stem.vi');
  if (result.refusal case final refusal?) {
    stderr.writeln('$name: $refusal');
    exit(1);
  }
  if (args.length == 2) {
    File(args[1]).writeAsStringSync(result.source!);
  } else {
    stdout.write(result.source);
  }
}
