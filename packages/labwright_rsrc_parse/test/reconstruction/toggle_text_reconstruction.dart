import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// Stack Overflow 32768403: a While loop that shows "on" or "off" for a toggle every tenth of
/// a second until stopped.
ViModel buildToggleText() {
  final vi = ViModel.empty(name: 'Toggle Text.vi');
  final loop = BdLoop.whileLoop();
  final stop = vi.control(BdType.boolean, 'Stop', frame: loop.body);
  final text = vi.indicator(BdType.string, 'Text', frame: loop.body);
  final toggle = vi.control(BdType.boolean, 'Toggle', frame: loop.body);

  vi.add(loop);
  final period = loop.add(BdConstant.u32(100, label: 'millisecond multiple'));
  final wait = loop.add(BdPrimitive(PrimOp.waitUntilNextMsMultiple));
  final choose = loop.add(BdCase());
  final shown = choose.tunnel(BdType.string, direction: BdTunnelDirection.output);
  final off = choose.whenFalse.add(BdConstant.string('off'));
  final on = choose.whenTrue.add(BdConstant.string('on'));
  off >> shown.inner(choose.whenFalse);
  on >> shown.inner(choose.whenTrue);
  stop >> loop.conditional;
  period >> wait['millisecond multiple'];
  toggle >> choose.selector;
  shown >> text;
  vi.write();
  return vi;
}
