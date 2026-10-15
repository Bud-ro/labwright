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
  final reset = loop.add(BdCase());
  final keep = reset.tunnel(BdType.i32, direction: BdTunnelDirection.input);
  final next = reset.tunnel(BdType.i32, direction: BdTunnelDirection.output);
  final cleared = reset.whenTrue.add(BdConstant.i32(0));
  keep.inner(reset.whenFalse) >> next.inner(reset.whenFalse);
  cleared >> next.inner(reset.whenTrue);
  reinitialize >> reset.selector;
  stop >> loop.conditional;
  next >> register.right;
  register.left >> keep;
  zero >> register.left;
  vi.write();
  return vi;
}
