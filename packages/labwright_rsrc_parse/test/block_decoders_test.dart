import 'dart:convert';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'test_util.dart';

Uint8List _strg(String text) {
  final body = utf8.encode(text);
  return u8([0, 0, 0, body.length, ...body]);
}

Uint8List _lvsr(int len, {int b0 = 0x20, int b1 = 0, int statusFlags = 0, int priority = 1, int kind = 2}) {
  final b = Uint8List(len);
  final v = ByteData.sublistView(b);
  b[0] = b0;
  b[1] = b1;
  b[2] = 0x80;
  if (len >= 8) v.setUint32(4, statusFlags);
  if (len >= 36) v.setUint16(32, priority);
  if (len >= 36) v.setUint16(34, kind);
  if (len >= 40) v.setInt32(36, -1);
  if (len >= 112) b.setAll(96, emptyPasswordDigest);
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
    expect(ViStringBlock(_strg('This VI does X')).text, 'This VI does X');
    expect(ViStringBlock(_strg('')).text, '');
    expect(ViStringBlock(_strg('### Foo.vi')).text, '### Foo.vi', reason: 'HLPT reuses the STRG layout');
    expect(ViStringBlock(u8([0, 0, 0, 1, 0xff])).text, isNotEmpty, reason: 'bad UTF-8 -> replacement, no throw');
    final body = _strg('x');
    expect(ViStringBlock(body).serialize(), viewOf(body));
    expect(() => ViStringBlock(u8([0, 0, 0, 6, 0x41, 0x42, 0x43])), throwsA(isA<AssertionError>()));
    expect(() => ViStringBlock(u8([0, 0, 0])), throwsA(isA<AssertionError>()));
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

    final bare = ViCompiledCode(vicd(layoutWord: 0x103, codeEndAt: 48));
    expect(
      (bare.architecture, bare.codeStart, bare.codeSize, bare.codeEnd, bare.symbolCount),
      (CodeArchitecture.i386, 24, 8, 48, 0),
    );
    expect(bare.fixupsAndCode.length, 24);
    final table = ViCompiledCode(vicd(layoutWord: 0x103, codeEndAt: 48, names: ['abc', 'defgh']));
    expect(table.symbolCount, 2);
    expect(String.fromCharCodes(table.symbolNameAt(1)), 'defgh');
    expect(table.serialize(), table.serialize());
    final legacy = ViCompiledCode(vicd(layoutWord: 0, codeEndAt: 44));
    expect((legacy.layoutWord, legacy.codeEnd), (0, 44));
    expect(
      () => ViCompiledCode(vicd(layoutWord: 0x103, codeEndAt: 48)..[22] = 0x41),
      throwsA(isA<AssertionError>()),
    );
    expect(() => ViCompiledCode(Uint8List(20)), throwsA(isA<AssertionError>()));
  });

  test('decodeHistory: 40-byte record fields and the reserved-zero check', () {
    final b = Uint8List(40);
    ByteData.sublistView(b)
      ..setUint32(0, 2)
      ..setUint32(4, 0x400)
      ..setUint32(8, 11);
    final h = ViHistory(b);
    expect((h.formatVersion, h.flags, h.revisionNumber), (2, 0x400, 11));
    expect(h.reservedAreZero, isTrue);
    expect(h.serialize(), viewOf(b));
    ByteData.sublistView(b).setUint32(12, 7);
    expect(ViHistory(b).reservedAreZero, isFalse, reason: 'offset 12 is a reserved word');
    expect(() => ViHistory(Uint8List(20)), throwsA(isA<AssertionError>()));
  });

  test('decodeFontTable: 8-byte header, 16-byte records naming packed Pascal names', () {
    final b = u8([
      0, 1, 0, 2, 0, 3, 0, 1, // version 1, words 2 and 3, one font
      0, 0, 0, 24, 0, 15, 4, 2, 3, 232, 0, 15, 0, 216, 0, 213, // record: name at 24, size 15, flags 4/2, weight 1000
      ...pascal('Segoe UI'),
    ]);
    final t = ViFontTable(b);
    expect((t.version, t.fontCount, t.nameTableOffset, t.entries.length), (1, 1, 24, 1));
    final e = t.entries.single;
    expect((e.nameOffset, e.size, e.flagsByte, e.styleFlags), (24, 15, 4, 2));
    expect((e.weight, e.resolvedSize, e.metricA, e.metricB, e.name), (1000, 15, 216, 213, 'Segoe UI'));
    expect((e.isBold, e.isPredefinedRef), (true, false));
    expect(identical(t.entryForRunFontId(-3), e), isTrue);
    expect(t.entryForRunFontId(0), isNull);
    expect(t.serialize(), viewOf(b));
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
    final pair = ViFontTable(two);
    expect((pair.entries[0].isPredefinedRef, pair.entries[1].name), (true, 'Tahoma'));
    final bogus = Uint8List(24)..[7] = 1;
    ByteData.sublistView(bogus).setUint32(8, 9999);
    expect(() => ViFontTable(bogus), throwsA(isA<AssertionError>()), reason: 'record must name the packed table');
    expect(() => ViFontTable(Uint8List(6)), throwsA(isA<AssertionError>()));
  });

  test('decodeDiagramTagStore: objects with their VITS-framed tags tile the payload', () {
    const boolVariant = [0x20, 0x00, 0x80, 0x00, 0, 0, 0, 1, 0, 4, 0, 0x21, 0, 1, 0, 0, 1, 0, 0, 0, 0];
    final tag = [0, 0, 0, 3, ...'SIM'.codeUnits, 0, 0, 0, boolVariant.length, ...boolVariant];
    final payload = u8([0, 0, 0, 2, 0, 0, 0, 0x42, 0, 0, 0, 1, ...tag, 0, 0, 0x05, 0x59, 0, 0, 0, 0]);
    final store = ViDiagramTagStore(payload);
    expect(store.declaredCount, 2);
    expect(store.objects.map((o) => (o.oid, o.tags.length)), [(0x42, 1), (0x559, 0)]);
    expect(store.objects.first.tags.single.name, 'SIM');
    expect(store.objects.first.tags.single.value, boolVariant);
    expect(store.serialize(), viewOf(payload));
    expect(() => ViDiagramTagStore(u8([0, 0, 0, 1, 0, 0, 0, 0x42])), throwsA(isA<AssertionError>()));
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
    final store = ViTagStore(prefixed);
    expect((store.declaredCount, store.entries.length), (1, 1));
    expect(
      (store.entries.single.name, store.entries.single.framing),
      ('NI.LV.All.SourceOnly', ViTagValueFraming.lengthPrefixed),
    );
    expect(store.entries.single.value, boolVariant);
    expect(store.serialize(), viewOf(prefixed));

    const strings = [
      0x12, 0x00, 0x80, 0x04, 0, 0, 0, 2, // version 12, two type descriptors
      0, 8, 0, 0x30, 0xff, 0xff, 0xff, 0xff, // string
      0, 12, 0, 0x40, 0, 1, 0xff, 0xff, 0xff, 0xff, 0, 0, // 1-d array of the string
      0, 1, 0, 1, // has value, of type 1
      0, 0, 0, 2, 0, 0, 0, 4, 0x44, 0x66, 0x6c, 0x74, 0, 0, 0, 3, 0x4d, 0x61, 0x63, // ["Dflt", "Mac"]
      0, 0, 0, 0, // no attributes
    ];
    final bare = u8([0, 0, 0, 2, ...entry('NI.LV.ALL.goodSyntaxTargets', strings), ...entry('B', boolVariant)]);
    final bareStore = ViTagStore(bare);
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
    final old = ViTagStore(inclusive);
    expect(old.entries.single.framing, ViTagValueFraming.lengthPrefixedInclusive);
    expect(old.entries.single.value, lv7);

    expect(() => ViTagStore(u8([0, 0, 0, 1, 0, 0, 0, 1, 0x41, 0, 0, 0, 9])), throwsA(isA<AssertionError>()));
    expect(
      () => ViTagStore(
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
    final info = ViLinkInfo(empty, version: ViVersionWord.at(bd(hx('20008000')), 0));
    expect((info.version, info.rootKind, info.entryCount, info.terminator, info.isWalked), (1, 'LVIN', 0, 3, true));
    expect(info.entries, isEmpty);
    expect(info.serialize(), viewOf(empty));
    final unknown = u8([0, 1, ...'BDHP'.codeUnits, 0, 0, 0, 1, 0, 2, ...'ZZZZ'.codeUnits, 1, 2, 3, 4, 0, 3]);
    final walked = ViLinkInfo(unknown, version: ViVersionWord.at(bd(hx('20008000')), 0));
    expect(walked.isWalked, isFalse);
    expect(walked.entries.single, isA<ViLinkEntryUnwalked>());
    expect((walked.entries.single.offset, walked.entries.single.end), (10, unknown.length - 2));
    expect(ViLinkInfo(unknown).entries.single, isA<ViLinkEntryUnwalked>(), reason: 'no version, no grammar');
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
    expect(ViLinkInfo(named).linkedNames, ['Sub.vi']);
    expect(() => ViLinkInfo(u8([0, 1, 2, 3])), throwsA(isA<AssertionError>()));
  });

  test('decodeLinkInfo walks each entry kind to the terminator under its saving version', () {
    const zero4 = [0, 0, 0, 0];
    const pth0 = [
      ...[0x50, 0x54, 0x48, 0x30],
      ...zero4,
    ];
    const basic = [...zero4, ...pth0, ...zero4, ...zero4];
    const basicLegacy = [...zero4, ...pth0, ...zero4];
    const apiCache = [...zero4, ...zero4, 0, 0, 0, ...zero4];
    const classAB = [0, 0, 0, 1, 1, 0x41, ...pth0, ...zero4, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0x42, ...pth0, ...zero4];
    final rows = <(String, String, List<int>)>[
      ('20008000', 'TCPI', [...basic, ...apiCache, ...zero4, 0, 0, 0, 0, 1, ...classAB, ...zero4]),
      ('20008000', 'AXVT', [...basic, 0, 0, 0, ...zero4, ...zero4, ...List.filled(40, 0)]),
      (
        '13008000',
        'RCFL',
        [...basic, ...zero4, ...zero4, ...zero4, 0, 0, 0, 1, 0, 0, 0, 1, 0, 4, 0, 0x20, 0, 1, 0, 0, ...zero4],
      ),
      ('13008000', 'RVPI', [...basic, ...apiCache]),
      ('20008000', 'DNVA', [...basic, ...pth0, ...zero4]),
      ('20008000', 'DSVr', [...basic, 0, 0, 0x42, ...zero4, ...zero4]),
      ('20008000', 'XNVI', [...basic, 0, 0, 0x42, ...zero4, ...zero4, ...pth0, ...zero4, 0, 0, 0, 1, 0x41]),
      ('20008000', 'VIGV', [...basic, 0, 0, 0x42, ...zero4, ...List.filled(36, 0x30)]),
      ('20008000', 'EiVr', [...basic, 0, 0, 0, 1, 0x30, ...zero4, ...zero4, ...zero4, 0]),
      (
        '08208000',
        'DNDA',
        [
          ...basicLegacy,
          0,
          0,
          ...List.filled(24, 0),
          ...zero4,
          ...zero4,
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
      final info = ViLinkInfo(payload, version: ViVersionWord.at(bd(hx(version)), 0));
      final entry = info.entries.single;
      expect(entry, isA<ViLinkEntryFramed>().having((e) => e.kind, 'kind', kind), reason: kind);
      expect((entry.offset, entry.end), (10, payload.length - 2), reason: kind);
    }
  });

  test('a framed link entry names the linked resource and its path record', () {
    final path = [
      ...'PTH0'.codeUnits,
      0,
      0,
      0,
      22,
      0,
      1,
      0,
      3,
      0,
      6,
      ...'Parent'.codeUnits,
      9,
      ...'Child.ctl'.codeUnits,
    ];
    final names = [0, 0, 0, 2, 9, ...'Lib.lvlib'.codeUnits, 9, ...'Child.ctl'.codeUnits];
    final payload = u8([
      0,
      1,
      ...'BDHP'.codeUnits,
      0,
      0,
      0,
      1,
      0,
      2,
      ...'VILB'.codeUnits,
      ...names,
      ...path,
      0,
      0,
      0,
      0,
      0,
      3,
    ]);
    final entry = ViLinkInfo(payload, version: ViVersionWord.at(bd(hx('20008000')), 0)).entries.single;
    expect(entry, isA<ViLinkEntryFramed>());
    final framed = entry as ViLinkEntryFramed;
    expect(framed.qualifiedName, ['Lib.lvlib', 'Child.ctl']);
    expect(framed.path?.components, ['', 'Parent', 'Child.ctl']);
    expect(framed.path?.pathType, 1);
  });

  test('decodeLibraryNames: [u32 count][count pstr]', () {
    final b = u8([0, 0, 0, 2, ...pascal('Outer.lvlib'), ...pascal('Inner.lvclass')]);
    final names = ViLibraryNames(b);
    expect((names.length, names[0], names[1]), (2, 'Outer.lvlib', 'Inner.lvclass'));
    expect(names.serialize(), viewOf(b));
    expect(() => ViLibraryNames(u8([0, 0, 0, 1, 9, 0x41])), throwsA(isA<AssertionError>()));
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
      final v = ViVersionWord.at(bd(hx(bytes)), 0);
      expect((v.major, v.minor, v.patch, v.version), (major, minor, patch, version), reason: bytes);
    }
    final v = ViVersionWord.at(bd(hx('08508002')), 0);
    expect((v.stage, v.build), (0x80, 2));
    expect(v.minor, 5, reason: 'minor is the high nibble of byte 1, not BCD(0x50)=50');
    expect(() => ViVersionWord.at(bd(hx('010203')), 0), throwsA(isA<AssertionError>()));
  });

  test('decodeVersBlock: version word, flags, and the two Pascal strings tiling the payload', () {
    final b = u8([0x20, 0x00, 0x80, 0x00, 0x00, 0x03, ...pascal('20.0'), ...pascal('20.0f1')]);
    final v = ViVersBlock(b);
    expect((v.versionWord.version, v.regionCode, v.versionText, v.infoText), ('20.0', 3, '20.0', '20.0f1'));
    expect(v.serialize(), viewOf(b));
    expect(() => ViVersBlock(u8([0x20, 0, 0x80, 0, 0, 0, 9, 0x41])), throwsA(isA<AssertionError>()));
  });

  group('decodeSaveRecord (LVSR)', () {
    test('decodes the BCD version word (same decode as vers)', () {
      final r = ViSaveRecord(_lvsr(160));
      expect(
        (r.versionWord.major, r.versionWord.minor, r.versionWord.stage, r.versionWord.version),
        (20, 0, 0x80, '20.0'),
      );
      expect(ViSaveRecord(_lvsr(160, b0: 0x09)).versionWord.major, 9);
      final v85 = ViSaveRecord(_lvsr(160, b0: 0x08, b1: 0x50)).versionWord;
      expect((v85.major, v85.minor, v85.version), (8, 5, '8.5'), reason: 'minor guard: not BCD(0x50)');
      expect(r.serialize(), r.serialize());
    });

    test('names the bits of the status flag word', () {
      final cases = <(int, Set<ViStatusFlag>)>[
        (0, {}),
        (1 << 27, {ViStatusFlag.evaluationWatermark}),
        (1 << 28, {ViStatusFlag.studentWatermark}),
        ((1 << 5) | (1 << 17), {ViStatusFlag.reentrant, ViStatusFlag.subroutine}),
      ];
      for (final (word, flags) in cases) {
        final r = ViSaveRecord(_lvsr(160, statusFlags: word));
        expect(r.statusFlagWord, word);
        expect(r.statusFlags, flags, reason: word.toRadixString(16));
      }
    });

    test('names the kind, priority, execution system and control style, and rejects unknown codes', () {
      final r = ViSaveRecord(_lvsr(160, kind: 11, priority: 5));
      expect(
        (r.kind, r.priority, r.executionSystem, r.controlStyle),
        (
          ViKind.polymorphic,
          ViPriority.subroutine,
          ViExecutionSystem.sameAsCaller,
          ViControlStyle.modern,
        ),
      );
      expect(() => ViSaveRecord(_lvsr(160, kind: 14)), throwsA(isA<AssertionError>()));
      expect(() => ViSaveRecord(_lvsr(160, priority: 6)), throwsA(isA<AssertionError>()));
    });

    test('the record holds the 96-byte prefix and any of the corpus tails', () {
      for (final len in [96, 112, 116, 120, 136, 137, 144, 160]) {
        expect(ViSaveRecord(_lvsr(len, b0: 0x16)).versionWord.major, 16, reason: 'len $len');
      }
      expect(ViSaveRecord.layout.minSize, 96);
      expect(() => ViSaveRecord(_lvsr(95)), throwsA(isA<AssertionError>()));
    });
  });

  test('connector pane (CONP): two bytes index the top-level types, any other length embeds a type pool', () {
    final p = ViConnectorPane(hx('002a'));
    expect(p, isA<ViConnectorPaneIndex>().having((p) => p.typeIndex, 'typeIndex', 0x2a));
    final pool = ViTypePool(u8([0, 0, 0, 2, 0, 4, 0, 0, 0, 8, 0, 0xf0, 0, 1, 0, 0, 0, 1, 0, 1]));
    expect((ViConnectorPane(hx('0001')) as ViConnectorPaneIndex).resolve(pool), isA<ViFunctionType>());
    expect((ViConnectorPane(hx('0002')) as ViConnectorPaneIndex).resolve(pool), isNull);
    final inline = ViConnectorPane(pool.serialize());
    expect(inline, isA<ViConnectorPaneInline>().having((p) => p.type, 'type', isA<ViFunctionType>()));
    expect(inline.typeIn(null), same((inline as ViConnectorPaneInline).type));
    expect(() => ViConnectorPane(Uint8List(0)), throwsA(isA<AssertionError>()));
    expect(() => ViConnectorPane(Uint8List(28)), throwsA(isA<AssertionError>()));
  });

  test('a type pool whose count word claims more descriptors than its bytes hold fails before allocating', () {
    expect(() => ViTypePool(u8([0x40, 0, 0, 0x10, 0, 0])), throwsA(isA<ViFormatException>()));
    expect(() => ViTypePool(u8([0, 0, 0, 2, 0, 4, 0, 0])), throwsA(isA<ViFormatException>()));
    expect(
      () => ViType.at(u8([0, 0x10, 0, 0xf1, 0, 0, 0, 1, 0x40, 0, 0, 0, 0, 0, 0, 0]), 0, 16),
      throwsA(isA<ViFormatException>()),
    );
  });

  test('front-panel datalog type (FPTD) names the data-item cluster a CPMp word indexes', () {
    final pool = ViTypePool(
      hx(
        '00000006'
        '00074003000178' // #0 i32 "x"
        '000640210179' // #1 boolean "y"
        '000a005000020000'
        '0001' // #2 items cluster {x, y}
        '00040000' // #3 void
        '000a005000020003'
        '0002' // #4 record cluster {void, items}
        '000a007000010001'
        '0004' // #5 datalog refnum over #4
        '00010005',
      ),
    );
    final fptd = ViFrontPanelType(hx('0001'));
    final items = fptd.panelItemsIn(pool)!;
    expect([for (var i = 0; i < items.memberCount; i++) pool.types[items.memberIndexAt(i)].label], ['x', 'y']);
    final map = ViConnectorPaneMap(u8([2, 0, 1, 0, 0xff, 0xff]));
    expect(pool.types[items.memberIndexAt((map[0] as PanelObjectTerminal).index)].label, 'y');
    expect(ViFrontPanelType(hx('0002')).panelItemsIn(pool), isNull);
  });

  test('decodeConnectorPaneMap (CPMp): little-endian count and terminals, 0xFFFF unassigned', () {
    final body = u8([3, 0, 2, 0, 0xff, 0xff, 0, 0]);
    final map = ViConnectorPaneMap(body);
    expect(map.length, 3);
    expect(map[0], const PanelObjectTerminal(2));
    expect(map[1], const UnassignedTerminal());
    expect(map[2], const PanelObjectTerminal(0));
    expect(map.assignedCount, 2);
    expect(map.terminals, hasLength(3));
    expect(map.serialize(), viewOf(body));
    expect(() => ViConnectorPaneMap(u8([2, 0, 0, 0])), throwsA(isA<AssertionError>()));
  });

  test('decodeHelpPath (HLPP): a PTH0 whose components tile the payload', () {
    final body = _pth0(['<helpdir>', 'JKI', 'Caraya', 'README.html']);
    final p = ViPath(body);
    expect((p.pathType, p.componentCount), (0, 4));
    expect(p.components, ['<helpdir>', 'JKI', 'Caraya', 'README.html']);
    expect((p.type, p.form, p.text), (ViPathType.absolute, ViPathForm.symbolic, r'<helpdir>\JKI\Caraya\README.html'));
    final forms = <(List<String>, int, ViPathForm, String)>[
      (['C', 'Users', 'me', 'Main.vi'], 0, ViPathForm.absolute, r'C:\Users\me\Main.vi'),
      (['', 'Program Files', 'x.dll'], 0, ViPathForm.absolute, r'\Program Files\x.dll'),
      (['http', '//www.example.com/doc'], 0, ViPathForm.url, 'http://www.example.com/doc'),
      (['', 'Robot Global Data.vi'], 1, ViPathForm.relative, 'Robot Global Data.vi'),
      (['', '', 'Sub', 'x.vi'], 1, ViPathForm.relative, r'..\Sub\x.vi'),
      (['<Not A Path>'], 1, ViPathForm.notAPath, '<Not A Path>'),
      (['user32.dll'], 1, ViPathForm.name, 'user32.dll'),
      ([], 1, ViPathForm.empty, ''),
      (['server', 'share', 'x.vi'], 3, ViPathForm.unc, r'\\server\share\x.vi'),
    ];
    for (final (comps, type, form, text) in forms) {
      final path = ViPath(_pth0(comps, type: type));
      expect((path.form, path.text), (form, text), reason: comps.toString());
    }
    final up = ViPath(_pth0(['', '', 'Sub', 'x.vi'], type: 1));
    expect(up.upLevels, 1);
    expect(up.segments, ['Sub', 'x.vi']);
    expect(up.fileName, 'x.vi');
    expect(() => ViPath(_pth0(['a'], type: 7)), throwsA(isA<AssertionError>()), reason: 'unknown type');
    expect(isPth0(_pth0(['a'], type: 7)), isFalse, reason: 'the gate agrees with the constructor');
    final bare = ViPath(_pth0([]));
    expect((bare.form, bare.text), (ViPathForm.empty, ''));
    expect(p.serialize(), viewOf(body));
    expect(isPth0(u8(List.filled(16, 0x41))), isFalse, reason: 'no magic');
    expect(isPth0(Uint8List(8)), isFalse, reason: 'too short');
    final lying = _pth0(['a']);
    ByteData.sublistView(lying).setUint16(10, 9999);
    expect(isPth0(lying), isFalse, reason: 'count overruns the length');
    expect(() => ViPath(lying), throwsA(isA<AssertionError>()));
    expect(ViPath.extentAt(u8([0, 0, ...body, 9, 9]), 2), body.length, reason: 'extent inside a larger buffer');
  });

  test('decodeIdTable (NUID/SUID/BNID): [u32 count][count u32] tiling the payload', () {
    final body = _idtab([0x1234, 0, 0x7]);
    final t = ViIdTable(body);
    expect((t.count, t[0], t[1], t[2]), (3, 0x1234, 0, 0x7));
    expect(t.serialize(), viewOf(body));
    expect(ViIdTable(_idtab([])).count, 0);
    final lying = Uint8List(12);
    ByteData.sublistView(lying).setUint32(0, 9999);
    expect(() => ViIdTable(lying), throwsA(isA<AssertionError>()), reason: 'count must tile');
    expect(() => ViIdTable(u8([0, 1])), throwsA(isA<AssertionError>()));
  });

  test('decodeAlignTable (BFAL): [u32 count][count × 9B entry] tiling the payload', () {
    final body = u8([
      0, 0, 0, 2, // count = 2
      0, 0, 0, 0x41, 0, 0, 0, 9, 1, // offset 0x41, value 9, kind 1
      0, 0, 1, 0x18, 0, 0, 0, 0x10, 3, // offset 0x118, value 0x10, kind 3
    ]);
    final t = ViAlignTable(body);
    expect(t.count, 2);
    expect((t[0].offset, t[0].value, t[0].kind), (0x41, 9, 1));
    expect((t[1].offset, t[1].value, t[1].kind), (0x118, 0x10, 3));
    expect(t.serialize(), viewOf(body));
    expect(() => ViAlignTable(Uint8List(4 + 9)..[3] = 99), throwsA(isA<AssertionError>()));
    expect(() => ViAlignTable(u8([0, 1])), throwsA(isA<AssertionError>()));
  });

  test('tables with variable entries record where each entry starts', () {
    final ccst = u8([0, 0, 0, 2, 0, 0, 0, 1, 0x41, 0, 0, 0, 2, 0x42, 0x43, 0, 0, 0, 0, 0, 0, 0, 1, 0x44]);
    final symbols = ViConditionalSymbols(ccst);
    expect(symbols.names, ['A', 'BC']);
    expect(symbols.values, ['', 'D']);
    expect(symbols.symbols, {'A': '', 'BC': 'D'});
    expect(() => ViConditionalSymbols(u8([0, 0, 0, 1, 0, 0, 0, 9])), throwsA(isA<AssertionError>()));
    final cpst = u8([0, 0, 0, 2, ...pascal('On'), ...pascal('Off')]);
    final strings = ViPolymorphicNames(cpst);
    expect((strings.length, strings[0], strings[1]), (2, 'On', 'Off'));
    expect(() => ViPolymorphicNames(u8([0, 0, 0, 1, 5, 0x41])), throwsA(isA<AssertionError>()));
    final bkmk = u8([
      0, 0, 0, 1, 0, 0, 0, 7, 0, 0, 0, 9, 0, 0, 0, 2, 0x41, 0x42, // A: wordA 7, wordB 9, "AB"
      0, 0, 0, 1, 0, 0, 0, 5, 0, 0, 0, 1, 0x43, // B: wordB 5, "C"
    ]);
    final marks = ViBookmarkList(bkmk);
    expect((marks.tableA.length, marks.tableA[0].wordA, marks.tableA[0].wordB), (1, 7, 9));
    expect(marks.tableA[0].text, [0x41, 0x42]);
    expect((marks.tableB.length, marks.tableB[0].wordB), (1, 5));
    expect(marks.tableB[0].text, [0x43]);
    expect(ViBookmarkList(u8([0, 0, 0, 0, 0, 0, 0, 0])).isEmpty, isTrue);
    expect(() => ViBookmarkList(u8([0, 0, 0, 1, 0, 0, 0, 7])), throwsA(isA<AssertionError>()));
    final trec = u8([...List.filled(72, 0), 0, 0, 0, 2, 0x58, 0x59]);
    final record = ViTextRecord(trec);
    expect((record.runCount, record.header.length), (1, 72));
    expect(record.runAt(0), [0x58, 0x59]);
    expect(ViTextRecord(Uint8List(72)).runCount, 0);
    expect(() => ViTextRecord(Uint8List(70)), throwsA(isA<AssertionError>()));
    final ipsr = u8([0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 9]);
    expect(ViOffsetTable(ipsr)[2], 9);
    expect(() => ViOffsetTable(u8([0, 0, 0, 2, 0, 0, 0, 2])), throwsA(isA<AssertionError>()), reason: 'not rising');
    final gcdi = u8([0, 0, 0, 3, 1, 0xaa, 0xbb]);
    expect(ViGcdiRecord(gcdi).recordCount, 3);
    expect(ViGcdiRecord(gcdi).records, [1, 0xaa, 0xbb]);
    expect(() => ViGcdiRecord(u8([0, 0, 0, 3, 2])), throwsA(isA<AssertionError>()));
  });

  group('icons', () {
    const px = [255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 0];

    test('decodeDataSpaceImage: a 24-bit raster, its pixels, and the geometry checks', () {
      final raster = ViDataSpaceImage(_iconSection(px));
      expect(raster, isA<ViDataSpaceRaster>());
      expect((raster.width, raster.height, raster.depth), (2, 2, 24));
      expect((raster as ViDataSpaceRaster).pixels, px);
      expect(raster.serialize(), raster.serialize());
      expect(() => ViDataSpaceImage(_iconSection(px)..[31] = 9), throwsA(isA<AssertionError>()));
      expect(() => ViDataSpaceImage(_iconSection(px)..[0] = 1), throwsA(isA<AssertionError>()));
      expect(() => ViDataSpaceImage(Uint8List(10)), throwsA(isA<AssertionError>()));
      expect(
        ViDataSpaceImage(
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
      final mono = ViLegacyIcon.icon1(Uint8List(128)..[0] = 0xA0);
      expect([for (var x = 0; x < 8; x++) mono.pixelAt(x, 0)], [1, 0, 1, 0, 0, 0, 0, 0], reason: 'MSB-first bits');
      expect((mono.argbAt(0, 0), mono.argbAt(1, 0)), (0xFF000000, 0xFFFFFFFF));
      final nib = ViLegacyIcon.icl4(Uint8List(512)..[0] = 0x3C);
      expect((nib.pixelAt(0, 0), nib.pixelAt(1, 0)), (3, 12), reason: 'two nibbles per byte');
      expect(nib.argbAt(0, 0), 0xFFDD0806);
      final byte = ViLegacyIcon.icl8(Uint8List(1024)..[37] = 200);
      expect((byte.pixelAt(5, 1), byte.argbAt(5, 1), byte.argbAt(0, 0)), (200, 0xFF006699, 0xFFFFFFFF));
      expect(byte.serialize(), byte.serialize());
      expect(() => ViLegacyIcon.icon1(Uint8List(100)), throwsA(isA<AssertionError>()));
      expect(() => ViLegacyIcon.icl4(Uint8List(1024)), throwsA(isA<AssertionError>()));
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
    test('every layout tiles its fixed prefix and has a docs row per field', () {
      final layouts = <ByteLayout>{};
      void collect(ByteLayout layout) {
        if (!layouts.add(layout)) return;
        for (final field in layout.fields) {
          switch (field) {
            case Entries(:final entry) || Struct(:final entry):
              collect(entry);
            default:
          }
        }
      }

      for (final tag in BlockTag.values) {
        final layout = tag.layout;
        if (layout == null) {
          expect(blockFieldDocs[tag], isNull, reason: tag.tag);
          continue;
        }
        collect(layout);
        expect(blockFieldDocs[tag]!.length, layout.fields.length, reason: tag.tag);
        expect(BlockTag.of(tag.tag), tag);
        expect(tag.displayName, isNotEmpty, reason: tag.tag);
      }
      collect(ViPath.layout);
      for (final layout in layouts) {
        final shape = layout.fields.map((f) => f.typeName).join(' ');
        expect(layout.isContiguous, isTrue, reason: shape);
        expect(layout.optionalsTrail, isTrue, reason: shape);
      }
    });

    test('ByteLayout sizes', () {
      const fixed = ByteLayout([U32(0), U16(4), Bytes(6, size: 2)]);
      const open = ByteLayout([U32(0), U32List(4, count: U32(0))]);
      const tail = ByteLayout([U32(0), Unknown(4, size: 4), Bytes(8, size: 8, optional: true)]);
      expect((fixed.size, fixed.minSize, fixed.fits(8), fixed.fits(9)), (8, 8, true, false));
      expect((open.size, open.minSize, open.fits(4), open.fits(3)), (null, 4, true, false));
      expect((tail.size, tail.minSize, tail.fits(8), tail.fits(16)), (null, 8, true, true));
      expect((tail.unknownBytes(16), tail.unknownBytes(6), tail.unknownBytes(2)), (4, 2, 0));
      expect(const ByteLayout([U32(0), Bytes(4, size: 4, optional: true), U32(8)]).optionalsTrail, isFalse);
      expect(tail.optionalsTrail, isTrue);
      expect(const ByteLayout([U32(0), U32(8)]).isContiguous, isFalse);
      expect(const ByteLayout([U32(0), Bytes(4), U32(0)]).isContiguous, isTrue);
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
      'ViStringBlock': ViStringBlock.new,
      'ViPath': ViPath.new,
      'ViHistory': ViHistory.new,
      'ViFontTable': ViFontTable.new,
      'ViLibraryNames': ViLibraryNames.new,
      'ViDataTypeHeap': ViDataTypeHeap.new,
      'ViVersBlock': ViVersBlock.new,
      'ViSaveRecord': ViSaveRecord.new,
      'ViTypeMap': ViTypeMap.new,
      'ViConnectorPane': ViConnectorPane.new,
      'ViIdTable': ViIdTable.new,
      'ViAlignTable': ViAlignTable.new,
      'ViDataSpaceImage': ViDataSpaceImage.new,
      'ViLegacyIcon.icl8': ViLegacyIcon.icl8,
      'ViLegacyIcon.icl4': ViLegacyIcon.icl4,
      'ViLegacyIcon.icon1': ViLegacyIcon.icon1,
      'ViPngStream': ViPngStream.new,
      'ViPictPicture': ViPictPicture.new,
      'ViEmfMetafile': ViEmfMetafile.new,
      'ViConnectorPaneMap': ViConnectorPaneMap.new,
      'ViOffsetTable': ViOffsetTable.new,
      'ViGcdiRecord': ViGcdiRecord.new,
      'ViBookmarkList': ViBookmarkList.new,
      'ViTagStore': ViTagStore.new,
      'ViCompiledCode': ViCompiledCode.new,
      'ViLinkInfo': ViLinkInfo.new,
      'ViPasswordRecord': ViPasswordRecord.new,
      'ViSignature': ViSignature.new,
      'ViSourceSignature': ViSourceSignature.new,
      'ViPiccRecord': ViPiccRecord.new,
      'ViPrintRecord': ViPrintRecord.new,
      'ViSectionEntry': ViSectionEntry.new,
      'ViMaxUid': ViMaxUid.new,
      'ViLinkEntryWords': ViLinkEntryWords.new,
      'ViUidValueTable': ViUidValueTable.new,
      'ViConstantRecord.gcpr': ViConstantRecord.gcpr,
      'ViConstantRecord.vpdp': ViConstantRecord.vpdp,
      'ViDldrRecord': ViDldrRecord.new,
      'ViNodeUidSet': ViNodeUidSet.new,
      'ViCoutRecord': ViCoutRecord.new,
      'ViFrontPanelType': ViFrontPanelType.new,
      'ViConnectorPaneData': ViConnectorPaneData.new,
      'ViTitle': ViTitle.new,
      'ViTextRecord': ViTextRecord.new,
      'ViVersionWord.at': (bytes) => ViVersionWord.at(ByteData.sublistView(bytes), 0),
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
      expect(ViLegacyIcon.icl8(icl8).serialize(), viewOf(icl8));
      final icl4 = Uint8List.fromList([for (var i = 0; i < 512; i++) (i * 13) & 0xff]);
      expect(ViLegacyIcon.icl4(icl4).serialize(), viewOf(icl4));
      final icon = Uint8List.fromList([for (var i = 0; i < 128; i++) (i * 29) & 0xff]);
      expect(ViLegacyIcon.icon1(icon).serialize(), viewOf(icon));
    });

    test('ViIdTable.serialize returns the backing [u32 count][entries] bytes', () {
      final body = _idtab([1, 2, 0xDEADBEEF, 0]);
      expect(ViIdTable(body).serialize(), viewOf(body));
      final empty = _idtab([]);
      expect(ViIdTable(empty).serialize(), viewOf(empty));
    });

    test('fixed records are views: serialize returns the backing bytes', () {
      for (final len in [160, 137, 136, 144, 120, 96, 116]) {
        final body = _lvsr(len);
        expect(ViSaveRecord(body).serialize(), viewOf(body), reason: 'len $len');
      }
      final dldr = u8([0, 0, 0, 1, ...List.filled(24, 0)]);
      expect(ViDldrRecord(dldr)[0], 1);
      expect(ViDldrRecord(dldr).serialize(), viewOf(dldr));
      expect(() => ViDldrRecord(u8([0, 0, 0, 1])), throwsA(isA<AssertionError>()), reason: 'not seven words');
      final grid = u8([0, 0, 3, 0xae, 0, 0, 3, 0xc4, 0, 0, 5, 9]);
      final words = ViNodeUidSet(grid);
      expect((words.length, words[0], words[2]), (3, 0x3ae, 0x509));
      expect(() => ViNodeUidSet(u8([1, 2, 3])), throwsA(isA<AssertionError>()));
      expect(ViNodeUidSet(u8([])).length, 0);
      expect(ViConstantRecord.vpdp(u8([0, 0, 0, 0])).isZero, isTrue);
      expect(ViConstantRecord.vpdp(u8([0, 0, 0, 1])).isZero, isFalse);
      final picc = u8([0, 0x92, 0x09, 0x02, 0, 0x2a, 0, 0x47, 0, 0xaa, 0xff, 0xa6]);
      final placement = ViPiccRecord(picc);
      expect((placement.top, placement.left, placement.bottom, placement.right), (0x2a, 0x47, 0xaa, -90));
      final fpse = u8([0, 0, 0, 5]);
      expect((ViSectionEntry(fpse).value, ViSectionEntry(fpse).extra), (5, null));
      expect(ViSectionEntry(u8([0, 0, 0, 5, 0, 0, 0, 7])).extra, 7);
      final bdpw = Uint8List.fromList([for (var i = 0; i < 48; i++) i]);
      final pw = ViPasswordRecord(bdpw);
      expect((pw.passwordDigest.length, pw.digest2[0], pw.digest3![0], pw.isUnprotected), (16, 16, 32, false));
      expect(ViPasswordRecord(Uint8List.sublistView(bdpw, 0, 32)).digest3, isNull);
      expect(ViPasswordRecord(u8([...emptyPasswordDigest, ...emptyPasswordDigest])).isUnprotected, isTrue);
      final scsr = Uint8List.fromList([9, 0, 0, 0, for (var i = 0; i < 16; i++) i]);
      expect((ViSourceSignature(scsr).version, ViSourceSignature(scsr).digest.length), (9, 16));
      final titl = u8([3, 0xff, 0x00, 0x41]);
      expect(ViTitle(titl).serialize(), viewOf(titl));
      expect(ViTitle(u8([2, 0x48, 0x69])).text, 'Hi');
      expect(() => ViTitle(u8([5, 1, 2])), throwsA(isA<AssertionError>()), reason: 'length overruns');
      final sig = Uint8List.fromList([for (var i = 0; i < 16; i++) (i * 11) & 0xff]);
      expect(serializeBlockPayload('OBSG', sig), sig);
      expect(serializeBlockPayload('CCSG', sig), sig);
      expect(() => serializeBlockPayload('OBSG', u8([1, 2, 3])), throwsA(isA<AssertionError>()));
      final cout = u8([0, 0, 0, 1, 0xe2, 0x4d, 0x4e, 0x32, 0xb4, 0x55, 0xad, 0xf7]);
      expect(serializeBlockPayload('COUT', cout), cout);
      expect(() => serializeBlockPayload('COUT', u8([0, 0, 0, 1])), throwsA(isA<AssertionError>()));
      expect(ViConnectorPaneData(u8([0, 7])).typeIndex, 7);
      expect(() => ViConnectorPaneData(u8([0, 7, 0])), throwsA(isA<AssertionError>()));
    });

    test('serializeBlockPayload: model-sources covered tags, null otherwise', () {
      final icl8 = Uint8List.fromList([for (var i = 0; i < 1024; i++) (i * 3) & 0xff]);
      expect(serializeBlockPayload('icl8', icl8), icl8);
      final nuid = _idtab([7, 8, 9]);
      expect(serializeBlockPayload('NUID', nuid), nuid);
      final suid = _idtab([0, 0, 7, 8]);
      expect(serializeBlockPayload('SUID', suid), suid);
      expect(() => serializeBlockPayload('BNID', _idtab([1, 2, 3])), throwsA(isA<AssertionError>()));
      expect(hasBlockWriter('BNID'), isTrue);
      expect(hasBlockWriter('LVSR'), isTrue);
      final lvsr = _lvsr(96);
      expect(serializeBlockPayload('LVSR', lvsr), lvsr);
      expect(() => serializeBlockPayload('LVSR', _lvsr(95)), throwsA(isA<AssertionError>()));
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
      expect(hasBlockWriter('MNGI'), isTrue);
      expect(() => serializeBlockPayload('icl8', u8([1, 2, 3])), throwsA(isA<AssertionError>()));
      expect(
        () => serializeBlockPayload('NUID', u8([0, 0, 0, 1, 0, 0, 0, 5, 0xFF, 0xFF])),
        throwsA(isA<AssertionError>()),
      );
    });
  });
}
