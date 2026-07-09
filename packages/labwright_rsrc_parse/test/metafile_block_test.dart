import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'test_util.dart';

/// Big-endian u16 bytes (QuickDraw PICT byte order).
List<int> _be16(int v) => [(v >> 8) & 0xff, v & 0xff];

/// Little-endian u32 bytes (EMF byte order).
List<int> _le32(int v) => [v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff];

/// A minimal version-2 PICT: header + version words + HeaderOp + a NOP + a
/// LongComment (odd data → pad) + OpEndPic on the last byte.
Uint8List _pict() => u8([
  ..._be16(0), // size
  ..._be16(0), ..._be16(0), ..._be16(0x0100), ..._be16(0x0100), // picFrame rect
  ..._be16(0x0011), ..._be16(0x02ff), // VersionOp + version 2
  ..._be16(0x0c00), ...List<int>.filled(24, 0), // HeaderOp + 24-byte header
  ..._be16(0x0000), // NOP
  ..._be16(0x00a1), ..._be16(0), ..._be16(3), 0x61, 0x62, 0x63, 0x00, // LongComment "abc" + pad
  ..._be16(0x00ff), // OpEndPic
]);

/// A minimal EMF: EMR_HEADER (48 B, " EMF" @40) + EMR_EOF (20 B) on the last byte.
Uint8List _emf() {
  final header = <int>[
    ..._le32(1), // iType = EMR_HEADER
    ..._le32(48), // nSize
    ...List<int>.filled(40, 0), // params (40 bytes → record is 48 B)
  ];
  header.setRange(40, 44, const [0x20, 0x45, 0x4d, 0x46]); // " EMF" signature @40
  final eof = <int>[
    ..._le32(14), // iType = EMR_EOF
    ..._le32(20), // nSize
    ...List<int>.filled(12, 0), // nPalEntries, offPalEntries, sizeLast
  ];
  return u8([...header, ...eof]);
}

void main() {
  group('PICT v2 framer', () {
    test('frames byte-exact and tiles to OpEndPic', () {
      final p = _pict();
      final f = framePictV2(p);
      expect(f, isNotNull);
      expect(f!.kind, ViMetafileKind.pictV2);
      expect(f.bytes, orderedEquals(p)); // byte-exact re-emission
      expect(f.modelBytes + f.copiedBytes, p.length); // tiling law
      expect(f.elementCount, 4); // HeaderOp, NOP, LongComment, OpEndPic
      // The 3-byte comment data ("abc" + pad) is the only opaque leaf.
      expect(f.copiedBytes, 4);
    });

    test('rejects a non-version-2 header', () {
      final p = Uint8List.fromList(_pict())..setRange(12, 14, const [0x00, 0x00]);
      expect(framePictV2(p), isNull);
    });

    test('rejects a stream that does not end at OpEndPic on the last byte', () {
      final p = u8([..._pict(), 0x00, 0x00]); // trailing bytes past OpEndPic
      expect(framePictV2(p), isNull);
    });

    test('dispatches through frameMetafile by tag', () {
      expect(frameMetafile('PICT', _pict())?.kind, ViMetafileKind.pictV2);
      expect(frameMetafile('XXXX', _pict()), isNull);
    });
  });

  group('EMF framer', () {
    test('frames byte-exact and tiles to EMR_EOF', () {
      final e = _emf();
      final f = frameEmf(e);
      expect(f, isNotNull);
      expect(f!.kind, ViMetafileKind.emf);
      expect(f.bytes, orderedEquals(e));
      expect(f.modelBytes + f.copiedBytes, e.length);
      expect(f.elementCount, 2); // EMR_HEADER, EMR_EOF
      // Two 8-byte record headers (16) + EMR_HEADER's fixed base (capped at this
      // synthetic's 40 param bytes) + EMR_EOF's 8-byte fixed prefix = 64. Only
      // EMR_EOF's trailing nSizeLast word (4 B) is the copied leaf.
      expect(f.modelBytes, 64);
      expect(f.copiedBytes, 4);
    });

    test('rejects a non-EMF magic / missing signature', () {
      final e = Uint8List.fromList(_emf())..setRange(40, 44, const [0, 0, 0, 0]);
      expect(frameEmf(e), isNull);
    });

    test('rejects a record whose size is not 4-aligned', () {
      final e = Uint8List.fromList(_emf());
      ByteData.sublistView(e).setUint32(4, 47, Endian.little); // nSize not %4
      expect(frameEmf(e), isNull);
    });

    test('rejects a stream that does not end at EMR_EOF on the last byte', () {
      final e = u8([..._emf(), 0x00, 0x00, 0x00, 0x00]);
      expect(frameEmf(e), isNull);
    });

    test('dispatches through frameMetafile by tag', () {
      expect(frameMetafile('WEMF', _emf())?.kind, ViMetafileKind.emf);
    });
  });
}
