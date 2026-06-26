import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_teststand/labwright_teststand.dart';
import 'package:labwright_teststand_inspector/src/document_view.dart';
import 'package:labwright_teststand_inspector/src/property_outline.dart';
import 'package:labwright_teststand_inspector/src/sequence_outline.dart';

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
  for (final n in [
    'PaddingNameSoTheInflatedBodyExceedsTheSixtyFourByteGuardHere',
    'SequenceFileData', 'MainSequence', 'Step', 'Locals', 'Parameters'
  ]) {
    pool..addAll(ascii.encode(n))..add(0);
  }
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
  test('documentText/Title render an XML document', () {
    final doc = SeqDocument.parse(_xml());
    expect(doc, isA<XmlSeqDocument>());
    expect(documentTitle(doc), contains('1 sequences'));
    expect(documentTitle(doc), contains('xml'));
    final text = documentText(doc);
    expect(text, contains('MainSequence'));
    expect(text, contains('S1'));
  });

  test('SeqOutline.of shapes sequences → groups → steps', () {
    final doc = SeqDocument.parse(_xml()) as XmlSeqDocument;
    final outline = SeqOutline.of(doc.file);

    expect(outline.sequences, hasLength(1));
    expect(outline.indexOf('MainSequence'), 0);
    expect(outline.indexOf('NoSuchSequence'), isNull);

    final seq = outline.sequences.single;
    expect(seq.name, 'MainSequence');
    expect(seq.stepCount, 1);
    expect(seq.groups.map((g) => g.name), ['Main']);

    final step = seq.groups.single.steps.single;
    expect(step.name, 'S1');
    expect(step.type, 'Statement');
    expect(step.isInFileCall, isFalse);
    expect(step.summary, contains('S1 [Statement]'));
  });

  test('propertyTree shapes the raw PropertyObject tree', () {
    final doc = SeqDocument.parse(_xml()) as XmlSeqDocument;
    final root = propertyTree(doc.file);

    // Root is the Data object; class Obj; has children (not a leaf).
    expect(root.name, 'Data');
    expect(root.className, 'Obj');
    expect(root.isLeaf, isFalse);
    expect(root.typeLabel, contains('Obj'));

    // Walk Data → Seq (Objs array) → its single element is the Sequence object
    // itself (name taken from the name= attribute).
    final seqContainer = root.children.firstWhere((c) => c.name == 'Seq');
    expect(seqContainer.isArray, isTrue);
    expect(seqContainer.typeLabel, contains('Objs['));
    final mainSeq = seqContainer.children.single;
    expect(mainSeq.name, 'MainSequence');
    expect(mainSeq.attributes['name'], 'MainSequence');
  });

  test('coverageLabel formats the modeled/total ratio', () {
    final doc = SeqDocument.parse(_xml()) as XmlSeqDocument;
    final c = measureCoverage(doc.file);
    final label = coverageLabel(c);
    expect(label, startsWith('model coverage '));
    expect(label, contains('${c.modeled}/${c.total}'));
    expect(label, matches(RegExp(r'\d+\.\d%')));
    // The fixture's typed lens recovers something but not everything.
    expect(c.modeled, greaterThan(0));
    expect(c.modeled, lessThanOrEqualTo(c.total));
  });

  test('binaryHeaderRows surfaces recon facts for a TOF1 file', () {
    final doc = SeqDocument.parse(_binary());
    expect(doc, isA<BinarySeqDocument>());
    final rows = binaryHeaderRows(doc as BinarySeqDocument);
    final map = {for (final (k, v) in rows) k: v};

    expect(map['Encoding'], 'binary');
    expect(map['File type'], 'SequenceFile');
    expect(map['Product'], 'TestStand');
    expect(map['Inflated body'], endsWith('bytes'));
    expect(int.parse(map['Strings recovered']!), greaterThan(0));
  });

  test('documentText/Title handle unrecognized bytes without throwing', () {
    final doc = SeqDocument.parse(Uint8List.fromList([1, 2, 3, 4]));
    expect(doc, isA<UnknownSeqDocument>());
    expect(documentTitle(doc), contains('unrecognized'));
    expect(documentText(doc), contains('Not a recognized TestStand sequence.'));
  });
}
