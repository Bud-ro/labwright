import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// NI's "Modifying LabVIEW Boolean Control Output Values": a button selecting between two
/// numbers.
ViModel buildBooleanOutputValues() {
  final vi = ViModel.empty(name: 'Boolean Output Values.vi');
  final bd = vi.blockDiagram;
  final button = bd.control(BdType.boolean, 'Button');
  final value = bd.indicator(BdType.dbl, 'Output Value');
  final whenTrue = bd.diagram.add(BdConstant.create(bd, BdType.dbl, 3.0, label: 't'));
  final whenFalse = bd.diagram.add(BdConstant.create(bd, BdType.dbl, 0, label: 'f'));
  final select = bd.diagram.add(BdPrimitive.create(bd, PrimOp.select));
  bd.connect(button.terminal, select.terminal('s'));
  bd.connect(whenTrue.out, select.terminal('t'));
  bd.connect(whenFalse.out, select.terminal('f'));
  bd.connect(select.terminal('s? t:f'), value.terminal, type: BdType.dbl);
  bd.write();
  return vi;
}
