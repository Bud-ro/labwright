@Tags(['corpus'])
library;

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import '../../../tool/corpus.dart';

void main() {
  test('crc8 lifts into placed objects, named terminals and wires, and writes back byte for byte', () {
    final bytes = extractSnippetVi(snippetPng('crc8.png').readAsBytesSync())!;
    final model = buildViModel(bytes);
    final editor = model.blockDiagram;
    final root = editor.diagram;
    expect(root.all<BdPrimitive>().map((p) => p.op?.name), ['exclusiveOr', 'stringToByteArray']);
    expect(root.all<BdLoop>().length, 2);
    expect(root.all<BdStructure>().map((s) => s.objectClass.name), [
      'bdForLoop',
      'bdDisableStructure',
      'bdForLoop',
      'bdStructureFrame',
    ]);
    expect(root.all<BdPanelTerminal>().length, 7);
    expect(root.wires.length, 14);
    final xor = root.all<BdPrimitive>().first;
    expect(xor.terminals.map((t) => t.name), ['x .xor. y?', 'y', 'x']);
    expect(xor.terminals.map((t) => t.isSink), [false, true, true]);
    expect(xor.terminal('x'), same(xor.inputs[1]));
    final loop = root.all<BdLoop>().first;
    expect((loop.isFor, loop.frames.length), (true, 1));
    expect(
      loop.body.all<BdPrimitive>().map((p) => p.op?.name ?? p.primResId.toString()),
      contains('toUnsignedByteInteger'),
    );
    final nested = loop.body.all<BdLoop>().single;
    expect(nested.body.all<BdCase>().single.frames.length, 2);
    expect(root.wires.first.endpointOids.length, greaterThanOrEqualTo(2));
    final before = model.section('BDHb')!.bytes;
    expect(editor.encode(), before);
    editor.write();
    expect(model.section('BDHb')!.bytes, before);
    expect(model.section('BDHb')!.edited, isFalse);
  });
}
