import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// NI's "Using Test Vector Indexes With the LabVIEW Unit Test Framework Toolkit": the VI under
/// test, Z as the sum of X and Y.
ViModel buildUnitTestAdd() {
  final vi = ViModel.empty(name: 'Add.vi');
  final bd = vi.blockDiagram;
  const nameAbove = HeapRect(top: -17, left: 0, bottom: 0, right: 10);
  final x = bd.control(BdType.dbl, 'X', at: (x: 0, y: 17), labelAt: nameAbove);
  final y = bd.control(BdType.dbl, 'Y', at: (x: 0, y: 65), labelAt: nameAbove);
  final z = bd.indicator(BdType.dbl, 'Z', at: (x: 73, y: 22), labelAt: nameAbove);
  final add = bd.diagram.add(
    BdPrimitive.create(bd, PrimOp.add, at: const HeapRect(top: 14, left: 36, bottom: 46, right: 68)),
  );
  bd.connect(x.terminal, add.terminal('x'));
  bd.connect(y.terminal, add.terminal('y'), bendX: 37);
  bd.connect(add.terminal('x+y'), z.terminal);
  bd.write();
  return vi;
}
