import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

DecodedSection bdex(List<int> bytes, {String tag = 'BDEx'}) => DecodedSection(
      section: ViSection(tag: tag, index: 0, dataOffset: 0, bytes: Uint8List.fromList(bytes)),
      bytes: Uint8List.fromList(bytes),
      wasCompressed: false,
    );

List<int> c4(int op, List<int> payload) => [0xc4, op, payload.length, ...payload];

List<int> pth0Record(String path) {
  final c = path.codeUnits;
  return [0x50, 0x54, 0x48, 0x30, 0, 0, 0, 0, 0, 0, 0, 1, c.length, ...c];
}

void main() {
  test('itemLabel (0x20) and symbolName (0xC4) decode as text', () {
    final recs = heapC4RecordsFromDecoded([
      bdex([...c4(0x20, 'Line 0'.codeUnits), ...c4(0xc4, 'ps2000aRunStreaming'.codeUnits)])
    ]);
    expect(recs[0].kind, HeapOpcode.itemLabel);
    expect(recs[0].text, 'Line 0');
    expect(recs[1].kind, HeapOpcode.symbolName);
    expect(recs[1].text, 'ps2000aRunStreaming');
  });

  test('methodName (0xB6) decodes as text', () {
    final rec = heapC4RecordsFromDecoded([bdex(c4(0xb6, 'FP.Open'.codeUnits))]).single;
    expect(rec.kind, HeapOpcode.methodName);
    expect(rec.kind.isDecoded, isTrue);
    expect(rec.text, 'FP.Open');
  });

  test('typeBounds (0x4A) decodes via the generic rect accessor', () {
    final rec = heapC4RecordsFromDecoded([
      bdex(c4(0x4a, [0x00, 0x10, 0x00, 0x20, 0x00, 0x30, 0x00, 0x40]))
    ]).single;
    expect(rec.kind, HeapOpcode.typeBounds);
    expect(rec.bounds, isNull, reason: 'typeBounds (0x4A) is not the semantic bounds opcode, so .bounds stays null');
    expect([rec.rect!.top, rec.rect!.left, rec.rect!.bottom, rec.rect!.right], [16, 32, 48, 64]);
  });

  test('path (0xA4) decodes a PTH0 record to a joined path', () {
    final rec = heapC4RecordsFromDecoded([bdex(c4(0xa4, pth0Record('ps5000.dll')))]).single;
    expect(rec.kind, HeapOpcode.path);
    expect(rec.path, 'ps5000.dll');
  });

  test('container (0x44) exposes its nested C4 children', () {
    final inner = <int>[
      ...c4(0x2d, [0, 0, 0, 0, 0, 10, 0, 20]),
      ...c4(0x22, 'Knob'.codeUnits),
    ];
    final rec = heapC4RecordsFromDecoded([bdex(c4(0x44, inner))]).single;
    expect(rec.kind, HeapOpcode.container44);
    expect(rec.kind.shape, HeapShape.container);
    final kids = rec.children;
    expect(kids.map((k) => k.kind), [HeapOpcode.bounds, HeapOpcode.caption]);
    expect(kids[1].text, 'Knob');
  });

  test('ViModel surfaces symbolNames and paths (external calls)', () {
    final heap = <int>[
      ...c4(0xc4, 'ps5000RunStreaming'.codeUnits),
      ...c4(0xc4, 'ps5000RunStreaming'.codeUnits),
      ...c4(0xa4, pth0Record('ps5000.dll')),
    ];
    final m = buildViModelFromDecoded([bdex(heap, tag: 'DTHP')]);
    expect(m.symbolNames, <String>['ps5000RunStreaming']);
    expect(m.paths, <String>['ps5000.dll']);
  });

  test('new opcodes preserve totality over arbitrary bytes', () {
    final heap = Uint8List.fromList([for (var i = 0; i < 400; i++) (i * 11 + 0xc4) & 0xff]);
    expect(() {
      for (final r in scanC4Records(heap, 'BDEx')) {
        r.rect;
        r.text;
        r.path;
        r.children;
      }
    }, returnsNormally);
  });
}
