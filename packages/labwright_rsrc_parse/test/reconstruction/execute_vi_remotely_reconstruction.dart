import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// NI's "Execute VI Remotely by Using VI Server", second snippet: a loop that shows its
/// iteration and waits half a second until its stop button is pressed.
ViModel buildExecuteViRemotely() {
  final vi = ViModel.empty(name: 'Execute VI Remotely.vi');
  final bd = vi.blockDiagram;
  final loop = bd.diagram.add(BdLoop.create(bd, isFor: false));
  final stop = bd.control(BdType.boolean, 'Stop Button', frame: loop.body);
  final index = bd.indicator(BdType.i32, 'Index', frame: loop.body);
  final halfSecond = loop.body.add(BdConstant.create(bd, BdType.u32, 500, label: 'milliseconds to wait'));
  final wait = loop.body.add(BdPrimitive.create(bd, PrimOp.waitMs));
  bd.connect(stop.terminal, loop.conditional!.innerPort);
  bd.connect(halfSecond.out, wait.terminal('milliseconds to wait'));
  bd.connect(loop.iteration.innerPort, index.terminal);
  bd.write();
  return vi;
}
