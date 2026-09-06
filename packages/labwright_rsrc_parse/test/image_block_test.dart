import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'test_util.dart';

List<int> _chunk(String type, List<int> data) {
  final typeData = Uint8List.fromList([...type.codeUnits, ...data]);
  final crc = crc32(typeData, 0, typeData.length);
  final len = ByteData(4)..setUint32(0, data.length);
  final crcB = ByteData(4)..setUint32(0, crc);
  return [...len.buffer.asUint8List(), ...type.codeUnits, ...data, ...crcB.buffer.asUint8List()];
}

const _pngSig = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];

Uint8List _png() {
  final ihdr = _chunk('IHDR', [
    0, 0, 0, 4, // width 4
    0, 0, 0, 4, // height 4
    8, 2, 0, 0, 0, // bit depth 8, colour type 2 (RGB), 0/0/0
  ]);
  final idat = _chunk('IDAT', [0xde, 0xad, 0xbe, 0xef, 0x01, 0x02]);
  final iend = _chunk('IEND', const []);
  return u8([..._pngSig, ...ihdr, ...idat, ...iend]);
}

({Uint8List png, Uint8List raster}) _pngRealIdat({int idatParts = 1}) {
  const w = 4, h = 4;
  final raster = Uint8List((1 + w * 3) * h);
  for (var i = 0; i < raster.length; i++) {
    raster[i] = (i * 7 + 3) & 0xff;
  }
  final z = Uint8List.fromList(const ZLibEncoder().encodeBytes(raster));
  final ihdr = _chunk('IHDR', [0, 0, 0, w, 0, 0, 0, h, 8, 2, 0, 0, 0]);
  final iend = _chunk('IEND', const []);
  final idats = <int>[];
  final part = (z.length / idatParts).ceil();
  for (var off = 0; off < z.length; off += part) {
    idats.addAll(_chunk('IDAT', z.sublist(off, off + part > z.length ? z.length : off + part)));
  }
  return (png: u8([..._pngSig, ...ihdr, ...idats, ...iend]), raster: raster);
}

Uint8List _dsimRaster(int w, int h, int depth, List<int> pixels, {List<int> trailer = const []}) {
  final b = ByteData(46);
  b.setUint16(4, w);
  b.setUint16(6, h);
  b.setUint16(8, depth);
  b.setUint32(22, pixels.length); // pixel byte count
  b.setUint16(30, w);
  b.setUint16(32, h);
  b.setUint16(34, depth);
  return u8([...b.buffer.asUint8List(), ...pixels, ...trailer]);
}

void main() {
  test('crc32 matches the canonical empty-IEND checksum', () {
    final iend = Uint8List.fromList('IEND'.codeUnits);
    expect(crc32(iend, 0, iend.length), 0xAE426082);
  });

  group('MNGI (bare PNG)', () {
    test('frames a PNG byte-exact and splits framing/IHDR model vs IDAT copied', () {
      final png = _png();
      final img = decodeImageBlock('MNGI', png)!;
      expect(img.bytes, png, reason: 're-emit must be byte-exact');
      expect(img.modelBytes + img.copiedBytes, png.length);
      expect(img.pngChunks, 3);
      expect(img.crcVerified, 3);
      expect(img.copiedBytes, 6);
      expect(img.isRaster, isFalse);
    });

    test('a corrupt CRC keeps that chunk copied but stays byte-exact', () {
      final png = Uint8List.fromList(_png());
      png[png.length - 1] ^= 0xff;
      final img = decodeImageBlock('MNGI', png)!;
      expect(img.bytes, isNot(equals(png)), reason: 'recomputed CRC no longer matches the corrupted byte');
      expect(img.crcVerified, 2);
    });

    test('a non-PNG MNG variant is not framed', () {
      expect(decodeImageBlock('MNGI', u8([0x8a, 0x4d, 0x4e, 0x47, 0, 1, 2, 3])), isNull);
    });

    test('an unrecoverable IDAT stream leaves the content-level split zero', () {
      final img = decodeImageBlock('MNGI', _png())!;
      expect(img.compressedContentBytes, 0);
      expect(img.inflatedContentBytes, 0);
      expect(img.inflatedModelBytes, 0);
      expect(imageRasterRoundTrips('MNGI', _png()), isNull);
    });

    test('a real IDAT inflates to the raster and counts as content-model', () {
      final made = _pngRealIdat();
      final img = decodeImageBlock('MNGI', made.png)!;
      expect(img.bytes, made.png, reason: 're-emit must stay byte-exact');
      expect(inflateImageRaster('MNGI', made.png), made.raster);
      expect(img.inflatedContentBytes, made.raster.length);
      expect(img.inflatedModelBytes, made.raster.length);
      expect(img.inflatedCopiedBytes, 0);
      expect(img.compressedContentBytes, greaterThan(0));
      expect(imageRasterRoundTrips('MNGI', made.png), isTrue);
    });

    test('a raster split across multiple IDAT chunks concatenates and inflates', () {
      final made = _pngRealIdat(idatParts: 3);
      expect(inflateImageRaster('MNGI', made.png), made.raster);
      expect(imageRasterRoundTrips('MNGI', made.png), isTrue);
      final img = decodeImageBlock('MNGI', made.png)!;
      expect(img.inflatedModelBytes, made.raster.length);
    });
  });

  group('DSIM', () {
    test('raw raster: header + pixels are model, trailer copied, byte-exact', () {
      final pixels = List.filled(4 * 4 * 3, 0xbb);
      final dsim = _dsimRaster(4, 4, 24, pixels, trailer: const [1, 2, 3, 4]);
      final img = decodeImageBlock('DSIM', dsim)!;
      expect(img.bytes, dsim);
      expect(img.isRaster, isTrue);
      expect(img.modelBytes, 46 + pixels.length);
      expect(img.copiedBytes, 4);
      expect(img.inflatedContentBytes, 0);
      expect(img.compressedContentBytes, 0);
      expect(inflateImageRaster('DSIM', dsim), isNull);
    });

    test('raw raster with a mismatched pixel-count field is not framed', () {
      final b = ByteData(46);
      b.setUint16(4, 4);
      b.setUint16(6, 4);
      b.setUint16(8, 24);
      b.setUint32(22, 999);
      b.setUint16(30, 4);
      b.setUint16(32, 4);
      b.setUint16(34, 24);
      final dsim = u8([...b.buffer.asUint8List(), ...List.filled(48, 0)]);
      expect(decodeImageBlock('DSIM', dsim), isNull);
    });

    test('PNG-carrying: header model + framed PNG + trailer copied, byte-exact', () {
      final header = ByteData(46);
      header.setUint16(4, 4);
      header.setUint16(6, 4);
      header.setUint16(8, 24);
      header.setUint16(30, 4);
      header.setUint16(32, 4);
      header.setUint16(34, 24);
      final png = _png();
      final dsim = u8([...header.buffer.asUint8List(), ...png, 0xaa, 0xbb]);
      final img = decodeImageBlock('DSIM', dsim)!;
      expect(img.bytes, dsim);
      expect(img.isRaster, isFalse);
      expect(img.modelBytes, 46 + (png.length - 6));
      expect(img.copiedBytes, 6 + 2);
    });

    test('an invalid header (nonzero lead) is not framed', () {
      final dsim = _dsimRaster(4, 4, 24, List.filled(48, 0));
      final bad = Uint8List.fromList(dsim)..[0] = 1;
      expect(decodeImageBlock('DSIM', bad), isNull);
    });
  });

  group('ancillary chunks (iCCP / iTXt)', () {
    List<int> iccp(List<int> profile) {
      final z = const ZLibEncoder().encodeBytes(Uint8List.fromList(profile));
      return _chunk('iCCP', [...'ICC'.codeUnits, 0, 0, ...z]);
    }

    List<int> itxtPlain(String keyword, String text) =>
        _chunk('iTXt', [...keyword.codeUnits, 0, 0, 0, 0, 0, ...text.codeUnits]);

    Uint8List pngWith(List<int> extra) {
      final ihdr = _chunk('IHDR', [0, 0, 0, 4, 0, 0, 0, 4, 8, 2, 0, 0, 0]);
      final idat = _chunk('IDAT', [0xde, 0xad, 0xbe, 0xef]);
      final iend = _chunk('IEND', const []);
      return u8([..._pngSig, ...ihdr, ...extra, ...idat, ...iend]);
    }

    test('iCCP: prefix modeled, zlib copied, inflated profile counts as content', () {
      final profile = List.generate(200, (i) => (i * 13 + 5) & 0xff);
      final png = pngWith(iccp(profile));
      final img = decodeImageBlock('MNGI', png)!;
      expect(img.bytes, png, reason: 're-emit stays byte-exact');
      expect(img.inflatedContentBytes, profile.length);
      expect(img.inflatedModelBytes, profile.length);
      expect(img.compressedContentBytes, greaterThan(0));
      final rt = imageAncillaryRoundTrips('MNGI', png);
      expect(rt.count, 1);
      expect(rt.ok, 1, reason: 'the iCCP profile round-trips through standard zlib');
    });

    test('uncompressed iTXt is modeled whole, carries no ancillary stream', () {
      final png = pngWith(itxtPlain('Comment', 'hello world'));
      final img = decodeImageBlock('MNGI', png)!;
      expect(img.bytes, png);
      expect(img.copiedBytes, 4);
      expect(imageAncillaryRoundTrips('MNGI', png).count, 0);
    });
  });

  test('an unrelated tag is not an image block', () {
    expect(decodeImageBlock('STRG', _png()), isNull);
  });
}
