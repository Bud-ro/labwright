import 'dart:typed_data';

import 'package:labwright_videcode/labwright_videcode.dart';
import 'package:labwright_viparse/labwright_viparse.dart';
import 'package:test/test.dart';

DecodedSection bdex(List<int> bytes) => DecodedSection(
      section: ViSection(tag: 'BDEx', index: 0, dataOffset: 0, bytes: Uint8List.fromList(bytes)),
      bytes: Uint8List.fromList(bytes),
      wasCompressed: false,
    );

List<int> c422(String s) => [0xc4, 0x22, s.length, ...s.codeUnits];

void main() {
  test('C4 22 record decodes payload as caption text', () {
    final rec = heapC4RecordsFromDecoded([bdex(c422('Amplitude (mV)'))]).single;
    expect(rec.text, 'Amplitude (mV)');
  });

  test('C4 22 with non-printable payload yields null text', () {
    final heap = <int>[0xc4, 0x22, 0x03, 0x41, 0x00, 0x42]; // contains a NUL
    expect(heapC4RecordsFromDecoded([bdex(heap)]).single.text, isNull);
  });

  test('non-C4-22 records have null text', () {
    final heap = <int>[0xc4, 0x2d, 0x08, 0, 0, 0, 0, 0, 10, 0, 10];
    expect(heapC4RecordsFromDecoded([bdex(heap)]).single.text, isNull);
  });

  test('ViModel.captions collects and dedupes C4 22 strings, order-preserving', () {
    final heap = <int>[
      ...c422('source'),
      ...c422('status'),
      ...c422('source'), // duplicate
      ...c422('error out'),
    ];
    final model = buildViModelFromDecoded([bdex(heap)]);
    expect(model.captions, <String>['source', 'status', 'error out']);
  });
}
