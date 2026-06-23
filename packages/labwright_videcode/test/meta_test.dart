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

  test('heapStringsFromDecoded extracts contiguous string runs, drops isolated + noise', () {
    // A contiguous Pascal-string table (a run), then noise, then an isolated
    // coincidental string (run length 1, must be dropped).
    final heap = <int>[
      ...pascal('Conversion time'),
      ...pascal('error out'),
      ...pascal('error out'), // duplicate within the run
      ...pascal('Range Volts'),
      ...pascal('1234'), // in-run but numeric -> dropped by wordiness
      0xff, 0xfe, 0x00, // breaks the run
      0x99, // junk length byte
      ...pascal('Lonely'), // single string, not part of a >=2 run -> dropped
      0x00, 0x00,
    ];
    final decoded = DecodedSection(
      section: ViSection(tag: 'BDEx', index: 0, dataOffset: 0, bytes: Uint8List.fromList(heap)),
      bytes: Uint8List.fromList(heap),
      wasCompressed: false,
    );
    final strings = heapStringsFromDecoded([decoded]);
    expect(strings, containsAll(<String>['Conversion time', 'error out', 'Range Volts']));
    expect(strings.where((s) => s == 'error out').length, 1); // deduped
    expect(strings, isNot(contains('1234'))); // numeric noise dropped
    expect(strings, isNot(contains('Lonely'))); // isolated (run length 1) dropped
  });

  test('heapStringTablesFromDecoded groups runs and records section + offset', () {
    final lead = <int>[0xff, 0xfe, 0x00]; // 3 bytes of non-string preamble
    final heap = <int>[
      ...lead,
      ...pascal('Range Volts'), // run A starts at offset 3
      ...pascal('error out'),
      0x00, 0x00, // break
      ...pascal('Channel'), // run B
      ...pascal('Sample Rate'),
    ];
    final decoded = DecodedSection(
      section: ViSection(tag: 'BDEx', index: 0, dataOffset: 0, bytes: Uint8List.fromList(heap)),
      bytes: Uint8List.fromList(heap),
      wasCompressed: false,
    );
    final tables = heapStringTablesFromDecoded([decoded]);
    expect(tables.length, 2);
    expect(tables.first.sectionTag, 'BDEx');
    expect(tables.first.offset, lead.length); // run A starts right after preamble
    expect(tables.first.strings, <String>['Range Volts', 'error out']);
    expect(tables[1].strings, <String>['Channel', 'Sample Rate']);
    // Flat view is exactly the tables flattened + globally deduped.
    expect(heapStringsFromDecoded([decoded]),
        <String>['Range Volts', 'error out', 'Channel', 'Sample Rate']);
  });

  test('heapStringTablesFromDecoded frames a 0x2E <len> opcode table exactly', () {
    final body = <int>[...pascal('Sine'), ...pascal('Square'), ...pascal('Ramp Up')];
    final heap = <int>[
      0xaa, 0xbb, // leading noise
      0x2e, body.length, ...body, // 0x2E <u8 len> <packed pascals>
      0x00, // break
    ];
    final decoded = DecodedSection(
      section: ViSection(tag: 'BDEx', index: 0, dataOffset: 0, bytes: Uint8List.fromList(heap)),
      bytes: Uint8List.fromList(heap),
      wasCompressed: false,
    );
    final tables = heapStringTablesFromDecoded([decoded]);
    expect(tables.length, 1);
    expect(tables.first.framed, isTrue);
    expect(tables.first.offset, 4); // after 0xaa 0xbb 0x2e <len>
    expect(tables.first.strings, <String>['Sine', 'Square', 'Ramp Up']);
  });

  test('heapStringTablesFromDecoded frames a 0x2E <u16 len> big table', () {
    // >255 bytes -> u16 length. Build ~30 strings.
    final entries = <int>[];
    final expected = <String>[];
    for (var k = 0; k < 30; k++) {
      final s = 'Channel Number $k';
      expected.add(s);
      entries.addAll(pascal(s));
    }
    expect(entries.length > 255, isTrue);
    final heap = <int>[
      0x2e, (entries.length >> 8) & 0xff, entries.length & 0xff, ...entries,
    ];
    final decoded = DecodedSection(
      section: ViSection(tag: 'BDEx', index: 0, dataOffset: 0, bytes: Uint8List.fromList(heap)),
      bytes: Uint8List.fromList(heap),
      wasCompressed: false,
    );
    final tables = heapStringTablesFromDecoded([decoded]);
    expect(tables.length, 1);
    expect(tables.first.framed, isTrue);
    expect(tables.first.offset, 3); // after 0x2e + u16 len
    expect(tables.first.strings, expected);
  });

  test('heapStringTables is total over arbitrary bytes', () {
    final rng = Random(11);
    for (var i = 0; i < 2000; i++) {
      final n = rng.nextInt(200);
      final b = Uint8List.fromList([for (var j = 0; j < n; j++) rng.nextInt(256)]);
      try {
        for (final t in heapStringTables(b)) {
          expect(t.offset, inInclusiveRange(0, b.length));
          expect(t.strings, isNotEmpty);
        }
      } on ViFormatException {
        // acceptable
      } catch (e) {
        fail('leaked ${e.runtimeType}: $e');
      }
    }
  });

  test('componentsFromDecoded summarizes per-block sizes, largest first', () {
    DecodedSection d(String tag, int rawLen, int decLen, bool comp) => DecodedSection(
          section: ViSection(tag: tag, index: 0, dataOffset: 0, bytes: Uint8List(rawLen)),
          bytes: Uint8List(decLen),
          wasCompressed: comp,
        );
    final comps = componentsFromDecoded([
      d('FPHb', 100, 100, false),
      d('BDEx', 50, 5000, true), // compressed -> big decompressed
      d('BDEx', 20, 200, true), // second BDEx section
    ]);
    expect(comps.first.tag, 'BDEx'); // largest decompressed first
    final bd = comps.firstWhere((c) => c.tag == 'BDEx');
    expect(bd.sectionCount, 2);
    expect(bd.decompressedBytes, 5200);
    expect(bd.rawBytes, 70);
    expect(bd.compressed, isTrue);
    expect(comps.firstWhere((c) => c.tag == 'FPHb').compressed, isFalse);
  });

  test('decodeVersion, extractHeapStrings, blockComponents are total over arbitrary bytes', () {
    final rng = Random(8);
    for (var i = 0; i < 2000; i++) {
      final n = rng.nextInt(200);
      final b = Uint8List.fromList([for (var j = 0; j < n; j++) rng.nextInt(256)]);
      try {
        decodeVersion(b);
        extractHeapStrings(b);
        blockComponents(b);
      } on ViFormatException {
        // acceptable
      } catch (e) {
        fail('leaked ${e.runtimeType}: $e');
      }
    }
  });
}
