import 'dart:math';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

List<int> pascal(String s) => [s.length, ...s.codeUnits];

DecodedSection sec(String tag, List<int> bytes, {bool comp = false}) => DecodedSection(
  section: ViSection(tag: tag, index: 0, dataOffset: 0, bytes: Uint8List.fromList(bytes)),
  bytes: Uint8List.fromList(bytes),
  wasCompressed: comp,
);

void main() {
  test('buildViModelFromDecoded aggregates version, components, tables, records', () {
    final vers = <int>[
      ...pascal('10.0'),
      0x00,
      ...'VIDS'.codeUnits,
      ...pascal('My Example.vi'),
    ];
    final table = <int>[...pascal('Sine'), ...pascal('Square'), ...pascal('Ramp')];
    final bdex = <int>[
      0xc4,
      0x2e,
      table.length,
      ...table,
      0xc4,
      0x2d,
      0x08,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
    ];
    final model = buildViModelFromDecoded([sec('vers', vers), sec('BDEx', bdex, comp: true)]);

    expect(model.version, '10.0');
    expect(model.title, 'My Example.vi');
    expect(model.components.any((c) => c.tag == 'BDEx'), isTrue);
    expect(model.stringTables.length, 1);
    expect(model.stringTables.first.framed, isTrue);
    expect(model.stringTables.first.strings, <String>['Sine', 'Square', 'Ramp']);
    expect(model.heapRecords.map((r) => r.opcode), containsAll(<int>[0x2e, 0x2d]));
    expect(model.labels, <String>['Sine', 'Square', 'Ramp']);
  });

  test('labels dedupes across tables, order-preserving', () {
    final t1 = <int>[...pascal('error out'), ...pascal('status')];
    final t2 = <int>[...pascal('status'), ...pascal('code')];
    final model = buildViModelFromDecoded([
      sec('BDEx', <int>[0xc4, 0x2e, t1.length, ...t1]),
      sec('FPHb', <int>[0xc4, 0x2e, t2.length, ...t2]),
    ]);
    expect(model.labels, <String>['error out', 'status', 'code']);
  });

  test('buildViModel is total over arbitrary bytes (ViModel or ViFormatException)', () {
    final rng = Random(3);
    for (var i = 0; i < 1500; i++) {
      final n = rng.nextInt(160);
      final b = Uint8List.fromList([for (var j = 0; j < n; j++) rng.nextInt(256)]);
      try {
        final m = buildViModel(b);
        expect(m.labels, isA<List<String>>());
      } on ViFormatException {
        // acceptable
      } catch (e) {
        fail('leaked ${e.runtimeType}: $e');
      }
    }
  });
}
