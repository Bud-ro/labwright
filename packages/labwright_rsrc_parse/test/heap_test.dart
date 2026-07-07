import 'dart:math';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

List<int> pascal(String s) => [s.length, ...s.codeUnits];

DecodedSection bdex(List<int> bytes) => DecodedSection(
  section: ViSection(tag: 'BDEx', index: 0, dataOffset: 0, bytes: Uint8List.fromList(bytes)),
  bytes: Uint8List.fromList(bytes),
  wasCompressed: false,
);

void main() {
  test('HeapOpcode catalog maps bytes to kinds and back', () {
    expect(HeapOpcode.fromByte(0x2d), HeapOpcode.bounds);
    expect(HeapOpcode.fromByte(0x1f), HeapOpcode.size);
    expect(HeapOpcode.fromByte(0x2e), HeapOpcode.stringTable);
    expect(HeapOpcode.fromByte(0x22), HeapOpcode.caption);
    expect(HeapOpcode.fromByte(0x19), HeapOpcode.description);
    expect(HeapOpcode.fromByte(0x5f), HeapOpcode.docBounds);
    expect(HeapOpcode.fromByte(0xAB), HeapOpcode.unknown, reason: 'uncatalogued byte -> unknown');
    expect(HeapOpcode.bounds.isDecoded, isTrue);
    expect(HeapOpcode.docBounds.isDecoded, isTrue, reason: 'pane document bounds (corpus-scoped role)');
    expect(HeapOpcode.unknown.isDecoded, isFalse);
    final bytes = HeapOpcode.values.where((o) => o != HeapOpcode.unknown).map((o) => o.byte).toList();
    expect(bytes.toSet().length, bytes.length, reason: 'every catalogued opcode has a unique byte');
  });

  test('HeapRecord.kind reflects the opcode byte', () {
    final heap = <int>[0xc4, 0x2d, 0x02, 0, 0];
    expect(heapC4RecordsFromDecoded([bdex(heap)]).single.kind, HeapOpcode.bounds);
  });

  test('HeapShape taxonomy: string opcodes decode via text, rect opcodes via rect', () {
    final plot = <int>[0xc4, 0x27, 6, ...'Plot 0'.codeUnits];
    final fmt = <int>[0xc4, 0x74, 5, ...'%020b'.codeUnits];
    final recs = heapC4RecordsFromDecoded([
      bdex([...plot, ...fmt]),
    ]);
    expect(recs[0].kind, HeapOpcode.plotName);
    expect(recs[0].text, 'Plot 0');
    expect(recs[1].kind, HeapOpcode.formatString);
    expect(recs[1].text, '%020b');
    expect(recs[0].kind.shape, HeapShape.string);

    final r4c = <int>[0xc4, 0x4c, 0x08, 0xff, 0xdf, 0xff, 0x8e, 0x01, 0xd1, 0x02, 0xad];
    final rec = heapC4RecordsFromDecoded([bdex(r4c)]).single;
    expect(rec.kind, HeapOpcode.dBounds);
    expect(rec.kind.shape, HeapShape.rectangle);
    expect(rec.bounds, isNull, reason: 'dBounds is a root-level rect, not the per-object bounds opcode');
    expect(rec.rect, isNotNull);
    expect([rec.rect!.top, rec.rect!.left], [-33, -114]);
  });

  test('HeapOpcode isDecoded marks semantics vs structural', () {
    expect(HeapOpcode.plotName.isDecoded, isTrue);
    expect(HeapOpcode.formatString.isDecoded, isTrue);
    expect(HeapOpcode.rect26.isDecoded, isFalse);
    expect(HeapOpcode.rect23.isDecoded, isFalse);
  });

  test('frames C4 length-prefixed records and skips payloads', () {
    final strTable = <int>[...pascal('Hi'), ...pascal('Yo')];
    final heap = <int>[
      0x10,
      0x55,
      0xc4,
      0x2d,
      0x08,
      0,
      0,
      0,
      0,
      0,
      0,
      0xc4,
      0x99,
      0xc4,
      0x5f,
      0x08,
      1,
      2,
      3,
      4,
      5,
      6,
      7,
      8,
      0xc4,
      0x2e,
      strTable.length,
      ...strTable,
    ];
    final recs = heapC4RecordsFromDecoded([bdex(heap)]);
    expect(recs.map((r) => r.opcode).toList(), <int>[
      0x2d,
      0x5f,
      0x2e,
    ], reason: 'the leading non-C4 0x10 token is stepped over');
    expect(recs[0].offset, 2);
    expect(recs[0].byteLength, 11, reason: '0xC4 + opcode + len + 8 payload bytes');
    expect(recs[0].payload.length, 8);
    expect(
      recs[1].opcode,
      0x5f,
      reason: 'the 0xC4 inside the first record payload (0xc4 0x99) did not start a new record',
    );
    expect(recs[2].payload.length, 6);
  });

  test('heapOpcodeHistogram counts C4 opcodes', () {
    final heap = <int>[
      0xc4,
      0x2d,
      0x02,
      0,
      0,
      0xc4,
      0x2d,
      0x02,
      0,
      0,
      0xc4,
      0x1f,
      0x01,
      0,
    ];
    final recs = heapC4RecordsFromDecoded([bdex(heap)]);
    expect(recs.where((r) => r.opcode == 0x2d).length, 2);
    expect(recs.where((r) => r.opcode == 0x1f).length, 1);
  });

  test('a C4 with a length running past the section end is not framed', () {
    final heap = <int>[0xc4, 0x2d, 0xff, 1, 2, 3];
    expect(
      heapC4RecordsFromDecoded([bdex(heap)]),
      isEmpty,
      reason: 'length claims 255 payload bytes but only 3 are present -> not framed',
    );
  });

  test('heapC4Records is total over arbitrary bytes and stays in-bounds', () {
    final rng = Random(5);
    for (var t = 0; t < 3000; t++) {
      final n = rng.nextInt(250);
      final b = Uint8List.fromList([for (var j = 0; j < n; j++) rng.nextInt(256)]);
      try {
        for (final r in heapC4RecordsFromDecoded([bdex(b)])) {
          expect(r.offset, inInclusiveRange(0, b.length));
          expect(r.offset + r.byteLength, lessThanOrEqualTo(b.length));
          expect(r.opcode, inInclusiveRange(0, 255));
        }
      } catch (e) {
        fail('leaked ${e.runtimeType}: $e');
      }
    }
  });
}
