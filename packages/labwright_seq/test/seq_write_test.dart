import 'dart:convert';

import 'package:labwright_seq/labwright_seq.dart';
import 'package:test/test.dart';

void main() {
  group('writeIniSeq', () {
    String doc(List<String> sections, {String nl = '\n', List<String>? header}) {
      final h =
          header ??
          ['ProductName = "TestStand"', 'ProductVersion = 3.5.0.365', 'Version = 354', 'Type = "SequenceFile"'];
      final sb = StringBuffer('[__Header__]$nl');
      for (final line in h) {
        sb.write('$line$nl');
      }
      for (final section in sections) {
        sb.write(nl);
        for (final line in const LineSplitter().convert(section)) {
          sb.write('$line$nl');
        }
      }
      sb.write(nl);
      return sb.toString();
    }

    IniSeqFile roundTrips(String text) {
      final original = latin1.encode(text);
      final file = parseIniSeqBytes(original);
      expect(writeIniSeq(file), original, reason: 'write(parse(doc)) must be byte-identical');
      return file;
    }

    test('quoting fidelity: bare vs quoted values survive verbatim, header included', () {
      final file = roundTrips(doc(['[SF]\nVersion = "0.0.0.0"\nBatchSync = 1\nGoalTime = 0.5']));
      expect(file.headerFields['ProductName'], '"TestStand"');
      expect(file.headerFields['ProductVersion'], '3.5.0.365', reason: 'bare header value must not gain quotes');
      expect(file.sections.single.members['Version'], '"0.0.0.0"');
      expect(file.sections.single.members['BatchSync'], '1');
    });

    test('interleaved member/directive line order is retained and re-emitted', () {
      final file = roundTrips(
        doc([
          '[SF.Seq[0]]\n'
              'LoadOpt = "opts"\n'
              '%FLG: LoadOpt = 4194304\n'
              'Version = "0.0.0.0"\n'
              '%FLG: Hidden = 8\n'
              '%NAME = "MainSequence"',
        ]),
      );
      final s = file.sections.single;
      expect(s.entries.map((e) => e.key).toList(), [
        'LoadOpt',
        '%FLG: LoadOpt',
        'Version',
        '%FLG: Hidden',
        '%NAME',
      ], reason: 'entries must keep document order — the maps alone cannot');
      expect(s.members.containsKey('Hidden'), isFalse, reason: 'a lone %FLG names a member with no value line');
      expect(s.directives['%FLG: Hidden'], '8');
      expect(s.name, 'MainSequence');
    });

    group('continuation re-split (inner > 120 chars → ` LineNNNN` fragments)', () {
      String makeInner(int length, [String alphabet = 'abcdefghij']) =>
          List.generate(length, (i) => alphabet[i % 10]).join();
      String split(String key, String inner) =>
          '$key Line0001 = "${inner.substring(0, 120)}"\n$key Line0002 = "${inner.substring(120)}"';

      test('a 130-char inner splits into 120 + 10, byte-exactly, rejoined at the first position', () {
        final inner = makeInner(130);
        final s = roundTrips(doc(['[SF]\n${split('Text', inner)}\nAfter = 1'])).sections.single;
        expect(s.entries.map((e) => e.key).toList(), ['Text', 'After']);
        expect(s.members['Text'], '"$inner"');
      });

      test('an exact multiple of 120 ends with a FULL fragment', () {
        final inner = makeInner(240, 'ABCDEFGHIJ');
        final file = roundTrips(doc(['[SF]\n${split('Text', inner)}']));
        expect(file.sections.single.members['Text'], '"$inner"');
      });

      test(r'escape-BLIND: a \\ pair straddles the 120 boundary (corpus-real)', () {
        final inner = '${'x' * 119}\\\\tail-after-the-straddle';
        expect(inner.substring(119, 121), r'\\');
        final file = roundTrips(doc(['[SF]\n${split('Expr', inner)}']));
        expect(file.sections.single.members['Expr'], '"$inner"');
      });

      test('applies to HEADER fields too (corpus: a long Path)', () {
        final inner = makeInner(150, 'pqrstuvwxy');
        final file = roundTrips(
          doc(
            ['[SF]\nVersion = "0.0.0.0"'],
            header: ['ProductName = "TestStand"', split('Path', inner), 'Version = 354', 'Type = "SequenceFile"'],
          ),
        );
        expect(file.headerFields['Path'], '"$inner"');
        expect(file.headerFields.keys.toList(), ['ProductName', 'Path', 'Version', 'Type']);
      });

      test('a 120-char inner is NOT split (the corpus threshold is inner > 120)', () {
        final inner = 'y' * 120;
        final file = roundTrips(doc(['[SF]\nText = "$inner"']));
        expect(file.sections.single.members['Text'], '"$inner"');
      });
    });

    test('escaping inversion: escapeIniQuoted(x) parses back to x', () {
      const logical = 'a\\b"c\nd\te\rf';
      final raw = escapeIniQuoted(logical);
      expect(raw, '"a\\\\b\\"c\\nd\\te\\rf"');
      final file = roundTrips(doc(['[SF]\n%NAME = $raw']));
      expect(file.sections.single.name, logical, reason: 'the reader unescape must invert escapeIniQuoted');
    });

    test('CRLF file: the terminator is captured and replayed byte-exactly; LF stays LF', () {
      expect(roundTrips(doc(['[SF]\nVersion = "0.0.0.0"'], nl: '\r\n')).lineTerminator, '\r\n');
      expect(roundTrips(doc(['[SF]\nVersion = "0.0.0.0"'])).lineTerminator, '\n');
    });

    test('EXTDATA sections round-trip in their original document position', () {
      final file = roundTrips(
        doc([
          '[DEF, SF]\nSeq = Objs',
          '[EXTDATA, SF.Seq, STRUCT]\nType = 6\nName = "s"',
          '[SF]\nVersion = "0.0.0.0"',
        ]),
      );
      expect(
        (file.sections[1].isExtData, file.sections[1].extDataKind, file.sections[1].path),
        (
          true,
          'STRUCT',
          'SF.Seq',
        ),
      );
      expect(file.sections.map((s) => s.isExtData).toList(), [
        false,
        true,
        false,
      ], reason: 'EXTDATA must stay interleaved, not segregated');
    });

    test('model deep-equals: write→parse preserves the model; mutation/reorder is detected', () {
      final text = doc(['[SF]\nVersion = "0.0.0.0"\n%FLG: Seq = 4194304']);
      final file = parseIniSeqBytes(latin1.encode(text));
      expect(iniDeepEquals(file, parseIniSeqBytes(writeIniSeq(file))), isTrue);
      final mutated = parseIniSeqBytes(
        latin1.encode(text.replaceFirst('"0.0.0.0"', '"0.0.0.1"')),
      );
      expect(iniDeepEquals(file, mutated), isFalse);
      final reordered = parseIniSeqBytes(
        latin1.encode(
          text.replaceFirst(
            'Version = "0.0.0.0"\n%FLG: Seq = 4194304',
            '%FLG: Seq = 4194304\nVersion = "0.0.0.0"',
          ),
        ),
      );
      expect(iniDeepEquals(file, reordered), isFalse, reason: 'entry order is fidelity, not noise');
    });
  });

  group('writeSeqFileXml', () {
    String doc({String typelist = '', required String data}) =>
        '﻿<?xml version="1.0" encoding="UTF-8"?>\n'
        "<teststandfileheader type='SequenceFile' fileversion='962' productname='TestStand' "
        "productversion='2021 SP1 (21.1.0.49154)' "
        'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
        'xmlns="http://www.ni.com/TestStand/21.0.0/SequenceFile">\n'
        '\t<typelist>\n'
        '$typelist'
        '\t</typelist>\n'
        '$data'
        '</teststandfileheader>\n';

    String dataProp(String inner) => "\t<Data classname='Obj'>\n\t\t<subprops>\n$inner\t\t</subprops>\n\t</Data>\n";

    SeqFile roundTrips(String text) {
      final original = utf8.encode(text);
      final file = parseSeqFile(original);
      expect(writeSeqFileXml(file), original, reason: 'write(parse(doc)) must be byte-identical');
      return file;
    }

    test('minimal file: BOM + decl + mixed-quote root attrs round-trip byte-exactly', () {
      final file = roundTrips(doc(data: "\t<Data classname='Obj'/>\n"));
      expect(file.rootAttributes!.keys.toList(), [
        'type',
        'fileversion',
        'productname',
        'productversion',
        'xmlns:xsi',
        'xmlns',
      ]);
      expect(file.rootAttributes!['productversion'], '2021 SP1 (21.1.0.49154)');
      expect(file.rootAttributes!['xmlns'], 'http://www.ni.com/TestStand/21.0.0/SequenceFile');
    });

    test('elemproto: the array element prototype is retained and re-emitted first', () {
      final file = roundTrips(
        doc(
          data: dataProp(
            "\t\t\t<Steps classname='Objs'>\n"
            "\t\t\t\t<value lbound='[0]' ubound='[0]'>\n"
            '\t\t\t\t\t<elemproto>\n'
            "\t\t\t\t\t\t<_NAME_IN_ATTRIBUTE_ typename='NI_CustomResult' xsi:type='NI_CustomResult' name='' classname='CustomResult'>\n"
            '\t\t\t\t\t\t\t<subprops>\n'
            "\t\t\t\t\t\t\t\t<Name classname='ExprValue'>\n"
            '\t\t\t\t\t\t\t\t\t<value/>\n'
            '\t\t\t\t\t\t\t\t</Name>\n'
            '\t\t\t\t\t\t\t</subprops>\n'
            '\t\t\t\t\t\t</_NAME_IN_ATTRIBUTE_>\n'
            '\t\t\t\t\t</elemproto>\n'
            '\t\t\t\t\t<value>\n'
            "\t\t\t\t\t\t<Obj name='Element0' classname='Obj'/>\n"
            '\t\t\t\t\t</value>\n'
            '\t\t\t\t</value>\n'
            '\t\t\t</Steps>\n',
          ),
        ),
      );
      final steps = file.data.prop('Steps')!;
      final proto = steps.elemProto;
      expect(proto, isNotNull, reason: 'elemproto must be modeled, not dropped');
      expect((proto!.typeName, proto.xmlTag), ('NI_CustomResult', '_NAME_IN_ATTRIBUTE_'));
      expect(proto.prop('Name'), isNotNull);
      expect(steps.array, hasLength(1));
      expect(steps.array!.single.name, 'Element0');
      expect(steps.array!.single.xmlTag, 'Obj', reason: 'tag is not derivable from name — must be retained');
    });

    test('array bounds are kept VERBATIM, including multi-dimensional and [] forms', () {
      final file = roundTrips(
        doc(
          data: dataProp(
            "\t\t\t<Empty classname='Objs'>\n\t\t\t\t<value lbound='[0]' ubound='[]'/>\n\t\t\t</Empty>\n"
            "\t\t\t<Grid classname='Nums'>\n\t\t\t\t<value lbound='[0][0]' ubound='[1][1]'/>\n\t\t\t</Grid>\n",
          ),
        ),
      );
      expect((file.data.prop('Empty')!.arrayLBound, file.data.prop('Empty')!.arrayUBound), ('[0]', '[]'));
      expect((file.data.prop('Grid')!.arrayLBound, file.data.prop('Grid')!.arrayUBound), ('[0][0]', '[1][1]'));
    });

    test('sparse array: arrayindex element wrappers round-trip on the wrapper', () {
      final file = roundTrips(
        doc(
          data: dataProp(
            "\t\t\t<Sparse classname='Nums'>\n"
            "\t\t\t\t<value lbound='[0]' ubound='[2]'>\n"
            "\t\t\t\t\t<value arrayindex='[1]'>9223372036854775806</value>\n"
            '\t\t\t\t</value>\n'
            '\t\t\t</Sparse>\n',
          ),
        ),
      );
      final element = file.data.prop('Sparse')!.array!.single;
      expect((element.attributes['arrayindex'], element.scalar), ('[1]', '9223372036854775806'));
    });

    test('multiline <value> text keeps its literal LFs; entities decode', () {
      final file = roundTrips(
        doc(
          data: dataProp(
            "\t\t\t<Expr classname='ExprValue'>\n"
            '\t\t\t\t<value>line one \nline two &lt; &amp; &gt; end</value>\n'
            '\t\t\t</Expr>\n',
          ),
        ),
      );
      expect(file.data.prop('Expr')!.scalar, 'line one \nline two < & > end');
    });

    test('extdata children are retained as ordered attr-maps', () {
      final file = roundTrips(
        doc(
          data: dataProp(
            "\t\t\t<Param name='x' classname='Num'>\n"
            '\t\t\t\t<value>0</value>\n'
            "\t\t\t\t<extdata controllername='C/C++ DLL' allowstructpassing='false' exclude='false'/>\n"
            "\t\t\t\t<extdata controllername='LabVIEW' allowclusterpassing='true' memberlabel='x'/>\n"
            '\t\t\t</Param>\n',
          ),
        ),
      );
      final param = file.data.prop('x')!;
      expect(param.extData, hasLength(2));
      expect(param.extData[0].keys.toList(), ['controllername', 'allowstructpassing', 'exclude']);
      expect(param.extData[1]['memberlabel'], 'x');
    });

    test('numericfmt and scalar <value representation> attributes are retained verbatim', () {
      final file = roundTrips(
        doc(
          data: dataProp(
            "\t\t\t<Mask classname='Num'>\n\t\t\t\t<value>255</value>\n\t\t\t\t<numericfmt>%#x</numericfmt>\n\t\t\t</Mask>\n"
            "\t\t\t<Big classname='Num'>\n\t\t\t\t<value representation='Int64'>-5</value>\n\t\t\t</Big>\n",
          ),
        ),
      );
      expect(file.data.prop('Mask')!.numericFormat, '%#x');
      expect(file.data.prop('Big')!.valueAttributes, {'representation': 'Int64'});
      expect(file.data.prop('Big')!.scalar, '-5');
    });

    test('typedef wrapper attributes and interleaved <protected> blobs round-trip in order', () {
      final file = roundTrips(
        doc(
          typelist:
              "\t\t<typedef alwayssavetype='false' additionaltypeflags='0' typelistordernum='2'>\n"
              "\t\t\t<Expression classname='ExprValue' isroottypedef='true'>\n"
              '\t\t\t\t<value/>\n'
              '\t\t\t</Expression>\n'
              '\t\t</typedef>\n'
              '\t\t<protected>E@=3HJL4100hYLEDF=_K@0@mKCYo_1KN2&lt;dfASB`]CF^aUXa]Y&amp;4WmD&gt;203</protected>\n'
              "\t\t<typedef alwayssavetype='true' additionaltypeflags='0' typelistordernum='1'>\n"
              "\t\t\t<NumericLimitTest classname='StepType' isroottypedef='true'/>\n"
              '\t\t</typedef>\n',
          data: "\t<Data classname='Obj'/>\n",
        ),
      );
      final entries = file.typelistEntries!;
      expect(entries, hasLength(3));
      expect(entries[0].attributes['typelistordernum'], '2');
      expect(entries[1].isProtected, isTrue);
      expect(entries[1].protectedData, contains('<dfASB`]CF^aUXa]Y&4WmD>203'));
      expect(entries[2].root!.name, 'NumericLimitTest');
      expect(file.types.map((t) => t.name), ['Expression', 'NumericLimitTest'], reason: 'legacy lens, in order');
    });

    test('model deep-equals: write→parse preserves the model; a mutation is detected', () {
      final text = doc(
        data: dataProp("\t\t\t<A classname='Str'>\n\t\t\t\t<value>x</value>\n\t\t\t</A>\n"),
      );
      final file = parseSeqFile(utf8.encode(text));
      expect(seqFileDeepEquals(file, parseSeqFile(writeSeqFileXml(file))), isTrue);
      final other = parseSeqFile(utf8.encode(text.replaceFirst('<value>x</value>', '<value>y</value>')));
      expect(seqFileDeepEquals(file, other), isFalse);
    });

    test('refuses a binary-flavor SeqFile instead of fabricating an XML file', () {
      final binaryFlavor = SeqFile(
        header: const SeqFileHeader(format: SeqFormat.binary, fileType: 'SequenceFile'),
        types: [],
        data: SeqProperty(name: 'Data'),
      );
      expect(() => writeSeqFileXml(binaryFlavor), throwsArgumentError);
    });
  });
}
