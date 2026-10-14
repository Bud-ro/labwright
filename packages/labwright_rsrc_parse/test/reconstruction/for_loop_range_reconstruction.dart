import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// Stack Overflow 30934016: the integers below N, as a For loop indexing its iteration count out.
ViModel buildForLoopRange() {
  final vi = ViModel.empty(name: 'Range.vi');
  final bd = vi.blockDiagram;
  final range = bd.indicator(const BdType.array(ViDataType.i32), 'Range');
  final n = bd.control(BdType.i32, 'N');
  final loop = bd.diagram.add(BdLoop.create(bd));
  final out = loop.tunnel(const BdType.array(ViDataType.i32), output: true, indexing: true);
  bd.connect(loop.iteration.innerPort, out.innerPort);
  bd.connect(n.terminal, loop.count!.outer!);
  bd.connect(out.outer!, range.terminal);
  bd.write();
  return vi;
}
