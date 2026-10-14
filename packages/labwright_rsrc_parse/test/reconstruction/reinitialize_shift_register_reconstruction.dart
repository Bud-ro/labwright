import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// NI's "Reinitializing a Shift Register Without Stopping the VI": a While loop whose shift
/// register a Case structure resets to zero when a button is pressed.
ViModel buildReinitializeShiftRegister() {
  final vi = ViModel.empty(name: 'Reinitialize Shift Register.vi');
  final bd = vi.blockDiagram;
  final zero = bd.diagram.add(BdConstant.create(bd, BdType.i32, 0));
  final loop = bd.diagram.add(BdLoop.create(bd, isFor: false));
  final register = loop.shiftRegister(BdType.i32);
  final reinitialize = bd.control(BdType.boolean, 'Reinitialize Register?', frame: loop.body);
  final stop = bd.control(BdType.boolean, 'stop', frame: loop.body);
  final reset = loop.body.add(BdCase.create(bd));
  final keep = reset.tunnel(BdType.i32, output: false);
  final next = reset.tunnel(BdType.i32, output: true);
  final cleared = reset.frames[1].add(BdConstant.create(bd, BdType.i32, 0));
  bd.connect(keep.inner(reset.frames[0]), next.inner(reset.frames[0]));
  bd.connect(cleared.out, next.inner(reset.frames[1]));
  bd.connect(reinitialize.terminal, reset.selector.outer!);
  bd.connect(stop.terminal, loop.conditional!.innerPort);
  bd.connect(next.outer!, register.right.innerPort);
  bd.connect(register.left.innerPort, keep.outer!);
  bd.connect(zero.out, register.left.outer!);
  bd.write();
  return vi;
}
