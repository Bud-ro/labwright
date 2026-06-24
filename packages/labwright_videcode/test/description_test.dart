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
  test('C4 19 record returns its RAW description text (no length prefix — the corpus form)', () {
    // The real corpus C4 19 payload is raw text from byte 0 (verified by review).
    final text = 'The <B>error</B> describes the source'.codeUnits;
    final heap = <int>[0xc4, 0x19, text.length, ...text];
    final rec = heapC4RecordsFromDecoded([bdex(heap)]).single;
    expect(rec.descriptionText, 'The <B>error</B> describes the source'); // leading 'T' preserved
  });

  test('non-C4-19 records have null descriptionText', () {
    final heap = <int>[0xc4, 0x22, 0x03, 0x41, 0x42, 0x43];
    expect(heapC4RecordsFromDecoded([bdex(heap)]).single.descriptionText, isNull);
  });

  test('ViModel.descriptions collects and dedupes raw help text', () {
    List<int> desc(String s) => [0xc4, 0x19, s.length, ...s.codeUnits]; // raw text payload
    final heap = <int>[
      ...desc('Cursors are draggable'),
      ...desc('Cursors are draggable'), // dup
      ...desc('Click to add a plot point'),
    ];
    final model = buildViModelFromDecoded([bdex(heap)]);
    expect(model.descriptions, <String>['Cursors are draggable', 'Click to add a plot point']);
  });

  test('descriptionText is total over arbitrary bytes', () {
    final heap = Uint8List.fromList([for (var i = 0; i < 200; i++) (i * 13 + 0x19) & 0xff]);
    expect(() => buildViModelFromDecoded([bdex(heap)]).descriptions, returnsNormally);
  });
}
