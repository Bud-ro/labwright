import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_teststand/labwright_teststand.dart';
import 'package:labwright_teststand_inspector/src/document_view.dart';

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

  test('documentText/Title handle unrecognized bytes without throwing', () {
    final doc = SeqDocument.parse(Uint8List.fromList([1, 2, 3, 4]));
    expect(doc, isA<UnknownSeqDocument>());
    expect(documentTitle(doc), contains('unrecognized'));
    expect(documentText(doc), contains('Not a recognized TestStand sequence.'));
  });
}
