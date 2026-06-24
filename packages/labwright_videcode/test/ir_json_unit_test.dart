import 'dart:convert';

import 'package:labwright_videcode/labwright_videcode.dart';
import 'package:test/test.dart';

// Deterministic (no-corpus) unit tests for viModelToJson, built from direct
// constructors so the emitted key SET and the non-finite drop are pinned exactly
// — guarding the viIrVersion contract and the jsonEncode-safety claim.

void main() {
  test('GOLDEN: emitted top-level + node key sets are pinned (bump viIrVersion if this changes)', () {
    // a fully-populated node so every conditional key is present at once
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
      blockDiagrams: [ViDiagram(sectionTag: 'BDHb', objects: [node])],
      subViNames: const ['Helper.vi'],
    );

    final json = viModelToJson(model);
    // This model has version/title/description/subViNames but no symbolNames or
    // libraryPaths (no heap records), so those two are absent here.
    expect(
      json.keys.toSet(),
      {'irVersion', 'labviewVersion', 'title', 'description', 'subViNames', 'blockDiagrams', 'frontPanelDiagrams'},
      reason: 'top-level key set changed — bump viIrVersion if this is a shape change',
    );

    final emittedNode = ((json['blockDiagrams'] as List).first as Map)['objects'] as List;
    final nodeKeys = (emittedNode.first as Map).keys.cast<String>().toSet();
    expect(
      nodeKeys,
      {
        'oid', 'kindCode', 'class', 'objectKind', 'typeKind', 'parentOid', 'label',
        'bounds', 'absBounds', 'items', 'termCount', 'memberOids', 'controlMin', 'controlMax', 'helpText',
      },
      reason: 'node key set changed — bump viIrVersion if this is a shape change',
    );
    // class is a nested map with its three documented keys
    expect(((emittedNode.first as Map)['class'] as Map).keys.cast<String>().toSet(),
        {'label', 'category', 'confidence'});
    expect(json['irVersion'], viIrVersion);
  });

  test('non-finite control range sentinels are dropped and the IR stays jsonEncode-safe', () {
    final node = ViHeapObject(oid: 1, kind: 0x50, offset: 0)
      ..category = ViObjectKind.terminal
      ..absBounds = const HeapRect(top: 0, left: 0, bottom: 10, right: 10)
      ..controlMin = double.negativeInfinity // "no minimum" sentinel
      ..controlMax = double.infinity; //         "no maximum" sentinel

    final model = ViModel(
      version: null,
      title: null,
      components: const [],
      stringTables: const [],
      heapRecords: const [],
      blockDiagrams: [ViDiagram(sectionTag: 'BDHb', objects: [node])],
    );

    final json = viModelToJson(model);
    final emitted = ((json['blockDiagrams'] as List).first as Map)['objects'] as List;
    final keys = (emitted.first as Map).keys;
    expect(keys, isNot(contains('controlMin')));
    expect(keys, isNot(contains('controlMax')));
    // jsonEncode would THROW on Infinity/NaN — this proves they never reach JSON
    expect(() => jsonEncode(json), returnsNormally);
  });
}
