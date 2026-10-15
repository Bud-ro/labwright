import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// Stack Overflow 30934016: the integers below N, as a For loop indexing its iteration count out.
ViModel buildForLoopRange() {
  final vi = ViModel.empty(name: 'Range.vi');
  final range = vi.indicator(BdType.i32.array, 'Range');
  final n = vi.control(BdType.i32, 'N');

  final loop = vi.add(BdLoop.forLoop());
  final out = loop.tunnel(BdType.i32.array, direction: BdTunnelDirection.output, indexing: true);
  loop.iteration >> out;
  n >> loop.count;
  out >> range;
  vi.write();
  return vi;
}
