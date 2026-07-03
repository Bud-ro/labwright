import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

ViHeapObject _obj(int oid, ViObjectKind cat, {int? parent, String? label}) {
  final o = ViHeapObject(oid: oid, kind: 0x12, offset: 0)
    ..category = cat
    ..parentOid = parent;
  if (label != null) o.label = label;
  return o;
}

ViModel _model(List<ViHeapObject> objs, {String? description}) =>
    ViModel(version: null, title: null, description: description, components: const [], stringTables: const [],
        heapRecords: const [], blockDiagrams: [ViDiagram(sectionTag: 'BDHb', objects: objs)]);

void main() {
  test('always carries the honest no-dataflow marker', () {
    final out = generateDartScaffold(_model([_obj(1, ViObjectKind.node)]));
    expect(out, contains(scaffoldMarker));
  });

  test('the VI description is surfaced in the header (one-lined)', () {
    final out = generateDartScaffold(_model([_obj(1, ViObjectKind.node)], description: 'Reads a\nPicoScope channel.'));
    expect(out, contains('// Description: Reads a PicoScope channel.'));
  });

  test('orphan (parent missing) is still emitted via the re-root path', () {
    final out = generateDartScaffold(_model([_obj(5, ViObjectKind.structure, parent: 999, label: 'Loop')]));
    expect(out, contains('[oid 5]'));
  });

  test('a parent/child cycle terminates and both nodes appear in the leftover section', () {
    final out = generateDartScaffold(_model([
      _obj(1, ViObjectKind.structure, parent: 2, label: 'A'),
      _obj(2, ViObjectKind.node, parent: 1, label: 'B'),
    ]));
    expect(out, contains('(objects outside the nesting tree:)'));
    expect(out, contains('[oid 1]'));
    expect(out, contains('[oid 2]'));
  });

  test('pathological deep nesting is truncated, not a stack overflow, and stays covered', () {
    final objs = <ViHeapObject>[_obj(0, ViObjectKind.structure)];
    for (var i = 1; i < 300; i++) {
      objs.add(_obj(i, ViObjectKind.structure, parent: i - 1, label: 'S$i'));
    }
    final out = generateDartScaffold(_model(objs));
    expect(out, contains('nesting truncated at depth'));
    for (final o in objs) {
      expect(out, contains('[oid ${o.oid}]'), reason: 'oid ${o.oid} dropped');
    }
  });

  test('a non-identifier VI name is sanitized into a valid function name', () {
    final out = generateDartScaffold(_model([_obj(1, ViObjectKind.node)]), name: '0bad name');
    expect(out, contains('void vi_0bad_name('));
  });

  test('a label containing */ or newlines cannot break out of the comment', () {
    final out = generateDartScaffold(_model([_obj(1, ViObjectKind.node, label: 'a*/b\nhack')]));
    expect(out, isNot(contains('*/')));
    for (final line in out.split('\n')) {
      final t = line.trimLeft();
      expect(t.isEmpty || t.startsWith('//') || t.startsWith('void ') || t == '}', isTrue,
          reason: 'non-comment line leaked: "$line"');
    }
  });

  test('a subVI-call node (name ends .vi) emits "calls"; other nodes stay "TODO:"', () {
    final call = _obj(1, ViObjectKind.node, label: 'Foo.vi');
    final prim = _obj(2, ViObjectKind.node);
    final out = generateDartScaffold(_model([call, prim]));
    expect(out, contains('// calls Foo.vi'));
    expect(out, isNot(contains('// TODO: Foo.vi')));
    expect(out, contains('TODO:'));
  });

  test('children emit in POSITIONAL order (visual top->left), not heap order', () {
    final s = _obj(1, ViObjectKind.structure);
    final x = _obj(2, ViObjectKind.node, parent: 1, label: 'lower')..absBounds = const HeapRect(top: 100, left: 0, bottom: 120, right: 40);
    final y = _obj(3, ViObjectKind.node, parent: 1, label: 'upper')..absBounds = const HeapRect(top: 10, left: 0, bottom: 30, right: 40);
    final out = generateDartScaffold(_model([s, x, y]));
    expect(out, contains('POSITIONAL order'));
    expect(out.indexOf('[oid 3]'), lessThan(out.indexOf('[oid 2]')),
        reason: 'upper node (oid 3, top 10) must emit before lower node (oid 2, top 100)');
  });

  test('connector-pane terminals are emitted from the CONP->VCTP cluster members', () {
    const dbl = ViType(index: 0, code: 0x0a, kind: ViDataType.dbl, name: 'Threshold');
    const cluster = ViType(index: 1, code: 0x50, kind: ViDataType.cluster, name: 'error out', members: [0]);
    final model = ViModel(
      version: null,
      title: null,
      components: const [],
      stringTables: const [],
      heapRecords: const [],
      types: [dbl, cluster],
      connectorPaneTypeIndex: 2,
      blockDiagrams: [ViDiagram(sectionTag: 'BDHb', objects: [_obj(1, ViObjectKind.node)])],
    );
    final out = generateDartScaffold(model, name: 'myVi');
    expect(out, contains('Connector-pane terminals'));
    expect(out, contains('dbl Threshold'));
    expect(out, contains('in/out direction not recovered'));
    expect(out, contains('suggested signature'));
    expect(out, contains('myVi(dbl Threshold)'));
    expect(out, contains('in/out not recovered'));
  });
}
