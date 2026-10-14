import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// NI's "Creating a For Loop with Alternative Starting Index and Increment Values": each
/// iteration's index times the increment, plus the start value.
ViModel buildForLoopStartIncrement() {
  final vi = ViModel.empty(name: 'For Loop with Start and Increment.vi');
  final bd = vi.blockDiagram;
  final iterations = bd.diagram.add(
    BdConstant.create(
      bd,
      BdType.i32,
      10,
      label: 'Loop iterations',
      at: const HeapRect(top: 0, left: 51, bottom: 36, right: 133),
      labelAt: const HeapRect(top: 0, left: 0, bottom: 17, right: 82),
      showLabel: true,
      boxAt: const HeapRect(top: 17, left: 0, bottom: 36, right: 19),
    ),
  );
  final increment = bd.control(
    BdType.i32,
    'Increment',
    at: (x: 58, y: 100),
    labelAt: const HeapRect(top: -1, left: -57, bottom: 16, right: 0),
  );
  final start = bd.control(
    BdType.i32,
    'Start Value',
    at: (x: 59, y: 56),
    labelAt: const HeapRect(top: -1, left: -59, bottom: 16, right: 0),
  );
  final output = bd.indicator(
    const BdType.array(ViDataType.i32),
    'Output',
    at: (x: 297, y: 118),
    labelAt: const HeapRect(top: -17, left: 0, bottom: 0, right: 41),
  );
  final loop = bd.diagram.add(BdLoop.create(bd, at: const HeapRect(top: 19, left: 108, bottom: 173, right: 289)));
  loop.iteration.termBounds = const HeapRect(top: 110, left: 34, bottom: 126, right: 50);
  final step = loop.tunnel(BdType.i32, output: false, top: 85);
  final first = loop.tunnel(BdType.i32, output: false, top: 41);
  final out = loop.tunnel(const BdType.array(ViDataType.i32), output: true, indexing: true, top: 103);
  final add = loop.body.add(
    BdPrimitive.create(bd, PrimOp.add, at: const HeapRect(top: 91, left: 119, bottom: 123, right: 151)),
  );
  final multiply = loop.body.add(
    BdPrimitive.create(bd, PrimOp.multiply, at: const HeapRect(top: 97, left: 61, bottom: 129, right: 93)),
  );
  bd
      .connect(add.terminal('x+y'), out.innerPort, type: BdType.i32)
      .label('B', at: const HeapRect(top: 100, left: 152, bottom: 117, right: 166));
  bd.connect(first.innerPort, add.terminal('x'), bendX: 119);
  bd
      .connect(multiply.terminal('x*y'), add.terminal('y'), type: BdType.i32)
      .label('A', at: const HeapRect(top: 106, left: 98, bottom: 123, right: 113));
  bd.connect(step.innerPort, multiply.terminal('x'), bendX: 61);
  bd.connect(loop.iteration.innerPort, multiply.terminal('y'));
  bd.connect(iterations.out, loop.count!.outer!, bendX: 107);
  bd.connect(increment.terminal, step.outer!);
  bd.connect(start.terminal, first.outer!);
  bd.connect(out.outer!, output.terminal);
  bd.write();
  return vi;
}
