import 'dart:math';
import 'dart:typed_data';

import 'package:labwright_videcode/labwright_videcode.dart';
import 'package:labwright_viparse/labwright_viparse.dart';
import 'package:test/test.dart';

List<int> pascal(String s) => [s.length, ...s.codeUnits];

DecodedSection bdex(List<int> bytes) => DecodedSection(
      section: ViSection(tag: 'BDEx', index: 0, dataOffset: 0, bytes: Uint8List.fromList(bytes)),
      bytes: Uint8List.fromList(bytes),
      wasCompressed: false,
    );

void main() {
  test('frames C4 length-prefixed records and skips payloads', () {
    final strTable = <int>[...pascal('Hi'), ...pascal('Yo')]; // 6 bytes
    final heap = <int>[
      0x10, 0x55, // a non-C4 token (stepped over)
      0xc4, 0x2d, 0x08, 0, 0, 0, 0, 0, 0, 0xc4, 0x99, // C4 2D, len 8 (payload contains a 0xC4!)
      0xc4, 0x5f, 0x08, 1, 2, 3, 4, 5, 6, 7, 8, // C4 5F, len 8
      0xc4, 0x2e, strTable.length, ...strTable, // C4 2E string table, len 6
    ];
    final recs = heapC4RecordsFromDecoded([bdex(heap)]);
    expect(recs.map((r) => r.opcode).toList(), <int>[0x2d, 0x5f, 0x2e]);
    expect(recs[0].offset, 2);
    expect(recs[0].byteLength, 11); // 0xC4 + op + len + 8 payload
    expect(recs[0].payload.length, 8);
    // The 0xC4 inside the first record's payload must NOT have started a record.
    expect(recs[1].opcode, 0x5f);
    expect(recs[2].payload.length, 6);
  });

  test('heapOpcodeHistogram counts C4 opcodes', () {
    final heap = <int>[
      0xc4, 0x2d, 0x02, 0, 0,
      0xc4, 0x2d, 0x02, 0, 0,
      0xc4, 0x1f, 0x01, 0,
    ];
    final hist = heapC4RecordsFromDecoded([bdex(heap)]).fold<Map<int, int>>({}, (m, r) {
      m[r.opcode] = (m[r.opcode] ?? 0) + 1;
      return m;
    });
    expect(hist[0x2d], 2);
    expect(hist[0x1f], 1);
  });

  test('a C4 with a length running past the section end is not framed', () {
    final heap = <int>[0xc4, 0x2d, 0xff, 1, 2, 3]; // claims 255 payload bytes, only 3 present
    expect(heapC4RecordsFromDecoded([bdex(heap)]), isEmpty);
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
