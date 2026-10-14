import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// NI's "Modifying LabVIEW Boolean Control Output Values": a button selecting between two
/// numbers.
ViModel buildBooleanOutputValues() {
  final vi = ViModel.empty(name: 'Boolean Output Values.vi');
  final bd = vi.blockDiagram;
  final button = bd.control(
    BdType.boolean,
    'Button',
    at: (x: 0, y: 19),
    labelAt: const HeapRect(top: -17, left: 0, bottom: 0, right: 39),
    icon: true,
  );
  final value = bd.indicator(
    BdType.dbl,
    'Output Value',
    at: (x: 132, y: 17),
    labelAt: const HeapRect(top: -17, left: 0, bottom: 0, right: 75),
    icon: true,
  );
  final whenTrue = bd.diagram.add(
    BdConstant.create(
      bd,
      BdType.dbl,
      3.0,
      label: 't',
      at: const HeapRect(top: 15, left: 55, bottom: 34, right: 69),
      labelAt: const HeapRect(top: -17, left: 7, bottom: 0, right: 14),
    ),
  );
  final whenFalse = bd.diagram.add(
    BdConstant.create(
      bd,
      BdType.dbl,
      0,
      label: 'f',
      at: const HeapRect(top: 43, left: 56, bottom: 62, right: 70),
      labelAt: const HeapRect(top: -17, left: 7, bottom: 0, right: 14),
    ),
  );
  final select = bd.diagram.add(
    BdPrimitive.create(bd, PrimOp.select, at: const HeapRect(top: 22, left: 82, bottom: 54, right: 114)),
  );
  bd.connect(whenTrue.out, select.terminal('t'), bendX: 78);
  bd.connect(button.terminal, select.terminal('s'));
  bd.connect(whenFalse.out, select.terminal('f'), bendX: 78);
  bd.connect(select.terminal('s? t:f'), value.terminal, type: BdType.dbl);
  bd.write();
  return vi;
}
