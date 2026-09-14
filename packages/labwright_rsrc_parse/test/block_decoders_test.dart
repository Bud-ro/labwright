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
  final b = Uint8List(46 + pixels.length);
  b[5] = 2;
  b[7] = 2;
  b[9] = 24;
  b[25] = pixels.length;
  b[31] = 2;
  b[33] = 2;
  b[35] = 24;
  b.setRange(46, b.length, pixels);
  return b;
}

void main() {
  test('decodeStringBlock (STRG/HLPT): [u32 len][text] filling the payload, lenient UTF-8', () {
    expect(decodeStringBlock(_strg('This VI does X')).text, 'This VI does X');
    expect(decodeStringBlock(_strg('')).text, '');
    expect(decodeStringBlock(_strg('### Foo.vi')).text, '### Foo.vi', reason: 'HLPT reuses the STRG layout');
    expect(decodeStringBlock(u8([0, 0, 0, 1, 0xff])).text, isNotEmpty, reason: 'bad UTF-8 -> replacement, no throw');
    final body = _strg('x');
    expect(decodeStringBlock(body).serialize(), same(body));
    expect(() => decodeStringBlock(u8([0, 0, 0, 6, 0x41, 0x42, 0x43])), throwsA(isA<AssertionError>()));
    expect(() => decodeStringBlock(u8([0, 0, 0])), throwsA(isA<AssertionError>()));
  });

  test('decodeCompiledCode (VICD): header, code-end pointer per layout word, bare or symbol-table CODE chunk', () {
    Uint8List vicd({required int layoutWord, required int codeEndAt, List<String> names = const []}) {
      final head = Uint8List(codeEndAt)
        ..setAll(4, 'i386'.codeUnits)
        ..setAll(20, 'code'.codeUnits);
      final h = ByteData.sublistView(head);
      h.setUint32(0, 24, Endian.little);
      h.setUint32(8, 8, Endian.little);
      h.setUint32(12, layoutWord, Endian.little);
      h.setUint32(layoutWord == 0x103 ? 36 : 28, codeEndAt, Endian.little);
      final chunk = BytesBuilder()
        ..add('CODE'.codeUnits)
        ..add(Uint8List(12));
      final self = ByteData(4)..setUint32(0, codeEndAt, Endian.little);
      chunk.add(self.buffer.asUint8List());
      if (names.isNotEmpty) {
        chunk.add((ByteData(4)..setUint32(0, names.length, Endian.little)).buffer.asUint8List());
        for (final n in names) {
          chunk.add((ByteData(4)..setUint32(0, n.length, Endian.little)).buffer.asUint8List());
          chunk.add(n.codeUnits);
          chunk.add(Uint8List((4 - n.length % 4) % 4));
        }
      }
      return u8([...head, ...chunk.toBytes()]);
    }

    final bare = decodeCompiledCode(vicd(layoutWord: 0x103, codeEndAt: 48));
    expect(
      (bare.architecture, bare.codeStart, bare.codeSize, bare.codeEnd, bare.symbolCount),
      (CodeArchitecture.i386, 24, 8, 48, 0),
    );
    expect(bare.fixupsAndCode.length, 24);
    final table = decodeCompiledCode(vicd(layoutWord: 0x103, codeEndAt: 48, names: ['abc', 'defgh']));
    expect(table.symbolCount, 2);
    expect(String.fromCharCodes(table.symbolNameAt(1)), 'defgh');
    expect(table.serialize(), same(table.bytes));
    final legacy = decodeCompiledCode(vicd(layoutWord: 0, codeEndAt: 44));
    expect((legacy.layoutWord, legacy.codeEnd), (0, 44));
    expect(
      () => decodeCompiledCode(vicd(layoutWord: 0x103, codeEndAt: 48)..[22] = 0x41),
      throwsA(isA<AssertionError>()),
    );
    expect(() => decodeCompiledCode(Uint8List(20)), throwsA(isA<AssertionError>()));
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

  test('decodeFontTable: 8-byte header, 16-byte records naming packed Pascal names', () {
    final b = u8([
      0, 1, 0, 2, 0, 3, 0, 1, // version 1, words 2 and 3, one font
      0, 0, 0, 24, 0, 15, 4, 2, 3, 232, 0, 15, 0, 216, 0, 213, // record: name at 24, size 15, flags 4/2, weight 1000
      ...pascal('Segoe UI'),
    ]);
    final t = decodeFontTable(b);
    expect((t.version, t.fontCount, t.nameTableOffset, t.entries.length), (1, 1, 24, 1));
    final e = t.entries.single;
    expect((e.nameOffset, e.size, e.flagsByte, e.styleFlags), (24, 15, 4, 2));
    expect((e.weight, e.resolvedSize, e.metricA, e.metricB, e.name), (1000, 15, 216, 213, 'Segoe UI'));
    expect((e.isBold, e.isPredefinedRef), (true, false));
    expect(identical(t.entryForRunFontId(-3), e), isTrue);
    expect(t.entryForRunFontId(0), isNull);
    expect(t.serialize(), same(b));
    final two = u8([
      0,
      1,
      0,
      2,
      0,
      3,
      0,
      2,
      0,
      0,
      0,
      40,
      ...List.filled(12, 0),
      0,
      0,
      0,
      42,
      ...List.filled(12, 0),
      ...pascal('1'),
      ...pascal('Tahoma'),
    ]);
    final pair = decodeFontTable(two);
    expect((pair.entries[0].isPredefinedRef, pair.entries[1].name), (true, 'Tahoma'));
    final bogus = Uint8List(24)..[7] = 1;
    ByteData.sublistView(bogus).setUint32(8, 9999);
    expect(() => decodeFontTable(bogus), throwsA(isA<AssertionError>()), reason: 'record must name the packed table');
    expect(() => decodeFontTable(Uint8List(6)), throwsA(isA<AssertionError>()));
  });

  test('decodeTagStore: length-prefixed, bare and LabVIEW 7 inclusive-length values', () {
    Uint8List entry(String name, List<int> value) => u8([0, 0, 0, name.length, ...name.codeUnits, ...value]);
    const version20 = [0x20, 0x00, 0x80, 0x00];
    const boolVariant = [...version20, 0, 0, 0, 1, 0, 4, 0, 0x21, 0, 1, 0, 0, 1, 0, 0, 0, 0];
    final prefixed = u8([
      0,
      0,
      0,
      1,
      ...entry('NI.LV.All.SourceOnly', [0, 0, 0, boolVariant.length, ...boolVariant]),
    ]);
    final store = decodeTagStore(prefixed);
    expect((store.declaredCount, store.entries.length), (1, 1));
    expect(
      (store.entries.single.name, store.entries.single.framing),
      ('NI.LV.All.SourceOnly', ViTagValueFraming.lengthPrefixed),
    );
    expect(store.entries.single.value, boolVariant);
    expect(store.serialize(), same(prefixed));

    const strings = [
      0x12, 0x00, 0x80, 0x04, 0, 0, 0, 2, // version 12, two type descriptors
      0, 8, 0, 0x30, 0xff, 0xff, 0xff, 0xff, // string
      0, 12, 0, 0x40, 0, 1, 0xff, 0xff, 0xff, 0xff, 0, 0, // 1-d array of the string
      0, 1, 0, 1, // has value, of type 1
      0, 0, 0, 2, 0, 0, 0, 4, 0x44, 0x66, 0x6c, 0x74, 0, 0, 0, 3, 0x4d, 0x61, 0x63, // ["Dflt", "Mac"]
      0, 0, 0, 0, // no attributes
    ];
    final bare = u8([0, 0, 0, 2, ...entry('NI.LV.ALL.goodSyntaxTargets', strings), ...entry('B', boolVariant)]);
    final bareStore = decodeTagStore(bare);
    expect(bareStore.entries.map((e) => e.framing), [ViTagValueFraming.bare, ViTagValueFraming.bare]);
    expect(bareStore.entries[0].value, strings);
    expect(bareStore.entries[1].name, 'B');

    const lv7 = [0, 4, 0, 0x21, 1, 0, 0, 0, 0];
    final inclusive = u8([
      0,
      0,
      0,
      1,
      ...entry('NI.VI.HiddenNSLibOutOfDate', [0, 0, 0, lv7.length + 4, ...lv7]),
    ]);
    final old = decodeTagStore(inclusive);
    expect(old.entries.single.framing, ViTagValueFraming.lengthPrefixedInclusive);
    expect(old.entries.single.value, lv7);

    expect(() => decodeTagStore(u8([0, 0, 0, 1, 0, 0, 0, 1, 0x41, 0, 0, 0, 9])), throwsA(isA<AssertionError>()));
    expect(
      () => decodeTagStore(
        u8([
          0,
          0,
          0,
          2,
          ...entry('A', [0, 0, 0, 0]),
        ]),
      ),
      throwsA(isA<AssertionError>()),
    );
  });

  test('decodeLinkInfo: header, count, terminator; entries walk with a version and stay unwalked without one', () {
    final empty = u8([0, 1, ...'LVIN'.codeUnits, 0, 0, 0, 0, 0, 3]);
    final info = decodeLinkInfo(empty, version: decodeVersionWord(hx('20008000')));
    expect((info.version, info.rootKind, info.entryCount, info.terminator, info.isWalked), (1, 'LVIN', 0, 3, true));
    expect(info.entries, isEmpty);
    expect(info.serialize(), same(empty));
    final unknown = u8([0, 1, ...'BDHP'.codeUnits, 0, 0, 0, 1, 0, 2, ...'ZZZZ'.codeUnits, 1, 2, 3, 4, 0, 3]);
    final walked = decodeLinkInfo(unknown, version: decodeVersionWord(hx('20008000')));
    expect(walked.isWalked, isFalse);
    expect(walked.entries.single, isA<ViLinkEntryUnwalked>());
    expect((walked.entries.single.offset, walked.entries.single.end), (10, unknown.length - 2));
    expect(decodeLinkInfo(unknown).entries.single, isA<ViLinkEntryUnwalked>(), reason: 'no version, no grammar');
    final named = u8([
      0,
      1,
      ...'BDHP'.codeUnits,
      0,
      0,
      0,
      1,
      0,
      2,
      ...'IUVI'.codeUnits,
      6,
      ...'Sub.vi'.codeUnits,
      0,
      3,
    ]);
    expect(decodeLinkInfo(named).linkedNames, ['Sub.vi']);
    expect(() => decodeLinkInfo(u8([0, 1, 2, 3])), throwsA(isA<AssertionError>()));
  });

  test('decodeLinkInfo walks each entry kind to the terminator under its saving version', () {
    const zero4 = [0, 0, 0, 0];
    const pth0 = [
      ...[0x50, 0x54, 0x48, 0x30],
      ...zero4,
    ];
    const basic = [...zero4, ...pth0, ...zero4];
    const basicLegacy = [...zero4, ...pth0];
    const apiCache = [...zero4, ...zero4, 0, 0, 0, ...zero4];
    const classAB = [0, 0, 0, 1, 1, 0x41, ...pth0, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0x42, ...pth0];
    final rows = <(String, String, List<int>)>[
      ('20008000', 'TCPI', [...basic, ...apiCache, ...zero4, 0, 0, 0, 0, 1, ...classAB, ...zero4]),
      ('20008000', 'AXVT', [...basic, ...zero4, 0, 0, 0, ...zero4, ...zero4, ...List.filled(40, 0)]),
      (
        '13008000',
        'RCFL',
        [...basic, ...zero4, ...zero4, ...zero4, 0, 0, 0, 1, 0, 0, 0, 1, 0, 4, 0, 0x20, 0, 1, 0, 0, ...zero4],
      ),
      ('13008000', 'RVPI', [...basic, ...apiCache]),
      (
        '08208000',
        'DNDA',
        [
          ...basicLegacy,
          0,
          0,
          ...List.filled(24, 0),
          ...zero4,
          ...List.filled(8, 0),
          1,
          0x61,
          1,
          0x62,
          1,
          0x63,
          1,
          0x64,
          ...zero4,
        ],
      ),
    ];
    for (final (version, kind, body) in rows) {
      final payload = u8([0, 1, ...'BDHP'.codeUnits, 0, 0, 0, 1, 0, 2, ...kind.codeUnits, ...body, 0, 3]);
      final info = decodeLinkInfo(payload, version: decodeVersionWord(hx(version)));
      final entry = info.entries.single;
      expect(entry, isA<ViLinkEntryFramed>().having((e) => e.kind, 'kind', kind), reason: kind);
      expect((entry.offset, entry.end), (10, payload.length - 2), reason: kind);
    }
  });

  test('decodeLibraryNames: [u32 count][count pstr]', () {
    final b = u8([0, 0, 0, 2, ...pascal('Outer.lvlib'), ...pascal('Inner.lvclass')]);
    final names = decodeLibraryNames(b);
    expect((names.length, names[0], names[1]), (2, 'Outer.lvlib', 'Inner.lvclass'));
    expect(names.serialize(), same(b));
    expect(() => decodeLibraryNames(u8([0, 0, 0, 1, 9, 0x41])), throwsA(isA<AssertionError>()));
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

  test('decodeConnectorPane (CONP): two bytes are a VCTP index, any other length is an inline descriptor', () {
    final p = decodeConnectorPane(hx('002a'));
    expect(p, isA<ViConnectorPaneTypeIndex>().having((p) => p.typeIndex, 'typeIndex', 0x2a));
    expect((decodeConnectorPane(hx('0105')) as ViConnectorPaneTypeIndex).typeIndex, 0x105);
    final inline = decodeConnectorPane(Uint8List(28));
    expect(inline, isA<ViConnectorPaneInline>().having((p) => p.descriptor.length, 'descriptor', 28));
    expect(inline.serialize(), same(inline.bytes));
    expect(() => decodeConnectorPane(Uint8List(0)), throwsA(isA<AssertionError>()));
  });

  test('decodeConnectorPaneMap (CPMp): little-endian count and terminals, 0xFFFF unassigned', () {
    final body = u8([3, 0, 2, 0, 0xff, 0xff, 0, 0]);
    final map = decodeConnectorPaneMap(body);
    expect(map.length, 3);
    expect(map[0], const PanelObjectTerminal(2));
    expect(map[1], const UnassignedTerminal());
    expect(map[2], const PanelObjectTerminal(0));
    expect(map.assignedCount, 2);
    expect(map.terminals, hasLength(3));
    expect(map.serialize(), same(body));
    expect(() => decodeConnectorPaneMap(u8([2, 0, 0, 0])), throwsA(isA<AssertionError>()));
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

  test('decodeHelpPath (HLPP): a PTH0 whose components tile the payload', () {
    final body = _pth0(['<helpdir>', 'JKI', 'Caraya', 'README.html']);
    final p = decodeHelpPath(body);
    expect((p.pathType, p.componentCount), (0, 4));
    expect(p.components, ['<helpdir>', 'JKI', 'Caraya', 'README.html']);
    expect(p.path, '<helpdir>/JKI/Caraya/README.html');
    expect(p.serialize(), same(body));
    expect(isPth0(u8(List.filled(16, 0x41))), isFalse, reason: 'no magic');
    expect(isPth0(Uint8List(8)), isFalse, reason: 'too short');
    final lying = _pth0(['a']);
    ByteData.sublistView(lying).setUint16(10, 9999);
    expect(isPth0(lying), isFalse, reason: 'count overruns the length');
    expect(() => decodeHelpPath(lying), throwsA(isA<AssertionError>()));
    expect(pth0ExtentAt(u8([0, 0, ...body, 9, 9]), 2), body.length, reason: 'extent inside a larger buffer');
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

    test('decodeDataSpaceImage: a 24-bit raster, its pixels, and the geometry checks', () {
      final raster = decodeDataSpaceImage(_iconSection(px));
      expect(raster, isA<ViDataSpaceRaster>());
      expect((raster.width, raster.height, raster.depth), (2, 2, 24));
      expect((raster as ViDataSpaceRaster).pixels, px);
      expect(raster.serialize(), same(raster.bytes));
      expect(() => decodeDataSpaceImage(_iconSection(px)..[31] = 9), throwsA(isA<AssertionError>()));
      expect(() => decodeDataSpaceImage(_iconSection(px)..[0] = 1), throwsA(isA<AssertionError>()));
      expect(() => decodeDataSpaceImage(Uint8List(10)), throwsA(isA<AssertionError>()));
      expect(
        decodeDataSpaceImage(
          Uint8List(16)
            ..[5] = 20
            ..[7] = 20
            ..[9] = 1,
        ),
        isA<ViDataSpaceHeaderOnly>(),
      );
    });

    test('rgbIconFromSections finds the 24-bit raster among the DSIM sections', () {
      final icon = rgbIconFromSections([dsec(List.filled(20, 0), tag: 'LVSR'), dsec(_iconSection(px), tag: 'DSIM')])!;
      expect(icon.width, 2);
      expect(icon.pixels, px);
      expect(rgbIconFromSections([dsec(_iconSection(px), tag: 'PICC')]), isNull);
    });

    test('decodeLegacyIcon: depth by tag, exact-size 32×32 bitmaps, pixel and palette reads', () {
      expect(
        [
          for (final t in ['icl8', 'icl4', 'ICON', 'STRG']) LegacyIconDepth.forTag(t),
        ],
        [LegacyIconDepth.eightBit, LegacyIconDepth.fourBit, LegacyIconDepth.mono, null],
      );
      final mono = decodeIcon1(Uint8List(128)..[0] = 0xA0);
      expect([for (var x = 0; x < 8; x++) mono.pixelAt(x, 0)], [1, 0, 1, 0, 0, 0, 0, 0], reason: 'MSB-first bits');
      expect((mono.argbAt(0, 0), mono.argbAt(1, 0)), (0xFF000000, 0xFFFFFFFF));
      final nib = decodeIcl4(Uint8List(512)..[0] = 0x3C);
      expect((nib.pixelAt(0, 0), nib.pixelAt(1, 0)), (3, 12), reason: 'two nibbles per byte');
      expect(nib.argbAt(0, 0), 0xFFDD0806);
      final byte = decodeIcl8(Uint8List(1024)..[37] = 200);
      expect((byte.pixelAt(5, 1), byte.argbAt(5, 1), byte.argbAt(0, 0)), (200, 0xFF006699, 0xFFFFFFFF));
      expect(byte.serialize(), same(byte.bytes));
      expect(() => decodeIcon1(Uint8List(100)), throwsA(isA<AssertionError>()));
      expect(() => decodeIcl4(Uint8List(1024)), throwsA(isA<AssertionError>()));
    });

    test('macIconArgb maps the Mac 16- and 256-colour palettes', () {
      expect(
        (macIconArgb(LegacyIconDepth.fourBit, 0), macIconArgb(LegacyIconDepth.fourBit, 6)),
        (0xFFFFFFFF, 0xFF0000D4),
      );
      expect(macIconArgb(LegacyIconDepth.fourBit, 15), 0xFF000000);
      const eight = LegacyIconDepth.eightBit;
      expect(
        [macIconArgb(eight, 0), macIconArgb(eight, 5), macIconArgb(eight, 35)],
        [0xFFFFFFFF, 0xFFFFFF00, 0xFFFF0000],
      );
      expect(
        [macIconArgb(eight, 215), macIconArgb(eight, 245), macIconArgb(eight, 255)],
        [0xFFEE0000, 0xFFEEEEEE, 0xFF000000],
      );
    });

    test('legacyIconFromSections prefers icl8 over icl4 over ICON', () {
      final icl4 = sec('icl4', List.filled(512, 1));
      final icon = sec('ICON', List.filled(128, 2));
      expect(legacyIconFromSections([icon, icl4])!.depth, LegacyIconDepth.fourBit);
      expect(legacyIconFromSections([icon, icl4, sec('icl8', List.filled(1024, 3))])!.depth, LegacyIconDepth.eightBit);
      expect(legacyIconFromSections([sec('icl8', List.filled(9, 3))]), isNull);
      expect(legacyIconFromSections([sec('LVSR', List.filled(160, 0))]), isNull);
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
      'decodePth0': decodePth0,
      'decodeHistory': decodeHistory,
      'decodeFontTable': decodeFontTable,
      'decodeLibraryNames': decodeLibraryNames,
      'decodeDataTypeHeap': decodeDataTypeHeap,
      'decodeVersionWord': decodeVersionWord,
      'decodeVersBlock': decodeVersBlock,
      'decodeSaveRecord': decodeSaveRecord,
      'decodeTypeMap': decodeTypeMap,
      'decodeConnectorPane': decodeConnectorPane,
      'decodeHelpPath': decodeHelpPath,
      'decodeIdTable': decodeIdTable,
      'decodeAlignTable': decodeAlignTable,
      'decodeDataSpaceImage': decodeDataSpaceImage,
      'decodeIcl8': decodeIcl8,
      'decodeIcl4': decodeIcl4,
      'decodeIcon1': decodeIcon1,
      'decodePngStream': decodePngStream,
      'decodePict': decodePict,
      'decodeEmf': decodeEmf,
      'decodeConnectorPaneMap': decodeConnectorPaneMap,
      'decodeOffsetTable': decodeOffsetTable,
      'decodeGcdiRecord': decodeGcdiRecord,
      'decodeBookmarkList': decodeBookmarkList,
      'decodeTagStore': decodeTagStore,
      'decodeCompiledCode': decodeCompiledCode,
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
      expect(decodeIcl8(icl8).serialize(), same(icl8));
      final icl4 = Uint8List.fromList([for (var i = 0; i < 512; i++) (i * 13) & 0xff]);
      expect(decodeIcl4(icl4).serialize(), same(icl4));
      final icon = Uint8List.fromList([for (var i = 0; i < 128; i++) (i * 29) & 0xff]);
      expect(decodeIcon1(icon).serialize(), same(icon));
    });

    test('ViIdTable.serialize returns the backing [u32 count][entries] bytes', () {
      final body = _idtab([1, 2, 0xDEADBEEF, 0]);
      expect(decodeIdTable(body).serialize(), same(body));
      final empty = _idtab([]);
      expect(decodeIdTable(empty).serialize(), same(empty));
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
      final unwalkedLi = u8([0, 1, ...'LVIN'.codeUnits, 0, 0, 0, 2, 0, 3]);
      expect(
        serializeBlockPayload('LIvi', unwalkedLi),
        unwalkedLi,
        reason: 'the view re-emits an unwalked entry region',
      );
      expect(serializeBlockPayload('VICD', u8([0, 0, 0, 9, 0x78, 0x9c, 0, 0])), isNull, reason: 'still enveloped');
      expect(hasBlockWriter('FPHb'), isFalse);
      expect(hasBlockWriter('MNGI'), isFalse);
      expect(() => serializeBlockPayload('icl8', u8([1, 2, 3])), throwsA(isA<AssertionError>()));
      expect(
        () => serializeBlockPayload('NUID', u8([0, 0, 0, 1, 0, 0, 0, 5, 0xFF, 0xFF])),
        throwsA(isA<AssertionError>()),
      );
    });
  });
}
