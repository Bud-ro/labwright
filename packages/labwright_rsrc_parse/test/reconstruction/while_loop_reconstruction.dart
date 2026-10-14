import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// NI's "LabVIEW While" snippet: a random number every 200 ms until Stop, the iteration count
/// tunnelled out.
ViModel buildWhileLoop() {
  final vi = ViModel.empty(name: 'While Loop.vi');
  final bd = vi.blockDiagram;
  final count = bd.indicator(
    BdType.i32,
    'Iteration Count',
    at: (x: 373, y: 546),
    labelAt: const HeapRect(top: -17, left: 0, bottom: 0, right: 83),
  );
  final loop = bd.diagram.add(
    BdLoop.create(bd, isFor: false, at: const HeapRect(top: 427, left: 289, bottom: 528, right: 599)),
  );
  loop.iteration.termBounds = const HeapRect(top: 77, left: 13, bottom: 93, right: 29);
  loop.conditional!.termBounds = const HeapRect(top: 74, left: 264, bottom: 90, right: 280);
  final out = loop.tunnel(BdType.i32, output: true)
    ..termBounds = const HeapRect(top: 92, left: 59, bottom: 101, right: 68);
  final stop = bd.control(
    BdType.boolean,
    'Stop',
    frame: loop.body,
    at: (x: 216, y: 74),
    labelAt: const HeapRect(top: -17, left: 0, bottom: 0, right: 27),
  );
  final random = bd.indicator(
    BdType.dbl,
    'Random Number',
    frame: loop.body,
    at: (x: 86, y: 36),
    labelAt: const HeapRect(top: -17, left: 0, bottom: 0, right: 98),
  );
  final period = loop.body.add(
    BdConstant.create(
      bd,
      BdType.u32,
      200,
      label: 'milliseconds to wait',
      at: const HeapRect(top: 33, left: 217, bottom: 52, right: 242),
      labelAt: const HeapRect(top: -17, left: -83, bottom: 0, right: 25),
    ),
  );
  final wait = loop.body.add(
    BdPrimitive.create(
      bd,
      PrimOp.waitMs,
      at: const HeapRect(top: 26, left: 250, bottom: 58, right: 282),
      label: 'Wait (ms)',
      labelAt: const HeapRect(top: -17, left: 0, bottom: 0, right: 54),
    ),
  );
  final number = loop.body.add(
    BdPrimitive.create(bd, PrimOp.randomNumber, at: const HeapRect(top: 29, left: 39, bottom: 61, right: 71)),
  );
  bd.connect(period.out, wait.terminal('milliseconds to wait'));
  bd.connect(number.terminal('number (0 to 1)'), random.terminal);
  bd.connect(stop.terminal, loop.conditional!.innerPort);
  bd.connect(loop.iteration.innerPort, out.innerPort);
  bd.connect(out.outer!, count.terminal, bendX: 352);
  bd.write();
  return vi;
}
