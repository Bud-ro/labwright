import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'test_util.dart';

List<int> _heap() => [
  ...open(0x1234, 1),
  ...bounds(10, 20, 30, 40),
  ...caption('outer'),
  ...open(0x1234, 2),
  ...bounds(1, 2, 3, 4),
  ...childRef(1),
  ...close(),
  ...close(),
  ...open(0x1234, 3),
  ...bounds(5, 5, 6, 6),
  ...childRef(2),
  ...close(),
];

Uint8List _file({int maxUid = 3}) => buildRsrc([
  (tag: 'MUID', sections: [be32(maxUid)]),
  (
    tag: 'VCTP',
    sections: [
      poolOf([ViNumericType.encode(TypeCode.i32, label: 'n')], topLevel: [0]),
    ],
  ),
  (
    tag: 'BDHb',
    sections: [compressedSection(heapBody(_heap()))],
  ),
]);

void main() {
  test('every edit lands in the journal, grouped by transaction', () {
    final model = buildViModel(_file());
    final diagram = model.blockDiagrams.single;
    model.moveObject(diagram, diagram.objects[0], dx: 1, dy: 1);
    model.setLabel(diagram, diagram.objects[0], 'o');
    model.transact(() {
      model.allocateUid();
      model.addType(ViBooleanType.encode(label: 'b'));
    });
    expect(model.journal.map((g) => g.length), [1, 1, 3]);
    expect(model.journal.map((g) => g.map((e) => e.section.tag).toSet()), [
      {'BDHb'},
      {'BDHb'},
      {'MUID', 'VCTP'},
    ]);
    expect(model.journal[0].single.removed, [0, 10, 0, 20, 0, 30, 0, 40]);
    expect((model.journal[1].single.removed.length, model.journal[1].single.inserted), (8, 4));
  });

  test('undo takes a group back byte for byte and rebuilds the diagram and types', () {
    final bytes = _file();
    final model = buildViModel(bytes);
    var diagram = model.blockDiagrams.single;
    model.moveObject(diagram, diagram.objects[0], dx: 1, dy: 1);
    model.setLabel(diagram, diagram.objects[0], 'outermost');
    model.addType(ViBooleanType.encode(label: 'b'));
    expect(model.types, hasLength(2));
    expect(model.undo(), isTrue);
    expect(model.types.map((t) => t.label), ['n']);
    expect(model.undo(), isTrue);
    diagram = model.blockDiagrams.single;
    expect(diagram.objects[0].label, 'outer');
    expect(diagram.objects[0].bounds!.top, 11);
    expect(model.undo(), isTrue);
    expect(model.blockDiagrams.single.objects[0].bounds!.top, 10);
    expect(model.undo(), isFalse);
    expect(model.serialize(), bytes);
    expect(model.sections.map((s) => s.edited), [false, false, false]);
  });

  test('a clone follows its original with fresh ids, its inner references following', () {
    final model = buildViModel(_file());
    final (heap: diagram, :clone) = model.cloneObject(
      model.blockDiagrams.single,
      model.blockDiagrams.single.objects[0],
    );
    expect(identical(diagram, model.blockDiagrams.single), isTrue);
    expect(diagram.objects.map((o) => o.oid), [1, 2, 4, 5, 3]);
    expect(clone.oid, 4);
    expect((clone.label, clone.bounds!.top, clone.parentOid), ('outer', 10, null));
    final inner = diagram.childrenOf(clone).single;
    expect((inner.oid, inner.parentOid), (5, 4));
    expect(inner.refs, [4]);
    expect(diagram.objects.last.refs, [2]);
    expect(ViMaxUid(model.section('MUID')!.bytes).maxUid, 5);
    expect(model.journal.map((g) => g.length), [3]);
    final again = buildViModel(model.serialize());
    expect(again.blockDiagrams.single.objects.map((o) => o.oid), [1, 2, 4, 5, 3]);
    expect(model.undo(), isTrue);
    expect(model.blockDiagrams.single.objects.map((o) => o.oid), [1, 2, 3]);
    expect(model.serialize(), _file());
  });

  test('a clone whose fresh ids pass 0x8000 widens its headers and references', () {
    final model = buildViModel(_file(maxUid: 0x7ffe));
    final (heap: diagram, :clone) = model.cloneObject(
      model.blockDiagrams.single,
      model.blockDiagrams.single.objects[0],
    );
    expect(diagram.objects.map((o) => o.oid), [1, 2, 0x7fff, 0x8000, 3]);
    final inner = diagram.childrenOf(clone).single;
    expect((inner.oid, inner.parentOid), (0x8000, 0x7fff));
    expect(inner.refs, [0x7fff]);
    expect(inner.end - inner.offset, diagram.objects[1].end - diagram.objects[1].offset + 4);
    final again = buildViModel(model.serialize()).blockDiagrams.single;
    expect(again.objects.map((o) => o.oid), [1, 2, 0x7fff, 0x8000, 3]);
    expect(again.childrenOf(again.byId[0x7fff]!).single.refs, [0x7fff]);
  });
}
