import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// NI's "Creating a For Loop with Alternative Starting Index and Increment Values": each
/// iteration's index times the increment, plus the start value.
ViModel buildForLoopStartIncrement() {
  final vi = ViModel.empty(name: 'For Loop with Start and Increment.vi');
  final bd = vi.blockDiagram;
  final iterations = bd.diagram.add(BdConstant.create(bd, BdType.i32, 10, label: 'Loop iterations'));
  final increment = bd.control(BdType.i32, 'Increment');
  final start = bd.control(BdType.i32, 'Start Value');
  final output = bd.indicator(const BdType.array(ViDataType.i32), 'Output');
  final loop = bd.diagram.add(BdLoop.create(bd));
  final step = loop.tunnel(BdType.i32, output: false);
  final first = loop.tunnel(BdType.i32, output: false);
  final out = loop.tunnel(const BdType.array(ViDataType.i32), output: true, indexing: true);
  final add = loop.body.add(BdPrimitive.create(bd, PrimOp.add));
  final multiply = loop.body.add(BdPrimitive.create(bd, PrimOp.multiply));
  bd.connect(add.terminal('x+y'), out.innerPort, type: BdType.i32);
  bd.connect(multiply.terminal('x*y'), add.terminal('y'), type: BdType.i32);
  bd.connect(step.innerPort, multiply.terminal('x'));
  bd.connect(first.innerPort, add.terminal('x'));
  bd.connect(loop.iteration.innerPort, multiply.terminal('y'));
  bd.connect(iterations.out, loop.count!.outer!);
  bd.connect(increment.terminal, step.outer!);
  bd.connect(start.terminal, first.outer!);
  bd.connect(out.outer!, output.terminal);
  bd.write();
  return vi;
}
