import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// NI's "Convert from a String to a Numeric Data Type in LabVIEW": a string with a decimal
/// comma read as a number, with the system decimal point.
ViModel buildStringToNumber() {
  final vi = ViModel.empty(name: 'String To Number.vi');
  final text = vi.control(BdType.string, 'String With Comma');
  final number = vi.indicator(BdType.dbl, 'number');

  final systemPoint = vi.add(BdConstant.boolean(true, label: 'use system decimal point (T)'));
  final parse = vi.add(BdPrimitive(PrimOp.fractExpStringToNumber));
  text >> parse['string'];
  systemPoint >> parse['use system decimal point'];
  parse['number'] >> number;
  vi.write();
  return vi;
}
