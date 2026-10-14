import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// Stack Overflow 16605742: a 2D array squared element by element, and each of its rows
/// scaled by the matching element of a 1D array in an auto-indexing For loop.
ViModel buildMultiplyRows() {
  final vi = ViModel.empty(name: 'Multiply Rows.vi');
  final bd = vi.blockDiagram;
  const matrix = BdType.array(ViDataType.dbl, dims: 2);
  const row = BdType.array(ViDataType.dbl);
  final d = bd.control(matrix, 'd');
  final e = bd.control(row, 'e');
  final scaled = bd.indicator(matrix, 'd*e');
  final squared = bd.indicator(matrix, 'd*d');
  final square = bd.diagram.add(BdPrimitive.create(bd, PrimOp.multiply));
  final loop = bd.diagram.add(BdLoop.create(bd));
  final rows = loop.tunnel(matrix, output: false, indexing: true);
  final factors = loop.tunnel(row, output: false, indexing: true);
  final out = loop.tunnel(matrix, output: true, indexing: true);
  final multiply = loop.body.add(BdPrimitive.create(bd, PrimOp.multiply));
  bd.connect(multiply.terminal('x*y'), out.innerPort, type: row);
  bd.connect(rows.innerPort, multiply.terminal('x'));
  bd.connect(factors.innerPort, multiply.terminal('y'));
  bd.connect(d.terminal, rows.outer!);
  bd.connect(d.terminal, square.terminal('x'));
  bd.connect(d.terminal, square.terminal('y'));
  bd.connect(e.terminal, factors.outer!);
  bd.connect(square.terminal('x*y'), squared.terminal, type: matrix);
  bd.connect(out.outer!, scaled.terminal);
  bd.write();
  return vi;
}
