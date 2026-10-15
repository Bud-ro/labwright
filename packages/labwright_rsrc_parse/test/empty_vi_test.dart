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
      ('21.0', 2, 1, 1),
    );
    expect((model.connectorPaneType as ViFunctionType?)?.parameterCount, kEmptyViPaneTerminals);
    final diagram = model.diagram;
    expect(
      (diagram.placed.length, diagram.wires.length, diagram.endpointTable?.oid),
      (0, 0, EmptyViOid.endpointTable.oid),
    );
    expect(model.allocateUid(), kEmptyViFirstFreeOid);
    expect(model.frontPanelDiagrams.single.objects.map((o) => o.objectClass.name).toSet(), contains('contentViewport'));
    expect(model.primaryBlockDiagram!.objects.map((o) => o.objectClass.name), ['diagramRoot', 'bdFrame', 'bdWire']);
    final again = buildViModel(model.serialize());
    expect(again.sections.map((s) => s.bytes.length), model.sections.map((s) => s.bytes.length));
  });

  test('two primitives wired in an empty VI re-read as nodes with named terminals and a signal', () {
    final model = ViModel.empty();
    final add = model.add(BdPrimitive(PrimOp.add, at: const HeapRect(top: 40, left: 40, bottom: 72, right: 72)));
    final times = model.add(
      BdPrimitive(PrimOp.multiply, at: const HeapRect(top: 40, left: 140, bottom: 72, right: 172)),
    );
    expect(add.terminals.map((t) => t.name), ['x+y', 'y', 'x']);
    expect(add.out.attachPoint.x, 72 - 11);
    final wire = model.connect([add.out, times.terminal('x')], type: BdType.i32);
    expect(wire.endpointOids, [add.out.oid, times.terminal('x').oid]);
    model.write();
    final diagram = model.primaryBlockDiagram!;
    final nodes = diagram.objects.where((o) => o.objectClass == HeapObjectClass.bdNode).toList();
    expect(nodes.map((o) => o.primResId), [PrimOp.add.id, PrimOp.multiply.id]);
    expect(nodes.map((o) => diagram.childrenOf(o).length), [3, 3]);
    expect(diagram.wires.single.endpointOids, wire.endpointOids);
    expect(diagram.wires.single.route?.pointCount, 3);
    final lifted = buildViModel(model.serialize()).diagram;
    expect(lifted.all<BdPrimitive>().map((p) => p.op?.name), ['add', 'multiply']);
    expect(lifted.wires.single.signalKind, 0x103);
  });
}
