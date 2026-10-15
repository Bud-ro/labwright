import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// NI's "Converting Hexadecimal String from Normal Display to Hex Display": the hex digits read
/// as a number and type cast to the string of its bytes.
ViModel buildHexStringDisplay() {
  final vi = ViModel.empty(name: 'Hex Display.vi');
  final digits = vi.control(BdType.string, 'Hexadecimal Number (Normal Display)');
  final bytes = vi.indicator(BdType.string, 'Hexadecimal String (Hex Display)');

  final asString = vi.add(BdConstant.string(''));
  final parse = vi.add(BdPrimitive(PrimOp.hexadecimalStringToNumber));
  final cast = vi.add(BdPrimitive(PrimOp.typeCast));
  vi.connect(digits, parse.terminal('string'));
  vi.connect(asString, cast.terminal('type'));
  vi.connect(parse.terminal('number'), cast.terminal('x'), type: BdType.u32);
  vi.connect(cast.terminal('*(type *) &x'), bytes);
  vi.write();
  return vi;
}
