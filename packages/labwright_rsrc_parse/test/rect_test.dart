import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

DecodedSection bdex(List<int> bytes) => DecodedSection(
      section: ViSection(tag: 'BDEx', index: 0, dataOffset: 0, bytes: Uint8List.fromList(bytes)),
      bytes: Uint8List.fromList(bytes),
      wasCompressed: false,
    );

void main() {
  test('C4 2D record decodes to an object-bounds rectangle (top,left,bottom,right)', () {
    final heap = <int>[0xc4, 0x2d, 0x08, 0x00, 0x35, 0x02, 0x45, 0x00, 0x5b, 0x02, 0xb8];
    final rec = heapC4RecordsFromDecoded([bdex(heap)]).single;
    final r = rec.bounds!;
    expect([r.top, r.left, r.bottom, r.right], [53, 581, 91, 696]);
    expect(r.height, 38);
    expect(r.width, 115);
    expect(r.isValid, isTrue);
  });

  test('negative coordinates decode as signed 16-bit', () {
    final heap = <int>[0xc4, 0x2d, 0x08, 0xff, 0xfe, 0xff, 0xff, 0x00, 0x0a, 0x00, 0x14];
    final r = heapC4RecordsFromDecoded([bdex(heap)]).single.bounds!;
    expect([r.top, r.left, r.bottom, r.right], [-2, -1, 10, 20]);
    expect(r.height, 12);
    expect(r.width, 21);
  });

  test('C4 1F record decodes to an origin-anchored size rectangle', () {
    final heap = <int>[0xc4, 0x1f, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0c, 0x00, 0x0c];
    final rec = heapC4RecordsFromDecoded([bdex(heap)]).single;
    expect(rec.bounds, isNull);
    final s = rec.sizeRect!;
    expect([s.top, s.left, s.bottom, s.right], [0, 0, 12, 12]);
    expect(s.width, 12);
    expect(s.height, 12);
  });

  test('non-C4-2D records have null bounds', () {
    final heap = <int>[
      0xc4, 0x1f, 0x08, 0, 0, 0, 0, 0, 0, 0, 0,
      0xc4, 0x2d, 0x02, 0, 0,
    ];
    final recs = heapC4RecordsFromDecoded([bdex(heap)]);
    expect(recs.every((r) => r.bounds == null), isTrue,
        reason: 'C4 1F is not a bounds record, and a C4 2D with a non-8 payload is rejected');
  });

  test('ViModel.objectBounds aggregates all C4 2D rectangles', () {
    final heap = <int>[
      0xc4, 0x2d, 0x08, 0x00, 0x00, 0x00, 0x00, 0x03, 0x37, 0x06, 0x95,
      0xc4, 0x2d, 0x08, 0x00, 0x35, 0x02, 0x45, 0x00, 0x5b, 0x02, 0xb8,
    ];
    final model = buildViModelFromDecoded([bdex(heap)]);
    expect(model.objectBounds.length, 2);
    expect(model.objectBounds.first.width, 1685);
    expect(model.objectBounds[1].height, 38);
  });
}
