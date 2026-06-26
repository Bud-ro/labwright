import 'dart:convert';
import 'dart:typed_data';

import 'package:labwright_teststand/labwright_teststand.dart';
import 'package:test/test.dart';

Uint8List _bytes(List<int> xs) => Uint8List.fromList(xs);

/// `TOF1` magic + 6 reserved bytes + a NUL-terminated file-type token at 0x0A.
Uint8List _binary(String fileType) => _bytes([
      ...ascii.encode('TOF1'),
      0, 0, 0, 0, 0, 0,
      ...ascii.encode(fileType), 0,
      ...List.filled(32, 0),
    ]);

Uint8List _xml({String type = 'SequenceFile', String version = '920', bool bom = true}) {
  final text = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
      "<teststandfileheader type='$type' fileversion='$version' productname='TestStand'>";
  return _bytes([if (bom) ...[0xef, 0xbb, 0xbf], ...utf8.encode(text)]);
}

void main() {
  group('detectSeqFormat', () {
    test('XML sequence with UTF-8 BOM', () {
      expect(detectSeqFormat(_xml()), SeqFormat.xml);
    });

    test('XML without a BOM', () {
      expect(detectSeqFormat(_xml(bom: false)), SeqFormat.xml);
    });

    test('binary TOF1 container', () {
      expect(detectSeqFormat(_binary('SequenceFile')), SeqFormat.binary);
    });

    test('legacy INI is recognized only with a TestStand marker', () {
      final ts = _bytes(ascii.encode('[TestStandStructuredFile]\nVersion=3.5\n'));
      expect(detectSeqFormat(ts), SeqFormat.ini);
      // A plain INI without any TestStand marker must NOT be claimed as a .seq.
      final plain = _bytes(ascii.encode('[General]\nname=other\n'));
      expect(detectSeqFormat(plain), SeqFormat.unknown);
    });

    test('arbitrary / empty bytes are unknown, never throwing (totality)', () {
      expect(detectSeqFormat(_bytes([])), SeqFormat.unknown);
      expect(detectSeqFormat(_bytes([0x00, 0x01, 0x02, 0xff])), SeqFormat.unknown);
      expect(detectSeqFormat(_bytes(ascii.encode('<html>not teststand'))), SeqFormat.unknown);
    });

    test('arbitrary XML that is not a TestStand file is unknown', () {
      expect(detectSeqFormat(_bytes(ascii.encode('<note><to>x</to></note>'))), SeqFormat.unknown);
    });
  });

  group('detectSeqHeader', () {
    test('XML header attributes', () {
      final h = detectSeqHeader(_xml(version: '962'));
      expect(h.format, SeqFormat.xml);
      expect(h.fileType, 'SequenceFile');
      expect(h.fileVersion, '962');
      expect(h.productName, 'TestStand');
    });

    test('binary header file-type token at 0x0A', () {
      final h = detectSeqHeader(_binary('SequenceFile'));
      expect(h.format, SeqFormat.binary);
      expect(h.fileType, 'SequenceFile');
      // Numeric fileversion not yet located in the binary container — not fabricated.
      expect(h.fileVersion, isNull);
    });

    test('binary header productName from the 0x40 slot', () {
      final b = Uint8List(0x60);
      b.setAll(0, ascii.encode('TOF1'));
      b.setAll(0x0a, ascii.encode('SequenceFile'));
      b.setAll(0x40, ascii.encode('TestStand'));
      final h = detectSeqHeader(b);
      expect(h.fileType, 'SequenceFile');
      expect(h.productName, 'TestStand');
    });
  });

  group('binaryStrings', () {
    test('extracts printable runs with offsets, incl. Latin-1 high bytes', () {
      final b = Uint8List.fromList([
        0x00, ...ascii.encode('Hello'), 0x00, 0x01, ...ascii.encode('World'), 0x00,
        // Latin-1 letters (0xa0..0xff) stay inside the run (ü, ç)...
        ...latin1.encode('Aktif_Güç'), 0x00,
        // ...but a C1-gap byte (0x7f..0x9f) still separates runs.
        ...ascii.encode('left'), 0x85, ...ascii.encode('right'),
      ]);
      final runs = binaryStrings(b);
      expect(runs.map((r) => r.text),
          ['Hello', 'World', 'Aktif_Güç', 'left', 'right']);
      expect(runs.first.offset, 1);
      expect(binaryStrings(Uint8List(0)), isEmpty); // no throw on empty
    });

    test('type-palette file kind via binary token', () {
      expect(detectSeqHeader(_binary('TypePaletteFile')).fileType, 'TypePaletteFile');
    });

    test('unknown input yields an unknown header, no throw', () {
      expect(detectSeqHeader(_bytes([1, 2, 3])).format, SeqFormat.unknown);
    });
  });

  test('SeqFormat.isText', () {
    expect(SeqFormat.xml.isText, isTrue);
    expect(SeqFormat.ini.isText, isTrue);
    expect(SeqFormat.binary.isText, isFalse);
    expect(SeqFormat.unknown.isText, isFalse);
  });
}
