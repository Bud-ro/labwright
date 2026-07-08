import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'test_util.dart';

const _magic = [0x52, 0x53, 0x52, 0x43, 0x0d, 0x0a];

/// Minimal well-formed RSRC container: 32-byte header ++ data area ++ info area.
Uint8List _container(List<int> data, List<int> info) {
  final header = Uint8List(32)..setRange(0, 6, _magic);
  ByteData.sublistView(header)
    ..setUint32(16, 32 + data.length)
    ..setUint32(24, 32)
    ..setUint32(28, data.length);
  return u8([...header, ...data, ...info]);
}

/// Stamps the RSRC magic + version 3 + LVIN/LBVW header fields at [at].
void _stampHeader(Uint8List b, [int at = 0]) {
  b.setRange(at, at + 6, _magic);
  ByteData.sublistView(b, at).setUint16(6, 3);
  b.setRange(at + 8, at + 12, 'LVIN'.codeUnits);
  b.setRange(at + 12, at + 16, 'LBVW'.codeUnits);
}

/// Minimal well-formed VI: info area = bare subheader (blockListRel 0x34, zero blocks) + name-table bytes.
Uint8List _minimalVi() {
  final bytes = _container([1, 2, 3, 4], [for (var i = 0; i < 0x34; i++) 0, 0, 0, 0, 0, 7, 7]);
  bytes.setRange(36, 42, _magic);
  ByteData.sublistView(bytes, 36).setUint32(0x2c, 0x34);
  return bytes;
}

void main() {
  group('ViContainer', () {
    test('parse -> toBytes is byte-exact; the three regions partition the file', () {
      final bytes = _container([1, 2, 3, 4, 5], [9, 8, 7]);
      final c = ViContainer.parse(bytes);
      expect(c.header.length, 32);
      expect(c.dataArea, orderedEquals([1, 2, 3, 4, 5]));
      expect(c.infoArea, orderedEquals([9, 8, 7]));
      expect(c.toBytes(), orderedEquals(bytes));
      expect(c.header.length + c.dataArea.length + c.infoArea.length, bytes.length, reason: 'no gap/overlap');
    });

    test('rejects a non-RSRC / mis-ordered container', () {
      expect(() => ViContainer.parse(Uint8List(10)), throwsA(isA<ViFormatException>()));
      final bad = _container([1, 2, 3, 4], const []);
      ByteData.sublistView(bad).setUint32(16, 8);
      expect(
        () => ViContainer.parse(bad),
        throwsA(isA<ViFormatException>()),
        reason: 'infoOffset < dataOffset is mis-ordered: rejected, never silently mangled',
      );
    });
  });

  group('ViHeader', () {
    test('parse -> serialize round-trips every field byte-exact', () {
      final bytes = _container([1, 2, 3, 4, 5], [9, 8, 7]);
      final h = ViHeader.parse(bytes);
      expect((h.formatVersion, h.dataOffset, h.infoOffset, h.dataSize), (0, 32, 37, 5));
      expect(h.serialize(), orderedEquals(bytes.sublist(0, 32)));

      final real = Uint8List(32);
      _stampHeader(real);
      ByteData.sublistView(real)
        ..setUint32(16, 19968)
        ..setUint32(20, 2097)
        ..setUint32(24, 32)
        ..setUint32(28, 19936);
      final p = ViHeader.parse(real);
      expect((p.formatVersion, p.fileType, p.creator), (3, 'LVIN', 'LBVW'));
      expect((p.infoOffset, p.infoSize, p.dataOffset, p.dataSize), (19968, 2097, 32, 19936));
      expect(p.serialize(), orderedEquals(real));
    });

    test('rejects a non-RSRC / too-short header', () {
      expect(() => ViHeader.parse(Uint8List(10)), throwsA(isA<ViFormatException>()));
      expect(() => ViHeader.parse(Uint8List(32)), throwsA(isA<ViFormatException>()));
    });
  });

  group('ViInfoSubheader', () {
    test('parses the dup header + blockListRel + reserved fields, serializes byte-exact', () {
      final info = Uint8List(0x40);
      _stampHeader(info);
      ByteData.sublistView(info)
        ..setUint32(0x28, 0x20)
        ..setUint32(0x2c, 0x34)
        ..setUint32(0x30, 0x0810);
      final sh = ViInfoSubheader.parse(info);
      expect((sh.blockListRel, sh.headerCopy.fileType), (0x34, 'LVIN'));
      expect(sh.reservedA, hasLength(0x2c - 32));
      expect(sh.reservedB, hasLength(0x34 - 0x30));
      expect((sh.reservedAMarker, sh.viNameOffset), (0x20, 0x0810));
      expect(sh.serialize(), orderedEquals(info.sublist(0, 0x34)));
    });

    test('rejects an implausible blockListRel', () {
      final info = Uint8List(0x40);
      ByteData.sublistView(info).setUint32(0x2c, 0x99999);
      expect(() => ViInfoSubheader.parse(info), throwsA(isA<ViFormatException>()));
    });
  });

  group('ViBlockList', () {
    test('parses count + 12-byte entries and serializes byte-exact', () {
      final region = u8([
        0, 0, 0, 2, //
        ...'LVSR'.codeUnits, 0, 0, 0, 0, 0, 0, 0, 0x10,
        ...'BDHb'.codeUnits, 0, 0, 0, 1, 0, 0, 0, 0x40,
      ]);
      final info = Uint8List(0x34 + region.length)..setRange(0x34, 0x34 + region.length, region);
      final bl = ViBlockList.parse(info, 0x34);
      expect(bl.count, 2);
      expect((bl.entries[0].tag, bl.entries[0].descRel), ('LVSR', 0x10));
      expect((bl.entries[1].tag, bl.entries[1].sectionCountMinus1), ('BDHb', 1));
      expect(bl.byteLength, region.length);
      expect(bl.serialize(), orderedEquals(region));
    });

    test('rejects an implausible count', () {
      final info = Uint8List(0x40);
      ByteData.sublistView(info).setUint32(0x34, 999999);
      expect(() => ViBlockList.parse(info, 0x34), throwsA(isA<ViFormatException>()));
    });
  });

  group('ViSectionDescriptor', () {
    test('parses five u32 words at an offset and serializes byte-exact', () {
      final rec = Uint8List(24);
      final d = ByteData.sublistView(rec)
        ..setUint32(4, 0xAABBCCDD)
        ..setUint32(8, 0x1234)
        ..setUint32(12, 0)
        ..setUint32(16, 0x55)
        ..setUint32(20, 0xFFFFFFFF);
      final sd = ViSectionDescriptor.parse(rec, 4);
      expect(
        (sd.word0, sd.secRel, sd.word8, sd.nameRef, sd.word16, sd.isNamed),
        (0xAABBCCDD, 0x1234, 0, 0x55, 0xFFFFFFFF, true),
      );
      expect(sd.serialize(), orderedEquals(rec.sublist(4, 24)));
      expect(d.getUint16(0), 0, reason: 'padding before the offset-4 descriptor stays untouched');
    });

    test('word16 == 0 (LIBN/VINS) still parses byte-exact; isNamed reflects nameRef (0 = unnamed)', () {
      final rec = Uint8List(20);
      ByteData.sublistView(rec)
        ..setUint32(4, 0x1000)
        ..setUint32(16, 0);
      final sd = ViSectionDescriptor.parse(rec, 0);
      expect((sd.word16, sd.secRel), (0, 0x1000));
      expect(sd.serialize(), orderedEquals(rec));

      final unnamed = Uint8List(20);
      ByteData.sublistView(unnamed).setUint32(16, 0xFFFFFFFF);
      expect(ViSectionDescriptor.parse(unnamed, 0).isNamed, isFalse);
      final named = Uint8List(20);
      ByteData.sublistView(named)
        ..setUint32(12, 7)
        ..setUint32(16, 0xFFFFFFFF);
      expect(ViSectionDescriptor.parse(named, 0).isNamed, isTrue);
    });
  });

  group('ViInfoPreGap', () {
    test('parses the FTAB/VITS marker + flags and serializes byte-exact', () {
      final rec = Uint8List(20);
      ByteData.sublistView(rec)
        ..setUint32(0, 0x46544142)
        ..setUint32(8, 1992)
        ..setUint32(16, 0xFFFFFFFF);
      final pg = ViInfoPreGap.parse(rec);
      expect((pg.markerTag, pg.word1, pg.word2, pg.word3, pg.flags), ('FTAB', 0, 1992, 0, 0xFFFFFFFF));
      expect(pg.hasEmbeddedSections, isTrue);
      expect(pg.serialize(), orderedEquals(rec));

      final vits = Uint8List(20);
      ByteData.sublistView(vits).setUint32(0, 0x56495453);
      final v = ViInfoPreGap.parse(vits);
      expect((v.markerTag, v.hasEmbeddedSections), ('VITS', false));
      expect(v.serialize(), orderedEquals(vits));
    });
  });

  group('ViNameTable', () {
    test('peels the trailing Pascal VI name; headerValue only from the canonical 12-byte header', () {
      final tail = u8([0x00, 0x01, 0x02, 0x03, ...pascal('Foo.vi')]);
      final nt = ViNameTable.parse(tail);
      expect(nt.trailingName, 'Foo.vi');
      expect(nt.header, orderedEquals([0x00, 0x01, 0x02, 0x03]));
      expect(nt.headerValue, isNull, reason: 'header not the canonical 12 bytes');
      expect(nt.serialize(), orderedEquals(tail));

      final canon = u8([0, 0, 0, 0, 0, 0, 0x4d, 0x40, 0, 0, 0, 0, ...pascal('X.vi')]);
      final c = ViNameTable.parse(canon);
      expect((c.header.length, c.headerValue, c.trailingName), (12, 0x4d40, 'X.vi'));
      expect(c.serialize(), orderedEquals(canon));
    });

    test('no clean trailing name -> all header, null name, still byte-exact', () {
      final tail = u8([0x05, 0xFF, 0xFE, 0x00]);
      final nt = ViNameTable.parse(tail);
      expect(nt.trailingName, isNull);
      expect(nt.serialize(), orderedEquals(tail));
    });
  });

  group('ViInfoArea + ViVi + ViExport', () {
    test('ViInfoArea composes subheader + block list + raw rest byte-exact', () {
      final info = Uint8List(0x34 + 4 + 12 + 5);
      _stampHeader(info);
      ByteData.sublistView(info)
        ..setUint32(0x2c, 0x34)
        ..setUint32(0x34, 1);
      info.setRange(0x38, 0x3c, 'BDHb'.codeUnits);
      info.setRange(0x34 + 4 + 12, info.length, const [0xDE, 0xAD, 0xBE, 0xEF, 0x01]);
      final ia = ViInfoArea.parse(info);
      expect(ia.blockList.count, 1);
      expect(ia.rest, orderedEquals([0xDE, 0xAD, 0xBE, 0xEF, 0x01]));
      expect(ia.serialize(), orderedEquals(info));
    });

    test('ViContainer.serialize and ViVi.parse->serialize reproduce the original bytes', () {
      final bytes = _minimalVi();
      final c = ViContainer.parse(bytes);
      expect(c.serialize(), orderedEquals(c.toBytes()));
      expect(c.serialize(), orderedEquals(bytes));
      final vi = ViVi.parse(bytes);
      expect(vi.serialize(), orderedEquals(bytes));
      expect(vi.header.dataOffset, 32);
      expect(vi.infoArea.blockList.count, 0);
    });

    test('withSectionEdited / editSection reject a secRel that is not a section start', () {
      expect(
        () => ViVi.parse(_minimalVi()).withSectionEdited(secRel: 0, newPayload: u8([9])),
        throwsA(isA<ViFormatException>()),
      );
      expect(
        () => ViExport.editSection(_container([1, 2, 3, 4], const []), secRel: 0, newPayload: u8([9])),
        throwsA(isA<ViFormatException>()),
      );
    });

    test('rebuildDataArea serializes sections as [u32 len][payload] and gaps verbatim', () {
      final out = ViExport.rebuildDataArea([
        ViSectionData(secRel: 0, payload: u8([1, 2, 3])),
        ViGap(u8([0, 0])),
        ViSectionData(secRel: 9, payload: u8([9])),
      ]);
      expect(out, orderedEquals([0, 0, 0, 3, 1, 2, 3, 0, 0, 0, 0, 0, 1, 9]));
      final edited = ViExport.rebuildDataArea([
        ViSectionData(secRel: 0, payload: u8([7, 7, 7, 7, 7])),
      ]);
      expect(edited, orderedEquals([0, 0, 0, 5, 7, 7, 7, 7, 7]), reason: 'length prefix recomputed');
    });
  });
}
