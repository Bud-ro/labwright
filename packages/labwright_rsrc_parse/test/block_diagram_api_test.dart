import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

void main() {
  test('a For loop built from the API re-reads with its terminals, and grows around its body', () {
    final vi = ViModel.empty();
    final bd = vi.blockDiagram;
    final loop = bd.diagram.add(BdLoop.create(bd));
    expect(loop.bounds, const HeapRect(top: 20, left: 20, bottom: 120, right: 140));
    final add = loop.body.add(BdPrimitive.create(bd, PrimOp.add));
    final times = loop.body.add(BdPrimitive.create(bd, PrimOp.multiply));
    expect(
      (add.bounds, times.bounds),
      (
        const HeapRect(top: 20, left: 20, bottom: 52, right: 52),
        const HeapRect(top: 20, left: 72, bottom: 52, right: 104),
      ),
    );
    final eight = bd.diagram.add(BdConstant.create(bd, BdType.i32, 8, label: 'eight'));
    bd.connect(eight.out, loop.count!.outer!);
    bd.connect(loop.iteration.innerPort, add.terminal('x'));
    bd.connect(add.terminal('x+y'), times.terminal('x'), type: BdType.i32);
    bd.connect(eight.out, times.terminal('y'));
    expect(loop.borderTerminals.map((t) => t.kind.name), ['count', 'loopTunnel', 'iteration']);
    bd.write();
    final diagram = vi.primaryBlockDiagram!;
    final classes = diagram.objects.map((o) => o.objectClass).toSet();
    expect(
      classes,
      containsAll([
        HeapObjectClass.bdForLoop,
        HeapObjectClass.bdCountTerminal,
        HeapObjectClass.bdIterationTerminal,
        HeapObjectClass.bdLoopTunnel,
        HeapObjectClass.bdConstDco,
      ]),
    );
    expect(diagram.wires.length, 4);
    final structure = diagram.objects.firstWhere((o) => o.objectClass == HeapObjectClass.bdForLoop);
    expect(diagram.childrenOf(structure).where((o) => o.objectClass == HeapObjectClass.bdFrame).length, 1);
    final constant = diagram.objects.firstWhere((o) => o.objectClass == HeapObjectClass.bdConstDco);
    expect((constant.constNumeric, constant.typeName), (8, 'eight'));
    final again = buildViModel(vi.serialize()).blockDiagram.diagram;
    expect(again.all<BdLoop>().single.body.all<BdPrimitive>().map((p) => p.op), [PrimOp.add, PrimOp.multiply]);
  });

  test('a wire from one source to two sinks is one signal with a branching route', () {
    final vi = ViModel.empty();
    final bd = vi.blockDiagram;
    final one = bd.diagram.add(
      BdConstant.create(bd, BdType.i32, 1, at: const HeapRect(top: 60, left: 10, bottom: 79, right: 46)),
    );
    final a = bd.diagram.add(
      BdPrimitive.create(bd, PrimOp.increment, at: const HeapRect(top: 10, left: 100, bottom: 42, right: 132)),
    );
    final b = bd.diagram.add(
      BdPrimitive.create(bd, PrimOp.decrement, at: const HeapRect(top: 110, left: 100, bottom: 142, right: 132)),
    );
    final wire = bd.connect(one.out, a.terminal('x'));
    expect(bd.connect(one.out, b.terminal('x')), same(wire));
    expect(wire.endpointOids, [one.oid, a.terminal('x').oid, b.terminal('x').oid]);
    bd.write();
    final signal = vi.primaryBlockDiagram!.wires.single;
    expect(signal.branchRoute, isNotNull);
    final tree = walkWireBranchRoute(signal.branchRoute!, one.out.attachPoint);
    expect(tree.leaves.toSet(), {a.terminal('x').attachPoint, b.terminal('x').attachPoint});
  });

  test('controls, indicators and typed constants carry their names and values through the pool', () {
    final vi = ViModel.empty();
    final bd = vi.blockDiagram;
    final poly = bd.control(BdType.u8, 'Poly');
    final crc = bd.indicator(BdType.u8, 'CRC');
    final flag = bd.diagram.add(BdConstant.create(bd, BdType.boolean, false, label: 'carry'));
    final lut = bd.diagram.add(BdConstant.create(bd, BdType.u8Array, [3, 1, 4]));
    final text = bd.diagram.add(BdConstant.create(bd, BdType.string, 'hi'));
    bd.connect(poly.terminal, crc.terminal);
    bd.write();
    final diagram = vi.primaryBlockDiagram!;
    final leaves = diagram.objects.where((o) => o.objectClass == HeapObjectClass.bdLeaf).toList();
    expect(leaves.map((l) => (l.typeName, l.isIndicator)), [('Poly', false), ('CRC', true)]);
    expect(vi.frontPanelDiagrams.single.objects.where((o) => o.objectClass == HeapObjectClass.node).length, 2);
    final constants = diagram.objects.where((o) => o.objectClass == HeapObjectClass.bdConstDco).toList();
    expect(constants.map((c) => c.constBool ?? c.constArray ?? c.constText), [
      false,
      [3, 1, 4],
      'hi',
    ]);
    expect(constants.map((c) => c.typeName), ['carry', null, null]);
    expect((flag.out.type, lut.out.type, text.out.type), (BdType.boolean, BdType.u8Array, BdType.string));
    expect(diagram.wires.single.signalType?.raw, BdType.u8.signalWord);
  });

  test('a Case with a wire through each frame, and a While loop, re-read with their frames and terminals', () {
    final vi = ViModel.empty();
    final bd = vi.blockDiagram;
    final choose = bd.diagram.add(BdCase.create(bd));
    final x = bd.diagram.add(BdConstant.create(bd, BdType.i32, 5));
    final yes = bd.diagram.add(BdConstant.create(bd, BdType.boolean, true));
    final out = bd.indicator(BdType.i32, 'out');
    final input = choose.tunnel(BdType.i32, output: false);
    final output = choose.tunnel(BdType.i32, output: true);
    final negate = choose.frames[1].add(BdPrimitive.create(bd, PrimOp.decrement));
    bd.connect(input.inner(choose.frames[0]), output.inner(choose.frames[0]));
    bd.connect(input.inner(choose.frames[1]), negate.terminal('x'));
    bd.connect(negate.terminal('x-1'), output.inner(choose.frames[1]));
    bd.connect(x.out, input.outer!);
    bd.connect(yes.out, choose.selector.outer!);
    bd.connect(output.outer!, out.terminal);
    final loop = bd.diagram.add(BdLoop.create(bd, isFor: false));
    bd.connect(yes.out, loop.conditional!.innerPort);
    bd.write();
    final diagram = vi.primaryBlockDiagram!;
    final structure = diagram.objects.firstWhere((o) => o.objectClass == HeapObjectClass.bdStructureFrame);
    expect(
      (
        structure.visibleFrameIndex,
        diagram.childrenOf(structure).where((o) => o.objectClass == HeapObjectClass.bdFrame).length,
      ),
      (1, 2),
    );
    expect(diagram.objects.where((o) => o.objectClass == HeapObjectClass.bdCaseTunnel).length, 2);
    expect(diagram.objects.where((o) => o.objectClass == HeapObjectClass.bdConditionalTerminal).length, 1);
    expect(diagram.wires.length, 7);
    final again = buildViModel(vi.serialize()).blockDiagram.diagram;
    final liftedCase = again.all<BdCase>().single;
    expect(liftedCase.borderTerminals.map((t) => t.kind.name), ['selector', 'caseTunnel', 'caseTunnel']);
    expect(liftedCase.borderTerminals[1].inners.length, 2);
    expect(again.all<BdLoop>().single.conditional, isNotNull);
  });
}
