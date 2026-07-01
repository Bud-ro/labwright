import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

/// The 6-byte RSRC container magic: `RSRC\r\n`.
const _rsrcMagic = [0x52, 0x53, 0x52, 0x43, 0x0d, 0x0a];

/// Builds a minimal well-formed RSRC container: 32-byte header (magic + the
/// dataOffset/dataSize/infoOffset words) ++ data area ++ info area.
Uint8List _container(List<int> data, List<int> info) {
  final header = Uint8List(32);
  header.setRange(0, 6, _rsrcMagic);
  final hd = ByteData.sublistView(header);
  const dataOffset = 32;
  final infoOffset = dataOffset + data.length;
  hd.setUint32(16, infoOffset);
  hd.setUint32(24, dataOffset);
  hd.setUint32(28, data.length);
  return Uint8List.fromList([...header, ...data, ...info]);
}

/// Builds the minimal well-formed VI used across the container/VI round-trip
/// tests: a container whose info area is a bare subheader (blockListRel = 0x34,
/// zero blocks) plus two trailing name-table bytes.
Uint8List _minimalVi() {
  final bytes = _container([1, 2, 3, 4], [for (var i = 0; i < 0x34; i++) 0, 0, 0, 0, 0, 7, 7]);
  bytes.setRange(36, 42, _rsrcMagic);
  ByteData.sublistView(bytes, 36).setUint32(0x2c, 0x34);
  return bytes;
}

void main() {
  group('ViContainer', () {
    test('parse → toBytes is byte-exact for an unmodified container', () {
      final bytes = _container([1, 2, 3, 4, 5], [9, 8, 7]);
      final c = ViContainer.parse(bytes);
      expect(c.header.length, 32);
      expect(c.dataArea, orderedEquals([1, 2, 3, 4, 5]));
      expect(c.infoArea, orderedEquals([9, 8, 7]));
      expect(c.toBytes(), orderedEquals(bytes));
    });

    test('rejects a non-RSRC / mis-ordered container', () {
      expect(() => ViContainer.parse(Uint8List(10)), throwsA(isA<ViFormatException>()));
      final bad = _container([1, 2, 3, 4], const []);
      ByteData.sublistView(bad).setUint32(16, 8);
      expect(() => ViContainer.parse(bad), throwsA(isA<ViFormatException>()),
          reason: 'infoOffset=8 < dataOffset=32 is mis-ordered and must be rejected, not silently mangled');
    });

    test('the three regions partition the whole file with no gap/overlap', () {
      final bytes = _container([10, 20, 30], [40, 50]);
      final c = ViContainer.parse(bytes);
      expect(c.header.length + c.dataArea.length + c.infoArea.length, bytes.length);
    });
  });

  group('ViHeader', () {
    test('parse -> serialize is byte-exact and decodes every field', () {
      final bytes = _container([1, 2, 3, 4, 5], [9, 8, 7]);
      final h = ViHeader.parse(bytes);
      expect(h.formatVersion, 0);
      expect(h.dataOffset, 32);
      expect(h.infoOffset, 37);
      expect(h.dataSize, 5);
      expect(h.serialize(), orderedEquals(bytes.sublist(0, 32)));
    });

    test('a realistic header round-trips each field exactly', () {
      final h = Uint8List(32);
      h.setRange(0, 6, _rsrcMagic);
      final d = ByteData.sublistView(h);
      d.setUint16(6, 3);
      h.setRange(8, 12, 'LVIN'.codeUnits);
      h.setRange(12, 16, 'LBVW'.codeUnits);
      d
        ..setUint32(16, 19968)
        ..setUint32(20, 2097)
        ..setUint32(24, 32)
        ..setUint32(28, 19936);
      final parsed = ViHeader.parse(h);
      expect(parsed.formatVersion, 3);
      expect(parsed.fileType, 'LVIN');
      expect(parsed.creator, 'LBVW');
      expect(parsed.infoOffset, 19968);
      expect(parsed.infoSize, 2097);
      expect(parsed.dataOffset, 32);
      expect(parsed.dataSize, 19936);
      expect(parsed.serialize(), orderedEquals(h));
    });

    test('rejects a non-RSRC / too-short header', () {
      expect(() => ViHeader.parse(Uint8List(10)), throwsA(isA<ViFormatException>()));
      expect(() => ViHeader.parse(Uint8List(32)), throwsA(isA<ViFormatException>()));
    });
  });

  group('ViInfoSubheader', () {
    test('parses the dup header + blockListRel and serializes byte-exact', () {
      final info = Uint8List(0x40);
      info.setRange(0, 6, _rsrcMagic);
      final d = ByteData.sublistView(info);
      d.setUint16(6, 3);
      info.setRange(8, 12, 'LVIN'.codeUnits);
      info.setRange(12, 16, 'LBVW'.codeUnits);
      d.setUint32(0x2c, 0x34);
      final sh = ViInfoSubheader.parse(info);
      expect(sh.blockListRel, 0x34);
      expect(sh.headerCopy.fileType, 'LVIN');
      expect(sh.reservedA, hasLength(0x2c - 32));
      expect(sh.reservedB, hasLength(0x34 - 0x30));
      expect(sh.serialize(), orderedEquals(info.sublist(0, 0x34)));
    });

    test('reservedAMarker reads 0x20 and viNameOffset reads the reservedB u32', () {
      final info = Uint8List(0x40);
      info.setRange(0, 6, _rsrcMagic);
      ByteData.sublistView(info)
        ..setUint16(6, 3)
        ..setUint32(0x28, 0x20)
        ..setUint32(0x2c, 0x34)
        ..setUint32(0x30, 0x0810);
      info.setRange(8, 12, 'LVIN'.codeUnits);
      info.setRange(12, 16, 'LBVW'.codeUnits);
      final sh = ViInfoSubheader.parse(info);
      expect(sh.reservedAMarker, 0x20);
      expect(sh.viNameOffset, 0x0810);
    });

    test('rejects an implausible blockListRel', () {
      final info = Uint8List(0x40);
      ByteData.sublistView(info).setUint32(0x2c, 0x99999);
      expect(() => ViInfoSubheader.parse(info), throwsA(isA<ViFormatException>()));
    });
  });

  group('ViBlockList', () {
    test('parses count + 12-byte entries and serializes byte-exact', () {
      final b = BytesBuilder();
      final cnt = ByteData(4)..setUint32(0, 2);
      b.add(cnt.buffer.asUint8List());
      void entry(String tag, int scm1, int descRel) {
        b.add(Uint8List.fromList(tag.codeUnits));
        final e = ByteData(8)
          ..setUint32(0, scm1)
          ..setUint32(4, descRel);
        b.add(e.buffer.asUint8List());
      }
      entry('LVSR', 0, 0x10);
      entry('BDHb', 1, 0x40);
      final region = b.toBytes();
      final info = Uint8List(0x34 + region.length)..setRange(0x34, 0x34 + region.length, region);

      final bl = ViBlockList.parse(info, 0x34);
      expect(bl.count, 2);
      expect(bl.entries[0].tag, 'LVSR');
      expect(bl.entries[0].descRel, 0x10);
      expect(bl.entries[1].tag, 'BDHb');
      expect(bl.entries[1].sectionCountMinus1, 1);
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
    test('parses a 20-byte descriptor into five u32 words and serializes byte-exact', () {
      final rec = Uint8List(24);
      final d = ByteData.sublistView(rec)
        ..setUint32(4, 0xAABBCCDD)
        ..setUint32(8, 0x1234)
        ..setUint32(12, 0)
        ..setUint32(16, 0x55)
        ..setUint32(20, 0xFFFFFFFF);
      final sd = ViSectionDescriptor.parse(rec, 4);
      expect(sd.word0, 0xAABBCCDD);
      expect(sd.secRel, 0x1234);
      expect(sd.word8, 0);
      expect(sd.nameRef, 0x55);
      expect(sd.word16, 0xFFFFFFFF);
      expect(sd.isNamed, isTrue);
      expect(sd.serialize(), orderedEquals(rec.sublist(4, 24)));
      expect(d.getUint16(0), 0, reason: 'the padding before the offset-4 descriptor stays untouched');
    });

    test('word16 == 0 still parses as a (LIBN/VINS) section, byte-exact', () {
      final rec = Uint8List(20);
      ByteData.sublistView(rec)
        ..setUint32(4, 0x1000)
        ..setUint32(16, 0);
      final sd = ViSectionDescriptor.parse(rec, 0);
      expect(sd.word16, 0);
      expect(sd.secRel, 0x1000);
      expect(sd.serialize(), orderedEquals(rec));
    });

    test('isNamed reflects the nameRef index (0 = unnamed)', () {
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
        ..setUint32(4, 0)
        ..setUint32(8, 1992)
        ..setUint32(12, 0)
        ..setUint32(16, 0xFFFFFFFF);
      final pg = ViInfoPreGap.parse(rec);
      expect(pg.markerTag, 'FTAB');
      expect(pg.word1, 0);
      expect(pg.word2, 1992);
      expect(pg.word3, 0);
      expect(pg.flags, 0xFFFFFFFF);
      expect(pg.hasEmbeddedSections, isTrue);
      expect(pg.serialize(), orderedEquals(rec));
    });

    test('VITS marker + flags 0 means no embedded sections', () {
      final rec = Uint8List(20);
      ByteData.sublistView(rec)
        ..setUint32(0, 0x56495453)
        ..setUint32(16, 0);
      final pg = ViInfoPreGap.parse(rec);
      expect(pg.markerTag, 'VITS');
      expect(pg.hasEmbeddedSections, isFalse);
      expect(pg.serialize(), orderedEquals(rec));
    });
  });

  group('ViNameTable', () {
    test('peels the trailing Pascal VI name and serializes byte-exact', () {
      const name = 'Foo.vi';
      final tail = Uint8List.fromList([
        0x00, 0x01, 0x02, 0x03,
        name.length, ...name.codeUnits,
      ]);
      final nt = ViNameTable.parse(tail);
      expect(nt.trailingName, 'Foo.vi');
      expect(nt.header, orderedEquals([0x00, 0x01, 0x02, 0x03]));
      expect(nt.serialize(), orderedEquals(tail));
    });

    test('no clean trailing name -> all header, null name, still byte-exact', () {
      final tail = Uint8List.fromList([0x05, 0xFF, 0xFE, 0x00]);
      final nt = ViNameTable.parse(tail);
      expect(nt.trailingName, isNull);
      expect(nt.serialize(), orderedEquals(tail));
    });

    test('headerValue reads the lone u32@4 of the canonical 12-byte header', () {
      const name = 'X.vi';
      final tail = Uint8List.fromList([
        0, 0, 0, 0,
        0, 0, 0x4d, 0x40,
        0, 0, 0, 0,
        name.length, ...name.codeUnits,
      ]);
      final nt = ViNameTable.parse(tail);
      expect(nt.header.length, 12);
      expect(nt.headerValue, 0x4d40);
      expect(nt.trailingName, 'X.vi');
      expect(nt.serialize(), orderedEquals(tail));
    });

    test('headerValue is null when the header is not the canonical 12 bytes', () {
      final nt = ViNameTable.parse(Uint8List.fromList([0x00, 0x01, 0x02, 0x03, 0x03, 0x66, 0x6f, 0x6f]));
      expect(nt.headerValue, isNull);
    });
  });

  group('ViInfoArea + ViContainer.serialize', () {
    test('ViInfoArea composes subheader + block list + raw rest byte-exact', () {
      final info = Uint8List(0x34 + 4 + 12 + 5);
      info.setRange(0, 6, _rsrcMagic);
      final d = ByteData.sublistView(info);
      d.setUint16(6, 3);
      info.setRange(8, 12, 'LVIN'.codeUnits);
      info.setRange(12, 16, 'LBVW'.codeUnits);
      d.setUint32(0x2c, 0x34);
      d.setUint32(0x34, 1);
      info.setRange(0x38, 0x3c, 'BDHb'.codeUnits);
      info.setRange(0x34 + 4 + 12, info.length, const [0xDE, 0xAD, 0xBE, 0xEF, 0x01]);
      final ia = ViInfoArea.parse(info);
      expect(ia.blockList.count, 1);
      expect(ia.rest, orderedEquals([0xDE, 0xAD, 0xBE, 0xEF, 0x01]));
      expect(ia.serialize(), orderedEquals(info));
    });

    test('ViContainer.serialize() reproduces the original bytes (== toBytes)', () {
      final bytes = _minimalVi();
      final c = ViContainer.parse(bytes);
      expect(c.serialize(), orderedEquals(c.toBytes()));
      expect(c.serialize(), orderedEquals(bytes));
    });
  });

  group('ViVi (capstone typed model)', () {
    test('parse -> serialize reproduces a synthetic VI byte-exact', () {
      final bytes = _minimalVi();

      final vi = ViVi.parse(bytes);
      expect(vi.serialize(), orderedEquals(bytes));
      expect(vi.header.dataOffset, 32);
      expect(vi.infoArea.blockList.count, 0);
    });

    test('withSectionEdited rejects a secRel that is not a section start', () {
      final bytes = _minimalVi();
      final vi = ViVi.parse(bytes);
      expect(
        () => vi.withSectionEdited(secRel: 0, newPayload: Uint8List.fromList([9])),
        throwsA(isA<ViFormatException>()),
      );
    });
  });

  group('ViExport.rebuildDataArea', () {
    test('serializes sections as [u32 len][payload] and gaps verbatim', () {
      final out = ViExport.rebuildDataArea([
        ViSectionData(secRel: 0, payload: Uint8List.fromList([1, 2, 3])),
        ViGap(Uint8List.fromList([0, 0])),
        ViSectionData(secRel: 9, payload: Uint8List.fromList([9])),
      ]);
      expect(out, orderedEquals([
        0, 0, 0, 3, 1, 2, 3,
        0, 0,
        0, 0, 0, 1, 9,
      ]));
    });

    test('editing a payload recomputes its length prefix', () {
      final out = ViExport.rebuildDataArea([
        ViSectionData(secRel: 0, payload: Uint8List.fromList([7, 7, 7, 7, 7])),
      ]);
      expect(out, orderedEquals([0, 0, 0, 5, 7, 7, 7, 7, 7]));
    });
  });

  group('ViExport.editSection', () {
    test('throws when no section starts at the given secRel', () {
      final bytes = _container([1, 2, 3, 4], const []);
      expect(
        () => ViExport.editSection(bytes, secRel: 0, newPayload: Uint8List.fromList([9])),
        throwsA(isA<ViFormatException>()),
      );
    });
  });
}
