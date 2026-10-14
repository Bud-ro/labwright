import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import '../corpus_dirs.dart';

const _laws = {'diagram', 'panel', 'edited', 'lift'};

bool _same(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

Map<String, int> _census(CorpusVi vi) {
  final c = <String, int>{};
  void bump(String k) => c[k] = (c[k] ?? 0) + 1;
  final model = vi.model;
  if (model == null || isNonRsrcFixture(vi.path)) return c;
  final diagram = model.section(BlockTag.bdhb.tag);
  final panel = model.section(BlockTag.fphb.tag);
  if (diagram == null || panel == null) return c;
  final diagramBefore = Uint8List.fromList(diagram.bytes);
  final panelBefore = Uint8List.fromList(panel.bytes);
  final BdEditor editor;
  try {
    editor = model.blockDiagram;
    for (final frame in editor.diagram.all<BdStructure>().expand((s) => s.frames)) {
      frame.placed;
      frame.wires;
    }
    editor.diagram.placed;
    editor.diagram.wires;
    editor.panel.controls;
  } catch (_) {
    bump('lift');
    return c;
  }
  editor.write();
  bump('lifted');
  if (!_same(diagram.bytes, diagramBefore)) bump('diagram');
  if (!_same(panel.bytes, panelBefore)) bump('panel');
  if (diagram.edited || panel.edited) bump('edited');
  return c;
}

const bdEditLaw = CorpusLaw('bd_edit', _census);

void bdEditTests() {
  test('every diagram and panel lifts into the editor and writes back byte for byte', () async {
    expect(await bdEditLaw.nonzero(_laws), isEmpty);
  });
}
