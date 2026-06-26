import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_teststand/labwright_teststand.dart';
import 'package:test/test.dart';

Uint8List _xml() => Uint8List.fromList([
      0xef, 0xbb, 0xbf,
      ...utf8.encode("<?xml version='1.0'?>\n"
          "<teststandfileheader type='SequenceFile' fileversion='920' productname='TestStand'>"
          "<typelist/><Data classname='Obj'><subprops>"
          "<Seq classname='Objs'><value lbound='[0]' ubound='[1]'><value>"
          "<Sequence name='MainSequence' classname='Obj'><subprops>"
          "<Main classname='Objs'><value lbound='[0]' ubound='[1]'>"
          "<value><Step typename='Statement' name='S1'/></value></value></Main>"
          "</subprops></Sequence></value></value></Seq></subprops></Data>"
          "</teststandfileheader>"),
    ]);

Uint8List _binary() {
  final pool = <int>[];
  for (final n in ['PaddingNameSoTheInflatedBodyExceedsTheSixtyFourByteGuardHere',
      'SequenceFileData', 'MainSequence', 'Step', 'Locals', 'Parameters']) {
    pool..addAll(ascii.encode(n))..add(0);
  }
  // Lay out a fixed 0x108-byte header so 'TestStand' lands at the 0x40 slot.
  final header = Uint8List(0x108);
  header.setAll(0, ascii.encode('TOF1'));
  header.setAll(0x0a, ascii.encode('SequenceFile'));
  header.setAll(0x40, ascii.encode('TestStand'));
  final b = BytesBuilder()
    ..add(header)
    ..add(zlib.encode(pool));
  return Uint8List.fromList(b.toBytes());
}

void main() {
  test('parse → XmlSeqDocument for XML', () {
    final doc = SeqDocument.parse(_xml());
    expect(doc, isA<XmlSeqDocument>());
    expect(doc.header.format, SeqFormat.xml);
    final x = doc as XmlSeqDocument;
    expect(x.file.sequences.single.name, 'MainSequence');
  });

  test('parse → BinarySeqDocument for TOF1 (recon)', () {
    final doc = SeqDocument.parse(_binary());
    expect(doc, isA<BinarySeqDocument>());
    expect(doc.header.format, SeqFormat.binary);
    expect(doc.header.productName, 'TestStand');
    final bin = doc as BinarySeqDocument;
    expect(bin.inflatedSize, greaterThan(0));
    expect(bin.strings.map((s) => s.text), contains('MainSequence'));
  });

  test('parse → UnknownSeqDocument for arbitrary bytes (no throw)', () {
    final doc = SeqDocument.parse(Uint8List.fromList([1, 2, 3, 4]));
    expect(doc, isA<UnknownSeqDocument>());
    expect(doc.header.format, SeqFormat.unknown);
  });
}
