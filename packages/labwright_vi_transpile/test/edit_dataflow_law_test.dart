@Tags(['corpus'])
library;

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_transpile/labwright_vi_transpile.dart';
import 'package:test/test.dart';

import 'crc8_api.dart';
import 'snippets.dart';

String? _signatureOf(ViModel model) {
  final diagram = model.primaryBlockDiagram;
  if (diagram == null) return null;
  final flow = buildLvDataflow(diagram, pool: model.types);
  return flow.refusal == null ? lvDataflowSignature(flow.dataflow!) : null;
}

void main() {
  test('crc8 built from the API computes what the corpus crc8 computes, before and after a file round trip', () {
    final vi = snippetUnit('crc8');
    final expected = lvDataflowSignature(buildLvDataflow(vi.diagram, pool: vi.pool).dataflow!);
    final built = buildCrc8();
    expect(_signatureOf(built), expected);
    expect(_signatureOf(buildViModel(built.serialize())), expected);
  });

  test('every snippet lifted into the editor, written and re-read computes the same dataflow', () {
    final differing = <String>[];
    var compared = 0;
    for (final file in corpusFiles(corpusVi, '.png')) {
      final bytes = extractSnippetVi(file.readAsBytesSync());
      if (bytes == null) continue;
      final model = buildViModel(bytes);
      final before = _signatureOf(model);
      if (before == null) continue;
      model.blockDiagram.write();
      final after = _signatureOf(buildViModel(model.serialize()));
      compared++;
      if (after != before) differing.add(file.uri.pathSegments.last);
    }
    expect(compared, greaterThan(300));
    expect(differing, isEmpty);
  });
}
