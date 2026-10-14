import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// Stack Overflow 32768403: a While loop that shows "on" or "off" for a toggle every tenth of
/// a second until stopped.
ViModel buildToggleText() {
  final vi = ViModel.empty(name: 'Toggle Text.vi');
  final bd = vi.blockDiagram;
  final loop = bd.diagram.add(BdLoop.create(bd, isFor: false));
  final body = loop.body;
  final stop = bd.control(BdType.boolean, 'Stop', frame: body);
  final text = bd.indicator(BdType.string, 'Text', frame: body);
  final period = body.add(BdConstant.create(bd, BdType.u32, 100, label: 'millisecond multiple'));
  final toggle = bd.control(BdType.boolean, 'Toggle', frame: body);
  final wait = body.add(BdPrimitive.create(bd, PrimOp.waitUntilNextMsMultiple));
  final choose = body.add(BdCase.create(bd));
  final shown = choose.tunnel(BdType.string, output: true);
  final off = choose.frames[0].add(BdConstant.create(bd, BdType.string, 'off'));
  final on = choose.frames[1].add(BdConstant.create(bd, BdType.string, 'on'));
  bd.connect(off.out, shown.inner(choose.frames[0]));
  bd.connect(on.out, shown.inner(choose.frames[1]));
  bd.connect(stop.terminal, loop.conditional!.innerPort);
  bd.connect(period.out, wait.terminal('millisecond multiple'));
  bd.connect(toggle.terminal, choose.selector.outer!);
  bd.connect(shown.outer!, text.terminal);
  bd.write();
  return vi;
}
