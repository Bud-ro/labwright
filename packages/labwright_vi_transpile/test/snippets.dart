import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_transpile/labwright_vi_transpile.dart';

Directory snippetDir() {
  var dir = Directory.current;
  for (var depth = 0; depth < 8; depth++) {
    for (final relative in const [
      'packages/labwright_rsrc_parse/corpus/snippets',
      '../labwright_rsrc_parse/corpus/snippets',
    ]) {
      final candidate = Directory('${dir.path}/$relative');
      if (candidate.existsSync()) return candidate;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  throw StateError('the tracked snippet corpus is missing');
}

List<File> snippetFiles() =>
    snippetDir()
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.png') && extractSnippetVi(file.readAsBytesSync()) != null)
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

({ViDiagram diagram, List<ViType> pool}) snippetVi(String name) {
  final unit = snippetUnit(name);
  return (diagram: unit.diagram, pool: unit.pool);
}

LvViUnit snippetUnit(String name) {
  final vi = extractSnippetVi(File('${snippetDir().path}/$name.png').readAsBytesSync())!;
  return LvViUnit.fromSections(decodeSections(Uint8List.fromList(vi)), fileName: '$name.vi')!;
}

ViDiagram snippetDiagram(String name) => snippetVi(name).diagram;

String snippetName(File file) => file.uri.pathSegments.last.replaceAll(RegExp(r'\.png$'), '');

Directory corpusViDir() {
  var dir = Directory.current;
  for (var depth = 0; depth < 8; depth++) {
    for (final relative in const ['packages/labwright_rsrc_parse/corpus', '../labwright_rsrc_parse/corpus']) {
      final candidate = Directory('${dir.path}/$relative/vi');
      if (candidate.existsSync()) return candidate;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  throw StateError('the VI corpus is not fetched');
}

List<String> corpusViPaths(Directory corpus) =>
    corpus
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.toLowerCase().endsWith('.vi'))
        .map((file) => file.path)
        .toList()
      ..sort();
