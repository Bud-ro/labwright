import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

void main() {
  test('an empty VI loads with its root frame, an empty panel and no types', () {
    final model = ViModel.empty(name: 'blank.vi');
    expect(model.sections.map((s) => s.tag), [
      'LVSR',
      'vers',
      'CONP',
      'LIvi',
      'CPC2',
      'LIfp',
      'FPEx',
      'FPHb',
      'FPSE',
      'LIbd',
      'BDEx',
      'BDHb',
      'BDSE',
      'DTHP',
      'MUID',
      'VCTP',
      'FTAB', //
    ]);
    expect(
      (model.version, model.types.length, model.blockDiagrams.length, model.frontPanelDiagrams.length),
      ('21.0', 0, 1, 1),
    );
    final diagram = model.blockDiagram.diagram;
    expect((diagram.placed.length, diagram.wires.length, diagram.endpointTable.oid), (0, 0, kEmptyViFirstFreeOid - 1));
    expect(model.allocateUid(), kEmptyViFirstFreeOid);
    expect(model.primaryBlockDiagram!.objects.map((o) => o.objectClass.name), ['diagramRoot', 'bdFrame', 'bdWire']);
    final again = buildViModel(model.serialize());
    expect(again.sections.map((s) => s.bytes.length), model.sections.map((s) => s.bytes.length));
  });

  test('two primitives wired in an empty VI re-read as nodes with named terminals and a signal', () {
    final model = ViModel.empty();
    final editor = model.blockDiagram;
    final add = editor.diagram.add(
      BdPrimitive.create(editor, PrimOp.add, at: const HeapRect(top: 40, left: 40, bottom: 72, right: 72)),
    );
    final times = editor.diagram.add(
      BdPrimitive.create(editor, PrimOp.multiply, at: const HeapRect(top: 40, left: 140, bottom: 72, right: 172)),
    );
    expect(add.terminals.map((t) => t.name), ['x+y', 'x', 'y']);
    expect(add.terminal('x+y').attachPoint.left, 72 - 11);
    final wire = editor.connect(add.terminal('x+y'), times.terminal('x'), type: 0x103);
    expect(wire.endpointOids, [add.terminal('x+y').oid, times.terminal('x').oid]);
    editor.write();
    final diagram = model.primaryBlockDiagram!;
    final nodes = diagram.objects.where((o) => o.objectClass == HeapObjectClass.bdNode).toList();
    expect(nodes.map((o) => o.primResId), [PrimOp.add.id, PrimOp.multiply.id]);
    expect(nodes.map((o) => diagram.childrenOf(o).length), [3, 3]);
    expect(diagram.wires.single.endpointOids, wire.endpointOids);
    expect(diagram.wires.single.route?.pointCount, 3);
    final lifted = buildViModel(model.serialize()).blockDiagram.diagram;
    expect(lifted.all<BdPrimitive>().map((p) => p.op?.name), ['add', 'multiply']);
    expect(lifted.wires.single.signalKind, 0x103);
  });
}
