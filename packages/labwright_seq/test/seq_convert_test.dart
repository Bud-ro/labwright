import 'dart:convert';

import 'package:labwright_seq/labwright_seq.dart';
import 'package:test/test.dart';

/// Unit coverage for the cross-flavor converters; the corpus gates live in
/// `seq_convert_corpus_test.dart`.
void main() {
  test('armor codec round-trips arbitrary text into an INI-inert alphabet', () {
    const cases = [
      '',
      'plain',
      'a b = c&d%e"f\\g',
      'line1\nline2\ttab\rcr',
      'ünïcode 中文 🙂',
      '%41 literal-percent-run %%',
      ' leading and trailing ',
      '"quoted"',
      '[SF.Seq[0]]',
      'Line0001 = "x"',
    ];
    for (final text in cases) {
      final armored = armorText(text);
      expect(unarmorText(armored), text, reason: jsonEncode(text));
      expect(
        armored.codeUnits.every((c) => c > 0x20 && c <= 0x7E && !const {0x22, 0x26, 0x3D, 0x5C}.contains(c)),
        isTrue,
        reason: 'armored form must avoid whitespace, ", &, =, \\: $armored',
      );
    }
  });

  group('xmlToIniSeqFile → iniToXmlSeqFile (hostile hand-built models)', () {
    test('every model field survives the loop deep-equal, and the INI reparses stable', () {
      final file = SeqFile(
        header: const SeqFileHeader(
          format: SeqFormat.xml,
          fileType: 'SequenceFile',
          productName: 'TestStand',
          fileVersion: '962',
        ),
        rootAttributes: const {
          'type': 'SequenceFile',
          'fileversion': '962',
          'productname': 'TestStand',
          'xmlns': 'http://www.ni.com/TestStand/21.0.0/SequenceFile',
        },
        types: [
          SeqProperty(name: 'MyType', xmlTag: 'MyType', className: 'Obj', attributes: const {'classname': 'Obj'}),
        ],
        typelistEntries: [
          SeqTypelistEntry(
            attributes: const {'alwayssavetype': 'true', 'typelistordernum': '0'},
            root: SeqProperty(
              name: 'MyType',
              xmlTag: 'MyType',
              className: 'Obj',
              attributes: const {'classname': 'Obj'},
            ),
          ),
          SeqTypelistEntry(protectedData: 'AAECAwQFBgcICQ== obfuscated blob'),
          // A root-less <typedef/> wrapper: unobserved in the corpus but representable.
          SeqTypelistEntry(attributes: const {'typelistordernum': '2'}),
        ],
        data: SeqProperty(
          name: 'Data',
          xmlTag: 'Data',
          className: 'Obj',
          attributes: const {'classname': 'Obj'},
          subProps: [
            // Names hostile to INI keys/paths and XML tags alike.
            SeqProperty(
              name: 'weird name = x',
              xmlTag: '_NAME_IN_ATTRIBUTE_',
              attributes: const {'name': 'weird name = x'},
              scalar: 'v1',
            ),
            SeqProperty(name: '', xmlTag: '_NAME_IN_ATTRIBUTE_', scalar: ''),
            SeqProperty(
              name: '%FLG',
              xmlTag: '_NAME_IN_ATTRIBUTE_',
              attributes: const {'name': '%FLG'},
              scalar: 'directive-like name',
            ),
            SeqProperty(
              name: '_NAME_IN_ATTRIBUTE_',
              xmlTag: '_NAME_IN_ATTRIBUTE_',
              attributes: const {'name': '_NAME_IN_ATTRIBUTE_'},
            ),
            // Duplicate sibling names (segment uniquification).
            SeqProperty(name: 'Dup', xmlTag: 'Dup', scalar: 'first'),
            SeqProperty(name: 'Dup', xmlTag: 'Dup', scalar: 'second'),
            // className/typeName inconsistent with the attribute map.
            SeqProperty(name: 'Odd', xmlTag: 'Odd', className: 'Num', typeName: 'CustomT'),
            // Scalars exercising the INI escape set and the armored fallback.
            SeqProperty(name: 'Multiline', xmlTag: 'Multiline', scalar: 'a\nb\t"q"\\end\r'),
            SeqProperty(name: 'NonLatin', xmlTag: 'NonLatin', scalar: 'температура 中'),
            SeqProperty(
              name: 'LongVal',
              xmlTag: 'LongVal',
              scalar: List.filled(40, '0123456789').join(), // 400 chars: continuation-split territory
            ),
            // A sparse scalar array with element attributes, bounds, a
            // representation hint, an elemproto, extdata, and numericfmt.
            SeqProperty(
              name: 'Nums',
              xmlTag: 'Nums',
              className: 'Nums',
              attributes: const {'classname': 'Nums'},
              valueAttributes: const {'lbound': '[0]', 'ubound': '[2]', 'representation': 'Int64'},
              array: [
                SeqProperty(name: '', scalar: '42', attributes: const {'arrayindex': '[1]'}),
              ],
              elemProto: SeqProperty(
                name: 'proto',
                xmlTag: 'proto',
                className: 'Num',
                attributes: const {'classname': 'Num'},
                scalar: '0',
              ),
              extData: const [
                {'controllername': 'a', 'exclude': 'false'},
                {'packingoption': '1'},
              ],
              numericFormat: '%#x',
            ),
            SeqProperty(
              name: 'Objs',
              xmlTag: 'Objs',
              className: 'Objs',
              attributes: const {'classname': 'Objs'},
              valueAttributes: const {'lbound': '[0]', 'ubound': '[0]'},
              array: [
                SeqProperty(
                  name: 'elem with space',
                  xmlTag: '_NAME_IN_ATTRIBUTE_',
                  attributes: const {'name': 'elem with space'},
                  subProps: [SeqProperty(name: 'Inner', xmlTag: 'Inner', scalar: 'x')],
                ),
              ],
            ),
            SeqProperty(
              name: 'Empty',
              xmlTag: 'Empty',
              className: 'Nums',
              attributes: const {'classname': 'Nums'},
              valueAttributes: const {'lbound': '[0]', 'ubound': '[]'},
              array: const [],
            ),
            // Empty numericfmt is a real corpus value (`%NUMFMT = ""`).
            SeqProperty(name: 'EmptyFmt', xmlTag: 'EmptyFmt', numericFormat: ''),
          ],
        ),
      );

      final ini = xmlToIniSeqFile(file);
      final reparsed = parseIniSeqBytes(writeIniSeq(ini));
      expect(iniDeepEquals(ini, reparsed), isTrue, reason: 'synthesized INI must reparse stable');
      final back = iniToXmlSeqFile(reparsed);
      expect(seqFileDeepEquals(file, back), isTrue, reason: 'XML → INI → XML must be lossless');
      expect(iniDeepEquals(ini, xmlToIniSeqFile(back)), isTrue, reason: 'loop must be a fixpoint');
      expect(back.types.map((t) => t.name), ['MyType'], reason: 'bare-types rebuild');
    });

    test('null root attributes and a missing typelist stay null (never fabricated)', () {
      final file = SeqFile(
        header: const SeqFileHeader(format: SeqFormat.xml, fileType: 'SequenceFile'),
        types: const [],
        data: SeqProperty(name: 'Data', xmlTag: 'Data'),
      );
      final back = iniToXmlSeqFile(parseIniSeqBytes(writeIniSeq(xmlToIniSeqFile(file))));
      expect(seqFileDeepEquals(file, back), isTrue);
      expect(back.rootAttributes, isNull);
      expect(back.typelistEntries, isNull);
      expect(back.header.fileVersion, isNull);
      expect(back.header.productName, isNull);
    });
  });

  group('iniToXmlSeqFile (native INI → XML mapping)', () {
    String doc(List<String> sections, {String nl = '\n'}) {
      final sb = StringBuffer('[__Header__]$nl')
        ..write('ProductName = "TestStand"$nl')
        ..write('Version = 354$nl')
        ..write('Type = "SequenceFile"$nl');
      for (final section in sections) {
        sb.write(nl);
        for (final line in const LineSplitter().convert(section)) {
          sb.write('$line$nl');
        }
      }
      sb.write(nl);
      return sb.toString();
    }

    final source = doc([
      '[DEF, %OBJROOT]\nSF = SequenceFileData\nTEInf = Obj',
      '[%TYPES]\nTEInf = "TEInf"',
      '[DEF, TEInf]\nMask = Num',
      '[TEInf]\nMask = 16',
      // The corpus-native %NUMFMT shape: a bare directive on the member's OWN
      // section while its value stays on the parent.
      '[TEInf.Mask]\n%NUMFMT = "%#x"',
      '[DEF, SF]\nSeq = Objs\nCols = Nums',
      '[SF]\n%HI: Seq = [0]\n%FLG: Seq = 4194304\n%LO: Cols = [1]\n%HI: Cols = [2]\nVersion = "0.0.0.0"',
      '[DEF, SF.Seq]\n%[0] = Sequence',
      '[DEF, SF.Seq[0]]\n%NAME = "MainSequence"',
      '[SF.Seq[0]]\n%COMMENT = "does the thing\\non two lines"',
      '[EXTDATA, SF.Version, STRUCT]\nDataVersion = 1\nType = 6',
    ]);

    test('fidelity directives cross natively; the loop is byte-exact', () {
      final bytes = latin1.encode(source);
      final ini = parseIniSeqBytes(bytes);
      final xml = iniToXmlSeqFile(ini);

      expect(xml.header.format, SeqFormat.xml);
      expect(xml.rootAttributes, {'type': 'SequenceFile', 'fileversion': '354', 'productname': 'TestStand'});

      // %NUMFMT crosses natively into numericFormat (not an attribute).
      final mask = xml.types.single.prop('Mask')!;
      expect(xml.types.single.name, 'TEInf');
      expect((mask.numericFormat, mask.scalar), ('%#x', '16'));
      expect(mask.attributes.containsKey('x-NUMFMT'), isFalse);

      // %HI/%LO become XML value bounds, %FLG rides the x- rename, and the
      // typed lenses read both spellings.
      final seq = xml.data.prop('Seq')!;
      expect((seq.arrayUBound, seq.arrayLBound), ('[0]', '[0]'));
      expect(seq.propertyFlags, 4194304);
      expect(seq.attributes['x-FLG'], '4194304');
      // A defaults-only declared array (bounds, no elements) stays a leaf.
      final cols = xml.data.prop('Cols')!;
      expect(cols.isArray, isFalse);
      expect((cols.attributes['x-LO'], cols.attributes['x-HI']), ('[1]', '[2]'));
      expect(cols.highIndices, [2]);
      expect(cols.lowIndices, [1]);
      expect(cols.declaredArrayLength, 2);

      // %COMMENT survives the rename and the Sequence lens still reads it.
      final main = Sequence(seq.array!.single);
      expect((main.name, main.comment), ('MainSequence', 'does the thing\non two lines'));

      final xmlBytes = writeSeqFileXml(xml);
      expect(detectSeqFormat(xmlBytes), SeqFormat.xml);
      final reparsed = parseSeqFile(xmlBytes);
      expect(seqFileDeepEquals(xml, reparsed), isTrue);

      // Byte-exact return, EXTDATA section and all; fixpoint after one hop.
      final back = xmlToIniSeqFile(reparsed);
      expect(writeIniSeq(back), bytes);
      expect(iniDeepEquals(ini, back), isTrue);
      expect(back.extDataSections.single.extDataKind, 'STRUCT');
      expect(seqFileDeepEquals(xml, iniToXmlSeqFile(back)), isTrue);
    });

    test('a CRLF-terminated INI round-trips byte-exactly through XML', () {
      final crlfDoc = doc(['[DEF, %OBJROOT]\nSF = SequenceFileData', '[SF]\nVersion = "1.0"'], nl: '\r\n');
      final bytes = latin1.encode(crlfDoc);
      final ini = parseIniSeqBytes(bytes);
      expect(ini.lineTerminator, '\r\n');
      final back = xmlToIniSeqFile(parseSeqFile(writeSeqFileXml(iniToXmlSeqFile(ini))));
      expect(back.lineTerminator, '\r\n');
      expect(writeIniSeq(back), bytes);
    });
  });

  group('honest refusals and partial marking', () {
    SeqFile flavored(SeqFormat format) => SeqFile(
      header: SeqFileHeader(format: format, fileType: 'SequenceFile'),
      types: const [],
      data: SeqProperty(name: 'Data'),
    );

    test('xmlToIniSeqFile refuses binary/INI-flavor (partial) models', () {
      expect(() => xmlToIniSeqFile(flavored(SeqFormat.binary)), throwsArgumentError);
      expect(() => xmlToIniSeqFile(flavored(SeqFormat.ini)), throwsArgumentError);
    });

    test('binaryToXmlSeqFile lifts only binary models and marks the output partial', () {
      final binModel = SeqFile(
        header: const SeqFileHeader(format: SeqFormat.binary, fileType: 'SequenceFile', productName: 'TestStand'),
        types: [
          SeqProperty(name: 'Action', className: 'StepType', attributes: const {'typecategory': '1'}),
        ],
        data: SeqProperty(
          name: 'Data',
          subProps: [
            SeqProperty(
              name: 'Seq',
              array: [
                SeqProperty(name: 'MainSequence', className: 'Sequence', attributes: const {'%BINOVERRIDES': 'true'}),
              ],
            ),
          ],
        ),
      );
      final xml = binaryToXmlSeqFile(binModel);
      expect(xml.rootAttributes![ConvKey.partialDecodeAttr], ConvKey.partialDecodeBinary);
      expect(xml.header.format, SeqFormat.xml);
      // The %BIN marker rides the rename and still reads as an override.
      final main = xml.data.prop('Seq')!.array!.single;
      expect(main.attributes['x-BINOVERRIDES'], 'true');
      expect(main.isInstanceOverride, isTrue);
      // The decoded surface survives write → reparse → INI → XML deep-equal.
      expect(seqFileDeepEquals(xml, parseSeqFile(writeSeqFileXml(xml))), isTrue);
      final viaIni = iniToXmlSeqFile(parseIniSeqBytes(writeIniSeq(binaryToIniSeqFile(binModel))));
      expect(seqFileDeepEquals(xml, viaIni), isTrue);
      expect(() => binaryToXmlSeqFile(xml), throwsArgumentError, reason: 'an XML-flavor model is refused');
    });
  });
}
