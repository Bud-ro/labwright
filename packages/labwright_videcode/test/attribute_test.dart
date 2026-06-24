import 'dart:typed_data';

import 'package:labwright_videcode/labwright_videcode.dart';
import 'package:test/test.dart';

/// Builds a `C5 <id> 08 <f64>` numeric-control parameter record.
Uint8List f64Rec(int id, double v) {
  final b = BytesBuilder()..add([0xc5, id, 0x08]);
  final d = ByteData(8)..setFloat64(0, v); // big-endian default
  b.add(d.buffer.asUint8List());
  return b.toBytes();
}

void main() {
  group('HeapAttribute catalog', () {
    test('ids are unique and round-trip via fromId', () {
      final seen = <int>{};
      for (final a in HeapAttribute.values) {
        if (a == HeapAttribute.unknown) continue;
        expect(seen.add(a.id), isTrue, reason: 'duplicate id 0x${a.id.toRadixString(16)} on $a');
        expect(HeapAttribute.fromId(a.id), a);
        expect(a.attrName, isNotEmpty);
      }
    });

    test('uncatalogued id maps to unknown', () {
      expect(HeapAttribute.fromId(0x99), HeapAttribute.unknown);
      expect(HeapAttribute.unknown.id, -1);
    });

    test('every confirmed name has a concrete kind (not unknown)', () {
      for (final a in HeapAttribute.values) {
        if (a == HeapAttribute.unknown) continue;
        expect(a.kind, isNot(HeapAttrKind.unknown));
      }
    });
  });

  group('decodeHeapAttr — widths', () {
    test('u8 (0x24)', () {
      final a = decodeHeapAttr(Uint8List.fromList([0x24, 0xdf, 0x05]), 0)!;
      expect(a.attribute, HeapAttribute.objectClass);
      expect(a.width, HeapAttrWidth.u8);
      expect(a.asInt, 5);
      expect(a.kind, HeapAttrKind.enumValue);
      expect(a.length, 3);
    });

    test('u16 (0x44)', () {
      final a = decodeHeapAttr(Uint8List.fromList([0x44, 0x89, 0x01, 0x00]), 0)!;
      expect(a.attribute, HeapAttribute.sizeExtent);
      expect(a.width, HeapAttrWidth.u16);
      expect(a.asInt, 256);
      expect(a.kind, HeapAttrKind.size);
      expect(a.length, 4);
    });

    test('u24 (0x64)', () {
      final a = decodeHeapAttr(Uint8List.fromList([0x64, 0xcb, 0x10, 0x00, 0x00]), 0)!;
      expect(a.attribute, HeapAttribute.packedValue);
      expect(a.width, HeapAttrWidth.u24);
      expect(a.asInt, 0x100000);
      expect(a.length, 5);
    });

    test('bare flag (0xE4)', () {
      final a = decodeHeapAttr(Uint8List.fromList([0xe4, 0x59]), 0)!;
      expect(a.attribute, HeapAttribute.reservedFlag);
      expect(a.width, HeapAttrWidth.flag);
      expect(a.length, 2);
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
  });

  group('decodeHeapAttr — control params (C5/f64)', () {
    test('min/max/unit decode as doubles with controlParam kind', () {
      final mn = decodeHeapAttr(f64Rec(0xf5, -1.0), 0)!;
      expect(mn.attribute, HeapAttribute.controlMin);
      expect(mn.kind, HeapAttrKind.controlParam);
      expect(mn.asDouble, -1.0);

      final unit = decodeHeapAttr(f64Rec(0xfa, 1.0), 0)!;
      expect(unit.attribute, HeapAttribute.controlUnit);
      expect(unit.asDouble, 1.0);
    });
  });

  group('rectangle-payload ids (C5 …08 is a rect, not an f64)', () {
    test('0x29 decodes its len-08 payload as a 4× s16 rectangle', () {
      // C5 29 08 <top=8, left=0, bottom=16, right=8>
      final rec = Uint8List.fromList([0xc5, 0x29, 0x08, 0x00, 0x08, 0x00, 0x00, 0x00, 0x10, 0x00, 0x08]);
      final a = decodeHeapAttr(rec, 0)!;
      expect(a.attribute, HeapAttribute.terminalRect);
      expect(a.width, HeapAttrWidth.rect);
      expect(a.kind, HeapAttrKind.rectangle);
      expect(a.asDouble, isNull); // NOT decoded as a garbage f64
      final r = a.asRect!;
      expect([r.top, r.left, r.bottom, r.right], [8, 0, 16, 8]);
      expect(a.length, 11);
    });

    test('0x29 in the 84-form is still a colour (resolved by width)', () {
      final a = decodeHeapAttr(Uint8List.fromList([0x84, 0x29, 0xff, 0x00, 0x00, 0x0c]), 0)!;
      expect(a.attribute, HeapAttribute.terminalRect);
      expect(a.width, HeapAttrWidth.rgb);
      expect(a.kind, HeapAttrKind.color);
      expect(a.rgb, 0x00000c);
    });

    test('a genuine f64 id (0xF5) is unaffected by the rect carve-out', () {
      final a = decodeHeapAttr(f64Rec(0xf5, -1.0), 0)!;
      expect(a.width, HeapAttrWidth.f64);
      expect(a.asRect, isNull);
      expect(a.asDouble, -1.0);
    });

    test('0x63/0x64 paired-rect block decodes as rectangles, not garbage f64', () {
      final a = decodeHeapAttr(Uint8List.fromList([0xc5, 0x63, 0x08, 0, 0, 0, 0, 0, 75, 0, 75]), 0)!;
      expect(a.attribute, HeapAttribute.rectFieldA);
      expect(a.kind, HeapAttrKind.rectangle);
      expect(a.asRect!.height, 75);
      expect(a.asDouble, isNull);
      final b = decodeHeapAttr(Uint8List.fromList([0xc5, 0x64, 0x08, 0, 0, 0, 0, 0, 75, 0, 75]), 0)!;
      expect(b.attribute, HeapAttribute.rectFieldB);
      expect(b.kind, HeapAttrKind.rectangle);
    });

    test('0xE7 is a nested-record CONTAINER (C5 E7 <len>), not a garbage f64', () {
      // C5 E7 08 <8 bytes>: container, value = payload[0] (inner element count), len 3+8.
      final rec = Uint8List.fromList([0xc5, 0xe7, 0x08, 0x04, 0x10, 0x00, 0x20, 0x00, 0x30, 0x00, 0x40]);
      final a = decodeHeapAttr(rec, 0)!;
      expect(a.attribute, HeapAttribute.fpControlAttr);
      expect(a.width, HeapAttrWidth.container);
      expect(a.kind, HeapAttrKind.container);
      expect(a.asDouble, isNull); // NOT a garbage f64
      expect(a.asInt, 0x04); // payload[0] — a count-like leading byte (not a reliable element count)
      expect(a.length, 11);
      // A variable-length form (len 6) is also a container.
      final r6 = decodeHeapAttr(Uint8List.fromList([0xc5, 0xe7, 0x06, 0x03, 0, 0, 0, 0, 0]), 0)!;
      expect(r6.width, HeapAttrWidth.container);
      expect(r6.length, 9);
    });

    test('the 45 E7 / 85 E7 scalar forms of 0xE7 stay value-kind-known (not container, not faked)', () {
      final u16 = decodeHeapAttr(Uint8List.fromList([0x45, 0xe7, 0x02, 0x08]), 0)!;
      expect(u16.attribute, HeapAttribute.fpControlAttr);
      expect(u16.width, HeapAttrWidth.u16);
      expect(u16.kind, isNot(HeapAttrKind.container)); // a scalar form isn't a container
      final rgb = decodeHeapAttr(Uint8List.fromList([0x85, 0xe7, 0x01, 0x00, 0x01, 0x00]), 0)!;
      expect(rgb.width, HeapAttrWidth.rgb);
      expect(rgb.rgb, isNull); // not a fake colour
    });
  });

  group('C5/C6 …08 + inline-string family (review3 follow-up)', () {
    test('0x31 inline string: C6 31 <len> <raw ASCII> decodes to the text', () {
      final rec = Uint8List.fromList([0xc6, 0x31, 0x05, ...'Scale'.codeUnits]);
      final a = decodeHeapAttr(rec, 0)!;
      expect(a.attribute, HeapAttribute.propertyName);
      expect(a.kind, HeapAttrKind.stringBlob);
      expect(a.asString, 'Scale');
      expect(a.length, 8);
    });

    test('0x20/0x21 in the C5/C6 …08 form are f64 control range min/max', () {
      final mn = decodeHeapAttr(f64Rec(0x20, -1.0), 0)!;
      expect(mn.attribute, HeapAttribute.foregroundColor);
      expect(mn.kind, HeapAttrKind.controlParam);
      expect(mn.asDouble, -1.0);
      // ...but the 84/nibble form of 0x20 is still a colour.
      final col = decodeHeapAttr(Uint8List.fromList([0x84, 0x20, 0xff, 0x10, 0x10, 0x10]), 0)!;
      expect(col.kind, HeapAttrKind.color);
    });

    test('0x22 in the C5/C6 …08 form is an f64 control default (dual-use with text)', () {
      final def = decodeHeapAttr(f64Rec(0x22, 0.0), 0)!;
      expect(def.attribute, HeapAttribute.textStyle);
      expect(def.kind, HeapAttrKind.controlParam);
      expect(def.asDouble, 0.0);
      // the 84-form of 0x22 is still a text/style field, NOT a colour.
      final txt = decodeHeapAttr(Uint8List.fromList([0x84, 0x22, 0x50, 0x61, 0x6e, 0x65]), 0)!;
      expect(txt.kind, HeapAttrKind.text);
      expect(txt.rgb, isNull);
    });

    test('0x6C <u8len> u32-strlen form decodes a library/format name (validity-gated)', () {
      // C6 6C <len=10> <u32 strlen=6> "Robot!"
      final rec = Uint8List.fromList([0xc6, 0x6c, 0x0a, 0x00, 0x00, 0x00, 0x06, ...'Robot!'.codeUnits]);
      final a = decodeHeapAttr(rec, 0)!;
      expect(a.attribute, HeapAttribute.helpDescription);
      expect(a.kind, HeapAttrKind.stringBlob);
      expect(a.asString, 'Robot!');
      expect(a.length, 13);
      // A non-validating payload (strlen overruns len) is NOT fabricated — null.
      final bad = Uint8List.fromList([0xc6, 0x6c, 0x06, 0x00, 0x00, 0x00, 0x40, 0x41, 0x42]);
      expect(decodeHeapAttr(bad, 0), isNull);
    });

    test('0x6C help-description blob (C6 6C FF) decodes to text', () {
      final blob = Uint8List.fromList([
        0xc6, 0x6c, 0xff, 0x00, 0x0a, // C6 6C FF len=10
        0x00, 0x00, 0x00, 0x06, // u32 strlen=6
        ...'Robot!'.codeUnits,
      ]);
      final a = decodeHeapAttr(blob, 0)!;
      expect(a.attribute, HeapAttribute.helpDescription);
      expect(a.kind, HeapAttrKind.stringBlob);
      expect(a.asString, 'Robot!');
    });
  });

  group('rgb-width kind resolution is honest', () {
    test('catalogued colour ids resolve to colour', () {
      final a = decodeHeapAttr(Uint8List.fromList([0x84, 0x28, 0xff, 0x12, 0x34, 0x56]), 0)!;
      expect(a.kind, HeapAttrKind.color);
      expect(a.rgb, 0x123456);
    });

    test('non-colour ids in the 84/8x form keep their catalogued kind (not fake colour)', () {
      // 0x22 textStyle carries packed ASCII in the 4-byte form — must NOT be a colour.
      final text = decodeHeapAttr(Uint8List.fromList([0x84, 0x22, 0x50, 0x61, 0x6e, 0x65]), 0)!; // "Pane"
      expect(text.attribute, HeapAttribute.textStyle);
      expect(text.kind, HeapAttrKind.text);
      expect(text.rgb, isNull);
      // 0x74 formatStyle likewise.
      final fmt = decodeHeapAttr(Uint8List.fromList([0x84, 0x74, 0x25, 0x2e, 0x30, 0x66]), 0)!; // "%.0f"
      expect(fmt.kind, HeapAttrKind.text);
      expect(fmt.rgb, isNull);
    });
  });

  group('dual-use resolution by width', () {
    test('0xF8 is size as u16, coarse increment as f64', () {
      final asSize = decodeHeapAttr(Uint8List.fromList([0x44, 0xf8, 0x00, 0xff]), 0)!;
      expect(asSize.kind, HeapAttrKind.size);
      expect(asSize.asInt, 255);

      final asInc = decodeHeapAttr(f64Rec(0xf8, 0.2), 0)!;
      expect(asInc.kind, HeapAttrKind.controlParam);
      expect(asInc.asDouble, closeTo(0.2, 1e-9));
    });

    test('0x5A is a flag as u8, identity string as C6 blob', () {
      final asFlag = decodeHeapAttr(Uint8List.fromList([0x24, 0x5a, 0x00]), 0)!;
      expect(asFlag.kind, HeapAttrKind.flag);

      // C6 5A FF <u16 len=12> <u32 strlen=8> "USB:TEST"
      final blob = Uint8List.fromList([
        0xc6, 0x5a, 0xff, 0x00, 0x0c, //
        0x00, 0x00, 0x00, 0x08, //
        ...'USB:TEST'.codeUnits,
      ]);
      final a = decodeHeapAttr(blob, 0)!;
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

  test('decodeHeapAttr agrees with recordSkip on the 64 cb 26 form (returns null)', () {
    // recordSkip frames `64 cb 26` as a fixed 3-byte record, not a 0x64 u24
    // attribute; decodeHeapAttr must not fabricate a u24 here (would desync a walk).
    final rec = Uint8List.fromList([0x64, 0xcb, 0x26, 0x84, 0x20]);
    expect(recordSkip(rec, 0), 3);
    expect(decodeHeapAttr(rec, 0), isNull);
    // a normal 0x64 u24 attribute (id != cb-26 form) still decodes.
    final u24 = decodeHeapAttr(Uint8List.fromList([0x64, 0xcb, 0x10, 0x00, 0x00]), 0)!;
    expect(u24.width, HeapAttrWidth.u24);
  });
}
