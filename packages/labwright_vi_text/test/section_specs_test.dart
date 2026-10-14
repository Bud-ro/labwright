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

void main() {
  final decoded = <String, List<(String, Uint8List)>>{
    'IconSection': [
      ('icl8', _b([for (var i = 0; i < 1024; i++) i * 7 & 0xff])),
      ('icl4', _b([for (var i = 0; i < 512; i++) i * 13 & 0xff])),
      ('ICON', _b([for (var i = 0; i < 128; i++) i * 29 & 0xff])),
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
      final read = _readBack([
        for (final (tag, bytes) in sections) RawSection(tag, bytes),
      ]);
      expect(read.map((s) => s.runtimeType.toString()).toSet(), {type});
      expect(read.map((s) => s.payload), sections.map((s) => s.$2));
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
