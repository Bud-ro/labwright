@Tags(['corpus'])
library;

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import '../corpus_dirs.dart';
import 'dataflow.dart';
import 'registry.dart';
import 'scene.dart';

void main() {
  for (final MapEntry(key: png, value: build) in reconstructions.entries) {
    test('$png rebuilt from the API wires the same things together, before and after a file round trip', () {
      final original = buildViModel(extractSnippetVi(snippetPng(png).readAsBytesSync())!);
      final expected = bdDataflow(original);
      final built = build();
      expect(bdDataflow(built), expected);
      expect(bdDataflow(buildViModel(built.serialize())), expected);
      expect(bdSceneText(built), bdSceneText(original));
    });
  }
}
