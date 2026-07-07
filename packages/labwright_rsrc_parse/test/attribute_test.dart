import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

/// Builds a `C5 <id> 08 <f64>` scale-parameter record.
Uint8List f64Rec(int id, double v, {int op = 0xc5}) {
  final d = ByteData(11)
    ..setUint8(0, op)
    ..setUint8(1, id)
    ..setUint8(2, 0x08)
    ..setFloat64(3, v);
  return d.buffer.asUint8List();
}

void main() {
  group('HeapAttribute catalog (raw 10-bit tag ids)', () {
    test('raw tag ids are unique and round-trip via fromRaw', () {
      final seen = <int>{};
      for (final a in HeapAttribute.values) {
        if (a == HeapAttribute.unknown) continue;
        expect(seen.add(a.raw), isTrue, reason: 'duplicate raw 0x${a.raw.toRadixString(16)} on $a');
        expect(a.raw, inInclusiveRange(0, 0x3ff), reason: 'raw tag ids are 10-bit');
        expect(HeapAttribute.fromRaw(a.raw), a);
        expect(a.attrName, isNotEmpty);
      }
    });

    test('uncatalogued raw tag maps to unknown', () {
      expect(HeapAttribute.fromRaw(0x399), HeapAttribute.unknown);
      expect(HeapAttribute.unknown.raw, -1);
    });

    test('every catalogued name has a concrete kind (not unknown)', () {
      for (final a in HeapAttribute.values) {
        if (a == HeapAttribute.unknown) continue;
        expect(a.kind, isNot(HeapAttrKind.unknown));
      }
    });
  });

  group('decodeHeapAttr — widths and the raw-tag key', () {
    test('u8 (0x24)', () {
      final a = decodeHeapAttr(Uint8List.fromList([0x24, 0xdf, 0x05]), 0)!;
      expect(a.attribute, HeapAttribute.partRole);
      expect(a.rawTag, 0x0df);
      expect(a.width, HeapAttrWidth.u8);
      expect(a.asInt, 5);
      expect(a.kind, HeapAttrKind.enumValue);
      expect(a.length, 3);
    });

    test('the op low 2 bits are tag bits 8-9: 44 E7 vs 45 E7 are different tags', () {
      final low = decodeHeapAttr(Uint8List.fromList([0x44, 0xe7, 0x02, 0x08]), 0)!;
      expect(low.rawTag, 0x0e7);
      expect(low.attribute, HeapAttribute.unknown, reason: 'raw 0x0E7 is uncatalogued');
      final high = decodeHeapAttr(Uint8List.fromList([0x45, 0xe7, 0x02, 0x08]), 0)!;
      expect(high.rawTag, 0x1e7);
      expect(high.attribute, HeapAttribute.compressedWireTable);
    });

    test('partRole (raw 0x0DF) decodes in both its corpus forms and is inferred', () {
      final u8 = decodeHeapAttr(Uint8List.fromList([0x24, 0xdf, 66]), 0)!;
      expect(u8.attribute, HeapAttribute.partRole);
      expect(u8.attribute.confidence, AttrConfidence.inferred);
      expect(u8.asInt, 66);
      final u16 = decodeHeapAttr(Uint8List.fromList([0x44, 0xdf, 0x1f, 0x42]), 0)!;
      expect(u16.attribute, HeapAttribute.partRole);
      expect(u16.width, HeapAttrWidth.u16);
      expect(u16.asInt, 8002);
    });

    test('masterPart (raw 0x0AF) is inferred: sibling-part partRole match at 97.29%', () {
      final a = decodeHeapAttr(Uint8List.fromList([0x24, 0xaf, 0x09]), 0)!;
      expect(a.attribute, HeapAttribute.masterPart);
      expect(a.attribute.confidence, AttrConfidence.inferred);
    });

    test('objFlags (raw 0x0CB) decodes at every width, including the once-special 64 CB 26 form', () {
      final a = decodeHeapAttr(Uint8List.fromList([0x64, 0xcb, 0x10, 0x00, 0x00]), 0)!;
      expect(a.attribute, HeapAttribute.objFlags);
      expect(a.width, HeapAttrWidth.u24);
      expect(a.asInt, 0x100000);
      expect(a.length, 5);
      final rec = Uint8List.fromList([0x64, 0xcb, 0x26, 0x84, 0x20]);
      expect(
        recordSkip(rec, 0),
        5,
        reason: 'the 3-byte 64 CB 26 special case was refuted (EOF balance 42.7% vs 99.95%)',
      );
      expect(decodeHeapAttr(rec, 0)!.asInt, 0x268420);
    });

    test('bare flag (0xE4) decodes true; the 04-form decodes false', () {
      final on = decodeHeapAttr(Uint8List.fromList([0xe4, 0x59]), 0)!;
      expect(on.attribute, HeapAttribute.reservedFlag);
      expect(on.width, HeapAttrWidth.flag);
      expect(on.asInt, 1);
      expect(on.length, 2);
      final off = decodeHeapAttr(Uint8List.fromList([0x04, 0x59]), 0)!;
      expect(off.attribute, HeapAttribute.reservedFlag);
      expect(off.width, HeapAttrWidth.flag);
      expect(off.asInt, 0);
      expect(off.length, 2);
    });
  });

  group('decodeHeapAttr — colors (0x84)', () {
    test('opaque RGB exposes rgb, not transparent', () {
      final a = decodeHeapAttr(Uint8List.fromList([0x84, 0x28, 0xff, 0x12, 0x34, 0x56]), 0)!;
      expect(a.attribute, HeapAttribute.backgroundColor);
      expect(a.kind, HeapAttrKind.color);
      expect(a.rgb, 0x123456);
      expect(a.isTransparent, isFalse);
      expect(a.length, 6);
    });

    test('transparent sentinel detected', () {
      final a = decodeHeapAttr(Uint8List.fromList([0x84, 0x28, 0x01, 0x00, 0x00, 0x00]), 0)!;
      expect(a.isTransparent, isTrue);
      expect(a.rgb, 0);
    });

    test('plotColor and borderColor decode as colours', () {
      final plot = decodeHeapAttr(Uint8List.fromList([0x84, 0x2a, 0xff, 0xff, 0x42, 0x42]), 0)!;
      expect(plot.attribute, HeapAttribute.plotColor);
      expect(plot.rgb, 0xff4242);
      final border = decodeHeapAttr(Uint8List.fromList([0x84, 0x2b, 0x01, 0x00, 0x00, 0x00]), 0)!;
      expect(border.attribute, HeapAttribute.borderColor);
      expect(border.isTransparent, isTrue);
    });
  });

  group('point-valued tags (packed s16 pairs, not colours)', () {
    test('origin (raw 0x0D0) decodes to a signed point', () {
      final a = decodeHeapAttr(Uint8List.fromList([0x84, 0xd0, 0xff, 0xfc, 0xff, 0xfc]), 0)!;
      expect(a.attribute, HeapAttribute.origin);
      expect(a.kind, HeapAttrKind.point);
      expect(a.asPoint, (a: -4, b: -4));
      expect(a.rgb, isNull, reason: 'a point must not read as a colour');
    });

    test('minPaneSize (raw 0x0B7) decodes its dominant (1,1) value', () {
      final a = decodeHeapAttr(Uint8List.fromList([0x84, 0xb7, 0x00, 0x01, 0x00, 0x01]), 0)!;
      expect(a.attribute, HeapAttribute.minPaneSize);
      expect(a.asPoint, (a: 1, b: 1));
    });
  });

  group('scale/std-num parameter families (Cx …08 f64)', () {
    test('C5 F5/FA decode as scaleDMin / scaleDMultiplier', () {
      final mn = decodeHeapAttr(f64Rec(0xf5, -1.0), 0)!;
      expect(mn.attribute, HeapAttribute.scaleDMin);
      expect(mn.kind, HeapAttrKind.controlParam);
      expect(mn.asDouble, -1.0);
      final mult = decodeHeapAttr(f64Rec(0xfa, 1.0), 0)!;
      expect(mult.attribute, HeapAttribute.scaleDMultiplier);
      expect(mult.asDouble, 1.0);
    });

    test('C6 20/21/22 decode as stdNumMin/Max/Inc (raw 0x220..0x222)', () {
      final mn = decodeHeapAttr(f64Rec(0x20, -1.0, op: 0xc6), 0)!;
      expect(mn.attribute, HeapAttribute.stdNumMin);
      expect(mn.kind, HeapAttrKind.controlParam);
      expect(mn.asDouble, -1.0);
      final inc = decodeHeapAttr(f64Rec(0x22, 0.0, op: 0xc6), 0)!;
      expect(inc.attribute, HeapAttribute.stdNumInc);
      expect(inc.asDouble, 0.0);
    });

    test('C5 20 08 (raw 0x120 = tableFlags, a u16 tag) is NOT decoded as an f64', () {
      final a = decodeHeapAttr(f64Rec(0x20, -1.0), 0)!;
      expect(a.width, HeapAttrWidth.container, reason: 'framed data payload, never a fabricated double');
      expect(a.asDouble, isNull);
    });
  });

  group('rectangle-payload tags (Cx …08 is a rect, not an f64)', () {
    test('termBounds (raw 0x129) decodes its len-08 payload as a 4x s16 rectangle', () {
      final rec = Uint8List.fromList([0xc5, 0x29, 0x08, 0x00, 0x08, 0x00, 0x00, 0x00, 0x10, 0x00, 0x08]);
      final a = decodeHeapAttr(rec, 0)!;
      expect(a.attribute, HeapAttribute.termBounds);
      expect(a.width, HeapAttrWidth.rect);
      expect(a.kind, HeapAttrKind.rectangle);
      expect(a.asDouble, isNull);
      final r = a.asRect!;
      expect([r.top, r.left, r.bottom, r.right], [8, 0, 16, 8]);
      expect(a.length, 11);
    });

    test('the 84 29 form is a DIFFERENT tag (raw 0x029, kindOnly numeric)', () {
      final a = decodeHeapAttr(Uint8List.fromList([0x84, 0x29, 0xff, 0x00, 0x00, 0x0c]), 0)!;
      expect(a.attribute, HeapAttribute.color29);
      expect(a.width, HeapAttrWidth.rgb);
      expect(a.kind, HeapAttrKind.numeric);
      expect(a.rgb, isNull);
    });

    test('totalBounds/srcRect (raw 0x163/0x164) decode as rectangles, not garbage f64', () {
      final a = decodeHeapAttr(Uint8List.fromList([0xc5, 0x63, 0x08, 0, 0, 0, 0, 0, 75, 0, 75]), 0)!;
      expect(a.attribute, HeapAttribute.totalBounds);
      expect(a.asRect!.height, 75);
      final b = decodeHeapAttr(Uint8List.fromList([0xc5, 0x64, 0x08, 0, 0, 0, 0, 0, 75, 0, 75]), 0)!;
      expect(b.attribute, HeapAttribute.srcRect);
    });

    test('savedSize (raw 0x275, C6 75 08) decodes as a rectangle (35,079/35,079 valid)', () {
      final a = decodeHeapAttr(Uint8List.fromList([0xc6, 0x75, 0x08, 0, 0, 0, 0, 1, 0, 2, 0]), 0)!;
      expect(a.attribute, HeapAttribute.savedSize);
      expect(a.kind, HeapAttrKind.rectangle);
      expect(a.asRect!.height, 256);
    });

    test('compressedWireTable container form (C5 E7 <len>) frames without faking an f64', () {
      final rec = Uint8List.fromList([0xc5, 0xe7, 0x08, 0x04, 0x10, 0x00, 0x20, 0x00, 0x30, 0x00, 0x40]);
      final a = decodeHeapAttr(rec, 0)!;
      expect(a.attribute, HeapAttribute.compressedWireTable);
      expect(a.width, HeapAttrWidth.container);
      expect(a.kind, HeapAttrKind.container);
      expect(a.asDouble, isNull);
      expect(a.asInt, 0x04, reason: 'asInt exposes payload[0], the leading byte');
      expect(a.length, 11);
      final r6 = decodeHeapAttr(Uint8List.fromList([0xc5, 0xe7, 0x06, 0x03, 0, 0, 0, 0, 0]), 0)!;
      expect(r6.width, HeapAttrWidth.container);
      expect(r6.length, 9);
    });

    test('the 45 E7 / 85 E7 scalar forms of raw 0x1E7 carry ints (small wire tables)', () {
      final u16 = decodeHeapAttr(Uint8List.fromList([0x45, 0xe7, 0x02, 0x08]), 0)!;
      expect(u16.attribute, HeapAttribute.compressedWireTable);
      expect(u16.width, HeapAttrWidth.u16);
      expect(u16.kind, isNot(HeapAttrKind.container));
      final wide = decodeHeapAttr(Uint8List.fromList([0x85, 0xe7, 0x01, 0x00, 0x01, 0x00]), 0)!;
      expect(wide.width, HeapAttrWidth.rgb);
      expect(wide.rgb, isNull);
    });
  });

  group('string forms', () {
    test('raw 0x231 inline string: C6 31 <len> <raw ASCII> decodes to the text', () {
      final rec = Uint8List.fromList([0xc6, 0x31, 0x05, ...'Scale'.codeUnits]);
      final a = decodeHeapAttr(rec, 0)!;
      expect(a.attribute, HeapAttribute.propItemName);
      expect(a.kind, HeapAttrKind.stringBlob);
      expect(a.asString, 'Scale');
      expect(a.length, 8);
    });

    test('raw 0x26C <u8len> u32-strlen form decodes a constant string (validity-gated)', () {
      final rec = Uint8List.fromList([0xc6, 0x6c, 0x0a, 0x00, 0x00, 0x00, 0x06, ...'Robot!'.codeUnits]);
      final a = decodeHeapAttr(rec, 0)!;
      expect(a.attribute, HeapAttribute.constValue);
      expect(a.kind, HeapAttrKind.stringBlob);
      expect(a.asString, 'Robot!');
      expect(a.length, 13);
      final bad = Uint8List.fromList([0xc6, 0x6c, 0x06, 0x00, 0x00, 0x00, 0x40, 0x41, 0x42]);
      final framed = decodeHeapAttr(bad, 0)!;
      expect(
        framed.width,
        HeapAttrWidth.container,
        reason: 'strlen overruns the declared len -> framed data, no string',
      );
      expect(framed.asString, isNull);
    });

    test('raw 0x26C FF blob rejects mostly-binary payloads (no garbage-as-string)', () {
      final bin = Uint8List.fromList([
        0xc6, 0x6c, 0xff, 0x00, 0x0a, //
        0x00, 0x00, 0x00, 0x06, 0x01, 0x02, 0x03, 0x04, 0x05, 0x41,
      ]);
      final framed = decodeHeapAttr(bin, 0)!;
      expect(
        framed.width,
        HeapAttrWidth.container,
        reason: 'a payload under 90% printable must not decode as a string',
      );
      expect(framed.asString, isNull);
      expect(
        framed.attribute,
        HeapAttribute.constValue,
        reason: 'the record still means "constant value" (framed data)',
      );
    });

    test('raw 0x26C <u8len> rejects the big-slack 1-char false positive', () {
      final fake = Uint8List.fromList([0xc6, 0x6c, 64, 0x00, 0x00, 0x00, 0x01, 0x23, ...List.filled(59, 0)]);
      final framed = decodeHeapAttr(fake, 0)!;
      expect(framed.asString, isNull, reason: 'len=64 / strLen=1 / slack=59 is structured data, not a string');
      expect(framed.width, HeapAttrWidth.container);
    });

    test('raw 0x26C FF blob decodes printable text', () {
      final blob = Uint8List.fromList([
        0xc6, 0x6c, 0xff, 0x00, 0x0a, //
        0x00, 0x00, 0x00, 0x06, ...'Robot!'.codeUnits,
      ]);
      final a = decodeHeapAttr(blob, 0)!;
      expect(a.attribute, HeapAttribute.constValue);
      expect(a.asString, 'Robot!');
    });

    test('magnitude-encoded ASCII ints: shortText (raw 0x022) and nodeName (raw 0x0C4)', () {
      final page = decodeHeapAttr(Uint8List.fromList([0x84, 0x22, 0x50, 0x61, 0x67, 0x65]), 0)!;
      expect(page.attribute, HeapAttribute.shortText);
      expect(page.kind, HeapAttrKind.text);
      expect(page.asciiText, 'Page');
      expect(page.asInt, 0x50616765, reason: 'the numeric value is preserved, not overwritten by the ASCII reading');
      expect(page.rgb, isNull);
      final y = decodeHeapAttr(Uint8List.fromList([0x24, 0x22, 0x79]), 0)!;
      expect(y.asciiText, 'y');
      expect(y.asInt, 0x79);
      final vi = decodeHeapAttr(Uint8List.fromList([0x44, 0xc4, 0x56, 0x49]), 0)!;
      expect(vi.attribute, HeapAttribute.nodeName);
      expect(vi.asciiText, 'VI');
      expect(vi.asInt, 0x5649);
      final nonAscii = decodeHeapAttr(Uint8List.fromList([0x44, 0x22, 0x01, 0x02]), 0)!;
      expect(nonAscii.asciiText, isNull, reason: 'non-printable magnitude bytes stay numeric — never fabricated');
      expect(nonAscii.asInt, 0x0102);
    });
  });

  group('per-tag decodes behind the corpus-verified upgrades', () {
    test('stamp (raw 0x114) carries a 1904-epoch timestamp', () {
      final a = decodeHeapAttr(Uint8List.fromList([0x85, 0x14, 0xdb, 0x3d, 0x11, 0x75]), 0)!;
      expect(a.attribute, HeapAttribute.stamp);
      expect(a.attribute.confidence, AttrConfidence.confirmed);
      expect(a.asInt, 0xdb3d1175);
    });

    test('termListLength (raw 0x158) is confirmed (== direct child count at 97.56%)', () {
      final a = decodeHeapAttr(Uint8List.fromList([0x25, 0x58, 0x02]), 0)!;
      expect(a.attribute, HeapAttribute.termListLength);
      expect(a.attribute.confidence, AttrConfidence.confirmed);
      expect(a.asInt, 2);
    });

    test('signal chain: signalState (25 15) and lastSignalKind (44 9F)', () {
      final st = decodeHeapAttr(Uint8List.fromList([0x25, 0x15, 0x01]), 0)!;
      expect(st.attribute, HeapAttribute.signalState);
      final lk = decodeHeapAttr(Uint8List.fromList([0x44, 0x9f, 0x83, 0x50]), 0)!;
      expect(lk.attribute, HeapAttribute.lastSignalKind);
      expect(lk.asInt, 0x8350);
    });

    test('conNum (24 44) keeps its 255 = unwired sentinel', () {
      final a = decodeHeapAttr(Uint8List.fromList([0x24, 0x44, 0xff]), 0)!;
      expect(a.attribute, HeapAttribute.conNum);
      expect(a.asInt, 255);
    });
  });

  group('dual-form resolution', () {
    test('raw 0x0F8 u16 is a size; C5 F8 (raw 0x1F8) is the scaleDIncr f64', () {
      final asSize = decodeHeapAttr(Uint8List.fromList([0x44, 0xf8, 0x00, 0xff]), 0)!;
      expect(asSize.attribute, HeapAttribute.sizeExtent);
      expect(asSize.kind, HeapAttrKind.size);
      expect(asSize.asInt, 255);
      final asInc = decodeHeapAttr(f64Rec(0xf8, 0.2), 0)!;
      expect(asInc.attribute, HeapAttribute.scaleDIncr);
      expect(asInc.kind, HeapAttrKind.controlParam);
      expect(asInc.asDouble, closeTo(0.2, 1e-9));
    });

    test('raw 0x05A is a u8 flag; the C6 5A FF blob is defaultData (raw 0x25A)', () {
      final asFlag = decodeHeapAttr(Uint8List.fromList([0x24, 0x5a, 0x00]), 0)!;
      expect(asFlag.attribute, HeapAttribute.flag5A);
      expect(asFlag.kind, HeapAttrKind.flag);
      final blob = Uint8List.fromList([
        0xc6, 0x5a, 0xff, 0x00, 0x0c, //
        0x00, 0x00, 0x00, 0x08, ...'USB:TEST'.codeUnits,
      ]);
      final a = decodeHeapAttr(blob, 0)!;
      expect(a.attribute, HeapAttribute.defaultData);
      expect(a.width, HeapAttrWidth.blob);
      expect(a.kind, HeapAttrKind.stringBlob);
      expect(a.asString, 'USB:TEST');
      expect(a.length, 17);
    });
  });

  test('non-attribute byte returns null', () {
    expect(decodeHeapAttr(Uint8List.fromList([0xc4, 0x2d, 0x08]), 0), isNull);
    expect(decodeHeapAttr(Uint8List.fromList([0x10, 0x19]), 0), isNull);
  });

  test('05/06 zero-size leads defer to the typed-list framing when a type tag follows', () {
    // `05 71` followed by a type tag would be framed as a typed list by
    // recordSkip, so decodeHeapAttr must not claim a 2-byte attr there.
    final ambiguous = Uint8List.fromList([0x05, 0x71, 0x01, 0xfd, 0x00, 0x07]);
    expect(recordSkip(ambiguous, 0), 6);
    expect(decodeHeapAttr(ambiguous, 0), isNull);
    // Without a type tag the 2-byte false-flag reading applies.
    final plain = Uint8List.fromList([0x05, 0x71, 0x24, 0xdf]);
    expect(recordSkip(plain, 0), 2);
    expect(decodeHeapAttr(plain, 0)!.asInt, 0);
  });
}
