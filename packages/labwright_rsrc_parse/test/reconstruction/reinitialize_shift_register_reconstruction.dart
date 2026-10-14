import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// NI's "Reinitializing a Shift Register Without Stopping the VI": a While loop whose shift
/// register a Case structure resets to zero when a button is pressed.
ViModel buildReinitializeShiftRegister() {
  final vi = ViModel.empty(name: 'Reinitialize Shift Register.vi');
  final bd = vi.blockDiagram;
  final zero = bd.diagram.add(
    BdConstant.create(bd, BdType.i32, 0, at: const HeapRect(top: 88, left: 0, bottom: 107, right: 13)),
  );
  final loop = bd.diagram.add(
    BdLoop.create(bd, isFor: false, at: const HeapRect(top: 0, left: 23, bottom: 211, right: 372)),
  );
  loop.iteration.termBounds = const HeapRect(top: 187, left: 8, bottom: 203, right: 24);
  loop.conditional!.termBounds = const HeapRect(top: 173, left: 318, bottom: 189, right: 334);
  final register = loop.shiftRegister(BdType.i32, top: 91);
  final reinitialize = bd.control(
    BdType.boolean,
    'Reinitialize Register?',
    frame: loop.body,
    at: (x: 32, y: 70),
    labelAt: const HeapRect(top: -17, left: 0, bottom: 0, right: 109),
  );
  final stop = bd.control(
    BdType.boolean,
    'stop',
    frame: loop.body,
    at: (x: 267, y: 170),
    labelAt: const HeapRect(top: -17, left: 0, bottom: 0, right: 26),
  );
  loop.body.comment(
    'Other Data Manipulation in the While Loop Goes Here',
    at: const HeapRect(top: 31, left: 47, bottom: 48, right: 336),
    anchorAt: const HeapRect(top: 8, left: 290, bottom: 20, right: 302),
  );
  final reset = loop.body.add(
    BdCase.create(
      bd,
      displayed: 1,
      at: const HeapRect(top: 52, left: 151, bottom: 127, right: 263),
      selectorLabelAt: const HeapRect(top: 0, left: 32, bottom: 17, right: 68),
    ),
  );
  reset.selector.termBounds = const HeapRect(top: 20, left: 0, bottom: 32, right: 8);
  final keep = reset.tunnel(BdType.i32, output: false, top: 41);
  final next = reset.tunnel(BdType.i32, output: true, top: 41);
  final cleared = reset.frames[1].add(
    BdConstant.create(bd, BdType.i32, 0, at: const HeapRect(top: 36, left: 35, bottom: 55, right: 48)),
  );
  bd.connect(keep.inner(reset.frames[0]), next.inner(reset.frames[0]));
  bd.connect(cleared.out, next.inner(reset.frames[1]));
  bd.connect(stop.terminal, loop.conditional!.innerPort);
  bd.connect(next.outer!, register.right.innerPort);
  bd.connect(register.left.innerPort, keep.outer!);
  bd.connect(reinitialize.terminal, reset.selector.outer!);
  bd.connect(zero.out, register.left.outer!);
  bd.write();
  return vi;
}
