import 'package:labwright_videcode/labwright_videcode.dart';
import 'package:test/test.dart';

// Deterministic (no-corpus) unit tests for generateDartScaffold's coverage
// guarantee and string safety, built from hand-constructed diagrams so the
// orphan / cycle / depth / sanitization paths are exercised directly.

ViHeapObject _obj(int oid, ViObjectKind cat, {int? parent, String? label}) {
  final o = ViHeapObject(oid: oid, kind: 0x12, offset: 0)
    ..category = cat
    ..parentOid = parent;
  if (label != null) o.label = label;
  return o;
}

ViModel _model(List<ViHeapObject> objs) =>
    ViModel(version: null, title: null, components: const [], stringTables: const [], heapRecords: const [],
        blockDiagrams: [ViDiagram(sectionTag: 'BDHb', objects: objs)]);

void main() {
  test('always carries the honest no-dataflow marker', () {
    final out = generateDartScaffold(_model([_obj(1, ViObjectKind.node)]));
    expect(out, contains(scaffoldMarker));
  });

  test('orphan (parent missing) is still emitted via the re-root path', () {
    // oid 5 has parentOid 999 which is absent → not a root, not in tree, but the
    // orphan pass must still surface it (no logic dropped).
    final out = generateDartScaffold(_model([_obj(5, ViObjectKind.structure, parent: 999, label: 'Loop')]));
    expect(out, contains('[oid 5]'));
  });

  test('a parent/child cycle terminates and both nodes appear in the leftover section', () {
    // A→B→A: neither is a root (both have a present parent), so only the leftover
    // coverage pass can emit them; the seen-guard must prevent infinite recursion.
    final out = generateDartScaffold(_model([
      _obj(1, ViObjectKind.structure, parent: 2, label: 'A'),
      _obj(2, ViObjectKind.node, parent: 1, label: 'B'),
    ]));
    expect(out, contains('(objects outside the nesting tree:)'));
    expect(out, contains('[oid 1]'));
    expect(out, contains('[oid 2]'));
  });

  test('pathological deep nesting is truncated, not a stack overflow, and stays covered', () {
    // a chain of 300 nested structures (each parented to the previous)
    final objs = <ViHeapObject>[_obj(0, ViObjectKind.structure)];
    for (var i = 1; i < 300; i++) {
      objs.add(_obj(i, ViObjectKind.structure, parent: i - 1, label: 'S$i'));
    }
    final out = generateDartScaffold(_model(objs));
    expect(out, contains('nesting truncated at depth'));
    // every structure oid is still represented (deep ones via the leftover pass)
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
    expect(out, isNot(contains('*/'))); // neutralized to '* /'
    // the injected newline must not have created a non-comment line
    for (final line in out.split('\n')) {
      final t = line.trimLeft();
      expect(t.isEmpty || t.startsWith('//') || t.startsWith('void ') || t == '}', isTrue,
          reason: 'non-comment line leaked: "$line"');
    }
  });
}
