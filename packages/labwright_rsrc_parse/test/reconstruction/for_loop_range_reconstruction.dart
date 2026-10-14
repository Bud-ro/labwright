import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// Stack Overflow 30934016: the integers below N, as a For loop indexing its iteration count out.
ViModel buildForLoopRange() {
  final vi = ViModel.empty(name: 'Range.vi');
  final bd = vi.blockDiagram;
  final range = bd.indicator(
    const BdType.array(ViDataType.i32),
    'Range',
    at: (x: 140, y: 15),
    labelAt: const HeapRect(top: 0, left: 32, bottom: 17, right: 68),
  );
  final n = bd.control(
    BdType.i32,
    'N',
    at: (x: 12, y: 0),
    labelAt: const HeapRect(top: 0, left: -12, bottom: 17, right: 0),
  );
  final loop = bd.diagram.add(BdLoop.create(bd, at: const HeapRect(top: 0, left: 53, bottom: 52, right: 132)));
  loop.iteration.termBounds = const HeapRect(top: 15, left: 31, bottom: 31, right: 47);
  final out = loop.tunnel(const BdType.array(ViDataType.i32), output: true, indexing: true, top: 19);
  bd.connect(loop.iteration.innerPort, out.innerPort);
  bd.connect(n.terminal, loop.count!.outer!);
  bd.connect(out.outer!, range.terminal);
  bd.write();
  return vi;
}
