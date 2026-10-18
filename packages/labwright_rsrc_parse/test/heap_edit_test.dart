import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'shape_probe.dart';
import 'test_util.dart';

List<int> _heap() => [
  ...open(0x1234, 1),
  ...bounds(10, 20, 30, 40),
  ...caption('outer'),
  ...open(0x1234, 2),
  ...bounds(1, 2, 3, 4),
  ...caption('inner'),
  ...close(),
  ...close(),
  ...open(0x1234, 3),
  ...bounds(5, 5, 6, 6),
  ...close(),
];

Uint8List _file() => buildRsrc([
  (tag: 'MUID', sections: [be32(3)]),
  (
    tag: 'BDHb',
    sections: [compressedSection(heapBody(_heap()))],
  ),
]);

void main() {
  test('the walker records each object\'s span, bounds payload and label record', () {
    final diagram = buildBlockDiagram(heapBody(_heap()));
    final [outer, inner, last] = diagram.objects;
    expect((outer.offset, outer.end), (4, 4 + _heap().length - (9 + 11 + 2)));
    expect(
      (inner.offset, inner.end, last.offset, last.end),
      (4 + 9 + 11 + 8, outer.end - 2, outer.end, heapBody(_heap()).length),
    );
    expect(
      (outer.boundsOffset, inner.boundsOffset, last.boundsOffset),
      (4 + 9 + 3, inner.offset + 9 + 3, last.offset + 9 + 3),
    );
    expect(
      (outer.labelOffset, outer.labelLength, inner.labelOffset, last.labelOffset),
      (4 + 9 + 11, 8, inner.offset + 9 + 11, null),
    );
  });

  test('a move rewrites the bounds in place and carries the absolute bounds of the inside along', () {
    final model = buildViModel(_file());
    final diagram = model.blockDiagrams.single;
    final [outer, inner, last] = diagram.objects;
    model.moveObject(diagram, outer as HeapPlaced, dx: 100, dy: -5);
    expect((outer.bounds!.top, outer.bounds!.left, outer.bounds!.bottom, outer.bounds!.right), (5, 120, 25, 140));
    expect((inner.bounds!.top, inner.absBounds!.top, inner.absBounds!.left), (1, 6, 122));
    expect((last.absBounds!.top, last.absBounds!.left), (5, 5));
    final again = buildViModel(model.serialize()).blockDiagrams.single;
    expect(again.objects.map((o) => (o.oid, o.absBounds!.top, o.absBounds!.left)), [
      (1, 5, 120),
      (2, 6, 122),
      (3, 5, 5),
    ]);
    expect(again.objects.map((o) => o.label), ['outer', 'inner', null]);
  });

  test('a label is spliced in at its record, shifting every offset after it', () {
    final model = buildViModel(_file());
    final diagram = model.blockDiagrams.single;
    final [outer, inner, last] = diagram.objects;
    final innerOffset = inner.offset, lastBounds = last.boundsOffset!, outerEnd = outer.end;
    model.setLabel(diagram, outer as HeapCaptioned, 'out');
    expect((outer.label, outer.labelLength), ('out', 6));
    expect(
      (inner.offset, last.boundsOffset, outer.end, inner.end),
      (innerOffset - 2, lastBounds - 2, outerEnd - 2, outerEnd - 4),
    );
    model.setLabel(diagram, inner as HeapCaptioned, 'x' * 300);
    expect((inner.labelLength, last.offset, outer.end), (305, outer.end, last.offset));
    model.moveObject(diagram, last as HeapPlaced, dx: 1, dy: 1);
    final again = buildViModel(model.serialize()).blockDiagrams.single;
    expect(again.objects.map((o) => o.label), ['out', 'x' * 300, null]);
    expect(again.objects.map((o) => (o.oid, o.bounds!.top, o.bounds!.left)), [(1, 10, 20), (2, 1, 2), (3, 6, 6)]);
    expect(() => model.setLabel(diagram, last as HeapCaptioned, 'new'), throwsArgumentError);
  });
}
