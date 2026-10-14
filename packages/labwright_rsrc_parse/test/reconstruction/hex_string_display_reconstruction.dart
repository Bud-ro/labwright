import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// NI's "Converting Hexadecimal String from Normal Display to Hex Display": the hex digits read
/// as a number and type cast to the string of its bytes.
ViModel buildHexStringDisplay() {
  final vi = ViModel.empty(name: 'Hex Display.vi');
  final bd = vi.blockDiagram;
  final digits = bd.control(
    BdType.string,
    'Hexadecimal Number (Normal Display)',
    at: (x: 176, y: 28),
    labelAt: const HeapRect(top: -17, left: -176, bottom: 0, right: 32),
  );
  final asString = bd.diagram.add(BdConstant.emptyString(bd, at: (x: 340, y: 0)));
  final bytes = bd.indicator(
    BdType.string,
    'Hexadecimal String (Hex Display)',
    at: (x: 460, y: 47),
    labelAt: const HeapRect(top: -17, left: 0, bottom: 0, right: 178),
  );
  final parse = bd.diagram.add(
    BdPrimitive.create(
      bd,
      PrimOp.hexadecimalStringToNumber,
      at: const HeapRect(top: 31, left: 271, bottom: 63, right: 303),
    ),
  );
  final cast = bd.diagram.add(
    BdPrimitive.create(bd, PrimOp.typeCast, at: const HeapRect(top: 39, left: 363, bottom: 71, right: 395)),
  );
  bd.connect(digits.terminal, parse.terminal('string'));
  bd.connect(asString.out, cast.terminal('type'));
  bd.connect(cast.terminal('*(type *) &x'), bytes.terminal, type: BdType.string);
  bd.connect(parse.terminal('number'), cast.terminal('x'), type: BdType.u32);
  bd.write();
  return vi;
}
