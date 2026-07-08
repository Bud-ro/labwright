import 'dart:convert';
import 'dart:typed_data';

import 'package:labwright_seq/labwright_seq.dart';
import 'package:test/test.dart';

Uint8List _b(List<int> xs) => Uint8List.fromList(xs);

/// `TOF1` magic + 6 reserved bytes + a NUL-terminated file-type token at 0x0A.
Uint8List _binary(String fileType) =>
    _b([...ascii.encode('TOF1'), 0, 0, 0, 0, 0, 0, ...ascii.encode(fileType), 0, ...List.filled(32, 0)]);

Uint8List _xml({
  String type = 'SequenceFile',
  String version = '920',
  bool bom = true,
  String pre = '',
  String attrs = '',
}) => _b([
  if (bom) ...[0xef, 0xbb, 0xbf],
  ...utf8.encode(
    '$pre<?xml version="1.0" encoding="UTF-8"?>\n'
    "<teststandfileheader $attrs type='$type' fileversion='$version' productname='TestStand'>",
  ),
]);

void main() {
  test('detectSeqFormat classifies every header shape, total over hostile input', () {
    final cases = <(String, Uint8List, SeqFormat)>[
      ('xml with BOM', _xml(), SeqFormat.xml),
      ('xml without BOM', _xml(bom: false), SeqFormat.xml),
      ('xml after leading whitespace', _xml(bom: false, pre: ' \t\n'), SeqFormat.xml),
      (
        'teststandfileheader without an xml decl',
        _b(ascii.encode("<teststandfileheader type='SequenceFile'>")),
        SeqFormat.xml,
      ),
      ('binary TOF1', _binary('SequenceFile'), SeqFormat.binary),
      ('bare TOF1 magic', _b(ascii.encode('TOF1')), SeqFormat.binary),
      ('truncated TOF magic', _b(ascii.encode('TOF')), SeqFormat.unknown),
      ('ini with a TestStand marker', _b(ascii.encode('[TestStandStructuredFile]\nVersion=3.5\n')), SeqFormat.ini),
      ('ini marker is case-insensitive', _b(ascii.encode('[teststand file]\n')), SeqFormat.ini),
      ('plain ini without the marker', _b(ascii.encode('[General]\nname=other\n')), SeqFormat.unknown),
      ('empty', _b([]), SeqFormat.unknown),
      ('arbitrary bytes', _b([0x00, 0x01, 0x02, 0xff]), SeqFormat.unknown),
      ('non-teststand html', _b(ascii.encode('<html>not teststand')), SeqFormat.unknown),
      ('non-teststand xml', _b(ascii.encode('<note><to>x</to></note>')), SeqFormat.unknown),
    ];
    for (final (name, bytes, want) in cases) {
      expect(detectSeqFormat(bytes), want, reason: name);
    }
  });

  test('SeqFormat.isText is true exactly for the text encodings', () {
    expect(
      {for (final f in SeqFormat.values) f: f.isText},
      {
        SeqFormat.xml: true,
        SeqFormat.ini: true,
        SeqFormat.binary: false,
        SeqFormat.unknown: false,
      },
    );
  });

  group('detectSeqHeader', () {
    test('XML header attributes', () {
      final h = detectSeqHeader(_xml(version: '962'));
      expect((h.format, h.fileType, h.fileVersion, h.productName), (SeqFormat.xml, 'SequenceFile', '962', 'TestStand'));
    });

    test('binary file-type token at 0x0A; fileversion not yet located, not fabricated', () {
      final h = detectSeqHeader(_binary('SequenceFile'));
      expect((h.format, h.fileType, h.fileVersion), (SeqFormat.binary, 'SequenceFile', null));
      expect(detectSeqHeader(_binary('TypePaletteFile')).fileType, 'TypePaletteFile');
    });

    test('binary productName from the 0x40 slot', () {
      final b = Uint8List(0x60);
      b.setAll(0, ascii.encode('TOF1'));
      b.setAll(0x0a, ascii.encode('SequenceFile'));
      b.setAll(0x40, ascii.encode('TestStand'));
      final h = detectSeqHeader(b);
      expect((h.fileType, h.productName), ('SequenceFile', 'TestStand'));
    });

    test('type= is not confused by an attribute merely ending in it (xsi:type=)', () {
      final h = detectSeqHeader(_xml(bom: false, attrs: "xsi:type='Wrong'"));
      expect((h.fileType, h.fileVersion, h.productName), ('SequenceFile', '920', 'TestStand'));
    });

    test('unknown input yields an unknown header, no throw', () {
      expect(detectSeqHeader(_b([1, 2, 3])).format, SeqFormat.unknown);
    });
  });

  test('binaryStrings extracts printable runs with offsets, incl. Latin-1 high bytes', () {
    final b = _b([
      0x00,
      ...ascii.encode('Hello'),
      0x00,
      0x01,
      ...ascii.encode('World'),
      0x00,
      ...latin1.encode('Aktif_Güç'),
      0x00,
      ...ascii.encode('left'),
      0x85,
      ...ascii.encode('right'),
    ]);
    final runs = binaryStrings(b);
    expect(runs.map((r) => r.text), ['Hello', 'World', 'Aktif_Güç', 'left', 'right']);
    expect(runs.first.offset, 1);
    expect(binaryStrings(Uint8List(0)), isEmpty);
  });
}
