import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// NI's "How Can I Calculate the Mean of a 2D Array": the sum of the elements over the
/// product of the dimension sizes.
ViModel buildMeanOf2dArray() {
  final vi = ViModel.empty(name: 'Mean of a 2D Array.vi');
  final bd = vi.blockDiagram;
  final mean = bd.indicator(BdType.dbl, 'Mean');
  final array = bd.control(const BdType.array(ViDataType.i32, dims: 2), '2D Array');
  final divide = bd.diagram.add(BdPrimitive.create(bd, PrimOp.divide));
  final count = bd.diagram.add(BdPrimitive.create(bd, PrimOp.multiplyArrayElements));
  final sizes = bd.diagram.add(BdPrimitive.create(bd, PrimOp.arraySize));
  final sum = bd.diagram.add(BdPrimitive.create(bd, PrimOp.addArrayElements));
  bd.connect(array.terminal, sum.terminal('numeric array'));
  bd.connect(array.terminal, sizes.terminal('array'));
  bd.connect(divide.terminal('x/y'), mean.terminal);
  bd.connect(count.terminal('product'), divide.terminal('y'), type: BdType.i32);
  bd.connect(sizes.terminal('size(s)'), count.terminal('numeric array'), type: const BdType.array(ViDataType.i32));
  bd.connect(sum.terminal('sum'), divide.terminal('x'), type: BdType.i32);
  bd.write();
  return vi;
}
