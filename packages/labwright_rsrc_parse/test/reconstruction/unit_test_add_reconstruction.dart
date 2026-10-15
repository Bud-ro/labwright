import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// NI's "Using Test Vector Indexes With the LabVIEW Unit Test Framework Toolkit": the VI under
/// test, Z as the sum of X and Y.
ViModel buildUnitTestAdd() {
  final vi = ViModel.empty(name: 'Add.vi');
  final x = vi.control(BdType.dbl, 'X');
  final y = vi.control(BdType.dbl, 'Y');
  final z = vi.indicator(BdType.dbl, 'Z');

  final add = vi.add(BdPrimitive(PrimOp.add));
  vi.connect([x, add.terminal('x')]);
  vi.connect([y, add.terminal('y')]);
  vi.connect([add.terminal('x+y'), z]);
  vi.write();
  return vi;
}
