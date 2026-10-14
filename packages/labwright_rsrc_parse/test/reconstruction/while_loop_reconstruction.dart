import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// NI's "LabVIEW While" snippet: a random number every 200 ms until Stop, the iteration count
/// tunnelled out.
ViModel buildWhileLoop() {
  final vi = ViModel.empty(name: 'While Loop.vi');
  final bd = vi.blockDiagram;
  final count = bd.indicator(BdType.i32, 'Iteration Count');
  final loop = bd.diagram.add(BdLoop.create(bd, isFor: false));
  final out = loop.tunnel(BdType.i32, output: true);
  final stop = bd.control(BdType.boolean, 'Stop', frame: loop.body);
  final random = bd.indicator(BdType.dbl, 'Random Number', frame: loop.body);
  final period = loop.body.add(BdConstant.create(bd, BdType.u32, 200, label: 'milliseconds to wait'));
  final wait = loop.body.add(BdPrimitive.create(bd, PrimOp.waitMs));
  final number = loop.body.add(BdPrimitive.create(bd, PrimOp.randomNumber));
  bd.connect(stop.terminal, loop.conditional!.innerPort);
  bd.connect(period.out, wait.terminal('milliseconds to wait'));
  bd.connect(number.terminal('number (0 to 1)'), random.terminal);
  bd.connect(loop.iteration.innerPort, out.innerPort);
  bd.connect(out.outer!, count.terminal);
  bd.write();
  return vi;
}
