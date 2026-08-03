/// The tracked VI-snippet PNGs: LabVIEW's own render of a block diagram with
/// the source `.vi` embedded, so a test can lower a real VI without a corpus
/// fetch. They are committed, so these helpers never skip.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_transpile/labwright_vi_transpile.dart';

/// The snippet corpus directory, resolved by walking up from the current
/// directory (tests run from the repo root or from this package).
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

/// Every tracked PNG that really is a snippet — snippet-ness is decided by
/// extraction, so plain art PNGs filter themselves out.
List<File> snippetFiles() =>
    snippetDir()
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.png') && extractSnippetVi(file.readAsBytesSync()) != null)
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

/// The block diagram and consolidated type pool of the snippet named [name]
/// (without the `.png`) — the two inputs a lowering takes.
({ViDiagram diagram, List<ViType> pool}) snippetVi(String name) {
  final unit = snippetUnit(name);
  return (diagram: unit.diagram, pool: unit.pool);
}

/// The snippet named [name] as a lowering unit, connector pane included.
LvViUnit snippetUnit(String name) {
  final vi = extractSnippetVi(File('${snippetDir().path}/$name.png').readAsBytesSync())!;
  return LvViUnit.fromSections(decodeSections(Uint8List.fromList(vi)), fileName: '$name.vi')!;
}

/// The block diagram of the snippet named [name] (without the `.png`).
ViDiagram snippetDiagram(String name) => snippetVi(name).diagram;

/// A snippet file's name without its extension.
String snippetName(File file) => file.uri.pathSegments.last.replaceAll(RegExp(r'\.png$'), '');

/// The RSRC package's fetched `.vi` corpus, or null when it is not present —
/// in which case a corpus-tagged sweep skips rather than failing.
Directory? corpusViDir() {
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
  return null;
}

/// Every `.vi` path under [corpus], sorted, so a sweep's chunking is stable.
List<String> corpusViPaths(Directory corpus) =>
    corpus
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.toLowerCase().endsWith('.vi'))
        .map((file) => file.path)
        .toList()
      ..sort();
