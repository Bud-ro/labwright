import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'test_util.dart';

/// Big-endian u16 bytes (QuickDraw PICT byte order).
List<int> _be16(int v) => [(v >> 8) & 0xff, v & 0xff];

/// A QuickTime ImageDescription (86 B, big-endian) for an uncompressed `raw `
/// image of [w]x[h] at [depth] bits; its raster is `w*depth/8 * h` bytes.
Uint8List _rawImageDesc(int w, int h, int depth) {
  final id = ByteData(86);
  id.setUint32(0, 86); // idSize
  id.setUint32(4, 0x72617720); // cType 'raw '
  id.setUint16(32, w);
  id.setUint16(34, h);
  id.setUint32(44, (w * depth ~/ 8) * h); // dataSize
  id.setUint16(82, depth);
  return id.buffer.asUint8List();
}

/// A minimal version-2 PICT holding one CompressedQuickTime (0x8200) opcode that
/// carries an uncompressed `raw ` [w]x[h]x[depth] image, ending at OpEndPic. The
/// opcode data is a 68-byte QuickTime header (version/matrix/matte/mask, all
/// zero), the [ImageDescription], then the raster; the u32 size word after the
/// opcode counts all of that.
Uint8List _pictWithRawQuickTime(int w, int h, int depth) {
  final imageDesc = _rawImageDesc(w, h, depth);
  final rasterLen = (w * depth ~/ 8) * h;
  final qtLen = 68 + imageDesc.length + rasterLen;
  final total = 14 + 26 + 2 + 4 + qtLen + 2;
  final b = ByteData(total);
  final out = b.buffer.asUint8List();
  var o = 0;
  void u16(int value) {
    b.setUint16(o, value);
    o += 2;
  }

  void u32(int value) {
    b.setUint32(o, value);
    o += 4;
  }

  u16(0); // size
  o += 8; // picFrame rect (zeros)
  u16(0x0011); // VersionOp
  u16(0x02ff); // version 2
  u16(0x0c00); // HeaderOp
  o += 24; // header (zeros)
  u16(0x8200); // CompressedQuickTime
  u32(qtLen); // opcode data size (everything after this word)
  o += 68; // QuickTime version/matrix/matte/mask fields (zeros → matte/mask 0)
  out.setRange(o, o + imageDesc.length, imageDesc);
  o += imageDesc.length;
  for (var i = 0; i < rasterLen; i++) {
    out[o + i] = i & 0xff; // raster
  }
  o += rasterLen;
  u16(0x00ff); // OpEndPic
  return out;
}

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

    test('a CompressedQuickTime raw image is fully modeled, byte-exact', () {
      final p = _pictWithRawQuickTime(2, 2, 32);
      final f = framePictV2(p);
      expect(f, isNotNull);
      expect(f!.bytes, orderedEquals(p)); // byte-exact re-emission
      expect(f.modelBytes + f.copiedBytes, p.length); // tiling law
      // The raw raster + its QuickTime framing are understood — nothing opaque.
      expect(f.copiedBytes, 0);
    });

    test('a non-raw CompressedQuickTime codec stays an opaque leaf', () {
      final p = _pictWithRawQuickTime(2, 2, 32);
      // The cType 4CC sits at: header(14) + HeaderOp(2+24) + QT opcode(2) +
      // size(4) + QT header(68) + idSize(4) = 118.
      const cTypeAt = 14 + 26 + 2 + 4 + 68 + 4;
      final q = Uint8List.fromList(p)..setRange(cTypeAt, cTypeAt + 4, 'jpeg'.codeUnits);
      final f = framePictV2(q);
      expect(f, isNotNull);
      expect(f!.bytes, orderedEquals(q)); // still byte-exact
      // An unrecognised codec is not modeled as a raster — its QuickTime data
      // (framing + ImageDescription + raster, ~170 B here) stays an opaque leaf.
      expect(f.copiedBytes, greaterThan(100));
    });

    test('decodePictQuickTimeRaster extracts the packed pixels', () {
      final p = _pictWithRawQuickTime(3, 2, 24);
      final r = decodePictQuickTimeRaster(p);
      expect(r, isNotNull);
      expect((r!.width, r.height, r.depth), (3, 2, 24));
      // 3px × 24-bit = 9 B/row × 2 rows; the synthetic raster is i & 0xff.
      expect(r.pixels, List<int>.generate(18, (i) => i & 0xff));
      // A non-raw codec yields no raster.
      const cTypeAt = 14 + 26 + 2 + 4 + 68 + 4;
      final q = Uint8List.fromList(p)..setRange(cTypeAt, cTypeAt + 4, 'jpeg'.codeUnits);
      expect(decodePictQuickTimeRaster(q), isNull);
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
