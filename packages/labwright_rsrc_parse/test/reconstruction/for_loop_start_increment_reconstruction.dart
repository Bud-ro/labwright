import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// NI's "Creating a For Loop with Alternative Starting Index and Increment Values": each
/// iteration's index times the increment, plus the start value.
ViModel buildForLoopStartIncrement() {
  final vi = ViModel.empty(name: 'For Loop with Start and Increment.vi');
  final increment = vi.control(BdType.i32, 'Increment');
  final start = vi.control(BdType.i32, 'Start Value');
  final output = vi.indicator(BdType.i32.array, 'Output');

  final iterations = vi.add(BdConstant.i32(10, label: 'Loop iterations', showLabel: true));
  final loop = vi.add(BdLoop.forLoop());
  final out = loop.tunnel(BdType.i32.array, direction: BdTunnelDirection.output, indexing: true);
  final add = loop.add(BdPrimitive(PrimOp.add));
  final multiply = loop.add(BdPrimitive(PrimOp.multiply));
  vi.connect(add.terminal('x+y'), out).label('B');
  vi.connect(increment, multiply.terminal('x'));
  vi.connect(start, add.terminal('x'));
  vi.connect(loop.iteration, multiply.terminal('y'));
  vi.connect(multiply.terminal('x*y'), add.terminal('y')).label('A');
  vi.connect(iterations, loop.count);
  vi.connect(out, output);
  vi.write();
  return vi;
}
