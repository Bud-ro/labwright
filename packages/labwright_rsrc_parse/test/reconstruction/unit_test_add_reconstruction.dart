import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// NI's "Using Test Vector Indexes With the LabVIEW Unit Test Framework Toolkit": the VI under
/// test, Z as the sum of X and Y.
ViModel buildUnitTestAdd() {
  final vi = ViModel.empty(name: 'Add.vi');
  final bd = vi.blockDiagram;
  final x = bd.control(BdType.dbl, 'X');
  final y = bd.control(BdType.dbl, 'Y');
  final z = bd.indicator(BdType.dbl, 'Z');
  final add = bd.diagram.add(BdPrimitive.create(bd, PrimOp.add));
  bd.connect(x.terminal, add.terminal('x'));
  bd.connect(y.terminal, add.terminal('y'));
  bd.connect(add.terminal('x+y'), z.terminal);
  bd.write();
  return vi;
}
