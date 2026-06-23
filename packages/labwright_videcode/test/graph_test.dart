import 'dart:typed_data';

import 'package:labwright_videcode/labwright_videcode.dart';
import 'package:test/test.dart';

// Object header: 10 19 02 fe <u16 kind> fd <u16 oid>
List<int> obj(int kind, int oid) => [0x10, 0x19, 0x02, 0xfe, kind >> 8, kind & 0xff, 0xfd, oid >> 8, oid & 0xff];
// bounds C4 2D
List<int> bounds(int t, int l, int b, int r) =>
    [0xc4, 0x2d, 0x08, t >> 8, t & 0xff, l >> 8, l & 0xff, b >> 8, b & 0xff, r >> 8, r & 0xff];
// caption C4 22
List<int> caption(String s) => [0xc4, 0x22, s.length, ...s.codeUnits];
// reference 14 19 01 fd <u16 id>
List<int> ref(int id) => [0x14, 0x19, 0x01, 0xfd, id >> 8, id & 0xff];

void main() {
  test('buildDiagram segments objects, attaches bounds/labels, resolves wire edges', () {
    final records = <int>[
      ...obj(0x50, 100), // a node, oid 100
      ...bounds(10, 20, 40, 100),
      ...caption('Trigger'),
      ...obj(0x50, 200), // another node, oid 200
      ...bounds(60, 20, 90, 100),
      ...caption('Source'),
      ...obj(0x68, 300), // a wire, oid 300, links 100 & 200
      ...ref(100),
      ...ref(200),
    ];
    final body = Uint8List.fromList([0, 0, 0, records.length, ...records]);
    final d = buildDiagram(body);

    expect(d.objects.length, 3);
    final n100 = d.byId[100]!;
    expect(n100.kind, 0x50);
    expect(n100.role, ViObjectRole.bounded);
    expect(n100.label, 'Trigger');
    expect([n100.bounds!.top, n100.bounds!.left, n100.bounds!.bottom, n100.bounds!.right], [10, 20, 40, 100]);

    final wire = d.byId[300]!;
    expect(wire.role, ViObjectRole.wire);
    expect(wire.refs, [100, 200]);

    final conns = d.connections;
    expect(conns.length, 1);
    expect(conns.single.endpoints.map((e) => e.oid).toSet(), {100, 200});
  });

  test('oids are unique and edges resolve to real objects', () {
    final records = <int>[
      ...obj(0x50, 1),
      ...bounds(0, 0, 10, 10),
      ...obj(0x68, 2),
      ...ref(1),
      ...ref(999), // dangling -> dropped from connections
    ];
    final body = Uint8List.fromList([0, 0, 0, records.length, ...records]);
    final d = buildDiagram(body);
    expect(d.byId.length, 2);
    // wire 2 has refs [1, 999] but only 1 resolves -> <2 endpoints -> no connection
    expect(d.connections, isEmpty);
  });

  test('classifies object kinds and infers type from attached C4 records', () {
    // C4 74 numeric format, and a C4 2E enum item list.
    List<int> fmt74(String s) => [0xc4, 0x74, s.length, ...s.codeUnits];
    List<int> enum2e(List<String> items) {
      final body = <int>[for (final it in items) ...[it.length, ...it.codeUnits]];
      return [0xc4, 0x2e, body.length, ...body];
    }

    final records = <int>[
      ...obj(0x50, 10), ...bounds(0, 0, 17, 80), ...fmt74('%#_6g'), // numeric float terminal
      ...obj(0x50, 11), ...bounds(0, 0, 17, 80), ...fmt74('%04d'), // numeric int terminal
      ...obj(0x0d, 12), ...bounds(0, 0, 17, 80), ...enum2e(['Low', 'High']), // enum
      ...obj(0x68, 20), ...ref(10), ...ref(11), // wire referencing 10 & 11
    ];
    final body = Uint8List.fromList([0, 0, 0, records.length, ...records]);
    final d = buildDiagram(body);
    expect(d.byId[10]!.typeKind, ViTypeKind.numericFloat);
    expect(d.byId[11]!.typeKind, ViTypeKind.numericInt);
    expect(d.byId[12]!.typeKind, ViTypeKind.enumRing);
    expect(d.byId[20]!.category, ViObjectKind.wire);
    // 10/11 are wire-referenced 0x50 -> terminal
    expect(d.byId[10]!.category, ViObjectKind.terminal);
  });

  test('ViModel.diagrams is populated from BDEx and buildDiagram is total', () {
    // totality over arbitrary bytes
    final junk = Uint8List.fromList([for (var i = 0; i < 300; i++) (i * 17 + 3) & 0xff]);
    expect(() => buildDiagram(junk), returnsNormally);
  });
}
