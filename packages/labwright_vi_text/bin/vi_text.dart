import 'dart:io';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_text/labwright_vi_text.dart';

/// `vi_text <file.vi|snippet.png> [out.dart]`: writes the VI's text form as Dart, naming it
/// after the file; without an output path, prints it.
void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: vi_text <file.vi|snippet.png> [out.dart]');
    exit(2);
  }
  var bytes = File(args[0]).readAsBytesSync();
  if (isPngBytes(bytes)) bytes = extractSnippetVi(bytes) ?? bytes;
  final stem = args[0]
      .split(RegExp(r'[\\/]'))
      .last
      .replaceAll(RegExp(r'\.(vi|png|ctl|vit)$'), '');
  final identifier = _identifier(stem);
  final text = emitViSpecDart(
    viSpecOf(bytes, name: '$stem.vi'),
    identifier: identifier,
  );
  if (args.length > 1) {
    File(args[1]).writeAsStringSync(text);
  } else {
    stdout.write(text);
  }
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
