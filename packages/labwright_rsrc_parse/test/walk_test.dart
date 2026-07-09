import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'test_util.dart';

void main() {
  test('recordSkip frames every known record family (null for an unknown lead)', () {
    final rows = <(List<int>, int?)>[
      (hx('c4 2d 08 0000 0000 0000 0000'), 11),
      ([0xc4, 0x19, 0xff, 0x01, 0x02, ...List.filled(258, 0)], 263),
      (hx('84 01 02 03 04 05'), 6),
      (hx('10 18 02 fe 0000 0000 00'), 9),
      (hx('10 e1 01 fb 0000'), 6),
      (hx('14 19 01 fd 0000'), 6),
      // FD value-escape (fd 80 00 <u32>) makes a 10-byte record (heap record-size desync fix)
      (hx('14 19 01 fd 8000 0000 846f'), 10),
      (hx('10 19 01 fd 8000 0001 36de'), 10),
      (hx('08 55'), 2),
      (hx('24 00 00'), 3),
      (hx('24 df 05'), 3),
      (hx('44 00 00 00'), 4),
      (hx('45 e7 02 08'), 4),
      (hx('64 cb 00 00 00'), 5),
      // 64 CB is a u24 objFlags leaf; the 3-byte special case was refuted by the EOF-balance probe
      (hx('64 cb 26 84 20'), 5),
      (hx('86 20 00 00 00 00'), 6),
      (hx('85 14 db 3d 11 75'), 6),
      (hx('e4 21'), 2),
      (hx('04 59'), 2),
      (hx('99 00 00'), null),
      // 0x25 is a fixed 3-byte record; the 25 2d form is NOT a counted list
      (hx('25 2d 03 08 19'), 3),
      (hx('c6 5a ff 0004 01020304'), 9),
      ([0xc6, 0x31, 0x05, ...'Scale'.codeUnits], 8),
    ];
    for (final (bytes, want) in rows) {
      expect(recordSkip(u8(bytes), 0), want, reason: bytes.map((x) => x.toRadixString(16)).join(' '));
    }
  });

  test('walkHeapBody walks a well-formed body to exact EOF and stops at an unknown opcode', () {
    final records = [
      ...hx('84 01 02 03 04 05'),
      ...hx('c4 2d 08 0000 0000 0000 0000'),
      ...hx('08 55'),
      ...hx('14 19 01 fd 0010'),
    ];
    final w = walkHeapBody(u8([0, 0, 0, records.length, ...records]));
    expect(w.complete, isTrue);
    expect(w.coverage, 1.0, reason: 'the leading [u32 contentLen] header value is ignored');
    expect(w.spans.map((s) => s.lead), [0x84, 0xc4, 0x08, 0x14]);
    expect(w.spans.firstWhere((s) => s.lead == 0xc4).isC4Record, isTrue);

    final stopped = walkHeapBody(u8([0, 0, 0, 4, ...hx('84 01 02 03 04 05'), 0x99, 0x00]));
    expect(stopped.complete, isFalse);
    expect(stopped.stoppedLead, 0x99);
    expect(stopped.spans.single.lead, 0x84);
  });

  test('HeapPropertyToken catalog: unique (op,subop) keys, round-trip via lookup', () {
    final seen = <int>{};
    for (final t in HeapPropertyToken.values) {
      expect(seen.add((t.op << 8) | t.subop), isTrue, reason: 'duplicate (op,subop) for ${t.tokenName}');
      expect(HeapPropertyToken.lookup(t.op, t.subop), t);
      expect(t.tokenName, isNotEmpty);
    }
    expect(HeapPropertyToken.lookup(0xff, 0xff), isNull);
  });

  test('decodeHeapPropertyToken decodes tagged-list values and bare selectors', () {
    final role = decodeHeapPropertyToken(hx('10 19 01 fe 0258'), 0)!;
    expect(role.token, HeapPropertyToken.smallValueProperty, reason: 'count==1 -> a single-item property token');
    expect((role.value, role.length), (0x0258, 6));
    expect(
      decodeHeapPropertyToken(hx('10 19 02 fe 0050 fd 002a'), 0),
      isNull,
      reason: 'the 10 19 02 fe <kind> fd <oid> object header is not a property token',
    );
    final esc = decodeHeapPropertyToken(hx('10 19 01 fd 8000 0001 36de'), 0)!;
    expect((esc.value, esc.length), (0x000136de, 10), reason: 'FD 7-byte escape: the value is the u32');
    final style = decodeHeapPropertyToken(hx('10 e1 01 fb 0007'), 0)!;
    expect((style.token, style.value), (HeapPropertyToken.controlStyleCount, 7), reason: 'tagged FB u16 sub-list');
    final slot = decodeHeapPropertyToken(hx('11 10 44 89'), 0)!;
    expect((slot.token, slot.value, slot.length), (HeapPropertyToken.viewportSlot1, null, 2), reason: 'bare selector');
    expect(decodeHeapPropertyToken(hx('10 77 01 fe 0000'), 0), isNull, reason: 'uncatalogued (op,subop)');
    expect(isTypeDescriptorToken(0x04), isTrue, reason: '0x04 leads are zero-size false-valued leaf tags');
    expect(isTypeDescriptorToken(0x10), isFalse);
  });

  test('HeapRefKind maps raw tag ids to relationships; decodeHeapRef decodes the 14..17-lead uid-leaf family', () {
    const kinds = <(int, HeapRefKind)>[
      (0x019, HeapRefKind.childRef),
      (0x04f, HeapRefKind.dcoRef),
      (0x01f, HeapRefKind.ownerRef),
      (0x050, HeapRefKind.dcoAggRef),
      (0x053, HeapRefKind.ddoRef),
      (0x113, HeapRefKind.srcDCORef),
      (0x28a, HeapRefKind.attachmentRef),
      (0x034, HeapRefKind.objectRef), // resolving-but-unnamed raw tag falls back to the generic objectRef
    ];
    for (final (raw, kind) in kinds) {
      expect(HeapRefKind.fromRaw(raw), kind, reason: '0x${raw.toRadixString(16)}');
    }
    final m = decodeHeapRef(hx('14 4f 01 fd 002a'), 0)!;
    expect((m.kind, m.targetOid, m.length), (HeapRefKind.dcoRef, 0x2a, 6));
    expect(decodeHeapRef(hx('14 53 01 fd 0009'), 0)!.kind, HeapRefKind.ddoRef, reason: 'cross-heap display ref');
    expect(decodeHeapRef(hx('16 8a 01 fd 0007'), 0)!.kind, HeapRefKind.attachmentRef);
    expect(decodeHeapRef(hx('14 53 01 fe 0009'), 0), isNull, reason: 'fe carries a class-code literal, not an oid');
    // The 32-bit oid escape `fd 80 00 <u32>` decodes to a 10-byte ref carrying
    // the full u32 oid (0x8000+ ids that would overflow the compact u16 slot).
    final esc = decodeHeapRef(hx('15 77 01 fd 8000 0000 0100'), 0)!;
    expect((esc.kind, esc.targetOid, esc.length), (HeapRefKind.fromRaw(0x177), 0x100, 10));
    expect(decodeHeapRef(hx('10 19 02 fe 0000'), 0), isNull, reason: 'not a leaf-with-attrs record');
  });

  test('walkHeapBody and recordSkip are total over arbitrary bytes', () {
    for (var seed = 0; seed < 1500; seed++) {
      final len = (seed * 7) % 200;
      final body = Uint8List.fromList([for (var j = 0; j < len; j++) (seed * 13 + j * 31) & 0xff]);
      final w = walkHeapBody(body);
      expect(w.coverage, inInclusiveRange(0.0, 1.0));
      for (final s in w.spans) {
        expect(s.offset + s.length, lessThanOrEqualTo(body.length));
      }
    }
  });
}
