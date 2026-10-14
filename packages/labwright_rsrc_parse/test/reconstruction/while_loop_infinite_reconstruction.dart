import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// The LabVIEW wiki's "While Loop - Infinite Loop": a loop whose stop terminal is wired false.
ViModel buildWhileLoopInfinite() {
  final vi = ViModel.empty(name: 'While Loop - Infinite Loop.vi');
  final bd = vi.blockDiagram;
  final loop = bd.diagram.add(
    BdLoop.create(bd, isFor: false, at: const HeapRect(top: 0, left: 0, bottom: 130, right: 165)),
  );
  final never = loop.body.add(
    BdConstant.create(bd, BdType.boolean, false, at: const HeapRect(top: 105, left: 107, bottom: 119, right: 123)),
  );
  bd.connect(never.out, loop.conditional!.innerPort);
  bd.write();
  return vi;
}
