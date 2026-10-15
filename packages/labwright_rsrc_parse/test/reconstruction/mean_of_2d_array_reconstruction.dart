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
  array >> sum['numeric array'];
  array >> sizes['array'];
  divide['x/y'] >> mean;
  vi.connect(count['product'], divide['y'], type: BdType.i32);
  vi.connect(sizes['size(s)'], count['numeric array'], type: BdType.i32.array);
  vi.connect(sum['sum'], divide['x'], type: BdType.i32);
  vi.write();
  return vi;
}
