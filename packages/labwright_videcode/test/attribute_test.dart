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
}
