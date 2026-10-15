import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// NI's "LabVIEW While" snippet: a random number every 200 ms until Stop, the iteration count
/// tunnelled out.
ViModel buildWhileLoop() {
  final vi = ViModel.empty(name: 'While Loop.vi');
  final loop = BdLoop.whileLoop();
  final count = vi.indicator(BdType.i32, 'Iteration Count');
  final stop = vi.control(BdType.boolean, 'Stop', frame: loop.body);
  final random = vi.indicator(BdType.dbl, 'Random Number', frame: loop.body);

  vi.add(loop);
  final period = loop.add(BdConstant.u32(200, label: 'milliseconds to wait'));
  final wait = loop.add(BdPrimitive(PrimOp.waitMs));
  final number = loop.add(BdPrimitive(PrimOp.randomNumber));
  vi.connect(stop, loop.conditional);
  vi.connect(period, wait.terminal('milliseconds to wait'));
  vi.connect(number.terminal('number (0 to 1)'), random);
  vi.connect(loop.iteration, count);
  vi.write();
  return vi;
}
