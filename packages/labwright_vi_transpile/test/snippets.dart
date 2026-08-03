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

/// The block diagram of the snippet named [name] (without the `.png`).
ViDiagram snippetDiagram(String name) {
  final vi = extractSnippetVi(File('${snippetDir().path}/$name.png').readAsBytesSync())!;
  final model = buildViModelFromDecoded(decodeSections(Uint8List.fromList(vi)));
  return lvBlockDiagramOf(model)!;
}

/// A snippet file's name without its extension.
String snippetName(File file) => file.uri.pathSegments.last.replaceAll(RegExp(r'\.png$'), '');
