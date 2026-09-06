import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_transpile/labwright_vi_transpile.dart';

void main(List<String> args) {
  final positional = args.where((argument) => !argument.startsWith('--')).toList();
  final options = {
    for (final argument in args.where((argument) => argument.startsWith('--')))
      argument.split('=').first: argument.contains('=') ? argument.split('=').last : '',
  };
  if (positional.isEmpty || positional.length > 2) {
    stderr.writeln('usage: dart run tool/generate.dart [--subvis=<dir>] [--errors=threaded] <input> [output.dart]');
    exit(64);
  }
  final input = File(positional.first);
  final name = input.uri.pathSegments.last;
  final stem = name.replaceAll(RegExp(r'\.\w+$'), '');
  final unit = _unitOf(input, '$stem.vi');
  if (unit == null) {
    stderr.writeln('$name: no block diagram heap with content');
    exit(1);
  }
  final library = options.containsKey('--subvis') ? _index(Directory(options['--subvis']!)) : const <String, File>{};
  final result = emitLvLibrary(
    unit,
    functionName: lvFieldName(stem),
    sourceNote: '$stem.vi',
    errorMode: options['--errors'] == 'threaded' ? LvErrorMode.threaded : LvErrorMode.exceptions,
    resolveSubVi: (fileName) {
      final file = library[fileName.toLowerCase()];
      return file == null ? null : _unitOf(file, fileName);
    },
  );
  if (result.refusal case final refusal?) {
    stderr.writeln('$name: $refusal');
    exit(1);
  }
  if (positional.length == 2) {
    File(positional[1]).writeAsStringSync(result.source!);
  } else {
    stdout.write(result.source);
  }
}

final Map<String, LvViUnit?> _cache = <String, LvViUnit?>{};

LvViUnit? _unitOf(File file, String fileName) => _cache.putIfAbsent(file.path, () {
  final bytes = file.readAsBytesSync();
  final vi = extractSnippetVi(bytes) ?? bytes;
  return LvViUnit.fromSections(decodeSections(Uint8List.fromList(vi)), fileName: fileName);
});

Map<String, File> _index(Directory root) {
  final found = <String, File>{};
  if (!root.existsSync()) return found;
  for (final entry in root.listSync(recursive: true)) {
    if (entry is! File || !entry.path.toLowerCase().endsWith('.vi')) continue;
    found.putIfAbsent(entry.uri.pathSegments.last.toLowerCase(), () => entry);
  }
  return found;
}
