import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'reconstruction/dataflow.dart';

void main() {
  test('a For loop built from the API re-reads with its terminals, and grows around its body', () {
    final vi = ViModel.empty();
    final loop = vi.add(BdLoop.forLoop());
    expect(loop.bounds, const HeapRect(top: 20, left: 20, bottom: 120, right: 140));
    final add = loop.add(BdPrimitive(PrimOp.add));
    final times = loop.add(BdPrimitive(PrimOp.multiply));
    expect(
      (add.bounds, times.bounds),
      (
        const HeapRect(top: 20, left: 20, bottom: 52, right: 52),
        const HeapRect(top: 20, left: 72, bottom: 52, right: 104),
      ),
    );
    final eight = vi.add(BdConstant.i32(8, label: 'eight'));
    vi.connect(eight, loop.count);
    vi.connect(loop.iteration, add.terminal('x'));
    vi.connect(add.terminal('x+y'), times.terminal('x'), type: BdType.i32);
    vi.connect(eight, times.terminal('y'));
    expect(loop.borderTerminals.map((t) => t.kind.name), ['count', 'loopTunnel', 'iteration']);
    vi.write();
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
    final again = buildViModel(vi.serialize()).diagram;
    expect(again.all<BdLoop>().single.body.all<BdPrimitive>().map((p) => p.op), [PrimOp.add, PrimOp.multiply]);
  });

  test('objects exist before a frame takes them, and a structure keeps what its frames took', () {
    final vi = ViModel.empty();
    final outer = BdLoop.whileLoop();
    final inner = BdCase();
    final stop = vi.control(BdType.boolean, 'stop', frame: outer.body);
    final one = inner.whenTrue.add(BdConstant.i32(1));
    final negate = inner.whenTrue.add(BdPrimitive(PrimOp.decrement));
    outer.add(inner);
    expect((outer.isPlaced, inner.isPlaced, one.isPlaced, stop.isPlaced), (false, false, false, false));
    expect(() => one.oid, throwsStateError);
    expect(() => inner.tunnel(BdType.i32, direction: BdTunnelDirection.input), throwsStateError);
    vi.add(outer);
    expect((outer.isPlaced, inner.isPlaced, one.isPlaced, stop.isPlaced), (true, true, true, true));
    expect(outer.body.placed, [stop, inner]);
    expect(inner.whenTrue.placed, [one, negate]);
    expect(() => vi.add(inner), throwsStateError);
    vi.connect(one, negate.terminal('x'));
    vi.connect(stop, outer.conditional);
    vi.write();
    final again = buildViModel(vi.serialize()).diagram;
    expect(again.all<BdLoop>().single.body.all<BdCase>().single.whenTrue.wires.length, 1);
  });

  test('a wire from one source to two sinks is one signal with a branching route', () {
    final vi = ViModel.empty();
    final one = vi.add(BdConstant.i32(1, at: const HeapRect(top: 60, left: 10, bottom: 79, right: 46)));
    final a = vi.add(BdPrimitive(PrimOp.increment, at: const HeapRect(top: 10, left: 100, bottom: 42, right: 132)));
    final b = vi.add(BdPrimitive(PrimOp.decrement, at: const HeapRect(top: 110, left: 100, bottom: 142, right: 132)));
    final wire = vi.connect(one, a.terminal('x'));
    expect(vi.connect(one, b.terminal('x')), same(wire));
    expect(wire.endpointOids, [one.oid, a.terminal('x').oid, b.terminal('x').oid]);
    vi.write();
    final signal = vi.primaryBlockDiagram!.wires.single;
    expect(signal.branchRoute, isNotNull);
    final tree = walkWireBranchRoute(signal.branchRoute!, one.attachPoint);
    expect(tree.leaves.toSet(), {a.terminal('x').attachPoint, b.terminal('x').attachPoint});
  });

  test('controls, indicators and typed constants carry their names and values through the pool', () {
    final vi = ViModel.empty();
    final poly = vi.control(BdType.u8, 'Poly');
    final crc = vi.indicator(BdType.u8, 'CRC');
    final flag = vi.add(BdConstant.boolean(false, label: 'carry'));
    final lut = vi.add(BdConstant.array(BdType.u8, [3, 1, 4]));
    final text = vi.add(BdConstant.string('hi'));
    final zero = vi.add(BdConstant.dbl(0));
    final big = vi.add(BdConstant.i16(-2));
    vi.connect(poly, crc);
    vi.write();
    final diagram = vi.primaryBlockDiagram!;
    final leaves = diagram.objects.where((o) => o.objectClass == HeapObjectClass.bdLeaf).toList();
    expect(leaves.map((l) => (l.typeName, l.isIndicator)), [('Poly', false), ('CRC', true)]);
    expect(vi.frontPanelDiagrams.single.objects.where((o) => o.objectClass == HeapObjectClass.node).length, 2);
    final constants = diagram.objects.where((o) => o.objectClass == HeapObjectClass.bdConstDco).toList();
    expect(constants.map((c) => c.constBool ?? c.constArray ?? c.constText ?? c.constNumeric), [
      false,
      [3, 1, 4],
      'hi',
      0,
      -2,
    ]);
    expect(constants.map((c) => c.constValueRaw?.length), [2, 7, 6, 9, 2]);
    expect(constants.map((c) => c.typeName), ['carry', null, null, null, null]);
    expect(
      (flag.type, lut.type, text.type, zero.type, big.type),
      (
        BdType.boolean,
        BdType.u8.array,
        BdType.string,
        BdType.dbl,
        const BdType.scalar(ViDataType.i16),
      ),
    );
    expect(diagram.wires.single.signalType?.raw, BdType.u8.signalWord);
  });

  test('a Case with a wire through each frame, and a While loop, re-read with their frames and terminals', () {
    final vi = ViModel.empty();
    final choose = vi.add(BdCase());
    final x = vi.add(BdConstant.i32(5));
    final yes = vi.add(BdConstant.boolean(true));
    final out = vi.indicator(BdType.i32, 'out');
    final input = choose.tunnel(BdType.i32, direction: BdTunnelDirection.input);
    final output = choose.tunnel(BdType.i32, direction: BdTunnelDirection.output);
    final negate = choose.whenTrue.add(BdPrimitive(PrimOp.decrement));
    vi.connect(input.inner(choose.whenFalse), output.inner(choose.whenFalse));
    vi.connect(input.inner(choose.whenTrue), negate.terminal('x'));
    vi.connect(negate.terminal('x-1'), output.inner(choose.whenTrue));
    vi.connect(x, input);
    vi.connect(yes, choose.selector);
    vi.connect(output, out);
    final loop = vi.add(BdLoop.whileLoop());
    vi.connect(yes, loop.conditional);
    vi.write();
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
    final again = buildViModel(vi.serialize()).diagram;
    final liftedCase = again.all<BdCase>().single;
    expect(liftedCase.borderTerminals.map((t) => t.kind.name), ['selector', 'caseTunnel', 'caseTunnel']);
    expect(liftedCase.borderTerminals[1].inners.length, 2);
    expect(again.all<BdLoop>().single.conditional.kind, BdBorderKind.conditional);
  });

  test('a wire across structure borders takes the tunnels it needs and reuses the ones it fed', () {
    final vi = ViModel.empty();
    final n = vi.control(BdType.i32, 'n');
    final out = vi.indicator(BdType.i32, 'out');
    final loop = vi.add(BdLoop.forLoop());
    final choose = loop.add(BdCase());
    final add = choose.whenTrue.add(BdPrimitive(PrimOp.add));
    final times = choose.whenTrue.add(BdPrimitive(PrimOp.multiply));
    vi.connect(n, add.terminal('x'));
    vi.connect(n, times.terminal('x'));
    vi.connect(loop.iteration, add.terminal('y'));
    vi.connect(add.terminal('x+y'), out, type: BdType.i32);
    expect(loop.borderTerminals.map((t) => t.kind.name), ['count', 'loopTunnel', 'loopTunnel', 'iteration']);
    expect(choose.borderTerminals.map((t) => t.kind.name), ['selector', 'caseTunnel', 'caseTunnel', 'caseTunnel']);
    final into = loop.borderTerminals[1];
    expect(vi.diagram.wires.first.endpointOids, [n.oid, into.outer.oid]);
    expect(loop.body.wires.first.endpointOids, [into.innerPort.oid, choose.borderTerminals[1].outer.oid]);
    expect(choose.whenTrue.wires.first.endpointOids, [
      choose.borderTerminals[1].inner(choose.whenTrue).oid,
      add.terminal('x').oid,
      times.terminal('x').oid,
    ]);
    expect(() => vi.connect(out, n), throwsArgumentError);
    expect(() => vi.connect(times.terminal('y'), add.terminal('y')), throwsArgumentError);
  });

  test('a flat sequence carries a value frame to frame through paired tunnels, and re-reads', () {
    final vi = ViModel.empty();
    final n = vi.control(BdType.i32, 'n');
    final sequence = vi.add(BdSequence(frameCount: 3));
    final first = sequence.stages[0], last = sequence.stages[2];
    final increment = first.add(BdPrimitive(PrimOp.increment));
    final decrement = sequence.stages[1].add(BdPrimitive(PrimOp.decrement));
    final out = vi.indicator(BdType.i32, 'out', frame: last.body);
    final twice = vi.indicator(BdType.i32, 'twice', frame: last.body);
    vi.connect(n, increment.terminal('x'));
    vi.connect(increment.out, out);
    vi.connect(increment.out, twice);
    vi.connect(n, decrement.terminal('x'));
    expect(first.borderTerminals.map((t) => t.kind.name), ['sequenceTunnel', 'frameTunnel']);
    expect(sequence.stages[1].borderTerminals.map((t) => t.kind.name), [
      'frameTunnel',
      'frameTunnel',
      'sequenceTunnel',
    ]);
    expect(last.borderTerminals.map((t) => t.kind.name), ['frameTunnel']);
    expect(first.borderTerminals[1].partner, same(sequence.stages[1].borderTerminals[0]));
    expect(vi.diagram.wires.map((w) => w.endpointOids.length), [3, 2, 2]);
    expect(last.body.wires.single.endpointOids.length, 3);
    vi.write();
    final before = bdDataflow(vi);
    expect(before, contains('bdFlatSequence displayed 0.f2.indicator out'));
    expect(bdDataflow(buildViModel(vi.serialize())), before);
  });
}
