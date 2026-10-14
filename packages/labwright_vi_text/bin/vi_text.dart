import 'dart:io';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_text/labwright_vi_text.dart';

/// `vi_text <file.vi|snippet.png> [out.dart]`: writes the VI's text form as Dart, naming it
/// after the file; without an output path, prints it.
///
/// `vi_text --corpus <out dir>`: writes one Dart file per VI, control and snippet under
/// `corpus/vi`, mirroring their paths, and reports the count and size.
void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln(
      'usage: vi_text <file.vi|snippet.png> [out.dart] | --corpus <out dir>',
    );
    exit(2);
  }
  if (args.first == '--corpus') {
    _corpus(Directory(args.length > 1 ? args[1] : 'corpus/text'));
    return;
  }
  final text = _textOf(File(args[0]));
  if (args.length > 1) {
    File(args[1]).writeAsStringSync(text);
  } else {
    stdout.write(text);
  }
}

String _textOf(File file) {
  var bytes = file.readAsBytesSync();
  if (isPngBytes(bytes)) bytes = extractSnippetVi(bytes) ?? bytes;
  final stem = file.uri.pathSegments.last.replaceAll(
    RegExp(r'\.(vi|png|ctl|vit)$'),
    '',
  );
  return emitViSpecDart(
    viSpecOf(bytes, name: '$stem.vi'),
    identifier: _identifier(stem),
  );
}

void _corpus(Directory out) {
  final root = Directory('corpus/vi');
  var count = 0, bytes = 0, skipped = 0;
  final clock = Stopwatch()..start();
  for (final file in root.listSync(recursive: true).whereType<File>()) {
    final path = file.path;
    final isVi =
        path.endsWith('.vi') ||
        path.endsWith('.ctl') ||
        path.endsWith('.vit') ||
        path.endsWith('.png');
    if (!isVi) continue;
    final String text;
    try {
      text = _textOf(file);
    } on ViFormatException {
      skipped++;
      continue;
    }
    final target = File(
      '${out.path}/${path.substring(root.path.length + 1)}.dart',
    )..parent.createSync(recursive: true);
    target.writeAsStringSync(text);
    count++;
    bytes += text.length;
  }
  stdout.writeln(
    '$count files, ${(bytes / 1e6).toStringAsFixed(1)} MB of Dart, $skipped not VIs, ${clock.elapsed.inSeconds} s',
  );
}

String _identifier(String stem) {
  final words = stem
      .split(RegExp(r'[^A-Za-z0-9]+'))
      .where((w) => w.isNotEmpty)
      .toList();
  if (words.isEmpty) return 'vi';
  final camel = [
    words.first.toLowerCase(),
    for (final word in words.skip(1)) word[0].toUpperCase() + word.substring(1),
  ].join();
  return RegExp(r'^[0-9]').hasMatch(camel) ? 'vi$camel' : camel;
}
