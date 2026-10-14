import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// NI's "Convert from a String to a Numeric Data Type in LabVIEW": a string with a decimal
/// comma read as a number, with the system decimal point.
ViModel buildStringToNumber() {
  final vi = ViModel.empty(name: 'String To Number.vi');
  final bd = vi.blockDiagram;
  final text = bd.control(BdType.string, 'String With Comma');
  final number = bd.indicator(BdType.dbl, 'number');
  final systemPoint = bd.diagram.add(
    BdConstant.create(bd, BdType.boolean, true, label: 'use system decimal point (T)'),
  );
  final parse = bd.diagram.add(BdPrimitive.create(bd, PrimOp.fractExpStringToNumber));
  bd.connect(text.terminal, parse.terminal('string'));
  bd.connect(systemPoint.out, parse.terminal('use system decimal point'));
  bd.connect(parse.terminal('number'), number.terminal, type: BdType.dbl);
  bd.write();
  return vi;
}
