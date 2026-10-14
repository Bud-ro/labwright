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
