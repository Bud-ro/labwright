import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// Stack Overflow 16605742: a 2D array squared element by element, and each of its rows
/// scaled by the matching element of a 1D array in an auto-indexing For loop.
ViModel buildMultiplyRows() {
  final vi = ViModel.empty(name: 'Multiply Rows.vi');
  final bd = vi.blockDiagram;
  const matrix = BdType.array(ViDataType.dbl, dims: 2);
  const row = BdType.array(ViDataType.dbl);
  final d = bd.control(
    matrix,
    'd',
    at: (x: 73, y: 124),
    labelAt: const HeapRect(top: -17, left: 28, bottom: 0, right: 38),
    icon: true,
  );
  final e = bd.control(
    row,
    'e',
    at: (x: 73, y: 207),
    labelAt: const HeapRect(top: -17, left: 29, bottom: 0, right: 38),
    icon: true,
  );
  final scaled = bd.indicator(
    matrix,
    'd*e',
    at: (x: 221, y: 200),
    labelAt: const HeapRect(top: -17, left: 0, bottom: 0, right: 21),
    icon: true,
  );
  final squared = bd.indicator(
    matrix,
    'd*d',
    at: (x: 154, y: 119),
    labelAt: const HeapRect(top: -17, left: 0, bottom: 0, right: 22),
    icon: true,
  );
  final square = bd.diagram.add(
    BdPrimitive.create(bd, PrimOp.multiply, at: const HeapRect(top: 122, left: 116, bottom: 154, right: 148)),
  );
  final loop = bd.diagram.add(BdLoop.create(bd, at: const HeapRect(top: 182, left: 122, bottom: 265, right: 211)));
  loop.iteration.termBounds = const HeapRect(top: 61, left: 1, bottom: 77, right: 17);
  final rows = loop.tunnel(matrix, output: false, indexing: true, top: 28);
  final factors = loop.tunnel(row, output: false, indexing: true, top: 40);
  final out = loop.tunnel(matrix, output: true, indexing: true, top: 33);
  final multiply = loop.body.add(
    BdPrimitive.create(bd, PrimOp.multiply, at: const HeapRect(top: 21, left: 26, bottom: 53, right: 58)),
  );
  bd.connect(multiply.terminal('x*y'), out.innerPort, type: row);
  bd.connect(factors.innerPort, multiply.terminal('y'), bendX: 27);
  bd.connect(rows.innerPort, multiply.terminal('x'));
  bd.connect(square.terminal('x*y'), squared.terminal, type: matrix);
  bd.connect(d.terminal, rows.outer!, bendX: 117);
  bd.connect(d.terminal, square.terminal('x'));
  bd.connect(d.terminal, square.terminal('y'));
  bd.connect(out.outer!, scaled.terminal);
  bd.connect(e.terminal, factors.outer!);
  bd.write();
  return vi;
}
