import 'dart:math';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

ViSection versSection(List<int> bytes) =>
    ViSection(tag: 'vers', index: 0, dataOffset: 0, bytes: Uint8List.fromList(bytes));

List<int> pascal(String s) => [s.length, ...s.codeUnits];

DecodedSection bdex(List<int> heap) => DecodedSection(
      section: ViSection(tag: 'BDEx', index: 0, dataOffset: 0, bytes: Uint8List.fromList(heap)),
      bytes: Uint8List.fromList(heap),
      wasCompressed: false,
    );

void expectTotalOverRandomBytes(int seed, void Function(Uint8List) probe) {
  final rng = Random(seed);
  for (var i = 0; i < 2000; i++) {
    final n = rng.nextInt(200);
    final b = Uint8List.fromList([for (var j = 0; j < n; j++) rng.nextInt(256)]);
    try {
      probe(b);
    } on ViFormatException {
      // acceptable
    } catch (e) {
      fail('leaked ${e.runtimeType}: $e');
    }
  }
}

void main() {
  test('decodes LabVIEW version and VIDS title from a vers section', () {
    final bytes = <int>[
      0xAB,
      ...pascal('10.0'),
      0x00,
      ...'VIDS'.codeUnits, ...pascal('My Example.vi'),
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
    final heap = <int>[
      ...pascal('Conversion time'),
      ...pascal('error out'),
      ...pascal('error out'),
      ...pascal('Range Volts'),
      ...pascal('1234'),
      0xff, 0xfe, 0x00,
      0x99,
      ...pascal('Lonely'),
      0x00, 0x00,
    ];
    final decoded = bdex(heap);
    final strings = heapStringsFromDecoded([decoded]);
    expect(strings, containsAll(<String>['Conversion time', 'error out', 'Range Volts']));
    expect(strings.where((s) => s == 'error out').length, 1);
    expect(strings, isNot(contains('1234')), reason: 'purely-numeric strings carry no ASCII letter and are dropped');
    expect(strings, isNot(contains('Lonely')), reason: 'a run of fewer than minRun (2) strings is dropped as coincidental');
  });

  test('heapStringTablesFromDecoded groups runs and records section + offset', () {
    final lead = <int>[0xff, 0xfe, 0x00];
    final heap = <int>[
      ...lead,
      ...pascal('Range Volts'),
      ...pascal('error out'),
      0x00, 0x00,
      ...pascal('Channel'),
      ...pascal('Sample Rate'),
    ];
    final decoded = bdex(heap);
    final tables = heapStringTablesFromDecoded([decoded]);
    expect(tables.length, 2);
    expect(tables.first.sectionTag, 'BDEx');
    expect(tables.first.offset, lead.length);
    expect(tables.first.strings, <String>['Range Volts', 'error out']);
    expect(tables[1].strings, <String>['Channel', 'Sample Rate']);
    expect(heapStringsFromDecoded([decoded]),
        <String>['Range Volts', 'error out', 'Channel', 'Sample Rate']);
  });

  test('heapStringTablesFromDecoded frames a C4 2E <len> opcode table exactly', () {
    final body = <int>[...pascal('Sine'), ...pascal('Square'), ...pascal('Ramp Up')];
    final heap = <int>[
      0xaa, 0xbb,
      0xc4, 0x2e, body.length, ...body,
      0x00,
    ];
    final decoded = bdex(heap);
    final tables = heapStringTablesFromDecoded([decoded]);
    expect(tables.length, 1);
    expect(tables.first.framed, isTrue);
    expect(tables.first.offset, 5, reason: 'payload starts after 2 noise bytes + the C4 2E <u8 len> header');
    expect(tables.first.strings, <String>['Sine', 'Square', 'Ramp Up']);
  });

  test('a bare 0x2E without the C4 prefix is NOT framed (rejects stray dots)', () {
    final body = <int>[...pascal('Sine'), ...pascal('Square')];
    final heap = <int>[0x2e, body.length, ...body];
    final decoded = bdex(heap);
    final tables = heapStringTablesFromDecoded([decoded]);
    expect(tables.every((t) => !t.framed), isTrue,
        reason: '0x2E is ASCII "." and is recovered only via the unframed heuristic, never as a framed table opcode');
  });

  test('heapStringTablesFromDecoded frames a C4 2E <u16 len> big table', () {
    final entries = <int>[];
    final expected = <String>[];
    for (var k = 0; k < 30; k++) {
      final s = 'Channel Number $k';
      expected.add(s);
      entries.addAll(pascal(s));
    }
    expect(entries.length > 255, isTrue);
    final heap = <int>[
      0xc4, 0x2e, 0xff, (entries.length >> 8) & 0xff, entries.length & 0xff, ...entries,
    ];
    final decoded = bdex(heap);
    final tables = heapStringTablesFromDecoded([decoded]);
    expect(tables.length, 1);
    expect(tables.first.framed, isTrue);
    expect(tables.first.offset, 5,
        reason: 'payload starts after the C4 2E FF <u16 len> extended-length header (5 bytes)');
    expect(tables.first.strings, expected);
  });

  test('heapStringTables is total over arbitrary bytes', () {
    expectTotalOverRandomBytes(11, (b) {
      for (final t in heapStringTables(b)) {
        expect(t.offset, inInclusiveRange(0, b.length));
        expect(t.strings, isNotEmpty);
      }
    });
  });

  test('componentsFromDecoded summarizes per-block sizes, largest first', () {
    DecodedSection d(String tag, int rawLen, int decLen, bool comp) => DecodedSection(
          section: ViSection(tag: tag, index: 0, dataOffset: 0, bytes: Uint8List(rawLen)),
          bytes: Uint8List(decLen),
          wasCompressed: comp,
        );
    final comps = componentsFromDecoded([
      d('FPHb', 100, 100, false),
      d('BDEx', 50, 5000, true),
      d('BDEx', 20, 200, true),
    ]);
    expect(comps.first.tag, 'BDEx');
    final bd = comps.firstWhere((c) => c.tag == 'BDEx');
    expect(bd.sectionCount, 2);
    expect(bd.decompressedBytes, 5200);
    expect(bd.rawBytes, 70);
    expect(bd.compressed, isTrue);
    expect(comps.firstWhere((c) => c.tag == 'FPHb').compressed, isFalse);
  });

  test('decodeVersion, extractHeapStrings, blockComponents are total over arbitrary bytes', () {
    expectTotalOverRandomBytes(8, (b) {
      decodeVersion(b);
      extractHeapStrings(b);
      blockComponents(b);
    });
  });
}
