import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// NI's "How Can I Calculate the Mean of a 2D Array": the sum of the elements over the
/// product of the dimension sizes.
ViModel buildMeanOf2dArray() {
  final vi = ViModel.empty(name: 'Mean of a 2D Array.vi');
  final bd = vi.blockDiagram;
  final mean = bd.indicator(
    BdType.dbl,
    'Mean',
    at: (x: 256, y: 49),
    labelAt: const HeapRect(top: -17, left: 0, bottom: 0, right: 33),
  );
  final array = bd.control(
    const BdType.array(ViDataType.i32, dims: 2),
    '2D Array',
    at: (x: 0, y: 17),
    labelAt: const HeapRect(top: -17, left: 0, bottom: 0, right: 48),
  );
  final divide = bd.diagram.add(
    BdPrimitive.create(bd, PrimOp.divide, at: const HeapRect(top: 41, left: 213, bottom: 73, right: 245)),
  );
  final count = bd.diagram.add(
    BdPrimitive.create(
      bd,
      PrimOp.multiplyArrayElements,
      at: const HeapRect(top: 81, left: 150, bottom: 113, right: 182),
    ),
  );
  final sizes = bd.diagram.add(
    BdPrimitive.create(bd, PrimOp.arraySize, at: const HeapRect(top: 81, left: 96, bottom: 113, right: 128)),
  );
  final sum = bd.diagram.add(
    BdPrimitive.create(bd, PrimOp.addArrayElements, at: const HeapRect(top: 9, left: 91, bottom: 41, right: 123)),
  );
  bd.connect(array.terminal, sum.terminal('numeric array'), bendX: 66);
  bd.connect(array.terminal, sizes.terminal('array'));
  bd.connect(divide.terminal('x/y'), mean.terminal);
  bd.connect(count.terminal('product'), divide.terminal('y'), type: BdType.i32, bendX: 213);
  bd.connect(
    sizes.terminal('size(s)'),
    count.terminal('numeric array'),
    type: const BdType.array(ViDataType.i32),
    bendX: 120,
  );
  bd.connect(sum.terminal('sum'), divide.terminal('x'), type: BdType.i32, bendX: 213);
  bd.write();
  return vi;
}
