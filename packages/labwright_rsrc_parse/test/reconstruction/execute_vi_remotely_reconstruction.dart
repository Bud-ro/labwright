import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// NI's "Execute VI Remotely by Using VI Server", second snippet: a loop that shows its
/// iteration and waits half a second until its stop button is pressed.
ViModel buildExecuteViRemotely() {
  final vi = ViModel.empty(name: 'Execute VI Remotely.vi');
  final bd = vi.blockDiagram;
  final loop = bd.diagram.add(
    BdLoop.create(bd, isFor: false, at: const HeapRect(top: 0, left: 0, bottom: 245, right: 418)),
  );
  final stop = bd.control(
    BdType.boolean,
    'Stop Button',
    frame: loop.body,
    at: (x: 338, y: 219),
    labelAt: const HeapRect(top: -17, left: 0, bottom: 0, right: 66),
  );
  final index = bd.indicator(
    BdType.i32,
    'Index',
    frame: loop.body,
    at: (x: 42, y: 219),
    labelAt: const HeapRect(top: -17, left: 0, bottom: 0, right: 32),
  );
  final halfSecond = loop.body.add(
    BdConstant.create(
      bd,
      BdType.u32,
      500,
      label: 'milliseconds to wait',
      at: const HeapRect(top: 196, left: 179, bottom: 215, right: 204),
      labelAt: const HeapRect(top: -17, left: -83, bottom: 0, right: 25),
    ),
  );
  final wait = loop.body.add(
    BdPrimitive.create(bd, PrimOp.waitMs, at: const HeapRect(top: 189, left: 212, bottom: 221, right: 244)),
  );
  bd.connect(stop.terminal, loop.conditional!.innerPort);
  bd.connect(halfSecond.out, wait.terminal('milliseconds to wait'));
  bd.connect(loop.iteration.innerPort, index.terminal);
  bd.write();
  return vi;
}
