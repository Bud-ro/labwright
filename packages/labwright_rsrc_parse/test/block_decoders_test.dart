import 'dart:convert';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'test_util.dart';

Uint8List _strg(String text) {
  final body = utf8.encode(text);
  return u8([0, 0, 0, body.length, ...body]);
}

Uint8List _lvsr(int len, {int b0 = 0x20, int b1 = 0, int flags = 0, List<int>? hash96, List<int>? hash144}) {
  final b = Uint8List(len);
  b[0] = b0;
  b[1] = b1;
  b[2] = 0x80;
  if (len >= 6) ByteData.sublistView(b).setUint16(4, flags);
  if (len >= 112) b.setAll(96, hash96 ?? emptyPasswordDigest);
  if (len >= 160) b.setAll(144, hash144 ?? emptyPasswordDigest);
  return b;
}

Uint8List _pth0(List<String> comps, {int type = 0}) {
  final body = [for (final c in comps) ...pascal(c)];
  return u8([...'PTH0'.codeUnits, 0, 0, 0, 4 + body.length, type >> 8, type & 0xff, 0, comps.length, ...body]);
}

Uint8List _idtab(List<int> entries) {
  final b = ByteData(4 * (entries.length + 1))..setUint32(0, entries.length);
  for (var i = 0; i < entries.length; i++) {
    b.setUint32(4 * (i + 1), entries[i]);
  }
  return b.buffer.asUint8List();
}

Uint8List _iconSection(List<int> pixels) {
  final b = Uint8List(40 + pixels.length);
  b[5] = 2;
  b[7] = 2;
  b[9] = 24;
  b[31] = 2;
  b[33] = 2;
  b.setRange(b.length - pixels.length, b.length, pixels);
  return b;
}

void main() {
  test('decodeStringBlock (STRG/HLPT): [u32 len][text], lying lengths clamp, lenient UTF-8, null when short', () {
    expect(decodeStringBlock(_strg('This VI does X')), 'This VI does X');
    expect(decodeStringBlock(_strg('')), '');
    expect(decodeStringBlock(_strg('### Foo.vi')), '### Foo.vi', reason: 'HLPT reuses the STRG layout');
    expect(decodeStringBlock(u8([0, 0, 0, 6, 0x41, 0x42, 0x43])), 'ABC', reason: 'len 6 > 3 body bytes clamps');
    expect(decodeStringBlock(u8([0, 0, 0, 1, 0xff])), isNotNull, reason: 'bad UTF-8 -> replacement, no throw');
    expect(decodeStringBlock(u8([0, 0, 0])), isNull);
  });

  test('decodeHistory: 40-byte record fields and the reserved-zero check', () {
    final b = Uint8List(40);
    ByteData.sublistView(b)
      ..setUint32(0, 2)
      ..setUint32(4, 0x400)
      ..setUint32(8, 11);
    final h = decodeHistory(b);
    expect((h.formatVersion, h.flags, h.entryCount), (2, 0x400, 11));
    expect(h.reservedAreZero, isTrue);
    expect(h.serialize(), same(b));
    ByteData.sublistView(b).setUint32(12, 7);
    expect(decodeHistory(b).reservedAreZero, isFalse, reason: 'offset 12 is a reserved word');
    expect(() => decodeHistory(Uint8List(20)), throwsA(isA<AssertionError>()));
  });

  test('decodeFontTable: version/count/offset + packed names, bogus offset safe, null when short', () {
    final b = u8([0, 1, 0, 2, 0, 3, 0, 2, 0, 0, 0, 16, 0, 0, 0, 0, ...pascal('Segoe UI'), ...pascal('Tahoma')]);
    final t = decodeFontTable(b)!;
    expect((t.version, t.fontCount, t.nameTableOffset), (1, 2, 16));
    expect(t.names, ['Segoe UI', 'Tahoma']);
    expect(t.entries, isEmpty, reason: 'name table at 16 != 8 + 2*16, so no record framing');
    final framed = u8([
      0,
      1,
      0,
      2,
      0,
      3,
      0,
      1,
      0,
      0,
      0,
      24,
      0,
      15,
      4,
      2,
      3,
      232,
      0,
      15,
      0,
      216,
      0,
      213,
      ...pascal('Segoe UI'),
    ]);
    final e = decodeFontTable(framed)!.entries.single;
    expect((e.nameOffset, e.size, e.flagsByte, e.styleFlags), (24, 15, 4, 2));
    expect((e.weight, e.resolvedSize, e.metricA, e.metricB, e.name), (1000, 15, 216, 213, 'Segoe UI'));
    final bogus = Uint8List(12);
    ByteData.sublistView(bogus)
      ..setUint16(0, 1)
      ..setUint16(6, 3)
      ..setUint32(8, 9999);
    expect(decodeFontTable(bogus)!.names, isEmpty, reason: 'bogus name offset yields fewer names, no throw');
    expect(decodeFontTable(Uint8List(8)), isNull);
  });

  test('decodeDataTypeHeap: dominant 4-byte header form; extended form recovers 40xx names; null when short', () {
    final h = decodeDataTypeHeap(hx('00170004'))!;
    expect((h.heapTypeCount, h.firstTopLevelIndex, h.viTypeIndexBase), (0x17, 4, 2));
    expect((h.isExtended, h.rawLength), (false, 4));
    expect(h.names, isEmpty);
    final e = decodeDataTypeHeap(u8([...hx('00000040 000e 4021 09'), ...'Auto Stop'.codeUnits]))!;
    expect(e.isExtended, isTrue);
    expect(e.names, contains('Auto Stop'));
    expect(decodeDataTypeHeap(hx('000102')), isNull);
  });

  test('decodeVersionWord: [BCD major][minor<<4|patch][stage][build]', () {
    const rows = <(String, int, int, int, String)>[
      ('08508002', 8, 5, 0, '8.5'),
      ('20008000', 20, 0, 0, '20.0'),
      ('10008000', 10, 0, 0, '10.0'),
      ('09008000', 9, 0, 0, '9.0'),
      ('21138005', 21, 1, 3, '21.1.3'),
    ];
    for (final (bytes, major, minor, patch, version) in rows) {
      final v = decodeVersionWord(hx(bytes));
      expect((v.major, v.minor, v.patch, v.version), (major, minor, patch, version), reason: bytes);
    }
    final v = decodeVersionWord(hx('08508002'));
    expect((v.stage, v.build), (0x80, 2));
    expect(v.minor, 5, reason: 'minor is the high nibble of byte 1, not BCD(0x50)=50');
    expect(() => decodeVersionWord(hx('010203')), throwsA(isA<AssertionError>()));
  });

  test('decodeVersBlock: version word, flags, and the two Pascal strings tiling the payload', () {
    final b = u8([0x20, 0x00, 0x80, 0x00, 0x00, 0x03, ...pascal('20.0'), ...pascal('20.0f1')]);
    final v = decodeVersBlock(b);
    expect((v.versionWord.version, v.flags, v.versionText, v.infoText), ('20.0', 3, '20.0', '20.0f1'));
    expect(v.serialize(), same(b));
    expect(() => decodeVersBlock(u8([0x20, 0, 0x80, 0, 0, 0, 9, 0x41])), throwsA(isA<AssertionError>()));
  });

  group('decodeSaveRecord (LVSR)', () {
    test('decodes the BCD version word (same decode as vers)', () {
      final r = decodeSaveRecord(_lvsr(160));
      expect(
        (r.versionWord.major, r.versionWord.minor, r.versionWord.stage, r.versionWord.version),
        (20, 0, 0x80, '20.0'),
      );
      expect(decodeSaveRecord(_lvsr(160, b0: 0x09)).versionWord.major, 9);
      final v85 = decodeSaveRecord(_lvsr(160, b0: 0x08, b1: 0x50)).versionWord;
      expect((v85.major, v85.minor, v85.version), (8, 5, '8.5'), reason: 'minor guard: not BCD(0x50)');
      expect(r.serialize(), same(r.bytes));
    });

    test('names the evaluation and home/student bits of the @4 flag word', () {
      final cases = <(int, Set<ViSaveFlag>)>[
        (0x0000, {}),
        (0x0800, {ViSaveFlag.evaluationLicense}),
        (0x1000, {ViSaveFlag.homeStudentEdition}),
        (0x5000, {ViSaveFlag.homeStudentEdition}),
        (0x1800, {ViSaveFlag.evaluationLicense, ViSaveFlag.homeStudentEdition}),
      ];
      for (final (word, flags) in cases) {
        final r = decodeSaveRecord(_lvsr(160, flags: word));
        expect(r.saveFlagWord, word);
        expect(r.saveFlags, flags, reason: word.toRadixString(16));
      }
    });

    test('reads the @96 password digest and the independent @144 secondary digest', () {
      final unset = decodeSaveRecord(_lvsr(160));
      expect(unset.blockDiagramPasswordDigest, emptyPasswordDigest);
      expect(unset.isBlockDiagramPasswordProtected, isFalse);
      final protectedDigest = List<int>.generate(16, (i) => i + 1);
      final prot = decodeSaveRecord(_lvsr(160, hash96: protectedDigest));
      expect(prot.blockDiagramPasswordDigest, protectedDigest);
      expect(prot.isBlockDiagramPasswordProtected, isTrue);
      final digest144 = List<int>.generate(16, (i) => 100 + i);
      final r = decodeSaveRecord(_lvsr(160, hash144: digest144));
      expect(r.secondaryDigest, digest144);
      expect(r.blockDiagramPasswordDigest, emptyPasswordDigest, reason: '@96 is independent of the @144 slot');
    });

    test('digest slots are gated on record length; the record needs at least the flag word', () {
      final r112 = decodeSaveRecord(_lvsr(112, b0: 0x12));
      expect(r112.blockDiagramPasswordDigest, isNotNull, reason: '112 bytes reaches @96');
      expect(r112.secondaryDigest, isNull, reason: '112 bytes does not reach @144');
      final tiny = decodeSaveRecord(hx('16008000 0000'));
      expect((tiny.versionWord.major, tiny.blockDiagramPasswordDigest, tiny.secondaryDigest), (16, null, null));
      expect(tiny.isBlockDiagramPasswordProtected, isFalse);
      expect(() => decodeSaveRecord(hx('16008000')), throwsA(isA<AssertionError>()));
    });
  });

  test('decodeTypeMap (TM80): variable-field [count][indexShift][flags] walk + byte-exact re-emit', () {
    const body = '0003 0004 8000d000 2000 8000d001';
    final m = decodeTypeMap(hx(body))!;
    expect((m.framesExactly, m.indexShift, m.rawLength), (true, 4, 14));
    expect(m.entries, [0xd000, 0x2000, 0xd001]);
    expect(reserializeTypeMap(hx(body)), hx(body));
    expect(typeMapFrames(hx(body)), isTrue);

    final inline = decodeTypeMap(hx('0000 0021 0008'))!;
    expect(inline.framesExactly, isFalse);
    expect(inline.entries, isEmpty);
    expect(reserializeTypeMap(hx('0000 0021 0008')), isNull);

    expect(decodeTypeMap(hx('00')), isNull);
  });

  test('decodeConnectorPane (CONP): 2-byte big-endian VCTP index; longer blocks flagged inline; null when empty', () {
    final p = decodeConnectorPane(hx('002a'))!;
    expect((p.typeIndex, p.isInline, p.rawLength), (0x2a, false, 2));
    expect(decodeConnectorPane(hx('0105'))!.typeIndex, 0x105);
    final inline = decodeConnectorPane(Uint8List(28))!;
    expect((inline.isInline, inline.typeIndex, inline.rawLength), (true, null, 28));
    expect(decodeConnectorPane(Uint8List(0)), isNull);
  });

  test('cpc2Description: u32-length-prefixed ASCII; non-description variants and wrong tags yield null', () {
    const text = 'Calls SetETS';
    expect(
      cpc2Description([
        sec('CPC2', [0, 0, 0, text.length, ...text.codeUnits]),
      ]),
      text,
    );
    expect(cpc2Description([sec('CPC2', hx('ffffffff 80000001'))]), isNull);
    expect(
      cpc2Description([
        sec('vers', [1, 2, 3]),
      ]),
      isNull,
    );
    final junk = [for (var i = 0; i < 256; i++) (i * 37 + 5) & 0xff];
    expect(() => cpc2Description([sec('CPC2', junk)]), returnsNormally);
  });

  test('decodeHelpPath (HLPP): PTH0 components + joined path; non-PTH0 flagged; lying counts safe', () {
    final p = decodeHelpPath(_pth0(['<helpdir>', 'JKI', 'Caraya', 'README.html']))!;
    expect((p.isPth0, p.pathType), (true, 0));
    expect(p.components, ['<helpdir>', 'JKI', 'Caraya', 'README.html']);
    expect(p.path, '<helpdir>/JKI/Caraya/README.html');
    final flat = decodeHelpPath(u8(List.filled(16, 0x41)))!;
    expect(flat.isPth0, isFalse, reason: 'non-PTH0 bytes are flagged, not guessed');
    expect(flat.components, isEmpty);
    expect(decodeHelpPath(Uint8List(8)), isNull);
    final lying = _pth0(['a']);
    ByteData.sublistView(lying).setUint16(10, 9999);
    expect(decodeHelpPath(lying)!.components.length, lessThanOrEqualTo(1), reason: 'huge count bails at buffer end');
  });

  test('decodeIdTable (NUID/SUID/BNID): [u32 count][count u32] tiling the payload', () {
    final body = _idtab([0x1234, 0, 0x7]);
    final t = decodeIdTable(body);
    expect((t.count, t[0], t[1], t[2]), (3, 0x1234, 0, 0x7));
    expect(t.serialize(), same(body));
    expect(decodeIdTable(_idtab([])).count, 0);
    final lying = Uint8List(12);
    ByteData.sublistView(lying).setUint32(0, 9999);
    expect(() => decodeIdTable(lying), throwsA(isA<AssertionError>()), reason: 'count must tile');
    expect(() => decodeIdTable(u8([0, 1])), throwsA(isA<AssertionError>()));
  });

  test('decodeAlignTable (BFAL): [u32 count][count × 9B entry] tiling the payload', () {
    final body = u8([
      0, 0, 0, 2, // count = 2
      0, 0, 0, 0x41, 0, 0, 0, 9, 1, // offset 0x41, value 9, kind 1
      0, 0, 1, 0x18, 0, 0, 0, 0x10, 3, // offset 0x118, value 0x10, kind 3
    ]);
    final t = decodeAlignTable(body);
    expect(t.count, 2);
    expect((t.offsetAt(0), t.valueAt(0), t.kindAt(0)), (0x41, 9, 1));
    expect((t.offsetAt(1), t.valueAt(1), t.kindAt(1)), (0x118, 0x10, 3));
    expect(t.serialize(), same(body));
    expect(() => decodeAlignTable(Uint8List(4 + 9)..[3] = 99), throwsA(isA<AssertionError>()));
    expect(() => decodeAlignTable(u8([0, 1])), throwsA(isA<AssertionError>()));
  });

  test('tables with variable entries record where each entry starts', () {
    final ccst = u8([0, 0, 0, 2, 0, 0, 0, 1, 0x41, 0, 0, 0, 2, 0x42, 0x43, 0, 0, 0, 0, 0, 0, 0, 1, 0x44]);
    final kv = decodeKeyValueTable(ccst);
    expect(kv.length, 2);
    expect(kv.keyAt(0), [0x41]);
    expect(kv.valueAt(0), [0x42, 0x43]);
    expect(kv.keyAt(1), isEmpty);
    expect(kv.valueAt(1), [0x44]);
    expect(() => decodeKeyValueTable(u8([0, 0, 0, 1, 0, 0, 0, 9])), throwsA(isA<AssertionError>()));
    final cpst = u8([0, 0, 0, 2, ...pascal('On'), ...pascal('Off')]);
    final strings = decodePascalStringTable(cpst);
    expect((strings.length, strings.textAt(0), strings.textAt(1)), (2, 'On', 'Off'));
    expect(() => decodePascalStringTable(u8([0, 0, 0, 1, 5, 0x41])), throwsA(isA<AssertionError>()));
    final bkmk = u8([
      0, 0, 0, 1, 0, 0, 0, 7, 0, 0, 0, 9, 0, 0, 0, 2, 0x41, 0x42, // A: wordA 7, wordB 9, "AB"
      0, 0, 0, 1, 0, 0, 0, 5, 0, 0, 0, 1, 0x43, // B: wordB 5, "C"
    ]);
    final marks = decodeBookmarkList(bkmk);
    expect((marks.tableA.length, marks.tableA.wordAAt(0), marks.tableA.wordBAt(0)), (1, 7, 9));
    expect(marks.tableA.textAt(0), [0x41, 0x42]);
    expect((marks.tableB.length, marks.tableB.wordAAt(0), marks.tableB.wordBAt(0)), (1, null, 5));
    expect(marks.tableB.textAt(0), [0x43]);
    expect(decodeBookmarkList(u8([0, 0, 0, 0, 0, 0, 0, 0])).isEmpty, isTrue);
    expect(() => decodeBookmarkList(u8([0, 0, 0, 1, 0, 0, 0, 7])), throwsA(isA<AssertionError>()));
    final trec = u8([...List.filled(72, 0), 0, 0, 0, 2, 0x58, 0x59]);
    final record = decodeTextRecord(trec);
    expect((record.runCount, record.header.length), (1, 72));
    expect(record.runAt(0), [0x58, 0x59]);
    expect(decodeTextRecord(Uint8List(72)).runCount, 0);
    expect(() => decodeTextRecord(Uint8List(70)), throwsA(isA<AssertionError>()));
    final ipsr = u8([0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 9]);
    expect(decodeOffsetTable(ipsr)[2], 9);
    expect(() => decodeOffsetTable(u8([0, 0, 0, 2, 0, 0, 0, 1])), throwsA(isA<AssertionError>()), reason: 'decreasing');
    final gcdi = u8([0, 0, 0, 3, 1, 0xaa, 0xbb]);
    expect(decodeGcdiRecord(gcdi).value, 3);
    expect(decodeGcdiRecord(gcdi).body, [0xaa, 0xbb]);
    expect(() => decodeGcdiRecord(u8([0, 0, 0, 3, 2])), throwsA(isA<AssertionError>()));
  });

  group('icons', () {
    const px = [255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 0];

    test('extractRgbIcon decodes the validated 2×2 RGB form and rejects everything else', () {
      final icon = extractRgbIcon(_iconSection(px))!;
      expect((icon.width, icon.height), (2, 2));
      expect(icon.rgb, px);
      expect(extractRgbIcon(_iconSection(px)..[9] = 8), isNull, reason: 'wrong depth');
      expect(extractRgbIcon(_iconSection(px)..[31] = 9), isNull, reason: 'rect not doubled');
      expect(extractRgbIcon(_iconSection(px)..[0] = 1), isNull, reason: 'nonzero flags');
      expect(extractRgbIcon(Uint8List(10)), isNull, reason: 'too short');
      expect(extractRgbIcon(u8(List.filled(60, 0x41))), isNull, reason: 'arbitrary bytes');
    });

    test('decodeViIcon finds the icon across sections regardless of tag', () {
      final icon = decodeViIcon([dsec(List.filled(20, 0), tag: 'LVSR'), dsec(_iconSection(px), tag: 'PICC')])!;
      expect(icon.width, 2);
      expect(icon.rgb, px);
      expect(decodeViIcon([dsec(List.filled(8, 0), tag: 'LVSR')]), isNull);
    });

    test('decodeLegacyIcon: bpp by tag, exact-size 32×32 bitmaps, wrong sizes rejected', () {
      expect(
        [legacyIconBpp('icl8'), legacyIconBpp('icl4'), legacyIconBpp('ICON'), legacyIconBpp('STRG')],
        [
          8,
          4,
          1,
          null,
        ],
      );
      final mono = decodeLegacyIcon(Uint8List(128)..[0] = 0xA0, 1)!;
      expect((mono.bpp, mono.pixels.length), (1, 1024));
      expect(mono.pixels.sublist(0, 8), [1, 0, 1, 0, 0, 0, 0, 0], reason: 'MSB-first bit expansion');
      final nib = decodeLegacyIcon(Uint8List(512)..[0] = 0x3C, 4)!;
      expect((nib.pixels.length, nib.pixels[0], nib.pixels[1]), (1024, 3, 12), reason: 'two nibbles per byte');
      final byte = decodeLegacyIcon(Uint8List(1024)..[5] = 200, 8)!;
      expect((byte.pixels.length, byte.pixels[5]), (1024, 200));
      expect(decodeLegacyIcon(Uint8List(100), 1), isNull, reason: '1-bpp must be exactly 128 bytes');
      expect(decodeLegacyIcon(Uint8List(1024), 4), isNull, reason: '4-bpp must be exactly 512 bytes');
    });
  });

  group('block registry', () {
    test('category/confidence table', () {
      const rows = <(BlockTag, BlockCategory, BlockConfidence)>[
        (BlockTag.fphb, BlockCategory.frontPanelHeap, BlockConfidence.confirmed),
        (BlockTag.bdhb, BlockCategory.blockDiagramHeap, BlockConfidence.confirmed),
        (BlockTag.fphc, BlockCategory.frontPanelHeap, BlockConfidence.tentative),
        (BlockTag.bdhc, BlockCategory.blockDiagramHeap, BlockConfidence.tentative),
        (BlockTag.vctp, BlockCategory.typeInfo, BlockConfidence.confirmed),
        (BlockTag.vicd, BlockCategory.compiledCode, BlockConfidence.confirmed),
        (BlockTag.mngi, BlockCategory.image, BlockConfidence.confirmed),
        (BlockTag.bdpw, BlockCategory.security, BlockConfidence.confirmed),
        (BlockTag.hlpp, BlockCategory.helpPath, BlockConfidence.confirmed),
        (BlockTag.hlpt, BlockCategory.text, BlockConfidence.confirmed),
        (BlockTag.vins, BlockCategory.embeddedVi, BlockConfidence.confirmed),
        (BlockTag.vers, BlockCategory.settings, BlockConfidence.confirmed),
        (BlockTag.rtsg, BlockCategory.identifier, BlockConfidence.confirmed),
        (BlockTag.scsr, BlockCategory.identifier, BlockConfidence.confirmed),
        (BlockTag.nuid, BlockCategory.identifier, BlockConfidence.confirmed),
        (BlockTag.cpst, BlockCategory.text, BlockConfidence.likely),
        (BlockTag.dllp, BlockCategory.helpPath, BlockConfidence.likely),
        (BlockTag.strg, BlockCategory.text, BlockConfidence.confirmed),
        (BlockTag.hist, BlockCategory.history, BlockConfidence.confirmed),
        (BlockTag.ftab, BlockCategory.nameTable, BlockConfidence.confirmed),
        (BlockTag.dthp, BlockCategory.typeInfo, BlockConfidence.likely),
        (BlockTag.conp, BlockCategory.connectorPane, BlockConfidence.confirmed),
        (BlockTag.cpc2, BlockCategory.connectorPane, BlockConfidence.likely),
        (BlockTag.lvsr, BlockCategory.settings, BlockConfidence.confirmed),
        (BlockTag.icl8, BlockCategory.icon, BlockConfidence.confirmed),
        (BlockTag.bfal, BlockCategory.unknown, BlockConfidence.confirmed),
      ];
      for (final (tag, category, confidence) in rows) {
        expect((tag.category, tag.confidence), (category, confidence), reason: tag.tag);
        expect(BlockTag.of(tag.tag), tag);
        expect(tag.displayName, isNotEmpty, reason: tag.tag);
      }
    });

    test('tags are exact four-character strings, unique, and unknown tags look up to null', () {
      expect(BlockTag.values.map((t) => t.tag).toSet(), hasLength(BlockTag.values.length));
      for (final t in BlockTag.values) {
        expect(t.tag, hasLength(4), reason: t.name);
      }
      expect(BlockTag.of('PRT '), BlockTag.prt);
      expect(BlockTag.of('PRT'), isNull, reason: "the real tag is 'PRT ' with a space");
      expect(BlockTag.of('STR '), BlockTag.str);
      expect(BlockTag.of('ZZZZ'), isNull);
    });

    test('the C4 record-heap set is exactly FPHb and BDHb', () {
      expect(BlockTag.recordHeaps, {BlockTag.fphb, BlockTag.bdhb});
      for (final t in [BlockTag.fphc, BlockTag.bdhc, BlockTag.fphp, BlockTag.bdhp, BlockTag.dthp, BlockTag.vctp]) {
        expect(t.isRecordHeap, isFalse, reason: '${t.tag} must not be walked as a heap');
      }
    });
  });

  test('every fixed-block decoder returns or rejects its precondition over random small buffers', () {
    final decoders = <String, Object? Function(Uint8List)>{
      'decodeStringBlock': decodeStringBlock,
      'decodeHistory': decodeHistory,
      'decodeFontTable': decodeFontTable,
      'decodeDataTypeHeap': decodeDataTypeHeap,
      'decodeVersionWord': decodeVersionWord,
      'decodeVersBlock': decodeVersBlock,
      'decodeSaveRecord': decodeSaveRecord,
      'decodeTypeMap': decodeTypeMap,
      'decodeConnectorPane': decodeConnectorPane,
      'decodeHelpPath': decodeHelpPath,
      'decodeIdTable': decodeIdTable,
      'decodeAlignTable': decodeAlignTable,
      'extractRgbIcon': extractRgbIcon,
      'icl8': (b) => decodeLegacyIcon(b, 8),
      'icl4': (b) => decodeLegacyIcon(b, 4),
      'ICON': (b) => decodeLegacyIcon(b, 1),
      'decodeConnectorPaneMap': decodeConnectorPaneMap,
      'decodeOffsetTable': decodeOffsetTable,
      'decodeGcdiRecord': decodeGcdiRecord,
      'decodeBookmarkList': decodeBookmarkList,
      'decodeTagStore': decodeTagStore,
      'decodeCompiledCode': decodeCompiledCode,
      'decodeDataSpaceImage': decodeDataSpaceImage,
      'decodePngEnvelope': decodePngEnvelope,
      'decodeLinkInfo': decodeLinkInfo,
      'decodePasswordRecord': decodePasswordRecord,
      'decodeSignature': decodeSignature,
      'decodeSourceSignature': decodeSourceSignature,
      'decodeIconPlacement': decodeIconPlacement,
      'decodePrintRecord': decodePrintRecord,
      'decodeSectionEntry': decodeSectionEntry,
      'decodeModifiedUid': decodeModifiedUid,
      'decodeExtendedState': decodeExtendedState,
      'decodeGcprRecord': decodeGcprRecord,
      'decodeVpdpRecord': decodeVpdpRecord,
      'decodeDldrRecord': decodeDldrRecord,
      'decodeWordGrid': decodeWordGrid,
      'decodeCoutRecord': decodeCoutRecord,
      'decodeU16Grid': decodeU16Grid,
      'decodeCpd2Record': decodeCpd2Record,
      'decodeTitle': decodeTitle,
      'decodeTextRecord': decodeTextRecord,
      'decodeHelpPath+fields': (b) {
        final p = decodeHelpPath(b);
        p?.components;
        return p?.path;
      },
    };
    var seed = 0;
    decoders.forEach((name, decode) {
      seed++;
      expectTotal(seed, 250, 96, (b) {
        try {
          decode(b);
        } on ViFormatException {
          rethrow;
        } on AssertionError {
          return;
        } catch (e) {
          fail('$name leaked ${e.runtimeType} on ${b.length} bytes: $e');
        }
      });
    });
  });

  group('block-payload writers (byte-exact serialize inverses)', () {
    test('ViLegacyIcon.serialize re-packs 8/4/1 bpp exactly (inverse of decode)', () {
      final icl8 = Uint8List.fromList([for (var i = 0; i < 1024; i++) (i * 7) & 0xff]);
      expect(decodeLegacyIcon(icl8, 8)!.serialize(), icl8);
      final icl4 = Uint8List.fromList([for (var i = 0; i < 512; i++) (i * 13) & 0xff]);
      expect(decodeLegacyIcon(icl4, 4)!.serialize(), icl4);
      final icon = Uint8List.fromList([for (var i = 0; i < 128; i++) (i * 29) & 0xff]);
      expect(decodeLegacyIcon(icon, 1)!.serialize(), icon);
    });

    test('ViIdTable.serialize returns the backing [u32 count][entries] bytes', () {
      final body = _idtab([1, 2, 0xDEADBEEF, 0]);
      expect(decodeIdTable(body).serialize(), same(body));
      final empty = _idtab([]);
      expect(decodeIdTable(empty).serialize(), same(empty));
    });

    test('ViStringBlock.serialize re-emits [u32 len][text] exactly', () {
      final body = _strg('This VI does a thing.');
      expect(decodeStringBlockRaw(body)!.serialize(), body);
      final empty = _strg('');
      expect(decodeStringBlockRaw(empty)!.serialize(), empty);
      final raw = u8([0, 0, 0, 3, 0xff, 0x00, 0x80]);
      expect(decodeStringBlockRaw(raw)!.serialize(), raw);
    });

    test('fixed records are views: serialize returns the backing bytes', () {
      for (final len in [160, 136, 144, 120, 96, 116, 8]) {
        final body = _lvsr(len);
        expect(decodeSaveRecord(body).serialize(), same(body), reason: 'len $len');
      }
      final dldr = u8([0, 0, 0, 1, ...List.filled(24, 0)]);
      expect(decodeDldrRecord(dldr)[0], 1);
      expect(decodeDldrRecord(dldr).serialize(), same(dldr));
      expect(() => decodeDldrRecord(u8([0, 0, 0, 1])), throwsA(isA<AssertionError>()), reason: 'not seven words');
      final grid = u8([0, 0, 3, 0xae, 0, 0, 3, 0xc4, 0, 0, 5, 9]);
      final words = decodeWordGrid(grid);
      expect((words.length, words[0], words[2]), (3, 0x3ae, 0x509));
      expect(() => decodeWordGrid(u8([1, 2, 3])), throwsA(isA<AssertionError>()));
      expect(() => decodeWordGrid(u8([])), throwsA(isA<AssertionError>()));
      expect(decodeVpdpRecord(u8([0, 0, 0, 0])).isZero, isTrue);
      expect(decodeVpdpRecord(u8([0, 0, 0, 1])).isZero, isFalse);
      final picc = u8([0, 0x92, 0x09, 0x02, 0, 0x2a, 0, 0x47, 0, 0xaa, 0xff, 0xa6]);
      final placement = decodeIconPlacement(picc);
      expect((placement.top, placement.left, placement.bottom, placement.right), (0x2a, 0x47, 0xaa, -90));
      final fpse = u8([0, 0, 0, 5]);
      expect((decodeSectionEntry(fpse).value, decodeSectionEntry(fpse).extra), (5, null));
      expect(decodeSectionEntry(u8([0, 0, 0, 5, 0, 0, 0, 7])).extra, 7);
      final bdpw = Uint8List.fromList([for (var i = 0; i < 48; i++) i]);
      final pw = decodePasswordRecord(bdpw);
      expect((pw.passwordDigest.length, pw.digest2[0], pw.digest3![0], pw.isUnprotected), (16, 16, 32, false));
      expect(decodePasswordRecord(Uint8List.sublistView(bdpw, 0, 32)).digest3, isNull);
      expect(decodePasswordRecord(u8([...emptyPasswordDigest, ...emptyPasswordDigest])).isUnprotected, isTrue);
      final scsr = Uint8List.fromList([0, 0, 0, 9, for (var i = 0; i < 16; i++) i]);
      expect((decodeSourceSignature(scsr).marker, decodeSourceSignature(scsr).digest.length), (9, 16));
      final titl = u8([3, 0xff, 0x00, 0x41]);
      expect(decodeTitle(titl).serialize(), same(titl));
      expect(decodeTitle(u8([2, 0x48, 0x69])).text, 'Hi');
      expect(() => decodeTitle(u8([5, 1, 2])), throwsA(isA<AssertionError>()), reason: 'length overruns');
      final sig = Uint8List.fromList([for (var i = 0; i < 16; i++) (i * 11) & 0xff]);
      expect(serializeBlockPayload('OBSG', sig), sig);
      expect(serializeBlockPayload('CCSG', sig), sig);
      expect(() => serializeBlockPayload('OBSG', u8([1, 2, 3])), throwsA(isA<AssertionError>()));
      final cout = u8([0, 0, 0, 1, 0xe2, 0x4d, 0x4e, 0x32, 0xb4, 0x55, 0xad, 0xf7]);
      expect(serializeBlockPayload('COUT', cout), cout);
      expect(() => serializeBlockPayload('COUT', u8([0, 0, 0, 1])), throwsA(isA<AssertionError>()));
      expect(decodeCpd2Record(u8([0, 7])).value, 7);
      expect(() => decodeCpd2Record(u8([0, 7, 0])), throwsA(isA<AssertionError>()));
    });

    test('serializeBlockPayload: model-sources covered tags, null otherwise', () {
      final icl8 = Uint8List.fromList([for (var i = 0; i < 1024; i++) (i * 3) & 0xff]);
      expect(serializeBlockPayload('icl8', icl8), icl8);
      final suid = _idtab([7, 8, 9]);
      expect(serializeBlockPayload('SUID', suid), suid);
      expect(hasBlockWriter('BNID'), isTrue);
      expect(hasBlockWriter('LVSR'), isTrue);
      final lvsr = u8([1, 2, 3, 4, 5, 6, 7, 8]);
      expect(serializeBlockPayload('LVSR', lvsr), lvsr);
      expect(() => serializeBlockPayload('LVSR', u8([1, 2, 3, 4, 5])), throwsA(isA<AssertionError>()));
      expect(hasBlockWriter('BDPW'), isTrue);
      final bdpw = Uint8List.fromList([for (var i = 0; i < 48; i++) (i * 5) & 0xff]);
      expect(serializeBlockPayload('BDPW', bdpw), bdpw);
      expect(() => serializeBlockPayload('BDPW', u8([1, 2, 3, 4])), throwsA(isA<AssertionError>()));
      expect(serializeBlockPayload('MUID', u8([0x12, 0x34, 0x56, 0x78])), u8([0x12, 0x34, 0x56, 0x78]));
      final emptyLi = u8([0, 1, ...'LVIN'.codeUnits, 0, 0, 0, 0, 0, 3]);
      expect(serializeBlockPayload('LIvi', emptyLi), emptyLi);
      expect(serializeBlockPayload('LIvi', u8([0, 1, ...'LVIN'.codeUnits, 0, 0, 0, 2, 0, 3])), isNull);
      expect(serializeBlockPayload('icl8', u8([1, 2, 3])), isNull);
      expect(
        () => serializeBlockPayload('NUID', u8([0, 0, 0, 1, 0, 0, 0, 5, 0xFF, 0xFF])),
        throwsA(isA<AssertionError>()),
      );
    });

    test('MUTATION: flipping an icon pixel confines the byte delta to its byte', () {
      final body = Uint8List.fromList([for (var i = 0; i < 1024; i++) (i * 5) & 0xff]);
      final icon = decodeLegacyIcon(body, 8)!;
      final pixels = [...icon.pixels]..[100] = 0xAB;
      final out = ViLegacyIcon(bpp: 8, pixels: pixels).serialize();
      final delta = [
        for (var i = 0; i < out.length; i++)
          if (out[i] != body[i]) i,
      ];
      expect(delta, [100], reason: '8 bpp: pixel 100 is byte 100');
    });
  });
}
