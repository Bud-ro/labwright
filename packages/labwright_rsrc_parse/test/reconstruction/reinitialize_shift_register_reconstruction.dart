import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// NI's "Reinitializing a Shift Register Without Stopping the VI": a While loop whose shift
/// register a Case structure resets to zero when a button is pressed.
ViModel buildReinitializeShiftRegister() {
  final vi = ViModel.empty(name: 'Reinitialize Shift Register.vi');
  final loop = BdLoop.whileLoop();
  final reinitialize = vi.control(BdType.boolean, 'Reinitialize Register?', frame: loop.body);
  final stop = vi.control(BdType.boolean, 'stop', frame: loop.body);

  final zero = vi.add(BdConstant.i32(0));
  vi.add(loop);
  final register = loop.shiftRegister(BdType.i32);
  loop.body.comment('Other Data Manipulation in the While Loop Goes Here');
  final reset = loop.add(BdCase());
  final keep = reset.tunnel(BdType.i32, direction: BdTunnelDirection.input);
  final next = reset.tunnel(BdType.i32, direction: BdTunnelDirection.output);
  final cleared = reset.whenTrue.add(BdConstant.i32(0));
  vi.connect(keep.inner(reset.whenFalse), next.inner(reset.whenFalse));
  vi.connect(cleared, next.inner(reset.whenTrue));
  vi.connect(reinitialize, reset.selector);
  vi.connect(stop, loop.conditional);
  vi.connect(next, register.right);
  vi.connect(register.left, keep);
  vi.connect(zero, register.left);
  vi.write();
  return vi;
}
