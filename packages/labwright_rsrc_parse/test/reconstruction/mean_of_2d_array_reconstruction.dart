import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// NI's "How Can I Calculate the Mean of a 2D Array": the sum of the elements over the
/// product of the dimension sizes.
ViModel buildMeanOf2dArray() {
  final vi = ViModel.empty(name: 'Mean of a 2D Array.vi');
  final mean = vi.indicator(BdType.dbl, 'Mean');
  final array = vi.control(BdType.i32.array.array, '2D Array');

  final divide = vi.add(BdPrimitive(PrimOp.divide));
  final count = vi.add(BdPrimitive(PrimOp.multiplyArrayElements));
  final sizes = vi.add(BdPrimitive(PrimOp.arraySize));
  final sum = vi.add(BdPrimitive(PrimOp.addArrayElements));
  vi.connect([array, sum.terminal('numeric array'), sizes.terminal('array')]);
  vi.connect([divide.terminal('x/y'), mean]);
  vi.connect([count.terminal('product'), divide.terminal('y')], type: BdType.i32);
  vi.connect([sizes.terminal('size(s)'), count.terminal('numeric array')], type: BdType.i32.array);
  vi.connect([sum.terminal('sum'), divide.terminal('x')], type: BdType.i32);
  vi.write();
  return vi;
}
