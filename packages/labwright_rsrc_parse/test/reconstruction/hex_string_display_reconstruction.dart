import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// NI's "Converting Hexadecimal String from Normal Display to Hex Display": the hex digits read
/// as a number and type cast to the string of its bytes.
ViModel buildHexStringDisplay() {
  final vi = ViModel.empty(name: 'Hex Display.vi');
  final bd = vi.blockDiagram;
  final digits = bd.control(BdType.string, 'Hexadecimal Number (Normal Display)');
  final asString = bd.diagram.add(BdConstant.create(bd, BdType.string, ''));
  final bytes = bd.indicator(BdType.string, 'Hexadecimal String (Hex Display)');
  final parse = bd.diagram.add(BdPrimitive.create(bd, PrimOp.hexadecimalStringToNumber));
  final cast = bd.diagram.add(BdPrimitive.create(bd, PrimOp.typeCast));
  bd.connect(digits.terminal, parse.terminal('string'));
  bd.connect(asString.out, cast.terminal('type'));
  bd.connect(parse.terminal('number'), cast.terminal('x'), type: BdType.u32);
  bd.connect(cast.terminal('*(type *) &x'), bytes.terminal, type: BdType.string);
  bd.write();
  return vi;
}
