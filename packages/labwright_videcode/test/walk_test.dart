import 'dart:typed_data';

import 'package:labwright_videcode/labwright_videcode.dart';
import 'package:test/test.dart';

void main() {
  test('recordSkip frames the known record families', () {
    Uint8List b(List<int> x) => Uint8List.fromList(x);
    expect(recordSkip(b([0xc4, 0x2d, 0x08, 0, 0, 0, 0, 0, 0, 0, 0]), 0), 11); // C4 u8
    expect(recordSkip(b([0xc4, 0x19, 0xff, 0x01, 0x02, ...List.filled(258, 0)]), 0), 263); // C4 FF u16
    expect(recordSkip(b([0x84, 1, 2, 3, 4, 5]), 0), 6); // color
    expect(recordSkip(b([0x10, 0x18, 0x02, 0xfe, 0, 0, 0, 0, 0]), 0), 9); // typed list fe, count 2
    expect(recordSkip(b([0x10, 0xe1, 0x01, 0xfb, 0, 0]), 0), 6); // typed list fb, count 1
    expect(recordSkip(b([0x14, 0x19, 0x01, 0xfd, 0, 0]), 0), 6); // 14 family
    expect(recordSkip(b([0x08, 0x55]), 0), 2);
    expect(recordSkip(b([0x24, 0, 0]), 0), 3);
    expect(recordSkip(b([0x44, 0, 0, 0]), 0), 4);
    expect(recordSkip(b([0x64, 0xcb, 0, 0, 0]), 0), 5);
    expect(recordSkip(b([0x64, 0xcb, 0x26]), 0), 3);
    expect(recordSkip(b([0x86, 0x20, 0, 0, 0, 0]), 0), 6); // attribute nibble 8x
    expect(recordSkip(b([0xe4, 0x21]), 0), 2); // attribute nibble Ex
    expect(recordSkip(b([0x99, 0, 0]), 0), isNull); // unknown
    // 0x25 is a fixed 3-byte record (the `25 2d` form is NOT a counted list).
    expect(recordSkip(b([0x25, 0x2d, 0x03, 0x08, 0x19]), 0), 3);
    // FD value-escape inside a typed list: item `fd 80 00 <u32>` is 7 bytes.
    expect(recordSkip(b([0x10, 0x19, 0x01, 0xfd, 0x80, 0x00, 0x00, 0x01, 0x36, 0xde]), 0), 10);
    // 0xC6 extended-length record (C4-style FF -> u16 escape).
    expect(recordSkip(b([0xc6, 0x5a, 0xff, 0x00, 0x04, 1, 2, 3, 4]), 0), 9);
  });

  test('walkHeapBody walks a well-formed body to exact EOF', () {
    // [u32 contentLen][records...]; contentLen value is ignored by the walker.
    final records = <int>[
      0x84, 1, 2, 3, 4, 5, // color (6)
      0xc4, 0x2d, 0x08, 0, 0, 0, 0, 0, 0, 0, 0, // bounds (11)
      0x08, 0x55, // node (2)
      0x14, 0x19, 0x01, 0xfd, 0x00, 0x10, // 14 family (6)
    ];
    final body = Uint8List.fromList([0, 0, 0, records.length, ...records]);
    final w = walkHeapBody(body);
    expect(w.complete, isTrue);
    expect(w.coverage, 1.0);
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
