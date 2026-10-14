import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// The LabVIEW wiki's "While Loop - Infinite Loop": a loop whose stop terminal is wired false.
ViModel buildWhileLoopInfinite() {
  final vi = ViModel.empty(name: 'While Loop - Infinite Loop.vi');
  final bd = vi.blockDiagram;
  final loop = bd.diagram.add(BdLoop.create(bd, isFor: false));
  final never = loop.body.add(BdConstant.create(bd, BdType.boolean, false));
  bd.connect(never.out, loop.conditional!.innerPort);
  bd.write();
  return vi;
}
