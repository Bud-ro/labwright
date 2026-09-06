import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'test_util.dart';

List<int> c4(int op, List<int> payload) => [0xc4, op, payload.length, ...payload];

List<int> pth0(String path) => [...'PTH0'.codeUnits, 0, 0, 0, 0, 0, 0, 0, 1, ...pascal(path)];

HeapRecord rec1(List<int> heap) => heapC4RecordsFromDecoded([dsec(heap)]).single;

void main() {
  group('HeapOpcode catalog', () {
    test('byte mapping, uniqueness, isDecoded flags', () {
      const rows = <(int, HeapOpcode, bool?)>[
        (0x2d, HeapOpcode.bounds, true),
        (0x1f, HeapOpcode.size, null),
        (0x2e, HeapOpcode.stringTable, null),
        (0x22, HeapOpcode.caption, null),
        (0x19, HeapOpcode.description, null),
        (0x5f, HeapOpcode.docBounds, true),
        (0x27, HeapOpcode.plotName, true),
        (0x74, HeapOpcode.formatString, true),
        (0x26, HeapOpcode.rect26, false),
        (0x23, HeapOpcode.rect23, false),
        (0x20, HeapOpcode.itemLabel, null),
        (0xc4, HeapOpcode.symbolName, null),
        (0xb6, HeapOpcode.methodName, true),
        (0x4a, HeapOpcode.typeBounds, null),
        (0xa4, HeapOpcode.path, null),
        (0x44, HeapOpcode.container44, null),
        (0x4c, HeapOpcode.dBounds, null),
      ];
      for (final (byte, op, decoded) in rows) {
        expect(HeapOpcode.fromByte(byte), op, reason: '0x${byte.toRadixString(16)}');
        if (decoded != null) expect(op.isDecoded, decoded, reason: op.name);
      }
      expect(HeapOpcode.fromByte(0xAB), HeapOpcode.unknown, reason: 'uncatalogued byte -> unknown');
      expect(HeapOpcode.unknown.isDecoded, isFalse);
      final bytes = HeapOpcode.values.where((o) => o != HeapOpcode.unknown).map((o) => o.byte).toList();
      expect(bytes.toSet().length, bytes.length, reason: 'every catalogued opcode has a unique byte');
    });
  });

  group('C4 record decode', () {
    test('string-shaped opcodes decode payload text; non-printable/other opcodes yield null text', () {
      const rows = <(int, HeapOpcode, String)>[
        (0x22, HeapOpcode.caption, 'Amplitude (mV)'),
        (0x27, HeapOpcode.plotName, 'Plot 0'),
        (0x74, HeapOpcode.formatString, '%020b'),
        (0x20, HeapOpcode.itemLabel, 'Line 0'),
        (0xc4, HeapOpcode.symbolName, 'ps2000aRunStreaming'),
        (0xb6, HeapOpcode.methodName, 'FP.Open'),
      ];
      for (final (op, kind, text) in rows) {
        final r = rec1(c4(op, text.codeUnits));
        expect((r.kind, r.text), (kind, text), reason: '0x${op.toRadixString(16)}');
        expect(r.kind.shape, HeapShape.string, reason: '0x${op.toRadixString(16)}');
      }
      expect(rec1([0xc4, 0x22, 0x03, 0x41, 0x00, 0x42]).text, isNull, reason: 'non-printable caption payload');
      expect(rec1(hx('c4 2d 08 0000 0000 000a 000a')).text, isNull, reason: 'a rect record is not text');
    });

    test('C4 2D decodes to signed object bounds; 1F to a size rect; 4C/4A rects via .rect only', () {
      final b = rec1(hx('c4 2d 08 0035 0245 005b 02b8')).bounds!;
      expect([b.top, b.left, b.bottom, b.right], [53, 581, 91, 696]);
      expect((b.height, b.width, b.isValid), (38, 115, true));
      final neg = rec1(hx('c4 2d 08 fffe ffff 000a 0014')).bounds!;
      expect([neg.top, neg.left, neg.bottom, neg.right], [-2, -1, 10, 20]);
      expect((neg.height, neg.width), (12, 21));

      final size = rec1(hx('c4 1f 08 0000 0000 000c 000c'));
      expect(size.bounds, isNull);
      final s = size.sizeRect!;
      expect([s.top, s.left, s.bottom, s.right], [0, 0, 12, 12]);

      final d = rec1(hx('c4 4c 08 ffdf ff8e 01d1 02ad'));
      expect((d.kind, d.kind.shape), (HeapOpcode.dBounds, HeapShape.rectangle));
      expect(d.bounds, isNull, reason: 'dBounds is a root-level rect, not the per-object bounds opcode');
      expect([d.rect!.top, d.rect!.left], [-33, -114]);

      final t = rec1(hx('c4 4a 08 0010 0020 0030 0040'));
      expect((t.kind, t.bounds), (HeapOpcode.typeBounds, null));
      expect([t.rect!.top, t.rect!.left, t.rect!.bottom, t.rect!.right], [16, 32, 48, 64]);

      final recs = heapC4RecordsFromDecoded([
        dsec([...hx('c4 1f 08 0000 0000 0000 0000'), ...hx('c4 2d 02 0000')]),
      ]);
      expect(recs.every((r) => r.bounds == null), isTrue, reason: 'a C4 2D with a non-8 payload is rejected');
    });

    test('HeapRect is a value: equal edges are one map key, any differing edge is another', () {
      const rect = HeapRect(top: 1, left: 2, bottom: 3, right: 4);
      final decoded = rec1(hx('c4 2d 08 0001 0002 0003 0004')).bounds!;
      expect(decoded, rect, reason: 'a rebuilt rect equals the one it was decoded from');
      expect(decoded.hashCode, rect.hashCode);
      const others = <HeapRect>[
        HeapRect(top: 9, left: 2, bottom: 3, right: 4),
        HeapRect(top: 1, left: 9, bottom: 3, right: 4),
        HeapRect(top: 1, left: 2, bottom: 9, right: 4),
        HeapRect(top: 1, left: 2, bottom: 3, right: 9),
      ];
      expect({rect, decoded, ...others}.length, 5);
    });

    test('C4 19 keeps its RAW description text; other opcodes have null descriptionText', () {
      const text = 'The <B>error</B> describes the source';
      expect(rec1(c4(0x19, text.codeUnits)).descriptionText, text, reason: 'raw from byte 0 — no length prefix');
      expect(rec1(c4(0x22, 'ABC'.codeUnits)).descriptionText, isNull);
    });

    test('path (0xA4) decodes a PTH0 record; container (0x44) exposes nested C4 children', () {
      expect(rec1(c4(0xa4, pth0('ps5000.dll'))).path, 'ps5000.dll');
      final rec = rec1(
        c4(0x44, [
          ...c4(0x2d, [0, 0, 0, 0, 0, 10, 0, 20]),
          ...c4(0x22, 'Knob'.codeUnits),
        ]),
      );
      expect((rec.kind, rec.kind.shape), (HeapOpcode.container44, HeapShape.container));
      expect(rec.children.map((k) => k.kind), [HeapOpcode.bounds, HeapOpcode.caption]);
      expect(rec.children[1].text, 'Knob');
    });

    test('framing: leading non-C4 stepped over, payload C4 not re-framed, overruns rejected', () {
      final strTable = [...pascal('Hi'), ...pascal('Yo')];
      final heap = [
        ...hx('10 55'),
        ...hx('c4 2d 08 0000 0000 0000 0000'),
        0xc4,
        0x99,
        ...hx('c4 5f 08 0102 0304 0506 0708'),
        0xc4,
        0x2e,
        strTable.length,
        ...strTable,
      ];
      final recs = heapC4RecordsFromDecoded([dsec(heap)]);
      expect(recs.map((r) => r.opcode), [0x2d, 0x5f, 0x2e], reason: 'the 0xc4 0x99 pair did not start a record');
      expect((recs[0].offset, recs[0].byteLength, recs[0].payload.length), (2, 11, 8));
      expect(recs[2].payload.length, 6);

      expect(
        heapC4RecordsFromDecoded([
          dsec([0xc4, 0x2d, 0xff, 1, 2, 3]),
        ]),
        isEmpty,
        reason: 'length claims 255 payload bytes but only 3 present -> not framed',
      );

      final hist = heapC4RecordsFromDecoded([
        dsec([...hx('c4 2d 02 0000'), ...hx('c4 2d 02 0000'), ...hx('c4 1f 01 00')]),
      ]);
      expect(hist.where((r) => r.opcode == 0x2d).length, 2);
      expect(hist.where((r) => r.opcode == 0x1f).length, 1);
      expect(hist.map((r) => r.kind), [HeapOpcode.bounds, HeapOpcode.bounds, HeapOpcode.size]);
    });
  });

  group('object assembly', () {
    test('bounds + adjacent 2E table (labels) or 22 caption pair into a named ViObject', () {
      final table = [...pascal('Sine'), ...pascal('Square')];
      final o = buildViModelFromDecoded([
        dsec([...hx('c4 2d 08 0035 0245 005b 02b8'), 0xc4, 0x2e, table.length, ...table]),
      ]).objects.single;
      expect((o.name, o.bounds.top, o.bounds.left, o.bounds.bottom, o.bounds.right), ('Sine', 53, 581, 91, 696));
      expect(o.labels, ['Sine', 'Square']);

      final cap = buildViModelFromDecoded([
        dsec([...hx('c4 2d 08 000a 0014 0028 0064'), ...c4(0x22, 'Trigger Sourc'.codeUnits)]),
      ]).objects.single;
      expect((cap.caption, cap.name, cap.bounds.left), ('Trigger Sourc', 'Trigger Sourc', 20));
      expect(cap.labels, isEmpty);
    });

    test('unpaired bounds make no object (but stay in objectBounds); labels beyond maxRecordGap do not pair', () {
      final unpaired = buildViModelFromDecoded([
        dsec([...hx('c4 2d 08 0000 0000 000a 000a'), ...hx('c4 1f 08 0000 0000 000c 000c')]),
      ]);
      expect(unpaired.objects, isEmpty, reason: 'a 0x1F size record is not a label');
      expect(unpaired.objectBounds.length, 1);

      final table = [...pascal('Late'), ...pascal('Label')];
      final far = buildViModelFromDecoded([
        dsec([
          ...hx('c4 2d 08 0000 0000 000a 000a'),
          for (var i = 0; i < 5; i++) ...hx('c4 22 01 00'),
          0xc4,
          0x2e,
          table.length,
          ...table,
        ]),
      ]);
      expect(far.objects, isEmpty, reason: 'label 5 records away, beyond maxRecordGap (3)');
    });

    test('ViModel.objectBounds aggregates every C4 2D rect', () {
      final m = buildViModelFromDecoded([
        dsec([...hx('c4 2d 08 0000 0000 0337 0695'), ...hx('c4 2d 08 0035 0245 005b 02b8')]),
      ]);
      expect(m.objectBounds.length, 2);
      expect((m.objectBounds.first.width, m.objectBounds[1].height), (1685, 38));
    });
  });

  group('model aggregation', () {
    test('buildViModelFromDecoded aggregates version, components, tables, records, labels', () {
      final vers = [...pascal('10.0'), 0x00, ...'VIDS'.codeUnits, ...pascal('My Example.vi')];
      final table = [...pascal('Sine'), ...pascal('Square'), ...pascal('Ramp')];
      final bd = [0xc4, 0x2e, table.length, ...table, ...hx('c4 2d 08 0000 0000 0000 0000')];
      final m = buildViModelFromDecoded([dsec(vers, tag: 'vers'), dsec(bd, comp: true)]);
      expect((m.version, m.title), ('10.0', 'My Example.vi'));
      expect(m.components.any((c) => c.tag == 'BDEx'), isTrue);
      expect(m.stringTables.single.framed, isTrue);
      expect(m.stringTables.single.strings, ['Sine', 'Square', 'Ramp']);
      expect(m.heapRecords.map((r) => r.opcode), containsAll(<int>[0x2e, 0x2d]));
      expect(m.labels, ['Sine', 'Square', 'Ramp']);
    });

    test('labels/captions/descriptions/symbolNames dedupe order-preserving; paths surface', () {
      final t1 = [...pascal('error out'), ...pascal('status')];
      final t2 = [...pascal('status'), ...pascal('code')];
      final m = buildViModelFromDecoded([
        dsec([0xc4, 0x2e, t1.length, ...t1]),
        dsec([0xc4, 0x2e, t2.length, ...t2], tag: 'FPHb'),
      ]);
      expect(m.labels, ['error out', 'status', 'code']);

      List<int> cap(String s) => c4(0x22, s.codeUnits);
      final caps = buildViModelFromDecoded([
        dsec([...cap('source'), ...cap('status'), ...cap('source'), ...cap('error out')]),
      ]);
      expect(caps.captions, ['source', 'status', 'error out']);

      List<int> desc(String s) => c4(0x19, s.codeUnits);
      final descs = buildViModelFromDecoded([
        dsec([...desc('Cursors are draggable'), ...desc('Cursors are draggable'), ...desc('Click to add')]),
      ]);
      expect(descs.descriptions, ['Cursors are draggable', 'Click to add']);

      final ext = buildViModelFromDecoded([
        dsec([
          ...c4(0xc4, 'ps5000RunStreaming'.codeUnits),
          ...c4(0xc4, 'ps5000RunStreaming'.codeUnits),
          ...c4(0xa4, pth0('ps5000.dll')),
        ], tag: 'DTHP'),
      ]);
      expect(ext.symbolNames, ['ps5000RunStreaming']);
      expect(ext.paths, ['ps5000.dll']);
    });
  });

  group('heap strings (meta)', () {
    test('versionFromSections decodes version + VIDS title; null when absent', () {
      final bytes = [0xAB, ...pascal('10.0'), 0x00, ...'VIDS'.codeUnits, ...pascal('My Example.vi')];
      final info = versionFromSections([sec('vers', bytes)]);
      expect((info.version, info.title), ('10.0', 'My Example.vi'));
      expect(versionFromSections([sec('vers', pascal('not a version'))]).version, isNull);
    });

    test('heapStringsFromDecoded keeps contiguous letter-bearing runs, drops noise/short runs, dedupes', () {
      final heap = [
        ...pascal('Conversion time'),
        ...pascal('error out'),
        ...pascal('error out'),
        ...pascal('Range Volts'),
        ...pascal('1234'),
        0xff,
        0xfe,
        0x00,
        0x99,
        ...pascal('Lonely'),
        0x00,
        0x00,
      ];
      final strings = heapStringsFromDecoded([dsec(heap)]);
      expect(strings, containsAll(<String>['Conversion time', 'error out', 'Range Volts']));
      expect(strings.where((s) => s == 'error out').length, 1);
      expect(strings, isNot(contains('1234')), reason: 'no ASCII letter -> dropped');
      expect(strings, isNot(contains('Lonely')), reason: 'run shorter than minRun (2) -> coincidental');
    });

    test('heapStringTablesFromDecoded groups unframed runs with section + offset', () {
      final lead = [0xff, 0xfe, 0x00];
      final heap = [
        ...lead,
        ...pascal('Range Volts'),
        ...pascal('error out'),
        0x00,
        0x00,
        ...pascal('Channel'),
        ...pascal('Sample Rate'),
      ];
      final tables = heapStringTablesFromDecoded([dsec(heap)]);
      expect(tables.length, 2);
      expect((tables.first.sectionTag, tables.first.offset), ('BDEx', lead.length));
      expect(tables.first.strings, ['Range Volts', 'error out']);
      expect(tables[1].strings, ['Channel', 'Sample Rate']);
      expect(heapStringsFromDecoded([dsec(heap)]), ['Range Volts', 'error out', 'Channel', 'Sample Rate']);
    });

    test('framed C4 2E tables: u8 and FF-u16 length forms exact; bare 0x2E never framed', () {
      final body = [...pascal('Sine'), ...pascal('Square'), ...pascal('Ramp Up')];
      final t = heapStringTablesFromDecoded([
        dsec([0xaa, 0xbb, 0xc4, 0x2e, body.length, ...body, 0x00]),
      ]).single;
      expect((t.framed, t.offset), (true, 5), reason: 'payload after 2 noise bytes + C4 2E <u8 len>');
      expect(t.strings, ['Sine', 'Square', 'Ramp Up']);

      final entries = <int>[];
      final expected = <String>[for (var k = 0; k < 30; k++) 'Channel Number $k'];
      for (final s in expected) {
        entries.addAll(pascal(s));
      }
      expect(entries.length, greaterThan(255));
      final big = heapStringTablesFromDecoded([
        dsec([0xc4, 0x2e, 0xff, entries.length >> 8, entries.length & 0xff, ...entries]),
      ]).single;
      expect((big.framed, big.offset), (true, 5), reason: 'payload after C4 2E FF <u16 len>');
      expect(big.strings, expected);

      final bare = heapStringTablesFromDecoded([
        dsec([0x2e, body.length, ...body]),
      ]);
      expect(bare.every((x) => !x.framed), isTrue, reason: '0x2E is ASCII "." — only the C4 form frames');
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
      expect((bd.sectionCount, bd.decompressedBytes, bd.rawBytes, bd.compressed), (2, 5200, 70, true));
      expect(comps.firstWhere((c) => c.tag == 'FPHb').compressed, isFalse);
    });
  });

  test('heap scanners and model builders are total over arbitrary bytes and stay in-bounds', () {
    expectTotal(5, 3000, 250, (b) {
      for (final r in heapC4RecordsFromDecoded([dsec(b)])) {
        expect(r.offset, inInclusiveRange(0, b.length));
        expect(r.offset + r.byteLength, lessThanOrEqualTo(b.length));
        expect(r.opcode, inInclusiveRange(0, 255));
      }
    });
    expectTotal(11, 2000, 200, (b) {
      for (final t in heapStringTables(b)) {
        expect(t.offset, inInclusiveRange(0, b.length));
        expect(t.strings, isNotEmpty);
      }
    });
    expectTotal(8, 2000, 200, (b) {
      decodeVersion(b);
      extractHeapStrings(b);
      blockComponents(b);
    });
    expectTotal(3, 1500, 160, (b) {
      final m = buildViModel(b);
      expect(m.labels, isA<List<String>>());
    });
    for (final (seed, step) in const [(7, 0xc4), (13, 0x19), (11, 0x22)]) {
      final junk = [for (var i = 0; i < 400; i++) (i * seed + step) & 0xff];
      final m = buildViModelFromDecoded([dsec(junk)]);
      m.objects;
      m.descriptions;
      m.captions;
      for (final r in scanC4Records(u8(junk), 'BDEx')) {
        r.rect;
        r.text;
        r.path;
        r.children;
      }
    }
  });
}
