import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// The LabVIEW wiki's "Loop-Invariant Code Motion", before: a For loop incrementing the same
/// number on every iteration.
ViModel buildLoopInvariantBefore() {
  final vi = ViModel.empty(name: 'Loop-Invariant Code Motion - Before.vi');
  final bd = vi.blockDiagram;
  final numeric = bd.control(
    BdType.i32,
    'Numeric',
    at: (x: 0, y: 37),
    labelAt: const HeapRect(top: -17, left: 0, bottom: 0, right: 49),
  );
  final array = bd.indicator(
    const BdType.array(ViDataType.i32),
    'Array',
    at: (x: 207, y: 37),
    labelAt: const HeapRect(top: -17, left: 0, bottom: 0, right: 31),
  );
  final ten = bd.diagram.add(
    BdConstant.create(bd, BdType.i32, 10, at: const HeapRect(top: 0, left: 71, bottom: 19, right: 90)),
  );
  final loop = bd.diagram.add(BdLoop.create(bd, at: const HeapRect(top: 1, left: 98, bottom: 97, right: 185)));
  loop.iteration.termBounds = const HeapRect(top: 70, left: 10, bottom: 86, right: 26);
  final input = loop.tunnel(BdType.i32, output: false, top: 40);
  final out = loop.tunnel(const BdType.array(ViDataType.i32), output: true, indexing: true, top: 40);
  final increment = loop.body.add(
    BdPrimitive.create(bd, PrimOp.increment, at: const HeapRect(top: 28, left: 30, bottom: 60, right: 62)),
  );
  bd.connect(increment.terminal('x+1'), out.innerPort);
  bd.connect(input.innerPort, increment.terminal('x'));
  bd.connect(numeric.terminal, input.outer!);
  bd.connect(out.outer!, array.terminal);
  bd.connect(ten.out, loop.count!.outer!);
  bd.write();
  return vi;
}

/// The LabVIEW wiki's "Loop-Invariant Code Motion", after: the increment moved out of the loop.
ViModel buildLoopInvariantAfter() {
  final vi = ViModel.empty(name: 'Loop-Invariant Code Motion - After.vi');
  final bd = vi.blockDiagram;
  final numeric = bd.control(
    BdType.i32,
    'Numeric',
    at: (x: 0, y: 37),
    labelAt: const HeapRect(top: -17, left: 0, bottom: 0, right: 49),
  );
  final array = bd.indicator(
    const BdType.array(ViDataType.i32),
    'Array',
    at: (x: 207, y: 37),
    labelAt: const HeapRect(top: -17, left: 0, bottom: 0, right: 31),
  );
  final ten = bd.diagram.add(
    BdConstant.create(bd, BdType.i32, 10, at: const HeapRect(top: 0, left: 71, bottom: 19, right: 90)),
  );
  final increment = bd.diagram.add(
    BdPrimitive.create(bd, PrimOp.increment, at: const HeapRect(top: 29, left: 51, bottom: 61, right: 83)),
  );
  final loop = bd.diagram.add(BdLoop.create(bd, at: const HeapRect(top: 1, left: 98, bottom: 97, right: 185)));
  loop.iteration.termBounds = const HeapRect(top: 70, left: 10, bottom: 86, right: 26);
  final out = loop.tunnel(const BdType.array(ViDataType.i32), output: true, indexing: true, top: 40);
  final input = loop.tunnel(BdType.i32, output: false, top: 40);
  bd.connect(input.innerPort, out.innerPort);
  bd.connect(ten.out, loop.count!.outer!);
  bd.connect(out.outer!, array.terminal);
  bd.connect(numeric.terminal, increment.terminal('x'));
  bd.connect(increment.terminal('x+1'), input.outer!);
  bd.write();
  return vi;
}
