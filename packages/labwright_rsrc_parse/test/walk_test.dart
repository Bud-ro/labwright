import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

void main() {
  Uint8List b(List<int> x) => Uint8List.fromList(x);
  test('recordSkip frames the known record families', () {
    expect(recordSkip(b([0xc4, 0x2d, 0x08, 0, 0, 0, 0, 0, 0, 0, 0]), 0), 11);
    expect(recordSkip(b([0xc4, 0x19, 0xff, 0x01, 0x02, ...List.filled(258, 0)]), 0), 263);
    expect(recordSkip(b([0x84, 1, 2, 3, 4, 5]), 0), 6);
    expect(recordSkip(b([0x10, 0x18, 0x02, 0xfe, 0, 0, 0, 0, 0]), 0), 9);
    expect(recordSkip(b([0x10, 0xe1, 0x01, 0xfb, 0, 0]), 0), 6);
    expect(recordSkip(b([0x14, 0x19, 0x01, 0xfd, 0, 0]), 0), 6);
    expect(
      recordSkip(b([0x14, 0x19, 0x01, 0xfd, 0x80, 0x00, 0x00, 0x00, 0x84, 0x6f]), 0),
      10,
      reason:
          'FD value-escape (fd 80 00 <u32>) makes a 10-byte record, not a hardcoded 6 (heap record-size desync fix)',
    );
    expect(recordSkip(b([0x08, 0x55]), 0), 2);
    expect(recordSkip(b([0x24, 0, 0]), 0), 3);
    expect(recordSkip(b([0x44, 0, 0, 0]), 0), 4);
    expect(recordSkip(b([0x64, 0xcb, 0, 0, 0]), 0), 5);
    expect(recordSkip(b([0x64, 0xcb, 0x26]), 0), 3);
    expect(recordSkip(b([0x86, 0x20, 0, 0, 0, 0]), 0), 6);
    expect(recordSkip(b([0xe4, 0x21]), 0), 2);
    expect(recordSkip(b([0x99, 0, 0]), 0), isNull);
    expect(
      recordSkip(b([0x25, 0x2d, 0x03, 0x08, 0x19]), 0),
      3,
      reason: '0x25 is a fixed 3-byte record; the 25 2d form is NOT a counted list',
    );
    expect(
      recordSkip(b([0x10, 0x19, 0x01, 0xfd, 0x80, 0x00, 0x00, 0x01, 0x36, 0xde]), 0),
      10,
      reason: 'FD value-escape (fd 80 00 <u32>) inside a typed list is a 7-byte item',
    );
    expect(
      recordSkip(b([0xc6, 0x5a, 0xff, 0x00, 0x04, 1, 2, 3, 4]), 0),
      9,
      reason: '0xC6 extended-length record (C4-style FF -> u16 escape)',
    );
  });

  test('walkHeapBody walks a well-formed body to exact EOF', () {
    final records = <int>[
      0x84,
      1,
      2,
      3,
      4,
      5,
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
      0x08,
      0x55,
      0x14,
      0x19,
      0x01,
      0xfd,
      0x00,
      0x10,
    ];
    final body = Uint8List.fromList([0, 0, 0, records.length, ...records]);
    final w = walkHeapBody(body);
    expect(w.complete, isTrue);
    expect(w.coverage, 1.0, reason: 'walker covers every record; the leading [u32 contentLen] header value is ignored');
    expect(w.spans.map((s) => s.lead).toList(), [0x84, 0xc4, 0x08, 0x14]);
    expect(w.spans.firstWhere((s) => s.lead == 0xc4).isC4Record, isTrue);
  });

  test('walkHeapBody stops and reports at an unknown opcode', () {
    final body = Uint8List.fromList([0, 0, 0, 4, 0x84, 1, 2, 3, 4, 5, 0x99, 0x00]);
    final w = walkHeapBody(body);
    expect(w.complete, isFalse);
    expect(w.stoppedLead, 0x99);
    expect(w.spans.single.lead, 0x84);
  });

  test('HeapPropertyToken catalog: unique keys, round-trip via lookup', () {
    final seen = <int>{};
    for (final t in HeapPropertyToken.values) {
      expect(seen.add((t.op << 8) | t.subop), isTrue, reason: 'duplicate (op,subop) for ${t.tokenName}');
      expect(HeapPropertyToken.lookup(t.op, t.subop), t);
      expect(t.tokenName, isNotEmpty);
    }
    expect(HeapPropertyToken.lookup(0xff, 0xff), isNull);
  });

  test('decodeHeapPropertyToken decodes tagged-list values and bare selectors', () {
    final role = decodeHeapPropertyToken(b([0x10, 0x19, 0x01, 0xfe, 0x02, 0x58]), 0);
    expect(
      role!.token,
      HeapPropertyToken.smallValueProperty,
      reason: 'count==1 makes 10 19 a genuine single-item property token',
    );
    expect(role.value, 0x0258);
    expect(role.length, 6);
    expect(
      decodeHeapPropertyToken(b([0x10, 0x19, 0x02, 0xfe, 0x00, 0x50, 0xfd, 0x00, 0x2a]), 0),
      isNull,
      reason: 'the 10 19 02 fe <kind> fd <oid> object header is not a property token',
    );
    final esc = decodeHeapPropertyToken(b([0x10, 0x19, 0x01, 0xfd, 0x80, 0x00, 0x00, 0x01, 0x36, 0xde]), 0);
    expect(esc!.value, 0x000136de, reason: 'FD 7-byte escape (fd 80 00 <u32>): value is the u32, not the 0x8000 bytes');
    expect(esc.length, 10);
    final style = decodeHeapPropertyToken(b([0x10, 0xe1, 0x01, 0xfb, 0x00, 0x07]), 0);
    expect(style!.token, HeapPropertyToken.controlStyleCount, reason: 'tagged FB u16 sub-list');
    expect(style.value, 7);
    final slot = decodeHeapPropertyToken(b([0x11, 0x10, 0x44, 0x89]), 0);
    expect(slot!.token, HeapPropertyToken.viewportSlot1);
    expect(slot.value, isNull, reason: 'bare 2-byte selector, no inline value');
    expect(slot.length, 2);
    expect(
      decodeHeapPropertyToken(b([0x10, 0x77, 0x01, 0xfe, 0, 0]), 0),
      isNull,
      reason: 'an uncatalogued (op,subop) is not a property token',
    );
    expect(isTypeDescriptorToken(0x04), isTrue, reason: '0x04 fragments are type-descriptor grammar, not properties');
    expect(isTypeDescriptorToken(0x10), isFalse);
  });

  test('HeapRefKind: subop maps to relationship; 0x53 is a literal, not a ref', () {
    expect(HeapRefKind.fromSubop(0x19), HeapRefKind.childRef);
    expect(HeapRefKind.fromSubop(0x4f), HeapRefKind.memberRef);
    expect(HeapRefKind.fromSubop(0x1f), HeapRefKind.ownerRef);
    expect(HeapRefKind.fromSubop(0x50), HeapRefKind.siblingRef);
    expect(
      HeapRefKind.fromSubop(0x34),
      HeapRefKind.objectRef,
      reason: 'a resolving but unnamed subop falls back to the generic objectRef',
    );
    expect(HeapRefKind.fromSubop(0x53), HeapRefKind.literal);
  });

  test('decodeHeapRef decodes typed refs and rejects the 0x53 literal', () {
    final m = decodeHeapRef(b([0x14, 0x4f, 0x01, 0xfd, 0x00, 0x2a]), 0)!;
    expect(m.kind, HeapRefKind.memberRef);
    expect(m.targetOid, 0x2a);
    expect(m.length, 6);
    expect(
      decodeHeapRef(b([0x14, 0x53, 0x01, 0xfd, 0x00, 0x09]), 0),
      isNull,
      reason: '14 53 frames as a record but is a literal value, not a reference',
    );
    expect(decodeHeapRef(b([0x10, 0x19, 0x02, 0xfe, 0, 0]), 0), isNull, reason: 'not a 14-family record');
  });

  test('walkHeapBody and recordSkip are total over arbitrary bytes', () {
    for (var seed = 0; seed < 1500; seed++) {
      final len = (seed * 7) % 200;
      final body = Uint8List.fromList([for (var j = 0; j < len; j++) (seed * 13 + j * 31) & 0xff]);
      expect(() {
        final w = walkHeapBody(body);
        expect(w.coverage, inInclusiveRange(0.0, 1.0));
        for (final s in w.spans) {
          expect(s.offset + s.length, lessThanOrEqualTo(body.length));
        }
      }, returnsNormally);
    }
  });
}
