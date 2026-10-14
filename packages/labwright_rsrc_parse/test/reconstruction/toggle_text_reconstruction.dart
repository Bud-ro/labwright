import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// Stack Overflow 32768403: a While loop that shows "on" or "off" for a toggle every tenth of
/// a second until stopped.
ViModel buildToggleText() {
  final vi = ViModel.empty(name: 'Toggle Text.vi');
  final bd = vi.blockDiagram;
  final loop = bd.diagram.add(
    BdLoop.create(bd, isFor: false, at: const HeapRect(top: 0, left: 0, bottom: 159, right: 303)),
  );
  loop.iteration.termBounds = const HeapRect(top: 133, left: 10, bottom: 149, right: 26);
  loop.conditional!.termBounds = const HeapRect(top: 133, left: 271, bottom: 149, right: 287);
  final body = loop.body;
  final stop = bd.control(
    BdType.boolean,
    'Stop',
    frame: body,
    at: (x: 227, y: 133),
    labelAt: const HeapRect(top: 0, left: -27, bottom: 17, right: 0),
  );
  final text = bd.indicator(
    BdType.string,
    'Text',
    frame: body,
    at: (x: 219, y: 57),
    labelAt: const HeapRect(top: 0, left: 32, bottom: 17, right: 57),
  );
  final period = body.add(
    BdConstant.create(
      bd,
      BdType.u32,
      100,
      label: 'millisecond multiple',
      at: const HeapRect(top: 119, left: 125, bottom: 138, right: 150),
      labelAt: const HeapRect(top: 1, left: -112, bottom: 18, right: -1),
    ),
  );
  final toggle = bd.control(
    BdType.boolean,
    'Toggle',
    frame: body,
    at: (x: 54, y: 77),
    labelAt: const HeapRect(top: 0, left: -40, bottom: 17, right: 0),
  );
  final wait = body.add(
    BdPrimitive.create(
      bd,
      PrimOp.waitUntilNextMsMultiple,
      at: const HeapRect(top: 112, left: 158, bottom: 144, right: 190),
    ),
  );
  final choose = body.add(
    BdCase.create(
      bd,
      at: const HeapRect(top: 14, left: 103, bottom: 101, right: 198),
      selectorLabelAt: const HeapRect(top: 0, left: 24, bottom: 17, right: 60),
    ),
  );
  choose.selector.termBounds = const HeapRect(top: 65, left: 0, bottom: 77, right: 8);
  final shown = choose.tunnel(BdType.string, output: true, top: 49);
  final off = choose.frames[0].add(
    BdConstant.create(bd, BdType.string, 'off', at: const HeapRect(top: 44, left: 26, bottom: 63, right: 50)),
  );
  final on = choose.frames[1].add(
    BdConstant.create(bd, BdType.string, 'on', at: const HeapRect(top: 44, left: 26, bottom: 63, right: 49)),
  );
  bd.connect(off.out, shown.inner(choose.frames[0]));
  bd.connect(on.out, shown.inner(choose.frames[1]));
  bd.connect(toggle.terminal, choose.selector.outer!);
  bd.connect(shown.outer!, text.terminal);
  bd.connect(period.out, wait.terminal('millisecond multiple'));
  bd.connect(stop.terminal, loop.conditional!.innerPort);
  bd.write();
  return vi;
}
