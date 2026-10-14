@Tags(['corpus'])
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_inspector/src/bd_oracle.dart';

import 'util.dart';

Future<Uint8List?> _rgba(ViModel model) async {
  final diagram = bestBlockDiagram(model);
  if (diagram == null) return null;
  final raster = await rasteriseBlockDiagram(diagram, scale: 1.0, margin: 2);
  return raster == null
      ? null
      : (await raster.image.toByteData())!.buffer.asUint8List();
}

bool _same(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

void main() {
  testWidgets(
    'every snippet lifted into the editor, written and re-read draws the same pixels',
    (tester) async {
      await loadRealTextFont();
      final differing = <String>[];
      var compared = 0;
      await tester.runAsync(() async {
        for (final file in snippetCorpusPngs()) {
          final model = buildViModel(extractSnippetVi(file.readAsBytesSync())!);
          final before = await _rgba(model);
          if (before == null) continue;
          model.blockDiagram.write();
          final after = await _rgba(buildViModel(model.serialize()));
          compared++;
          if (after == null || !_same(before, after))
            differing.add(file.uri.pathSegments.last);
        }
      });
      expect(compared, greaterThan(500));
      expect(differing, isEmpty);
    },
  );
}
