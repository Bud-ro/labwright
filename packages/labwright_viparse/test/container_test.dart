import 'dart:typed_data';

import 'package:labwright_viparse/labwright_viparse.dart';
import 'package:test/test.dart';

/// Builds a minimal well-formed RSRC container: 32-byte header (magic + the
/// dataOffset/dataSize/infoOffset words) ++ data area ++ info area.
Uint8List _container(List<int> data, List<int> info) {
  final header = Uint8List(32);
  header.setRange(0, 6, const [0x52, 0x53, 0x52, 0x43, 0x0d, 0x0a]); // RSRC\r\n
  final hd = ByteData.sublistView(header);
  const dataOffset = 32;
  final infoOffset = dataOffset + data.length;
  hd.setUint32(16, infoOffset);
  hd.setUint32(24, dataOffset);
  hd.setUint32(28, data.length);
  return Uint8List.fromList([...header, ...data, ...info]);
}

void main() {
  group('ViContainer', () {
    test('parse → toBytes is byte-exact for an unmodified container', () {
      final bytes = _container([1, 2, 3, 4, 5], [9, 8, 7]);
      final c = ViContainer.parse(bytes);
      expect(c.header.length, 32);
      expect(c.dataArea, orderedEquals([1, 2, 3, 4, 5]));
      expect(c.infoArea, orderedEquals([9, 8, 7]));
      expect(c.toBytes(), orderedEquals(bytes)); // the idempotency contract
    });

    test('rejects a non-RSRC / mis-ordered container', () {
      expect(() => ViContainer.parse(Uint8List(10)), throwsA(isA<ViFormatException>())); // bad magic
      // infoOffset before dataOffset (mis-ordered) must be rejected, not silently mangled.
      final bad = _container([1, 2, 3, 4], const []);
      ByteData.sublistView(bad).setUint32(16, 8); // infoOffset=8 < dataOffset=32
      expect(() => ViContainer.parse(bad), throwsA(isA<ViFormatException>()));
    });

    test('the three regions partition the whole file with no gap/overlap', () {
      final bytes = _container([10, 20, 30], [40, 50]);
      final c = ViContainer.parse(bytes);
      expect(c.header.length + c.dataArea.length + c.infoArea.length, bytes.length);
    });
  });

  group('ViHeader', () {
    test('parse -> serialize is byte-exact and decodes every field', () {
      final bytes = _container([1, 2, 3, 4, 5], [9, 8, 7]); // dataOffset=32, infoOffset=37, dataSize=5
      final h = ViHeader.parse(bytes);
      expect(h.formatVersion, 0); // _container leaves @6 zero
      expect(h.dataOffset, 32);
      expect(h.infoOffset, 37);
      expect(h.dataSize, 5);
      // the header serializes back to the original first 32 bytes
      expect(h.serialize(), orderedEquals(bytes.sublist(0, 32)));
    });

    test('a realistic header round-trips each field exactly', () {
      // mirror a real RSRC header (LVIN/LBVW, formatVersion 3, symmetric offsets)
      final h = Uint8List(32);
      h.setRange(0, 6, const [0x52, 0x53, 0x52, 0x43, 0x0d, 0x0a]);
      final d = ByteData.sublistView(h);
      d.setUint16(6, 3);
      h.setRange(8, 12, 'LVIN'.codeUnits);
      h.setRange(12, 16, 'LBVW'.codeUnits);
      d
        ..setUint32(16, 19968) // infoOffset
        ..setUint32(20, 2097) // infoSize
        ..setUint32(24, 32) // dataOffset
        ..setUint32(28, 19936); // dataSize
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
      expect(() => ViHeader.parse(Uint8List(32)), throwsA(isA<ViFormatException>())); // bad magic
    });
  });

  group('ViInfoSubheader', () {
    test('parses the dup header + blockListRel and serializes byte-exact', () {
      // build a 0x34-byte subheader: dup RSRC header, reserved, blockListRel=0x34
      final info = Uint8List(0x40);
      info.setRange(0, 6, const [0x52, 0x53, 0x52, 0x43, 0x0d, 0x0a]);
      final d = ByteData.sublistView(info);
      d.setUint16(6, 3);
      info.setRange(8, 12, 'LVIN'.codeUnits);
      info.setRange(12, 16, 'LBVW'.codeUnits);
      d.setUint32(0x2c, 0x34); // blockListRel
      final sh = ViInfoSubheader.parse(info);
      expect(sh.blockListRel, 0x34);
      expect(sh.headerCopy.fileType, 'LVIN');
      expect(sh.reservedA, hasLength(0x2c - 32));
      expect(sh.reservedB, hasLength(0x34 - 0x30));
      // serialize reproduces exactly the [0, blockListRel) prefix
      expect(sh.serialize(), orderedEquals(info.sublist(0, 0x34)));
    });

    test('rejects an implausible blockListRel', () {
      final info = Uint8List(0x40);
      ByteData.sublistView(info).setUint32(0x2c, 0x99999); // > length
      expect(() => ViInfoSubheader.parse(info), throwsA(isA<ViFormatException>()));
    });
  });

  group('ViBlockList', () {
    test('parses count + 12-byte entries and serializes byte-exact', () {
      // count=2, entries: {LVSR, scm1=0, descRel=0x10}, {BDHb, scm1=1, descRel=0x40}
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
      // put it at offset 0x34 inside a synthetic info area
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
      ByteData.sublistView(info).setUint32(0x34, 999999); // > 100000
      expect(() => ViBlockList.parse(info, 0x34), throwsA(isA<ViFormatException>()));
    });
  });

  group('ViSectionDescriptor', () {
    test('parses a 20-byte descriptor into five u32 words and serializes byte-exact', () {
      final rec = Uint8List(24); // descriptor at offset 4
      final d = ByteData.sublistView(rec)
        ..setUint32(4, 0xAABBCCDD) // word0 @0
        ..setUint32(8, 0x1234) // secRel @4
        ..setUint32(12, 0) // word8 @8
        ..setUint32(16, 0x55) // nameRef @12
        ..setUint32(20, 0xFFFFFFFF); // word16 @16
      final sd = ViSectionDescriptor.parse(rec, 4);
      expect(sd.word0, 0xAABBCCDD);
      expect(sd.secRel, 0x1234);
      expect(sd.word8, 0);
      expect(sd.nameRef, 0x55);
      expect(sd.word16, 0xFFFFFFFF);
      expect(sd.isNamed, isTrue); // nameRef 0x55 != 0
      expect(sd.serialize(), orderedEquals(rec.sublist(4, 24)));
      expect(d.getUint16(0), 0); // padding before the descriptor untouched
    });

    test('word16 == 0 still parses as a (LIBN/VINS) section, byte-exact', () {
      // A record with @16 == 0 is a real section (LIBN/VINS), not a "row".
      final rec = Uint8List(20);
      ByteData.sublistView(rec)
        ..setUint32(4, 0x1000) // secRel
        ..setUint32(16, 0); // word16 == 0
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
        ..setUint32(12, 7) // nameRef = index 7
        ..setUint32(16, 0xFFFFFFFF);
      expect(ViSectionDescriptor.parse(named, 0).isNamed, isTrue);
    });
  });

  group('ViInfoPreGap', () {
    test('parses the FTAB/VITS marker + flags and serializes byte-exact', () {
      final rec = Uint8List(20);
      ByteData.sublistView(rec)
        ..setUint32(0, 0x46544142) // "FTAB"
        ..setUint32(4, 0)
        ..setUint32(8, 1992)
        ..setUint32(12, 0)
        ..setUint32(16, 0xFFFFFFFF); // flags: has embedded sections
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
        ..setUint32(0, 0x56495453) // "VITS"
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
        0x00, 0x01, 0x02, 0x03, // header (raw)
        name.length, ...name.codeUnits, // [len][name] at EOF
      ]);
      final nt = ViNameTable.parse(tail);
      expect(nt.trailingName, 'Foo.vi');
      expect(nt.header, orderedEquals([0x00, 0x01, 0x02, 0x03]));
      expect(nt.serialize(), orderedEquals(tail));
    });

    test('no clean trailing name -> all header, null name, still byte-exact', () {
      final tail = Uint8List.fromList([0x05, 0xFF, 0xFE, 0x00]); // not a valid trailing pascal string
      final nt = ViNameTable.parse(tail);
      expect(nt.trailingName, isNull);
      expect(nt.serialize(), orderedEquals(tail));
    });
  });

  group('ViInfoArea + ViContainer.serialize', () {
    test('ViInfoArea composes subheader + block list + raw rest byte-exact', () {
      // synthetic info area: 0x34 subheader, block list (count=1, one entry), tail
      final info = Uint8List(0x34 + 4 + 12 + 5);
      info.setRange(0, 6, const [0x52, 0x53, 0x52, 0x43, 0x0d, 0x0a]);
      final d = ByteData.sublistView(info);
      d.setUint16(6, 3);
      info.setRange(8, 12, 'LVIN'.codeUnits);
      info.setRange(12, 16, 'LBVW'.codeUnits);
      d.setUint32(0x2c, 0x34); // blockListRel
      d.setUint32(0x34, 1); // count
      info.setRange(0x38, 0x3c, 'BDHb'.codeUnits); // entry tag
      info.setRange(0x34 + 4 + 12, info.length, const [0xDE, 0xAD, 0xBE, 0xEF, 0x01]); // tail
      final ia = ViInfoArea.parse(info);
      expect(ia.blockList.count, 1);
      expect(ia.rest, orderedEquals([0xDE, 0xAD, 0xBE, 0xEF, 0x01]));
      expect(ia.serialize(), orderedEquals(info));
    });

    test('ViContainer.serialize() reproduces the original bytes (== toBytes)', () {
      final bytes = _container([1, 2, 3, 4], [
        // a minimal but well-formed info area so ViInfoArea.parse succeeds
        for (var i = 0; i < 0x34; i++) 0,
        0, 0, 0, 0, // block list count = 0
        7, 7, // tail
      ]);
      // fix the header magic/blockListRel the synthetic info area needs
      final info = bytes.sublist(36); // dataOffset=32 + data(4)=36
      final id = ByteData.sublistView(info);
      info.setRange(0, 6, const [0x52, 0x53, 0x52, 0x43, 0x0d, 0x0a]);
      id.setUint32(0x2c, 0x34);
      bytes.setRange(36, bytes.length, info);
      final c = ViContainer.parse(bytes);
      expect(c.serialize(), orderedEquals(c.toBytes()));
      expect(c.serialize(), orderedEquals(bytes));
    });
  });

  group('ViVi (capstone typed model)', () {
    test('parse -> serialize reproduces a synthetic VI byte-exact', () {
      final bytes = _container([1, 2, 3, 4], [
        for (var i = 0; i < 0x34; i++) 0,
        0, 0, 0, 0, // block list count = 0
        7, 7, // name-table tail
      ]);
      final info = bytes.sublist(36); // header(32) + data(4)
      info.setRange(0, 6, const [0x52, 0x53, 0x52, 0x43, 0x0d, 0x0a]);
      ByteData.sublistView(info).setUint32(0x2c, 0x34); // blockListRel
      bytes.setRange(36, bytes.length, info);

      final vi = ViVi.parse(bytes);
      expect(vi.serialize(), orderedEquals(bytes));
      // the typed sub-models are reachable
      expect(vi.header.dataOffset, 32);
      expect(vi.infoArea.blockList.count, 0);
    });

    test('withSectionEdited rejects a secRel that is not a section start', () {
      final bytes = _container([1, 2, 3, 4], [
        for (var i = 0; i < 0x34; i++) 0,
        0, 0, 0, 0, // block list count = 0 (no sections)
        7, 7,
      ]);
      final info = bytes.sublist(36);
      info.setRange(0, 6, const [0x52, 0x53, 0x52, 0x43, 0x0d, 0x0a]);
      ByteData.sublistView(info).setUint32(0x2c, 0x34);
      bytes.setRange(36, bytes.length, info);
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
        0, 0, 0, 3, 1, 2, 3, // section: len=3 + payload
        0, 0, //                 gap
        0, 0, 0, 1, 9, //        section: len=1 + payload
      ]));
    });

    test('editing a payload recomputes its length prefix', () {
      final out = ViExport.rebuildDataArea([
        ViSectionData(secRel: 0, payload: Uint8List.fromList([7, 7, 7, 7, 7])), // grew to 5
      ]);
      expect(out, orderedEquals([0, 0, 0, 5, 7, 7, 7, 7, 7]));
    });
  });

  group('ViExport.editSection', () {
    test('throws when no section starts at the given secRel', () {
      // a synthetic container has no info-area descriptors, so no editable
      // section is located — editSection must reject rather than corrupt.
      final bytes = _container([1, 2, 3, 4], const []);
      expect(
        () => ViExport.editSection(bytes, secRel: 0, newPayload: Uint8List.fromList([9])),
        throwsA(isA<ViFormatException>()),
      );
    });
  });
}
