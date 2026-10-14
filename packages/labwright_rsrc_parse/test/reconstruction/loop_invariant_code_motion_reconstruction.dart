import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// The LabVIEW wiki's "Loop-Invariant Code Motion", before: a For loop incrementing the same
/// number on every iteration.
ViModel buildLoopInvariantBefore() {
  final vi = ViModel.empty(name: 'Loop-Invariant Code Motion - Before.vi');
  final bd = vi.blockDiagram;
  final numeric = bd.control(BdType.i32, 'Numeric');
  final array = bd.indicator(const BdType.array(ViDataType.i32), 'Array');
  final ten = bd.diagram.add(BdConstant.create(bd, BdType.i32, 10));
  final loop = bd.diagram.add(BdLoop.create(bd));
  final input = loop.tunnel(BdType.i32, output: false);
  final out = loop.tunnel(const BdType.array(ViDataType.i32), output: true, indexing: true);
  final increment = loop.body.add(BdPrimitive.create(bd, PrimOp.increment));
  bd.connect(increment.terminal('x+1'), out.innerPort);
  bd.connect(input.innerPort, increment.terminal('x'));
  bd.connect(numeric.terminal, input.outer!);
  bd.connect(ten.out, loop.count!.outer!);
  bd.connect(out.outer!, array.terminal);
  bd.write();
  return vi;
}

/// The LabVIEW wiki's "Loop-Invariant Code Motion", after: the increment moved out of the loop.
ViModel buildLoopInvariantAfter() {
  final vi = ViModel.empty(name: 'Loop-Invariant Code Motion - After.vi');
  final bd = vi.blockDiagram;
  final numeric = bd.control(BdType.i32, 'Numeric');
  final array = bd.indicator(const BdType.array(ViDataType.i32), 'Array');
  final ten = bd.diagram.add(BdConstant.create(bd, BdType.i32, 10));
  final increment = bd.diagram.add(BdPrimitive.create(bd, PrimOp.increment));
  final loop = bd.diagram.add(BdLoop.create(bd));
  final out = loop.tunnel(const BdType.array(ViDataType.i32), output: true, indexing: true);
  final input = loop.tunnel(BdType.i32, output: false);
  bd.connect(input.innerPort, out.innerPort);
  bd.connect(numeric.terminal, increment.terminal('x'));
  bd.connect(ten.out, loop.count!.outer!);
  bd.connect(increment.terminal('x+1'), input.outer!);
  bd.connect(out.outer!, array.terminal);
  bd.write();
  return vi;
}
