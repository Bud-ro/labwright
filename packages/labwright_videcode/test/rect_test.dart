import 'dart:typed_data';

import 'package:labwright_videcode/labwright_videcode.dart';
import 'package:labwright_viparse/labwright_viparse.dart';
import 'package:test/test.dart';

DecodedSection bdex(List<int> bytes) => DecodedSection(
      section: ViSection(tag: 'BDEx', index: 0, dataOffset: 0, bytes: Uint8List.fromList(bytes)),
      bytes: Uint8List.fromList(bytes),
      wasCompressed: false,
    );

void main() {
  test('C4 2D record decodes to an object-bounds rectangle (top,left,bottom,right)', () {
    // top=53 left=581 bottom=91 right=696  -> 0x0035 0x0245 0x005b 0x02b8
    final heap = <int>[0xc4, 0x2d, 0x08, 0x00, 0x35, 0x02, 0x45, 0x00, 0x5b, 0x02, 0xb8];
    final rec = heapC4RecordsFromDecoded([bdex(heap)]).single;
    final r = rec.bounds!;
    expect([r.top, r.left, r.bottom, r.right], [53, 581, 91, 696]);
    expect(r.height, 38);
    expect(r.width, 115);
    expect(r.isValid, isTrue);
  });

  test('negative coordinates decode as signed 16-bit', () {
    // top=-2 (0xFFFE) left=-1 (0xFFFF) bottom=10 right=20
    final heap = <int>[0xc4, 0x2d, 0x08, 0xff, 0xfe, 0xff, 0xff, 0x00, 0x0a, 0x00, 0x14];
    final r = heapC4RecordsFromDecoded([bdex(heap)]).single.bounds!;
    expect([r.top, r.left, r.bottom, r.right], [-2, -1, 10, 20]);
    expect(r.height, 12);
    expect(r.width, 21);
  });

  test('C4 1F record decodes to an origin-anchored size rectangle', () {
    // (0,0,12,12) size; bounds must be null (only 2D), sizeRect set.
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
      0xc4, 0x1f, 0x08, 0, 0, 0, 0, 0, 0, 0, 0, // C4 1F, not bounds
      0xc4, 0x2d, 0x02, 0, 0, // C4 2D but wrong payload length
    ];
    final recs = heapC4RecordsFromDecoded([bdex(heap)]);
    expect(recs.every((r) => r.bounds == null), isTrue);
  });

  test('ViModel.objectBounds aggregates all C4 2D rectangles', () {
    final heap = <int>[
      0xc4, 0x2d, 0x08, 0x00, 0x00, 0x00, 0x00, 0x03, 0x37, 0x06, 0x95, // 0,0,823,1685
      0xc4, 0x2d, 0x08, 0x00, 0x35, 0x02, 0x45, 0x00, 0x5b, 0x02, 0xb8, // 53,581,91,696
    ];
    final model = buildViModelFromDecoded([bdex(heap)]);
    expect(model.objectBounds.length, 2);
    expect(model.objectBounds.first.width, 1685);
    expect(model.objectBounds[1].height, 38);
  });
}
