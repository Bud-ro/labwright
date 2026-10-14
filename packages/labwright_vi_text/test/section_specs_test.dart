import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_text/labwright_vi_text.dart';
import 'package:test/test.dart';

Uint8List _b(List<int> bytes) => Uint8List.fromList(bytes);

const _variant = [
  0x21,
  0x00,
  0x80,
  0x00,
  0,
  0,
  0,
  1,
  0,
  4,
  0,
  0x21,
  0,
  1,
  0,
  0,
  1,
  0,
  0,
  0,
  0, //
];

List<SectionSpec> _readBack(List<SectionSpec> sections) =>
    viSpecOf(ViSpec('t.vi', sections).encode()).sections;

String _text(List<SectionSpec> sections) =>
    emitViSpecDart(ViSpec('t.vi', sections), identifier: 't');

final _vers12 = _b([0x12, 0, 0x80, 0, 0, 0, 4, ...'12.0'.codeUnits, 0]);

Uint8List _saveRecord(int length) {
  final bytes = _b([for (var i = 0; i < length; i++) i * 31 & 0xff]);
  ByteData.sublistView(bytes)
    ..setUint16(32, ViPriority.normal.code)
    ..setUint16(34, ViKind.standard.code)
    ..setInt32(36, ViExecutionSystem.sameAsCaller.code)
    ..setUint16(78, ViControlStyle.nxg.code);
  return bytes;
}

void main() {
  final decoded = <String, List<(String, Uint8List)>>{
    'IconSection': [
      ('icl8', _b([for (var i = 0; i < 1024; i++) i * 7 & 0xff])),
      ('icl4', _b([for (var i = 0; i < 512; i++) i * 13 & 0xff])),
      ('ICON', _b([for (var i = 0; i < 128; i++) i * 29 & 0xff])),
    ],
    'SaveRecordSection': [
      for (final length in [96, 120, 137, 160]) ('LVSR', _saveRecord(length)),
    ],
    'PasswordSection': [
      ('BDPW', _b([for (var i = 0; i < 48; i++) i])),
      ('BDPW', _b([for (var i = 0; i < 32; i++) 255 - i])),
    ],
    'SignatureSection': [
      for (final tag in ['RTSG', 'OBSG', 'CCSG'])
        (tag, _b([for (var i = 0; i < 16; i++) i * 17 & 0xff])),
    ],
    'LinkInfoSection': [
      ('LIvi', _b([0, 1, ...'LVIN'.codeUnits, 0, 0, 0, 0, 0, 3])),
      (
        'LIbd',
        _b([
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
          9,
          0,
          3,
        ]),
      ),
    ],
    'VersionSection': [
      ('vers', _vers12),
      (
        'vers',
        _b([0x21, 0, 0x80, 4, 0, 14, 4, ...'21.0'.codeUnits, 2, 0x61, 0x62]),
      ),
    ],
    'ConnectorPaneSection': [
      ('CONP', _b([0, 1])),
      ('CPC2', _b([0, 2])),
    ],
    'MaxUidSection': [
      ('MUID', _b([0, 0, 0x0d, 0xfb])),
    ],
    'SectionEntrySection': [
      ('FPSE', _b([0, 0, 0, 0x61])),
      ('BDSE', _b([0, 0, 3, 0xdd, 0, 0, 0, 7])),
    ],
    'LinkEntryWordsSection': [
      ('FPEx', _b([0, 0, 0, 0])),
      ('BDEx', _b([0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 9])),
    ],
    'DataTypeHeapSection': [
      ('DTHP', _b([0, 0x73, 0, 3])),
    ],
    'DataTypeHeapWordSection': [
      ('DTHP', _b([0, 5])),
    ],
    'FontTableSection': [
      (
        'FTAB',
        _b([
          0, 1, 0, 2, 0, 3, 0, 2, //
          0, 0, 0, 40, 0, 15, 4, 0, 0, 0, 0, 15, 0, 217, 0, 212,
          0, 0, 0, 42, 0x80, 0, 0x84, 0, 0x80, 0, 0, 15, 0x7f, 0xff, 0, 1,
          1, 0x30, 8, ...'Segoe UI'.codeUnits,
        ]),
      ),
    ],
    'TagStoreSection': [
      (
        'VITS',
        _b([
          0, 0, 0, 3, //
          0, 0, 0, 1, 0x61, 0, 0, 0, _variant.length, ..._variant,
          0, 0, 0, 1, 0x62, ..._variant,
          0, 0, 0, 1, 0x63, 0, 0, 0, 8, 0, 0, 0, 0,
        ]),
      ),
    ],
  };
  for (final MapEntry(key: type, value: sections) in decoded.entries) {
    test('$type: decoded sections build their own bytes', () {
      for (final (tag, bytes) in sections) {
        final read = _readBack([RawSection(tag, bytes)]).single;
        expect(read.runtimeType.toString(), type);
        expect(read.payload, bytes);
      }
    });
  }

  final built = <String, List<SectionSpec>>{
    'IconSection': [
      IconSection(
        depth: LegacyIconDepth.mono,
        rows: [for (var y = 0; y < 32; y++) '#.' * 16],
      ),
      IconSection(
        depth: LegacyIconDepth.fourBit,
        rows: [for (var y = 0; y < 32; y++) '0123456789abcdef' * 2],
      ),
      IconSection(
        depth: LegacyIconDepth.eightBit,
        rows: [for (var y = 0; y < 32; y++) 'ff00' * 16],
      ),
    ],
    'SaveRecordSection': [
      SaveRecordSection(
        versionWord: 0x21008000,
        statusFlags: ViStatusFlag.reentrant.mask,
        optionFlags: 0,
        flags12: 0,
        unknown16: 3,
        windowFlags: ViWindowFlag.canClose.mask,
        hiddenButtons: 0,
        frontPanelFlags: ViFrontPanelFlag.titleBar.mask,
        stateFlags: ViStateFlag.debugCapable.mask,
        unknown28: 1,
        priority: ViPriority.normal,
        viType: ViKind.standard,
        executionSystem: ViExecutionSystem.sameAsCaller,
        unknown40: Uint8List(12),
        unknown52: Uint8List(16),
        frontPanelGrid: 12,
        blockDiagramGrid: 16,
        unknown76: 0,
        controlStyle: ViControlStyle.modern,
        unknown80: Uint8List(16),
        unknown96: Uint8List(16),
        unknown112: 0x1000,
        unknown116: -2,
        unknown120: Uint8List(16),
      ),
    ],
    'PasswordSection': [
      PasswordSection(
        passwordDigest: _b(emptyPasswordDigest),
        digest2: Uint8List(16),
      ),
    ],
    'SignatureSection': [
      SignatureSection(tag: 'RTSG', digest: Uint8List(16)),
      SignatureSection(tag: 'CCSG', digest: _b(emptyPasswordDigest)),
    ],
    'LinkInfoSection': [
      LinkInfoSection(
        tag: 'LIvi',
        rootKind: 'LVIN',
        entryCount: 1,
        entries: const [],
        unwalked: _b([0, 2, ...'IUVI'.codeUnits, 1, 2, 3]),
      ),
    ],
    'LinkInfoSection, library form': [
      VersionSection(versionWord: 0x12008000, versionText: '12.0'),
      LinkInfoSection(
        tag: 'LIvi',
        rootKind: 'LVIN',
        qualifiedName: 'Lib.lvlib:Some.vi',
        words: const [1, 2],
        entries: const [],
      ),
    ],
    'ConnectorPaneSection': [
      ConnectorPaneSection(tag: 'CONP', typeIndex: 1),
      ConnectorPaneSection(tag: 'CPC2', typeIndex: 2),
    ],
    'MaxUidSection': [MaxUidSection(maxUid: 3579)],
    'SectionEntrySection': [
      SectionEntrySection(tag: 'FPSE', value: 97),
      SectionEntrySection(tag: 'BDSE', value: 989, extra: 0),
    ],
    'LinkEntryWordsSection': [
      LinkEntryWordsSection(tag: 'BDEx', words: const [0, 0, 0]),
    ],
    'DataTypeHeapSection': [
      DataTypeHeapSection(heapTypeCount: 115, firstTopLevelIndex: 3),
    ],
    'DataTypeHeapWordSection': [DataTypeHeapWordSection(word: 5)],
    'FontTableSection': [
      FontTableSection(
        platform: 1,
        fonts: const [
          FontSpec(
            name: 'Lucida Grande',
            size: 13,
            flagsByte: 4,
            styleFlags: 0,
            weight: 1000,
            resolvedSize: 13,
            metricA: 180,
            metricB: 170,
          ),
        ],
      ),
    ],
    'TagStoreSection': [
      TagStoreSection(
        tags: [
          TagSpec(name: 'NI.LV.All.SourceOnly', value: _b(_variant)),
          TagSpec(
            name: 'bare',
            value: _b(_variant),
            framing: ViTagValueFraming.bare,
          ),
        ],
      ),
    ],
  };
  for (final MapEntry(key: type, value: sections) in built.entries) {
    test('$type: built sections read back to the same constructors', () {
      expect(_text(_readBack(sections)), _text(sections));
    });
  }
}
