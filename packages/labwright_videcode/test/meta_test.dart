import 'dart:math';
import 'dart:typed_data';

import 'package:labwright_videcode/labwright_videcode.dart';
import 'package:labwright_viparse/labwright_viparse.dart';
import 'package:test/test.dart';

ViSection versSection(List<int> bytes) =>
    ViSection(tag: 'vers', index: 0, dataOffset: 0, bytes: Uint8List.fromList(bytes));

List<int> pascal(String s) => [s.length, ...s.codeUnits];

void main() {
  test('decodes LabVIEW version and VIDS title from a vers section', () {
    final bytes = <int>[
      0xAB, // noise
      ...pascal('10.0'), // version pascal string
      0x00,
      ...'VIDS'.codeUnits, ...pascal('My Example.vi'), // VIDS title record
    ];
    final info = versionFromSections([versSection(bytes)]);
    expect(info.version, '10.0');
    expect(info.title, 'My Example.vi');
  });

  test('version is null when no version-like string is present', () {
    final info = versionFromSections([versSection([...pascal('not a version')])]);
    expect(info.version, isNull);
  });

  test('heapStringsFromDecoded pulls wordy labels, dedups, drops numeric noise', () {
    final heap = <int>[
      ...pascal('Conversion time'),
      0x02, 0x00, 0x01, // noise that is not a valid printable run
      ...pascal('error out'),
      ...pascal('error out'), // duplicate
      ...pascal('1234'), // numeric -> filtered by wordiness
    ];
    final decoded = DecodedSection(
      section: ViSection(tag: 'BDEx', index: 0, dataOffset: 0, bytes: Uint8List.fromList(heap)),
      bytes: Uint8List.fromList(heap),
      wasCompressed: false,
    );
    final strings = heapStringsFromDecoded([decoded]);
    expect(strings, contains('Conversion time'));
    expect(strings, contains('error out'));
    expect(strings.where((s) => s == 'error out').length, 1); // deduped
    expect(strings, isNot(contains('1234'))); // numeric noise dropped
  });

  test('decodeVersion and extractHeapStrings are total over arbitrary bytes', () {
    final rng = Random(8);
    for (var i = 0; i < 2000; i++) {
      final n = rng.nextInt(200);
      final b = Uint8List.fromList([for (var j = 0; j < n; j++) rng.nextInt(256)]);
      try {
        decodeVersion(b);
        extractHeapStrings(b);
      } on ViFormatException {
        // acceptable
      } catch (e) {
        fail('leaked ${e.runtimeType}: $e');
      }
    }
  });
}
