import 'dart:convert';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

void main() {
  test('GOLDEN: emitted top-level + node key sets are pinned (update if the IR shape changes)', () {
    final node = ViHeapObject(oid: 7, kind: 0x12, offset: 0)
      ..category = ViObjectKind.node
      ..parentOid = 1
      ..label = 'doit'
      ..bounds = const HeapRect(top: 1, left: 2, bottom: 3, right: 4)
      ..absBounds = const HeapRect(top: 5, left: 6, bottom: 7, right: 8)
      ..items = const ['a', 'b']
      ..termCount = 2
      ..controlMin = 0.0
      ..controlMax = 10.0
      ..helpText = 'help';
    node.typedRefs[HeapRefKind.childRef] = [1];

    final model = ViModel(
      version: '10.0',
      title: 'T',
      description: 'D',
      components: const [],
      stringTables: const [],
      heapRecords: const [],
      blockDiagrams: [
        ViDiagram(sectionTag: 'BDHb', objects: [node]),
      ],
      subViNames: const ['Helper.vi'],
    );

    final json = viModelToJson(model);
    expect(
      json.keys.toSet(),
      {'labviewVersion', 'title', 'description', 'subViNames', 'blockDiagrams', 'frontPanelDiagrams'},
      reason:
          'top-level key set changed (IR shape) — update this golden expectation. '
          'symbolNames/libraryPaths are absent here because this model has no heap records.',
    );

    final emittedNode = ((json['blockDiagrams'] as List).first as Map)['objects'] as List;
    final nodeKeys = (emittedNode.first as Map).keys.cast<String>().toSet();
    expect(
      nodeKeys,
      {
        'oid',
        'kindCode',
        'class',
        'objectKind',
        'typeKind',
        'parentOid',
        'label',
        'bounds',
        'absBounds',
        'items',
        'termCount',
        'memberOids',
        'controlMin',
        'controlMax',
        'helpText',
      },
      reason: 'node key set changed (IR shape) — update this golden expectation',
    );
    expect(((emittedNode.first as Map)['class'] as Map).keys.cast<String>().toSet(), {
      'label',
      'category',
      'confidence',
    });
  });

  test('non-finite control range sentinels are dropped and the IR stays jsonEncode-safe', () {
    final node = ViHeapObject(oid: 1, kind: 0x50, offset: 0)
      ..category = ViObjectKind.terminal
      ..absBounds = const HeapRect(top: 0, left: 0, bottom: 10, right: 10)
      ..controlMin = double.negativeInfinity
      ..controlMax = double.infinity;

    final model = ViModel(
      version: null,
      title: null,
      components: const [],
      stringTables: const [],
      heapRecords: const [],
      blockDiagrams: [
        ViDiagram(sectionTag: 'BDHb', objects: [node]),
      ],
    );

    final json = viModelToJson(model);
    final emitted = ((json['blockDiagrams'] as List).first as Map)['objects'] as List;
    final keys = (emitted.first as Map).keys;
    expect(keys, isNot(contains('controlMin')));
    expect(keys, isNot(contains('controlMax')));
    expect(
      () => jsonEncode(json),
      returnsNormally,
      reason: 'jsonEncode throws on Infinity/NaN — the sentinels must never reach JSON',
    );
  });

  test('connector pane: index + resolved terminals are emitted in the IR JSON', () {
    const dbl = ViType(index: 0, code: 0x0a, kind: ViDataType.dbl, name: 'Threshold');
    const cluster = ViType(index: 1, code: 0x50, kind: ViDataType.cluster, name: 'error out', members: [0]);
    const model = ViModel(
      version: null,
      title: null,
      components: [],
      stringTables: [],
      heapRecords: [],
      types: [dbl, cluster],
      connectorPaneTypeIndex: 2,
    );
    final json = viModelToJson(model);
    expect(json['connectorPaneTypeIndex'], 2, reason: '1-based index into the type pool -> the cluster');
    final terms = json['connectorPaneTerminals'] as List;
    expect(terms, hasLength(1), reason: "the cluster's one member");
    expect((terms.first as Map)['kind'], 'dbl');
    expect((terms.first as Map)['name'], 'Threshold');
    expect(() => jsonEncode(json), returnsNormally);
  });
}
