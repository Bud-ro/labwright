import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// NI's "Execute VI Remotely by Using VI Server", second snippet: a loop that shows its
/// iteration and waits half a second until its stop button is pressed.
ViModel buildExecuteViRemotely() {
  final vi = ViModel.empty(name: 'Execute VI Remotely.vi');
  final loop = BdLoop.whileLoop();
  final stop = vi.control(BdType.boolean, 'Stop Button', frame: loop.body);
  final index = vi.indicator(BdType.i32, 'Index', frame: loop.body);

  vi.add(loop);
  final halfSecond = loop.add(BdConstant.u32(500, label: 'milliseconds to wait'));
  final wait = loop.add(BdPrimitive(PrimOp.waitMs));
  stop >> loop.conditional;
  halfSecond >> wait['milliseconds to wait'];
  loop.iteration >> index;
  vi.write();
  return vi;
}
