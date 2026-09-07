@Tags(['corpus'])
library;

import 'dart:io';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

void main() {
  test('corpus pin: crc8 scalar-width caption', () {
    final crc8 = File('${corpusViDir.path}/rcpacini_VI-Snippets/rcpacini-VI-Snippets-1662bd7/crc8.png');
    final vi = extractSnippetVi(crc8.readAsBytesSync())!;
    final o = buildViModel(vi).blockDiagrams.single.byId[221]!;
    expect((o.kind, o.label, o.parentOid), (0x0a, 'XOR?', 220));
  });
}
