import 'dart:typed_data';

import 'package:labwright_vi_parse/labwright_vi_parse.dart';
import 'package:test/test.dart';

List<int> pascal(String s) => [s.length, ...s.codeUnits];

DecodedSection bdex(List<int> bytes) => DecodedSection(
      section: ViSection(tag: 'BDEx', index: 0, dataOffset: 0, bytes: Uint8List.fromList(bytes)),
      bytes: Uint8List.fromList(bytes),
      wasCompressed: false,
    );

void main() {
  test('pairs a C4 2D bounds immediately followed by a C4 2E label into a ViObject', () {
    final table = <int>[...pascal('Sine'), ...pascal('Square')];
    final heap = <int>[
      0xc4, 0x2d, 0x08, 0x00, 0x35, 0x02, 0x45, 0x00, 0x5b, 0x02, 0xb8, // bounds 53,581,91,696
      0xc4, 0x2e, table.length, ...table, // label table immediately after
    ];
    final model = buildViModelFromDecoded([bdex(heap)]);
    expect(model.objects.length, 1);
    final o = model.objects.single;
    expect(o.name, 'Sine');
    expect(o.labels, <String>['Sine', 'Square']);
    expect([o.bounds.top, o.bounds.left, o.bounds.bottom, o.bounds.right], [53, 581, 91, 696]);
  });

  test('pairs a C4 2D bounds with a following C4 22 caption into a named object', () {
    final heap = <int>[
      0xc4, 0x2d, 0x08, 0x00, 0x0a, 0x00, 0x14, 0x00, 0x28, 0x00, 0x64, // bounds 10,20,40,100
      0xc4, 0x22, 13, ...'Trigger Source'.codeUnits.take(13), // caption immediately after
    ];
    final o = buildViModelFromDecoded([bdex(heap)]).objects.single;
    expect(o.caption, 'Trigger Sourc'); // 13 chars
    expect(o.name, 'Trigger Sourc');
    expect(o.labels, isEmpty);
    expect(o.bounds.left, 20);
  });

  test('a bounds with no following label is not assembled into an object', () {
    final heap = <int>[
      0xc4, 0x2d, 0x08, 0, 0, 0, 0, 0, 10, 0, 10, // lone bounds
      0xc4, 0x1f, 0x08, 0, 0, 0, 0, 0, 12, 0, 12, // a size record, not a label
    ];
    final model = buildViModelFromDecoded([bdex(heap)]);
    expect(model.objects, isEmpty);
    expect(model.objectBounds.length, 1); // bounds still surfaced
  });

  test('a label far from any bounds (> maxRecordGap) is not paired', () {
    final table = <int>[...pascal('Late'), ...pascal('Label')];
    final filler = <int>[for (var i = 0; i < 5; i++) ...[0xc4, 0x22, 0x01, 0x00]]; // 5 other records
    final heap = <int>[
      0xc4, 0x2d, 0x08, 0, 0, 0, 0, 0, 10, 0, 10, // bounds
      ...filler,
      0xc4, 0x2e, table.length, ...table, // label, > 3 records later
    ];
    final objs = buildViModelFromDecoded([bdex(heap)]).objects;
    expect(objs, isEmpty);
  });

  test('objects assembly is total over arbitrary bytes', () {
    final heap = Uint8List.fromList([for (var i = 0; i < 300; i++) (i * 7 + 0xc4) & 0xff]);
    expect(() => buildViModelFromDecoded([bdex(heap)]).objects, returnsNormally);
  });
}
