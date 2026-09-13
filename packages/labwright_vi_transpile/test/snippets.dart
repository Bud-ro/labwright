import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_transpile/labwright_vi_transpile.dart';

import '../../../tool/corpus.dart';

export '../../../tool/corpus.dart';

({ViDiagram diagram, List<ViType> pool}) snippetVi(String name) {
  final unit = snippetUnit(name);
  return (diagram: unit.diagram, pool: unit.pool);
}

LvViUnit snippetUnit(String name) {
  final vi = extractSnippetVi(snippetPng('$name.png').readAsBytesSync())!;
  return LvViUnit.fromSections(decodeSections(Uint8List.fromList(vi)), fileName: '$name.vi')!;
}

ViDiagram snippetDiagram(String name) => snippetVi(name).diagram;

List<String> corpusViPaths() => [for (final file in corpusFiles(corpusVi, '.vi')) file.path];
