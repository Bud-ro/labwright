import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// The LabVIEW wiki's "Loop-Invariant Code Motion", before: a For loop incrementing the same
/// number on every iteration.
ViModel buildLoopInvariantBefore() {
  final vi = ViModel.empty(name: 'Loop-Invariant Code Motion - Before.vi');
  final numeric = vi.control(BdType.i32, 'Numeric');
  final array = vi.indicator(BdType.i32.array, 'Array');

  final ten = vi.add(BdConstant.i32(10));
  final loop = vi.add(BdLoop.forLoop());
  final out = loop.tunnel(BdType.i32.array, direction: BdTunnelDirection.output, indexing: true);
  final increment = loop.add(BdPrimitive(PrimOp.increment));
  vi.connect([increment.terminal('x+1'), out]);
  vi.connect([numeric, increment.terminal('x')]);
  vi.connect([ten, loop.count]);
  vi.connect([out, array]);
  vi.write();
  return vi;
}

/// The LabVIEW wiki's "Loop-Invariant Code Motion", after: the increment moved out of the loop.
ViModel buildLoopInvariantAfter() {
  final vi = ViModel.empty(name: 'Loop-Invariant Code Motion - After.vi');
  final numeric = vi.control(BdType.i32, 'Numeric');
  final array = vi.indicator(BdType.i32.array, 'Array');

  final ten = vi.add(BdConstant.i32(10));
  final increment = vi.add(BdPrimitive(PrimOp.increment));
  final loop = vi.add(BdLoop.forLoop());
  final out = loop.tunnel(BdType.i32.array, direction: BdTunnelDirection.output, indexing: true);
  final input = loop.tunnel(BdType.i32, direction: BdTunnelDirection.input);
  vi.connect([input.innerPort, out.innerPort]);
  vi.connect([numeric, increment.terminal('x')]);
  vi.connect([ten, loop.count]);
  vi.connect([increment.terminal('x+1'), input]);
  vi.connect([out, array]);
  vi.write();
  return vi;
}
