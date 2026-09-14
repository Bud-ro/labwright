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
const _mngSig = [0x8a, 0x4d, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];

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

Uint8List _dsimHeader(int w, int h, int depth, int pixelBytes) {
  final b = ByteData(46);
  b.setUint16(4, w);
  b.setUint16(6, h);
  b.setUint16(8, depth);
  b.setInt32(22, pixelBytes);
  b.setUint16(30, w);
  b.setUint16(32, h);
  b.setUint16(34, depth);
  return b.buffer.asUint8List();
}

Uint8List _dsimRaster(int w, int h, int depth, List<int> pixels, {List<int> trailer = const []}) =>
    u8([..._dsimHeader(w, h, depth, pixels.length), ...pixels, ...trailer]);

void main() {
  test('crc32 matches the canonical empty-IEND checksum', () {
    final iend = Uint8List.fromList('IEND'.codeUnits);
    expect(crc32(iend, 0, iend.length), 0xAE426082);
  });

  group('MNGI (bare PNG)', () {
    test('records every chunk, verifies CRCs, and splits framing from the copied IDAT', () {
      final png = _png();
      final stream = decodePngStream(png);
      expect(stream.serialize(), same(png));
      expect(stream.kind, ChunkStreamKind.png);
      expect((stream.width, stream.height, stream.chunkCount), (4, 4, 3));
      expect([for (var i = 0; i < 3; i++) stream.chunkTypeAt(i)], ['IHDR', 'IDAT', 'IEND']);
      expect(stream.chunkDataAt(1), [0xde, 0xad, 0xbe, 0xef, 0x01, 0x02]);
      final acc = stream.accounting();
      expect(acc.modelBytes + acc.copiedBytes, png.length);
      expect((acc.chunkCount, acc.crcVerified, acc.copiedBytes), (3, 3, 6));
    });

    test('a corrupt CRC keeps that chunk retained', () {
      final png = Uint8List.fromList(_png());
      png[png.length - 1] ^= 0xff;
      final stream = decodePngStream(png);
      expect(stream.chunkCrcOkAt(2), isFalse);
      expect(stream.accounting().crcVerified, 2);
      expect(stream.serialize(), same(png));
    });

    test('an MNG stream is the same chunk framing ending at MEND', () {
      final mng = u8([
        ..._mngSig,
        ..._chunk('MHDR', [0, 0, 0, 9, 0, 0, 0, 7, 0, 0, 0, 0]),
        ..._chunk('MEND', const []),
      ]);
      final stream = decodePngStream(mng);
      expect((stream.kind, stream.width, stream.height, stream.chunkCount), (ChunkStreamKind.mng, 9, 7, 2));
    });

    test('a stream that does not tile to its end chunk violates the precondition', () {
      expect(() => decodePngStream(u8([0x8a, 0x4d, 0x4e, 0x47, 0, 1, 2, 3])), throwsA(isA<AssertionError>()));
      expect(() => decodePngStream(u8([..._png(), 0])), throwsA(isA<AssertionError>()));
    });

    test('an unrecoverable IDAT stream leaves the content-level split zero', () {
      final stream = decodePngStream(_png());
      final acc = stream.accounting();
      expect((acc.compressedContentBytes, acc.inflatedContentBytes), (0, 0));
      expect(stream.rasterRoundTrips(), isNull);
    });

    test('a real IDAT inflates to the raster and counts as content', () {
      final made = _pngRealIdat();
      final stream = decodePngStream(made.png);
      expect(stream.inflateRaster(), made.raster);
      final acc = stream.accounting();
      expect(acc.inflatedContentBytes, made.raster.length);
      expect(acc.compressedContentBytes, greaterThan(0));
      expect(stream.rasterRoundTrips(), isTrue);
    });

    test('a raster split across multiple IDAT chunks concatenates and inflates', () {
      final made = _pngRealIdat(idatParts: 3);
      final stream = decodePngStream(made.png);
      expect(stream.inflateRaster(), made.raster);
      expect(stream.rasterRoundTrips(), isTrue);
    });
  });

  group('DSIM', () {
    test('raw raster: header + pixels are model, trailer retained', () {
      final pixels = List.filled(4 * 4 * 3, 0xbb);
      final dsim = _dsimRaster(4, 4, 24, pixels, trailer: const [1, 2, 3, 4]);
      final image = decodeDataSpaceImage(dsim);
      expect(image, isA<ViDataSpaceRaster>());
      expect(image.serialize(), same(dsim));
      expect((image as ViDataSpaceRaster).pixels, pixels);
      expect(image.trailer, [1, 2, 3, 4]);
      expect((image.accounting.modelBytes, image.accounting.copiedBytes), (46 + pixels.length, 4));
    });

    test('raw raster with a mismatched pixel-count field violates the precondition', () {
      final dsim = u8([..._dsimHeader(4, 4, 24, 999), ...List.filled(48, 0)]);
      expect(() => decodeDataSpaceImage(dsim), throwsA(isA<AssertionError>()));
    });

    test('PNG-carrying: header + PNG framing modelled, IDAT and trailer retained', () {
      final png = _png();
      final dsim = u8([..._dsimHeader(4, 4, 24, -1), ...png, 0xaa, 0xbb]);
      final image = decodeDataSpaceImage(dsim);
      expect(image, isA<ViDataSpacePng>());
      final withPng = image as ViDataSpacePng;
      expect((withPng.pngOffset, withPng.png.width, withPng.png.chunkCount), (46, 4, 3));
      expect(withPng.png.bytes, png);
      expect(withPng.trailer, [0xaa, 0xbb]);
      expect((image.accounting.modelBytes, image.accounting.copiedBytes), (46 + (png.length - 6), 6 + 2));
      final at48 = u8([..._dsimHeader(4, 4, 8, -1), 0, 0, ...png]);
      expect((decodeDataSpaceImage(at48) as ViDataSpacePng).pngOffset, 48);
    });

    test('a 16-byte header-only image carries just the geometry', () {
      final image = decodeDataSpaceImage(u8([0, 0, 0, 0, 0, 20, 0, 20, 0, 1, 0, 0, 0, 0, 0, 0]));
      expect(image, isA<ViDataSpaceHeaderOnly>());
      expect((image.width, image.height, image.depth, image.trailer.length), (20, 20, 1, 0));
    });

    test('an invalid header (nonzero lead or unrepeated geometry) violates the precondition', () {
      final dsim = _dsimRaster(4, 4, 24, List.filled(48, 0));
      expect(() => decodeDataSpaceImage(Uint8List.fromList(dsim)..[0] = 1), throwsA(isA<AssertionError>()));
      expect(() => decodeDataSpaceImage(Uint8List.fromList(dsim)..[31] = 5), throwsA(isA<AssertionError>()));
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

    test('iCCP: prefix modelled, zlib retained, inflated profile counts as content', () {
      final profile = List.generate(200, (i) => (i * 13 + 5) & 0xff);
      final stream = decodePngStream(pngWith(iccp(profile)));
      final acc = stream.accounting();
      expect(acc.inflatedContentBytes, profile.length);
      expect(acc.compressedContentBytes, greaterThan(0));
      expect(stream.ancillaryRoundTrips(), (count: 1, ok: 1));
    });

    test('uncompressed iTXt is modelled whole and carries no ancillary stream', () {
      final stream = decodePngStream(pngWith(itxtPlain('Comment', 'hello world')));
      expect(stream.accounting().copiedBytes, 4);
      expect(stream.ancillaryRoundTrips(), (count: 0, ok: 0));
    });
  });
}
