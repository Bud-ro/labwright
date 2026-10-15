import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// The LabVIEW wiki's "While Loop - Infinite Loop": a loop whose stop terminal is wired false.
ViModel buildWhileLoopInfinite() {
  final vi = ViModel.empty(name: 'While Loop - Infinite Loop.vi');
  final loop = vi.add(BdLoop.whileLoop());
  final never = loop.add(BdConstant.boolean(false));
  vi.connect([never, loop.conditional]);
  vi.write();
  return vi;
}
