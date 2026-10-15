import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// NI's "Modifying LabVIEW Boolean Control Output Values": a button selecting between two
/// numbers.
ViModel buildBooleanOutputValues() {
  final vi = ViModel.empty(name: 'Boolean Output Values.vi');
  final button = vi.control(BdType.boolean, 'Button');
  final value = vi.indicator(BdType.dbl, 'Output Value');

  final whenTrue = vi.add(BdConstant.dbl(3, label: 't'));
  final whenFalse = vi.add(BdConstant.dbl(0, label: 'f'));
  final select = vi.add(BdPrimitive(PrimOp.select));
  vi.connect([button, select.terminal('s')]);
  vi.connect([whenTrue, select.terminal('t')]);
  vi.connect([whenFalse, select.terminal('f')]);
  vi.connect([select.terminal('s? t:f'), value]);
  vi.write();
  return vi;
}
