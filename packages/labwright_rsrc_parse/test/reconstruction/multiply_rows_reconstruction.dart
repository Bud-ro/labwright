import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// Stack Overflow 16605742: a 2D array squared element by element, and each of its rows
/// scaled by the matching element of a 1D array in an auto-indexing For loop.
ViModel buildMultiplyRows() {
  final vi = ViModel.empty(name: 'Multiply Rows.vi');
  final matrix = BdType.dbl.array.array;
  final row = BdType.dbl.array;
  final d = vi.control(matrix, 'd');
  final e = vi.control(row, 'e');
  final scaled = vi.indicator(matrix, 'd*e');
  final squared = vi.indicator(matrix, 'd*d');

  final square = vi.add(BdPrimitive(PrimOp.multiply));
  final loop = vi.add(BdLoop.forLoop());
  final rows = loop.tunnel(matrix, direction: BdTunnelDirection.input, indexing: true);
  final factors = loop.tunnel(row, direction: BdTunnelDirection.input, indexing: true);
  final out = loop.tunnel(matrix, direction: BdTunnelDirection.output, indexing: true);
  final multiply = loop.add(BdPrimitive(PrimOp.multiply));
  vi.connect([multiply.terminal('x*y'), out]);
  vi.connect([rows, multiply.terminal('x')]);
  vi.connect([factors, multiply.terminal('y')]);
  vi.connect([d, rows, square.terminal('x'), square.terminal('y')]);
  vi.connect([e, factors]);
  vi.connect([square.terminal('x*y'), squared]);
  vi.connect([out, scaled]);
  vi.write();
  return vi;
}
