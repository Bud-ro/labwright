import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// NI's "Convert from a String to a Numeric Data Type in LabVIEW": a string with a decimal
/// comma read as a number, with the system decimal point.
ViModel buildStringToNumber() {
  final vi = ViModel.empty(name: 'String To Number.vi');
  final bd = vi.blockDiagram;
  final text = bd.control(
    BdType.string,
    'String With Comma',
    at: (x: 38, y: 31),
    labelAt: const HeapRect(top: -17, left: -38, bottom: 0, right: 70),
  );
  final number = bd.indicator(
    BdType.dbl,
    'number',
    at: (x: 180, y: 50),
    labelAt: const HeapRect(top: -17, left: 0, bottom: 0, right: 45),
  );
  final systemPoint = bd.diagram.add(
    BdConstant.create(
      bd,
      BdType.boolean,
      true,
      label: 'use system decimal point (T)',
      at: const HeapRect(top: 0, left: 147, bottom: 14, right: 163),
      labelAt: const HeapRect(top: -17, left: -139, bottom: 0, right: 16),
    ),
  );
  final parse = bd.diagram.add(
    BdPrimitive.create(
      bd,
      PrimOp.fractExpStringToNumber,
      at: const HeapRect(top: 34, left: 137, bottom: 66, right: 169),
    ),
  );
  bd.connect(text.terminal, parse.terminal('string'));
  bd.connect(parse.terminal('number'), number.terminal, type: BdType.dbl);
  bd.connect(systemPoint.out, parse.terminal('use system decimal point'), bendX: 153);
  bd.write();
  return vi;
}
