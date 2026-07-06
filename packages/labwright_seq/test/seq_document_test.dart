import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_seq/labwright_seq.dart';
import 'package:test/test.dart';

Uint8List _xml() => Uint8List.fromList([
  0xef,
  0xbb,
  0xbf,
  ...utf8.encode(
    "<?xml version='1.0'?>\n"
    "<teststandfileheader type='SequenceFile' fileversion='920' productname='TestStand'>"
    "<typelist/><Data classname='Obj'><subprops>"
    "<Seq classname='Objs'><value lbound='[0]' ubound='[1]'><value>"
    "<Sequence name='MainSequence' classname='Obj'><subprops>"
    "<Main classname='Objs'><value lbound='[0]' ubound='[1]'>"
    "<value><Step typename='Statement' name='S1'/></value></value></Main>"
    "</subprops></Sequence></value></value></Seq></subprops></Data>"
    "</teststandfileheader>",
  ),
]);

Uint8List _binary() {
  final pool = <int>[];
  for (final n in [
    'PaddingNameSoTheInflatedBodyExceedsTheSixtyFourByteGuardHere',
    'SequenceFileData',
    'MainSequence',
    'Step',
    'Locals',
    'Parameters',
  ]) {
    pool
      ..addAll(ascii.encode(n))
      ..add(0);
  }
  final header = Uint8List(0x108);
  header.setAll(0, ascii.encode('TOF1'));
  header.setAll(0x0a, ascii.encode('SequenceFile'));
  header.setAll(0x40, ascii.encode('TestStand'));
  final b = BytesBuilder()
    ..add(header)
    ..add(zlib.encode(pool));
  return b.toBytes();
}

Uint8List _ini() => ascii.encode(
  [
    '[__Header__]',
    'ProductName = "TestStand"',
    'Version = 354',
    'Type = "SequenceFile"',
    '',
    '[DEF, %OBJROOT]',
    'SF = SequenceFileData',
    '[DEF, SF]',
    'Seq = Objs',
    '%NAME = "Data"',
    '[DEF, SF.Seq]',
    '%[0] = Sequence',
    '[DEF, SF.Seq[0]]',
    'Main = Objs',
    '%NAME = "MainSequence"',
    '[DEF, SF.Seq[0].Main]',
    '%[0] = Step',
    '%TYPE: %[0] = "Action"',
    '[DEF, SF.Seq[0].Main[0]]',
    '%NAME = "myStep"',
    '',
  ].join('\n'),
);

void main() {
  test('parse → XmlSeqDocument for XML', () {
    final doc = SeqDocument.parse(_xml());
    expect(doc, isA<XmlSeqDocument>());
    expect(doc, isA<StructuredSeqDocument>());
    expect(doc.header.format, SeqFormat.xml);
    final x = doc as XmlSeqDocument;
    expect(x.file.sequences.single.name, 'MainSequence');
  });

  test('parse → IniSeqDocument for legacy INI (typed model)', () {
    final doc = SeqDocument.parse(_ini());
    expect(doc, isA<IniSeqDocument>());
    expect(doc, isA<StructuredSeqDocument>());
    expect(doc.header.format, SeqFormat.ini);
    final ini = doc as IniSeqDocument;
    final seq = ini.file.sequences.single;
    expect(seq.name, 'MainSequence');
    expect(seq.main.single.name, 'myStep');
    expect(seq.main.single.type, 'Action');
  });

  test('parse → BinarySeqDocument for TOF1 (recon)', () {
    final doc = SeqDocument.parse(_binary());
    expect(doc, isA<BinarySeqDocument>());
    expect(doc.header.format, SeqFormat.binary);
    expect(doc.header.productName, 'TestStand');
    final bin = doc as BinarySeqDocument;
    expect(bin.inflatedSize, greaterThan(0));
    expect(bin.strings.map((s) => s.text), contains('MainSequence'));
    expect(bin.layout, isNotNull);
    expect(bin.layout!.stringCount, greaterThanOrEqualTo(5));
  });

  test('parse → UnknownSeqDocument for arbitrary bytes (no throw)', () {
    final doc = SeqDocument.parse(Uint8List.fromList([1, 2, 3, 4]));
    expect(doc, isA<UnknownSeqDocument>());
    expect(doc.header.format, SeqFormat.unknown);
  });
}
