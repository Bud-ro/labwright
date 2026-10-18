import 'dart:convert';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'test_util.dart';

void main() {
  test('GOLDEN: emitted top-level + node key sets are pinned (update if the IR shape changes)', () {
    final node = BdPrimitive(
      oid: 7,
      parentOid: 1,
      caption: const HeapCaption('doit'),
      bounds: const HeapRect(top: 1, left: 2, bottom: 3, right: 4),
      absBounds: const HeapRect(top: 5, left: 6, bottom: 7, right: 8),
      helpText: 'help',
      refs: const [1],
      primResId: 1051,
    );

    final model = ViModel(
      version: '10.0',
      title: 'T',
      components: const [],
      blockDiagrams: [
        BdDiagram(objects: [node]),
      ],
      subViNames: const ['Helper.vi'],
    );

    final json = viModelToJson(model);
    expect(
      json.keys.toSet(),
      {'labviewVersion', 'title', 'subViNames', 'blockDiagrams', 'frontPanels'},
      reason:
          'top-level key set changed (IR shape) — update this golden expectation. '
          'symbolNames/libraryPaths are absent here because this model has no Call Library nodes.',
    );

    final emittedNode =
        (json['blockDiagrams'] as List<Map<String, Object?>>).first['objects'] as List<Map<String, Object?>>;
    final nodeKeys = emittedNode.first.keys.toSet();
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
        'memberOids',
        'helpText',
        'primResId',
        'primName',
      },
      reason: 'node key set changed (IR shape) — update this golden expectation',
    );
    expect((emittedNode.first['class'] as Map<String, Object?>).keys.toSet(), {
      'label',
      'category',
      'confidence',
    });
  });

  test('non-finite control range sentinels are dropped and the IR stays jsonEncode-safe', () {
    final control = FpNumericControl(
      FpObjectClass.numeric,
      oid: 1,
      bounds: const HeapRect(top: 0, left: 0, bottom: 10, right: 10),
      typeDescIdx: 0,
      min: double.negativeInfinity,
      max: double.infinity,
    );

    final model = ViModel(
      version: null,
      title: null,
      components: const [],
      frontPanels: [
        FpPanel(objects: [control]),
      ],
    );

    final json = viModelToJson(model);
    final emitted = (json['frontPanels'] as List<Map<String, Object?>>).first['objects'] as List<Map<String, Object?>>;
    final keys = emitted.first.keys;
    expect(keys, isNot(contains('controlMin')));
    expect(keys, isNot(contains('controlMax')));
    expect(
      () => jsonEncode(json),
      returnsNormally,
      reason: 'jsonEncode throws on Infinity/NaN — the sentinels must never reach JSON',
    );
  });

  test('connector pane: index + resolved terminals are emitted in the IR JSON', () {
    final pool = ViTypePool(
      Uint8List.fromList([
        0, 0, 0, 2, //
        0, 15, 0x40, 0x0a, 0, 9, ...'Threshold'.codeUnits,
        0, 8, 0, 0xf0, 0, 1, 0, 0,
        0, 1, 0, 1,
      ]),
    );
    final model = ViModel(
      version: null,
      title: null,
      components: [],
      types: pool.types,
      connectorPaneType: ViConnectorPaneIndex(u8([0, 1])).resolve(pool),
    );
    final json = viModelToJson(model);
    final terms = json['connectorPaneTerminals'] as List<Map<String, Object?>>;
    expect(terms, hasLength(1), reason: "the function type's one parameter");
    expect(terms.first['kind'], 'dbl');
    expect(terms.first['name'], 'Threshold');
    expect(() => jsonEncode(json), returnsNormally);
  });
}
