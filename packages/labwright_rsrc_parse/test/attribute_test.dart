import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'test_util.dart';

Uint8List f64Rec(int id, double v, {int op = 0xc5}) {
  final d = ByteData(11)
    ..setUint8(0, op)
    ..setUint8(1, id)
    ..setUint8(2, 0x08)
    ..setFloat64(3, v);
  return d.buffer.asUint8List();
}

void chk(
  List<int> bytes,
  HeapAttribute attr, {
  HeapAttrWidth? width,
  HeapAttrKind? kind,
  int? rawTag,
  int? asInt,
  double? asDouble,
  String? asString,
  String? ascii,
  int? rgb,
  bool? transparent,
  ({int a, int b})? point,
  List<int>? rect,
  int? len,
  AttrConfidence? confidence,
  bool noDouble = false,
  bool noString = false,
  bool noRgb = false,
  bool noAscii = false,
}) {
  final a = decodeHeapAttr(u8(bytes), 0)!;
  final r = bytes.map((x) => x.toRadixString(16).padLeft(2, '0')).join(' ');
  expect(a.attribute, attr, reason: r);
  if (width != null) expect(a.width, width, reason: r);
  if (kind != null) expect(a.kind, kind, reason: r);
  if (rawTag != null) expect(a.rawTag, rawTag, reason: r);
  if (asInt != null) expect(a.asInt, asInt, reason: r);
  if (asDouble != null) expect(a.asDouble, closeTo(asDouble, 1e-9), reason: r);
  if (asString != null) expect(a.asString, asString, reason: r);
  if (ascii != null) expect(a.asciiText, ascii, reason: r);
  if (rgb != null) expect(a.rgb, rgb, reason: r);
  if (transparent != null) expect(a.isTransparent, transparent, reason: r);
  if (point != null) expect(a.asPoint, point, reason: r);
  if (rect != null) {
    final x = a.asRect!;
    expect([x.top, x.left, x.bottom, x.right], rect, reason: r);
  }
  if (len != null) expect(a.length, len, reason: r);
  if (confidence != null) expect(a.attribute.confidence, confidence, reason: r);
  if (noDouble) expect(a.asDouble, isNull, reason: '$r: no fabricated double');
  if (noString) expect(a.asString, isNull, reason: r);
  if (noRgb) expect(a.rgb, isNull, reason: r);
  if (noAscii) expect(a.asciiText, isNull, reason: '$r: non-printable magnitude stays numeric');
}

void main() {
  test('HeapAttribute catalog: unique 10-bit raw ids, fromRaw round-trip, concrete kinds', () {
    final seen = <int>{};
    for (final a in HeapAttribute.values) {
      if (a == HeapAttribute.unknown) continue;
      expect(seen.add(a.raw), isTrue, reason: 'duplicate raw 0x${a.raw.toRadixString(16)} on $a');
      expect(a.raw, inInclusiveRange(0, 0x3ff), reason: 'raw tag ids are 10-bit');
      expect(HeapAttribute.fromRaw(a.raw), a);
      expect(a.attrName, isNotEmpty);
      expect(a.kind, isNot(HeapAttrKind.unknown));
    }
    expect(HeapAttribute.fromRaw(0x399), HeapAttribute.unknown);
    expect(HeapAttribute.unknown.raw, -1);
  });

  test('widths and the raw-tag key (op low 2 bits are tag bits 8-9)', () {
    chk(
      [0x24, 0xdf, 0x05],
      HeapAttribute.partRole,
      rawTag: 0x0df,
      width: HeapAttrWidth.u8,
      kind: HeapAttrKind.enumValue,
      asInt: 5,
      len: 3,
    );
    chk([0x44, 0xe7, 0x02, 0x08], HeapAttribute.unknown, rawTag: 0x0e7);
    chk([0x45, 0xe7, 0x02, 0x08], HeapAttribute.compressedWireTable, rawTag: 0x1e7);
    chk([0x24, 0xdf, 66], HeapAttribute.partRole, asInt: 66, confidence: AttrConfidence.inferred);
    chk([0x44, 0xdf, 0x1f, 0x42], HeapAttribute.partRole, width: HeapAttrWidth.u16, asInt: 8002);
    chk([0x24, 0xaf, 0x09], HeapAttribute.masterPart, confidence: AttrConfidence.inferred);
    chk([0x64, 0xcb, 0x10, 0x00, 0x00], HeapAttribute.objFlags, width: HeapAttrWidth.u24, asInt: 0x100000, len: 5);
    final rec = u8([0x64, 0xcb, 0x26, 0x84, 0x20]);
    expect(recordSkip(rec, 0), 5, reason: 'the 3-byte 64 CB 26 special case was refuted');
    expect(decodeHeapAttr(rec, 0)!.asInt, 0x268420);
    chk([0xe4, 0x59], HeapAttribute.reservedFlag, width: HeapAttrWidth.flag, asInt: 1, len: 2);
    chk([0x04, 0x59], HeapAttribute.reservedFlag, width: HeapAttrWidth.flag, asInt: 0, len: 2);
  });

  test('colours (0x84 …) and point-valued tags (packed s16 pairs)', () {
    chk(
      [0x84, 0x28, 0xff, 0x12, 0x34, 0x56],
      HeapAttribute.backgroundColor,
      kind: HeapAttrKind.color,
      rgb: 0x123456,
      transparent: false,
      len: 6,
    );
    chk([0x84, 0x28, 0x01, 0x00, 0x00, 0x00], HeapAttribute.backgroundColor, rgb: 0, transparent: true);
    chk([0x84, 0x2a, 0xff, 0xff, 0x42, 0x42], HeapAttribute.plotColor, rgb: 0xff4242);
    chk([0x84, 0x2b, 0x01, 0x00, 0x00, 0x00], HeapAttribute.borderColor, transparent: true);
    chk(
      [0x84, 0xd0, 0xff, 0xfc, 0xff, 0xfc],
      HeapAttribute.origin,
      kind: HeapAttrKind.point,
      point: (a: -4, b: -4),
      noRgb: true,
    );
    chk([0x84, 0xb7, 0x00, 0x01, 0x00, 0x01], HeapAttribute.minPaneSize, point: (a: 1, b: 1));
  });

  test('scale/std-num f64 families (Cx …08) and the 0x120 non-f64 exception', () {
    chk(f64Rec(0xf5, -1.0), HeapAttribute.scaleDMin, kind: HeapAttrKind.controlParam, asDouble: -1.0);
    chk(f64Rec(0xfa, 1.0), HeapAttribute.scaleDMultiplier, asDouble: 1.0);
    chk(f64Rec(0x20, -1.0, op: 0xc6), HeapAttribute.stdNumMin, kind: HeapAttrKind.controlParam, asDouble: -1.0);
    chk(f64Rec(0x21, 5.0, op: 0xc6), HeapAttribute.stdNumMax, asDouble: 5.0);
    chk(f64Rec(0x22, 0.0, op: 0xc6), HeapAttribute.stdNumInc, asDouble: 0.0);
    chk(f64Rec(0x20, -1.0), HeapAttribute.tableFlags, width: HeapAttrWidth.container, noDouble: true);
  });

  test('rectangle-payload tags (Cx …08 rect, not f64) and container forms', () {
    chk(
      hx('c5 29 08 0008 0000 0010 0008'),
      HeapAttribute.termBounds,
      width: HeapAttrWidth.rect,
      kind: HeapAttrKind.rectangle,
      rect: [8, 0, 16, 8],
      len: 11,
      noDouble: true,
    );
    chk(
      [0x84, 0x29, 0xff, 0x00, 0x00, 0x0c],
      HeapAttribute.color29,
      width: HeapAttrWidth.rgb,
      kind: HeapAttrKind.numeric,
      noRgb: true,
    );
    chk(u8([0xc5, 0x63, 0x08, 0, 0, 0, 0, 0, 75, 0, 75]), HeapAttribute.totalBounds, rect: [0, 0, 75, 75]);
    chk(u8([0xc5, 0x64, 0x08, 0, 0, 0, 0, 0, 75, 0, 75]), HeapAttribute.srcRect);
    chk(
      u8([0xc6, 0x75, 0x08, 0, 0, 0, 0, 1, 0, 2, 0]),
      HeapAttribute.savedSize,
      kind: HeapAttrKind.rectangle,
      rect: [0, 0, 256, 512],
    );
    chk(
      hx('c5 e7 08 04 10 00 20 00 30 00 40'),
      HeapAttribute.compressedWireTable,
      width: HeapAttrWidth.container,
      kind: HeapAttrKind.container,
      asInt: 0x04,
      len: 11,
      noDouble: true,
    );
    chk(
      u8([0xc5, 0xe7, 0x06, 0x03, 0, 0, 0, 0, 0]),
      HeapAttribute.compressedWireTable,
      width: HeapAttrWidth.container,
      len: 9,
    );
    chk([0x45, 0xe7, 0x02, 0x08], HeapAttribute.compressedWireTable, width: HeapAttrWidth.u16);
    chk([0x85, 0xe7, 0x01, 0x00, 0x01, 0x00], HeapAttribute.compressedWireTable, width: HeapAttrWidth.rgb, noRgb: true);
  });

  test('string forms: inline 0x231, validity-gated 0x26C const strings, magnitude-encoded ASCII', () {
    chk(
      [0xc6, 0x31, 0x05, ...'Scale'.codeUnits],
      HeapAttribute.propItemName,
      kind: HeapAttrKind.stringBlob,
      asString: 'Scale',
      len: 8,
    );
    chk(
      [0xc6, 0x6c, 0x0a, 0x00, 0x00, 0x00, 0x06, ...'Robot!'.codeUnits],
      HeapAttribute.constValue,
      kind: HeapAttrKind.stringBlob,
      asString: 'Robot!',
      len: 13,
    );
    chk(
      [0xc6, 0x6c, 0xff, 0x00, 0x0a, 0x00, 0x00, 0x00, 0x06, ...'Robot!'.codeUnits],
      HeapAttribute.constValue,
      asString: 'Robot!',
    );
    chk(hx('c6 6c 06 00000040 4142'), HeapAttribute.constValue, width: HeapAttrWidth.container, noString: true);
    chk(
      hx('c6 6c ff 000a 00000006 0102030405 41'),
      HeapAttribute.constValue,
      width: HeapAttrWidth.container,
      noString: true,
    );
    chk(
      [0xc6, 0x6c, 64, 0x00, 0x00, 0x00, 0x01, 0x23, ...List.filled(59, 0)],
      HeapAttribute.constValue,
      width: HeapAttrWidth.container,
      noString: true,
    );
    chk(
      [0x84, 0x22, ...'Page'.codeUnits],
      HeapAttribute.shortText,
      kind: HeapAttrKind.text,
      ascii: 'Page',
      asInt: 0x50616765,
      noRgb: true,
    );
    chk([0x24, 0x22, 0x79], HeapAttribute.shortText, ascii: 'y', asInt: 0x79);
    chk([0x44, 0xc4, 0x56, 0x49], HeapAttribute.nodeName, ascii: 'VI', asInt: 0x5649);
    chk([0x44, 0x22, 0x01, 0x02], HeapAttribute.shortText, asInt: 0x0102, noAscii: true);
  });

  test('per-tag decodes behind the corpus-verified upgrades', () {
    chk(hx('85 14 db 3d 11 75'), HeapAttribute.stamp, asInt: 0xdb3d1175, confidence: AttrConfidence.confirmed);
    chk([0x25, 0x58, 0x02], HeapAttribute.termListLength, asInt: 2, confidence: AttrConfidence.confirmed);
    chk([0x25, 0x15, 0x01], HeapAttribute.signalState);
    chk([0x44, 0x9f, 0x83, 0x50], HeapAttribute.lastSignalKind, asInt: 0x8350);
    chk([0x24, 0x44, 0xff], HeapAttribute.conNum, asInt: 255, len: 3);
  });

  test('dual-form resolution: 0x0F8 size vs 0x1F8 f64; 0x05A flag vs 0x25A blob', () {
    chk([0x44, 0xf8, 0x00, 0xff], HeapAttribute.sizeExtent, kind: HeapAttrKind.size, asInt: 255);
    chk(f64Rec(0xf8, 0.2), HeapAttribute.scaleDIncr, kind: HeapAttrKind.controlParam, asDouble: 0.2);
    chk([0x24, 0x5a, 0x00], HeapAttribute.flag5A, kind: HeapAttrKind.flag);
    chk(
      [0xc6, 0x5a, 0xff, 0x00, 0x0c, 0x00, 0x00, 0x00, 0x08, ...'USB:TEST'.codeUnits],
      HeapAttribute.defaultData,
      width: HeapAttrWidth.blob,
      kind: HeapAttrKind.stringBlob,
      asString: 'USB:TEST',
      len: 17,
    );
  });

  test('non-attribute bytes return null; 05/06 zero-size leads defer to typed-list framing', () {
    expect(decodeHeapAttr(hx('c4 2d 08'), 0), isNull);
    expect(decodeHeapAttr(hx('10 19'), 0), isNull);
    final ambiguous = hx('05 71 01 fd 00 07');
    expect(recordSkip(ambiguous, 0), 6, reason: '05 71 + type tag frames as a typed list');
    expect(decodeHeapAttr(ambiguous, 0), isNull);
    final plain = hx('05 71 24 df');
    expect(recordSkip(plain, 0), 2, reason: 'no type tag -> the 2-byte false-flag reading');
    expect(decodeHeapAttr(plain, 0)!.asInt, 0);
  });
}
