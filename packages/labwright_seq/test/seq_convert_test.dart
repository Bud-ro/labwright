import 'dart:convert';
import 'dart:typed_data';

import 'package:labwright_seq/labwright_seq.dart';
import 'package:test/test.dart';

/// Unit coverage for the cross-flavor converters (`seq_convert.dart`): the
/// armor codec, hostile hand-built models through the XML → INI → XML loop,
/// native INI → XML mapping of the fidelity directives, and the honest
/// refusal guards. The corpus gates (58/58 INI, 36/36 XML byte-exact, the
/// binary decoded-surface loops) live in `seq_convert_corpus_test.dart`.
void main() {
  group('armor codec', () {
    test('round-trips arbitrary text, including INI-hostile characters', () {
      const cases = [
        '',
        'plain',
        'a b = c&d%e"f\\g',
        'line1\nline2\ttab\rcr',
        'ünïcode 中文 🙂',
        '%41 literal-percent-run %%',
        ' leading and trailing ',
        '"quoted"',
      ];
      for (final text in cases) {
        final armored = armorText(text);
        expect(unarmorText(armored), text, reason: jsonEncode(text));
        // The armored alphabet is INI-inert: printable ASCII, no whitespace,
        // quotes, escapes, or `=`/`&` separators.
        expect(
          armored.codeUnits.every(
            (c) =>
                c > 0x20 &&
                c <= 0x7E &&
                c != 0x22 /* " */ &&
                c != 0x26 /* & */ &&
                c != 0x3D /* = */ &&
                c != 0x5C /* \ */,
          ),
          isTrue,
          reason: 'armored form must be INI-inert: $armored',
        );
      }
    });
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
          // An empty <typedef/> wrapper (root-less): unobserved in the corpus
          // but representable, so it must cross too.
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
            // className/typeName inconsistent with the attribute map
            // (hand-built): needs the explicit override record.
            SeqProperty(name: 'Odd', xmlTag: 'Odd', className: 'Num', typeName: 'CustomT'),
            // Scalars exercising the INI escape set and the armored fallback.
            SeqProperty(name: 'Multiline', xmlTag: 'Multiline', scalar: 'a\nb\t"q"\\end\r'),
            SeqProperty(name: 'NonLatin', xmlTag: 'NonLatin', scalar: 'температура 中'),
            SeqProperty(
              name: 'LongVal',
              xmlTag: 'LongVal',
              scalar: List.filled(40, '0123456789').join(), // 400 chars: continuation-split territory
            ),
            // A sparse scalar array with element attributes, bounds,
            // a representation hint, an elemproto, extdata, and numericfmt.
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
            // Object array elements plus an empty array.
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
      // The synthesized INI must itself survive its byte writer/parser.
      final reparsed = parseIniSeqBytes(writeIniSeq(ini));
      expect(iniDeepEquals(ini, reparsed), isTrue, reason: 'synthesized INI must reparse stable');
      final back = iniToXmlSeqFile(reparsed);
      expect(seqFileDeepEquals(file, back), isTrue, reason: 'XML → INI → XML must be lossless');
      // Fixpoint: converting the rebuilt model again yields the same INI.
      expect(iniDeepEquals(ini, xmlToIniSeqFile(back)), isTrue, reason: 'loop must be a fixpoint');
      // The bare-types fallback is exercised via SeqFile.types rebuild.
      expect(back.types.map((t) => t.name), ['MyType']);
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
      '[DEF, %OBJROOT]\n'
          'SF = SequenceFileData\n'
          'TEInf = Obj',
      '[%TYPES]\n'
          'TEInf = "TEInf"',
      '[DEF, TEInf]\n'
          'Mask = Num',
      '[TEInf]\n'
          'Mask = 16',
      // The corpus-native %NUMFMT shape: a bare directive on the member's OWN
      // section while its value stays on the parent (e.g. NI_CustomResult.Flags).
      '[TEInf.Mask]\n'
          '%NUMFMT = "%#x"',
      '[DEF, SF]\n'
          'Seq = Objs\n'
          'Cols = Nums',
      '[SF]\n'
          '%HI: Seq = [0]\n'
          '%FLG: Seq = 4194304\n'
          '%LO: Cols = [1]\n'
          '%HI: Cols = [2]\n'
          'Version = "0.0.0.0"',
      '[DEF, SF.Seq]\n'
          '%[0] = Sequence',
      '[DEF, SF.Seq[0]]\n'
          '%NAME = "MainSequence"',
      '[SF.Seq[0]]\n'
          '%COMMENT = "does the thing\\non two lines"',
      '[EXTDATA, SF.Version, STRUCT]\n'
          'DataVersion = 1\n'
          'Type = 6',
    ]);

    test('fidelity directives cross natively; the loop is byte-exact', () {
      final bytes = Uint8List.fromList(latin1.encode(source));
      final ini = parseIniSeqBytes(bytes);
      final xml = iniToXmlSeqFile(ini);

      expect(xml.header.format, SeqFormat.xml);
      expect(xml.rootAttributes, {'type': 'SequenceFile', 'fileversion': '354', 'productname': 'TestStand'});

      // %NUMFMT crosses natively into numericFormat (not an attribute), and
      // the member's parent-section value is retained alongside it.
      final mask = xml.types.single.prop('Mask');
      expect(xml.types.single.name, 'TEInf');
      expect(mask!.numericFormat, '%#x');
      expect(mask.scalar, '16');
      expect(mask.attributes.containsKey('x-NUMFMT'), isFalse);

      // %HI/%LO become XML value bounds (same bracket syntax), %FLG rides the
      // x- rename, and the typed lenses read both spellings.
      final seq = xml.data.prop('Seq')!;
      expect(seq.arrayUBound, '[0]');
      expect(seq.arrayLBound, '[0]');
      expect(seq.propertyFlags, 4194304);
      expect(seq.attributes['x-FLG'], '4194304');
      // A defaults-only declared array (bounds but no materialized elements)
      // stays a leaf; its %LO/%HI ride the x- rename and the bounds lenses
      // still read them.
      final cols = xml.data.prop('Cols')!;
      expect(cols.isArray, isFalse);
      expect(cols.attributes['x-LO'], '[1]');
      expect(cols.attributes['x-HI'], '[2]');
      expect(cols.highIndices, [2]);
      expect(cols.lowIndices, [1]);
      expect(cols.declaredArrayLength, 2);

      // %COMMENT survives the rename and the Sequence lens still reads it.
      final main = Sequence(seq.array!.single);
      expect(main.name, 'MainSequence');
      expect(main.comment, 'does the thing\non two lines');

      // The written XML is a well-formed XML-flavor file that reparses to a
      // deep-equal model (channel included).
      final xmlBytes = writeSeqFileXml(xml);
      expect(detectSeqFormat(xmlBytes), SeqFormat.xml);
      final reparsed = parseSeqFile(xmlBytes);
      expect(seqFileDeepEquals(xml, reparsed), isTrue);

      // Byte-exact return, EXTDATA section and all.
      final back = xmlToIniSeqFile(reparsed);
      expect(writeIniSeq(back), bytes);
      expect(iniDeepEquals(ini, back), isTrue);
      expect(back.extDataSections.single.extDataKind, 'STRUCT');

      // Fixpoint after the first hop.
      expect(seqFileDeepEquals(xml, iniToXmlSeqFile(back)), isTrue);
    });

    test('a CRLF-terminated INI round-trips byte-exactly through XML', () {
      final crlfDoc = doc(['[DEF, %OBJROOT]\nSF = SequenceFileData', '[SF]\nVersion = "1.0"'], nl: '\r\n');
      final bytes = Uint8List.fromList(latin1.encode(crlfDoc));
      final ini = parseIniSeqBytes(bytes);
      expect(ini.lineTerminator, '\r\n');
      final back = xmlToIniSeqFile(parseSeqFile(writeSeqFileXml(iniToXmlSeqFile(ini))));
      expect(back.lineTerminator, '\r\n');
      expect(writeIniSeq(back), bytes);
    });
  });

  group('honest refusals and partial marking', () {
    test('xmlToIniSeqFile refuses binary/INI-flavor (partial) models', () {
      final binModel = SeqFile(
        header: const SeqFileHeader(format: SeqFormat.binary, fileType: 'SequenceFile'),
        types: const [],
        data: SeqProperty(name: 'Data'),
      );
      expect(() => xmlToIniSeqFile(binModel), throwsArgumentError);
      final iniModel = SeqFile(
        header: const SeqFileHeader(format: SeqFormat.ini, fileType: 'SequenceFile'),
        types: const [],
        data: SeqProperty(name: 'Data'),
      );
      expect(() => xmlToIniSeqFile(iniModel), throwsArgumentError);
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
      final reparsed = parseSeqFile(writeSeqFileXml(xml));
      expect(seqFileDeepEquals(xml, reparsed), isTrue);
      final viaIni = iniToXmlSeqFile(parseIniSeqBytes(writeIniSeq(binaryToIniSeqFile(binModel))));
      expect(seqFileDeepEquals(xml, viaIni), isTrue);
      // And an XML-flavor model is refused (it is not a binary decode).
      expect(() => binaryToXmlSeqFile(xml), throwsArgumentError);
    });
  });
}
