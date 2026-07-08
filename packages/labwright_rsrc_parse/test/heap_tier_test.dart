import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'test_util.dart';

void main() {
  // Each crafted record is graded standalone by heapDecodeTier (the single source of truth for the
  // 3-tier coverage metric): (name, bytes, tier, valueKindPayloadBytes, enclosingKind).
  final rows = <(String, List<int>, HeapDecodeTier, int, int)>[
    ('object header', hx('10 19 02 fe 0050 fd 002a'), HeapDecodeTier.semantic, 0, -1),
    ('group close', hx('08 55'), HeapDecodeTier.semantic, 0, -1),
    ('group open (type tag)', hx('10 e1 01 fb 0007'), HeapDecodeTier.semantic, 0, -1),
    ('childRef', hx('14 19 01 fd 0009'), HeapDecodeTier.semantic, 0, -1),
    ('C4 bounds (isDecoded)', hx('c4 2d 08 0000 0000 000a 0014'), HeapDecodeTier.semantic, 0, -1),
    ('backgroundColor (confirmed)', hx('84 28 ff 123456'), HeapDecodeTier.semantic, 0, -1),
    ('plotColor (inferred)', hx('84 2a ff ff4242'), HeapDecodeTier.semantic, 0, -1),
    ('borderColor (inferred)', hx('84 2b ff bcbcbc'), HeapDecodeTier.semantic, 0, -1),
    ('raw 0x0CB objFlags (inferred)', hx('64 cb 10 0000'), HeapDecodeTier.semantic, 0, -1),
    ('raw 0x0AF masterPart (inferred)', hx('24 af 09'), HeapDecodeTier.semantic, 0, -1),
    ('raw 0x1E7 wire table, small scalar form', hx('45 e7 02 08'), HeapDecodeTier.semantic, 0, -1),
    (
      'raw 0x1E7 wire table, container: 3-byte header known, 6 payload bytes not decoded',
      hx('c5 e7 06 03 00 00 00 00 00'),
      HeapDecodeTier.semantic,
      6,
      -1,
    ),
    ('raw 0x09F lastSignalKind (inferred)', hx('44 9f 83 50'), HeapDecodeTier.semantic, 0, -1),
    ('ddoRef (cross-heap, 100%)', hx('14 53 01 fd 0007'), HeapDecodeTier.semantic, 0, -1),
    ('srcDCORef (15-lead leaf ref)', hx('15 13 01 fd 0007'), HeapDecodeTier.semantic, 0, -1),
    ('attachmentRef (16-lead leaf ref)', hx('16 8a 01 fd 0007'), HeapDecodeTier.semantic, 0, -1),
    ('C4 5F docBounds (decoded rect role)', hx('c4 5f 08 0000 0000 000a 0014'), HeapDecodeTier.semantic, 0, -1),
    (
      'raw 0x26C constValue container: role catalogued, 4 payload bytes not',
      hx('c6 6c ff 0004 ffffffff'),
      HeapDecodeTier.semantic,
      4,
      -1,
    ),
    ('empty catalogued container: no interior bytes', hx('c5 e7 00'), HeapDecodeTier.semantic, 0, -1),
    (
      'uncatalogued raw 0x199 container: extent known, role/content not',
      hx('c5 99 02 aabb'),
      HeapDecodeTier.valueKindKnown,
      0,
      -1,
    ),
    ('C4 44 container44: known shape, contents not decoded', hx('c4 44 00'), HeapDecodeTier.valueKindKnown, 0, -1),
    (
      'C4 26 rect26: structural rect, role undetermined',
      hx('c4 26 08 0000 0000 000a 0014'),
      HeapDecodeTier.valueKindKnown,
      0,
      -1,
    ),
    ('uncatalogued tag with grammar-known width', hx('24 99 05'), HeapDecodeTier.valueKindKnown, 0, -1),
    ('raw 0x023 field23 stays kindOnly', hx('24 23 01'), HeapDecodeTier.valueKindKnown, 0, -1),
    ('leaf with an fe (class) attribute', hx('14 53 01 fe 0034'), HeapDecodeTier.valueKindKnown, 0, -1),
    (
      'fd-escape leaf (7-byte value form): not a compact ref',
      hx('15 77 01 fd 8000 0000 0100'),
      HeapDecodeTier.valueKindKnown,
      0,
      -1,
    ),
    ('uncatalogued bare 2-byte selector', hx('15 99 24 df'), HeapDecodeTier.valueKindKnown, 0, -1),
    (
      'raw 0x231 inline property-item-name string',
      [0xc6, 0x31, 0x05, ...'Scale'.codeUnits],
      HeapDecodeTier.semantic,
      0,
      -1,
    ),
    (
      'raw 0x26C constant-value text blob',
      [0xc6, 0x6c, 0xff, 0x00, 0x0a, 0x00, 0x00, 0x00, 0x06, ...'Robot!'.codeUnits],
      HeapDecodeTier.semantic,
      0,
      -1,
    ),
    ('raw 0x220 stdNumMin f64', hx('c6 20 08 bff0 0000 0000 0000'), HeapDecodeTier.semantic, 0, -1),
    ('raw 0x222 stdNumInc f64', hx('c6 22 08 0000 0000 0000 0000'), HeapDecodeTier.semantic, 0, -1),
    ('partRole u8 (66 = annex part role)', hx('24 df 42'), HeapDecodeTier.semantic, 0, -1),
    ('partRole u16 (8002 = numeric-control role)', hx('44 df 1f42'), HeapDecodeTier.semantic, 0, -1),
    ('raw 0x020 u32 inside bigMultiCosm = colour', hx('84 20 ff 101010'), HeapDecodeTier.semantic, 0, 0x0c),
    (
      'raw 0x020 u32 inside a label class: text-style word, not colour',
      hx('84 20 ff 101010'),
      HeapDecodeTier.valueKindKnown,
      0,
      0x0a,
    ),
    ('raw 0x021 u32 with no known enclosing class', hx('84 21 00 814404'), HeapDecodeTier.valueKindKnown, 0, -1),
    ('45 20 is raw 0x120 tableFlags, a different tag', hx('45 20 02 00'), HeapDecodeTier.semantic, 0, -1),
    ('raw 0x021 as u16: text-mode word, not colour', hx('44 21 1234'), HeapDecodeTier.valueKindKnown, 0, -1),
    ('raw 0x020 as u8: small index, not colour', hx('24 20 05'), HeapDecodeTier.valueKindKnown, 0, -1),
    (
      'raw 0x028 bgColor at u8 width: narrow colour-ness not established',
      hx('24 28 01'),
      HeapDecodeTier.valueKindKnown,
      0,
      -1,
    ),
    ('uncatalogued C4 opcode: framed payload extent known', hx('c4 99 00'), HeapDecodeTier.valueKindKnown, 0, -1),
    ('unknown lead byte', hx('99 00'), HeapDecodeTier.framed, 0, -1),
  ];

  test('heapDecodeTier grades every crafted record into its exact tier and payload split', () {
    for (final (name, bytes, tier, payload, enclosingKind) in rows) {
      final g = heapDecodeTier(u8(bytes), 0, bytes[0], 'BDHb', enclosingKind: enclosingKind);
      expect(g.tier, tier, reason: name);
      expect(g.valueKindPayloadBytes, payload, reason: '$name: payload-byte split');
    }
  });
}
