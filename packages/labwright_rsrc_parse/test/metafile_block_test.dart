import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'test_util.dart';

List<int> _be16(int v) => [(v >> 8) & 0xff, v & 0xff];

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

List<int> _le32(int v) => [v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff];

Uint8List _pict() => u8([
  ..._be16(0), // size
  ..._be16(0), ..._be16(0), ..._be16(0x0100), ..._be16(0x0100), // picFrame rect
  ..._be16(0x0011), ..._be16(0x02ff), // VersionOp + version 2
  ..._be16(0x0c00), ...List<int>.filled(24, 0), // HeaderOp + 24-byte header
  ..._be16(0x0000), // NOP
  ..._be16(0x00a1), ..._be16(0), ..._be16(3), 0x61, 0x62, 0x63, 0x00, // LongComment "abc" + pad
  ..._be16(0x00ff), // OpEndPic
]);

Uint8List _emf() {
  final header = <int>[
    ..._le32(1), // iType = EMR_HEADER
    ..._le32(48), // nSize
    ...List<int>.filled(40, 0), // params (40 bytes → record is 48 B)
  ];
  header.setRange(40, 44, const [0x20, 0x45, 0x4d, 0x46]); // " EMF" signature @40
  header.setRange(16, 20, _le32(640));
  header.setRange(20, 24, _le32(480));
  final eof = <int>[
    ..._le32(14), // iType = EMR_EOF
    ..._le32(20), // nSize
    ...List<int>.filled(12, 0), // nPalEntries, offPalEntries, sizeLast
  ];
  return u8([...header, ...eof]);
}

void main() {
  group('PICT v2', () {
    test('decodes the frame rectangle and accounts for the opcodes to OpEndPic', () {
      final p = _pict();
      final pict = decodePict(p);
      expect(pict.serialize(), same(p));
      expect((pict.top, pict.left, pict.bottom, pict.right, pict.width), (0, 0, 0x100, 0x100, 0x100));
      expect(pict.frame.modelBytes + pict.frame.copiedBytes, p.length);
      expect((pict.frame.elementCount, pict.frame.copiedBytes), (4, 4));
      expect(pict.quickTimeRaster, isNull);
    });

    test('rejects a non-version-2 header', () {
      final p = Uint8List.fromList(_pict())..setRange(12, 14, const [0x00, 0x00]);
      expect(() => decodePict(p), throwsA(isA<AssertionError>()));
    });

    test('rejects a stream that does not end at OpEndPic on the last byte', () {
      expect(() => decodePict(u8([..._pict(), 0x00, 0x00])), throwsA(isA<AssertionError>()));
    });

    test('metafileFrame dispatches by tag', () {
      expect(metafileFrame('PICT', _pict())?.elementCount, 4);
      expect(metafileFrame('XXXX', _pict()), isNull);
    });

    test('a CompressedQuickTime raw image is fully modelled and exposes its pixels', () {
      final p = _pictWithRawQuickTime(3, 2, 24);
      final pict = decodePict(p);
      expect(pict.frame.modelBytes + pict.frame.copiedBytes, p.length);
      expect(pict.frame.copiedBytes, 0);
      final r = pict.quickTimeRaster!;
      expect((r.width, r.height, r.depth), (3, 2, 24));
      expect(r.pixels, List<int>.generate(18, (i) => i & 0xff));
    });

    test('a non-raw CompressedQuickTime codec stays an opaque leaf', () {
      final p = _pictWithRawQuickTime(2, 2, 32);
      const cTypeAt = 14 + 26 + 2 + 4 + 68 + 4;
      final q = Uint8List.fromList(p)..setRange(cTypeAt, cTypeAt + 4, 'jpeg'.codeUnits);
      final pict = decodePict(q);
      expect(pict.frame.copiedBytes, greaterThan(100));
      expect(pict.quickTimeRaster, isNull);
    });
  });

  group('EMF', () {
    test('decodes the bounds and accounts for the records to EMR_EOF', () {
      final e = _emf();
      final emf = decodeEmf(e);
      expect(emf.serialize(), same(e));
      expect((emf.boundsRight, emf.boundsBottom), (640, 480));
      expect(emf.frame.modelBytes + emf.frame.copiedBytes, e.length);
      expect(emf.frame.elementCount, 2);
      expect(metafileFrame('WEMF', e)?.elementCount, 2);
    });

    test('rejects a missing signature, a bad record size, and a stream past EMR_EOF', () {
      expect(() => decodeEmf(Uint8List.fromList(_emf())..[40] = 0), throwsA(isA<AssertionError>()));
      expect(() => decodeEmf(Uint8List.fromList(_emf())..[48 + 4] = 21), throwsA(isA<AssertionError>()));
      expect(() => decodeEmf(u8([..._emf(), 0, 0, 0, 0])), throwsA(isA<AssertionError>()));
    });
  });
}
