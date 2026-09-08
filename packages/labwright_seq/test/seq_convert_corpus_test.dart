@Tags(['corpus'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_seq/labwright_seq.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

const _pinnedIniSeqCount = 45;
const _pinnedXmlSeqCount = 42;
const _pinnedBinarySeqCount = 297;

void main() {
  final byFormat = <SeqFormat, List<File>>{};
  final files = corpusSeqDir.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.seq')).toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final f in files) {
    byFormat.putIfAbsent(detectSeqFormat(f.readAsBytesSync()), () => []).add(f);
  }

  test('INI → XML → INI is byte-exact for every INI corpus file (and the XML hop is stable)', () {
    final iniFiles = byFormat[SeqFormat.ini] ?? const <File>[];
    expect(iniFiles.length, _pinnedIniSeqCount, reason: 'INI corpus count drifted');
    for (final f in iniFiles) {
      final bytes = f.readAsBytesSync();
      final doc = parseIniSeqBytes(bytes);
      final xml = iniToXmlSeqFile(doc);

      final xmlBytes = writeSeqFileXml(xml);
      expect(detectSeqFormat(xmlBytes), SeqFormat.xml, reason: '${f.path}: intermediate must sniff as XML');
      final reparsed = parseSeqFile(xmlBytes);
      expect(seqFileDeepEquals(xml, reparsed), isTrue, reason: '${f.path}: XML intermediate must reparse deep-equal');

      final back = xmlToIniSeqFile(reparsed);
      expect(iniDeepEquals(doc, back), isTrue, reason: '${f.path}: INI model must return deep-equal');
      expect(writeIniSeq(back), bytes, reason: '${f.path}: INI → XML → INI must be byte-exact');
      expect(seqFileDeepEquals(xml, iniToXmlSeqFile(back)), isTrue, reason: '${f.path}: INI → XML must be a fixpoint');
    }
    print('retention INI → XML → INI: byte-exact ${iniFiles.length}/${iniFiles.length}');
  });

  test('iniDataTree keeps instance directives on an inherited container member', () {
    const fixture = '''
[__Header__]
ProductName = "TestStand"
ProductVersion = 3.5.0.365
Version = 354
Type = "SequenceFile"

[DEF, %OBJROOT]
SF = SequenceFileData

[DEF, SF]
Seq = Objs
%NAME = "Data"

[DEF, SF.Seq]
%[0] = Sequence

[DEF, SF.Seq[0]]
Locals = Obj
%NAME = "MainSequence"

[DEF, SF.Seq[0].Locals]
signalA = "TYPE, LabVIEWDynamicData"
signalB = "TYPE, LabVIEWDynamicData"

[SF.Seq[0].Locals.signalA]
Name = "a"

[SF.Seq[0].Locals.signalB]
Name = "b"
%HI: Element1 = [1]

[DEF, LabVIEWDynamicData]
Name = Str
Element1 = Obj

[DEF, LabVIEWDynamicData.Element1]
Attr = Num
''';
    final root = iniDataTree(parseIniSeqBytes(Uint8List.fromList(fixture.codeUnits)));
    expect(root, isNotNull, reason: 'fixture data root must decode');
    final locals = root!.prop('Seq')?.array?.first.prop('Locals');
    for (final (name, expectHi) in const [('signalA', false), ('signalB', true)]) {
      final signal = locals?.prop(name);
      expect(signal?.typeName, 'LabVIEWDynamicData', reason: '$name must resolve its inherited type');
      final element1 = signal?.prop('Element1');
      expect(element1, isNotNull, reason: '$name: inherited container member must materialize');
      expect(
        element1!.attributes['%HI'] != null,
        expectHi,
        reason: '$name: the instance %HI directive must survive expansion on exactly the instance carrying it',
      );
    }
  });

  test('XML → INI → XML is byte-exact for every XML corpus file (and the INI hop is stable)', () {
    final xmlFiles = byFormat[SeqFormat.xml] ?? const <File>[];
    expect(xmlFiles.length, _pinnedXmlSeqCount, reason: 'XML corpus count drifted');
    for (final f in xmlFiles) {
      final bytes = f.readAsBytesSync();
      final file = parseSeqFile(bytes);
      final ini = xmlToIniSeqFile(file);

      final iniBytes = writeIniSeq(ini);
      expect(detectSeqFormat(iniBytes), SeqFormat.ini, reason: '${f.path}: intermediate must sniff as INI');
      final reparsed = parseIniSeqBytes(iniBytes);
      expect(iniDeepEquals(ini, reparsed), isTrue, reason: '${f.path}: INI intermediate must reparse deep-equal');

      final back = iniToXmlSeqFile(reparsed);
      expect(seqFileDeepEquals(file, back), isTrue, reason: '${f.path}: XML model must return deep-equal');
      expect(writeSeqFileXml(back), bytes, reason: '${f.path}: XML → INI → XML must be byte-exact');
      expect(iniDeepEquals(ini, xmlToIniSeqFile(back)), isTrue, reason: '${f.path}: XML → INI must be a fixpoint');
    }
    print('retention XML → INI → XML: byte-exact ${xmlFiles.length}/${xmlFiles.length}');
  });

  test('binary → XML/INI loops retain exactly the decoded surface, marked partial', () {
    final binFiles = byFormat[SeqFormat.binary] ?? const <File>[];
    expect(binFiles.length, _pinnedBinarySeqCount, reason: 'binary corpus count drifted');
    var surfaceExact = 0;
    var refused = 0;
    for (final f in binFiles) {
      final bytes = f.readAsBytesSync();
      SeqFile bin;
      try {
        bin = parseSeqFile(bytes);
      } on FormatException {
        refused++;
        continue;
      }
      final xml = binaryToXmlSeqFile(bin);
      expect(
        xml.rootAttributes?[ConvKey.partialDecodeAttr],
        ConvKey.partialDecodeBinary,
        reason: '${f.path}: binary-derived output must be marked partial',
      );
      expect(_surface(xml.data), _surface(bin.data), reason: '${f.path}: lifted data surface must match the decode');
      expect(xml.types.length, bin.types.length, reason: '${f.path}: type count must match the decode');
      for (var i = 0; i < bin.types.length; i++) {
        expect(_surface(xml.types[i]), _surface(bin.types[i]), reason: '${f.path}: type[$i] surface must match');
      }
      final reparsed = parseSeqFile(writeSeqFileXml(xml));
      expect(seqFileDeepEquals(xml, reparsed), isTrue, reason: '${f.path}: lifted XML must reparse deep-equal');

      final ini = xmlToIniSeqFile(reparsed);
      final iniReparsed = parseIniSeqBytes(writeIniSeq(ini));
      expect(iniDeepEquals(ini, iniReparsed), isTrue, reason: '${f.path}: INI hop must reparse deep-equal');
      expect(
        seqFileDeepEquals(xml, iniToXmlSeqFile(iniReparsed)),
        isTrue,
        reason: '${f.path}: XML ↔ INI loop must retain the decoded surface',
      );
      surfaceExact++;
    }
    print('retention binary → XML/INI: decoded-surface-exact $surfaceExact/${binFiles.length} ($refused refused)');
    expect(surfaceExact, _pinnedBinarySeqCount, reason: 'every corpus binary currently inflates and converts');
    expect(refused, 0, reason: 'refused-binary count drifted');
  });
}

List<Object?> _surface(SeqProperty p) => [
  p.name,
  p.className,
  p.typeName,
  p.scalar,
  p.numericFormat ?? p.attributes['%NUMFMT'],
  p.extData,
  [for (final c in p.subProps) _surface(c)],
  switch (p.array) {
    final array? => [for (final e in array) _surface(e)],
    _ => null,
  },
  switch (p.elemProto) {
    final elemProto? => _surface(elemProto),
    _ => null,
  },
];
