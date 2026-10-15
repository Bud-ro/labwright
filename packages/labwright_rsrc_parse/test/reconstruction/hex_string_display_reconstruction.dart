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
  digits >> parse['string'];
  asString >> cast['type'];
  vi.connect(parse['number'], cast['x'], type: BdType.u32);
  cast['*(type *) &x'] >> bytes;
  vi.write();
  return vi;
}
