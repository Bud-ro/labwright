@Tags(['corpus'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_seq/labwright_seq.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

/// The number of XML-flavor `.seq` files in the pinned corpus — the byte-exact
/// gate asserts ALL of them round-trip, and pins the count so a corpus refresh
/// that adds XML files consciously extends the gate rather than silently
/// widening it.
const _pinnedXmlSeqCount = 36;

/// A document in EXACTLY the writer's serialization (BOM, decl, quoting,
/// tabs, LF) wrapping [typelist] and [data] — unit inputs are written in this
/// shape so `write(parse(input)) == input` can be asserted byte-for-byte.
String _doc({String typelist = '', required String data}) =>
    '\uFEFF<?xml version="1.0" encoding="UTF-8"?>\n'
    "<teststandfileheader type='SequenceFile' fileversion='962' productname='TestStand' "
    "productversion='2021 SP1 (21.1.0.49154)' "
    'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
    'xmlns="http://www.ni.com/TestStand/21.0.0/SequenceFile">\n'
    '\t<typelist>\n'
    '$typelist'
    '\t</typelist>\n'
    '$data'
    '</teststandfileheader>\n';

Uint8List _bytes(String doc) => utf8.encode(doc);

/// Asserts the writer reproduces [doc] byte-for-byte and returns the parse.
SeqFile _roundTrips(String doc) {
  final original = _bytes(doc);
  final file = parseSeqFile(original);
  expect(writeSeqFileXml(file), original, reason: 'write(parse(doc)) must be byte-identical');
  return file;
}

void main() {
  group('writeSeqFileXml (unit)', () {
    test('minimal file: BOM + decl + mixed-quote root attrs round-trip byte-exactly', () {
      final file = _roundTrips(_doc(data: "\t<Data classname='Obj'/>\n"));
      expect(file.rootAttributes, isNotNull);
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
      final doc = _doc(
        data:
            "\t<Data classname='Obj'>\n"
            '\t\t<subprops>\n'
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
            '\t\t\t</Steps>\n'
            '\t\t</subprops>\n'
            '\t</Data>\n',
      );
      final file = _roundTrips(doc);
      final steps = file.data.prop('Steps')!;
      final proto = steps.elemProto;
      expect(proto, isNotNull, reason: 'elemproto must be modeled, not dropped');
      expect(proto!.typeName, 'NI_CustomResult');
      expect(proto.xmlTag, '_NAME_IN_ATTRIBUTE_');
      expect(proto.prop('Name'), isNotNull);
      expect(steps.array, hasLength(1));
      expect(steps.array!.single.name, 'Element0');
      expect(steps.array!.single.xmlTag, 'Obj', reason: 'tag is not derivable from name — must be retained');
    });

    test('array bounds are kept VERBATIM, including multi-dimensional and [] forms', () {
      final doc = _doc(
        data:
            "\t<Data classname='Obj'>\n"
            '\t\t<subprops>\n'
            "\t\t\t<Empty classname='Objs'>\n"
            "\t\t\t\t<value lbound='[0]' ubound='[]'/>\n"
            '\t\t\t</Empty>\n'
            "\t\t\t<Grid classname='Nums'>\n"
            "\t\t\t\t<value lbound='[0][0]' ubound='[1][1]'/>\n"
            '\t\t\t</Grid>\n'
            '\t\t</subprops>\n'
            '\t</Data>\n',
      );
      final file = _roundTrips(doc);
      expect(file.data.prop('Empty')!.arrayLBound, '[0]');
      expect(file.data.prop('Empty')!.arrayUBound, '[]');
      expect(file.data.prop('Grid')!.arrayLBound, '[0][0]');
      expect(file.data.prop('Grid')!.arrayUBound, '[1][1]');
    });

    test('sparse array: arrayindex element wrappers round-trip on the wrapper', () {
      final doc = _doc(
        data:
            "\t<Data classname='Obj'>\n"
            '\t\t<subprops>\n'
            "\t\t\t<Sparse classname='Nums'>\n"
            "\t\t\t\t<value lbound='[0]' ubound='[2]'>\n"
            "\t\t\t\t\t<value arrayindex='[1]'>9223372036854775806</value>\n"
            '\t\t\t\t</value>\n'
            '\t\t\t</Sparse>\n'
            '\t\t</subprops>\n'
            '\t</Data>\n',
      );
      final file = _roundTrips(doc);
      final element = file.data.prop('Sparse')!.array!.single;
      expect(element.attributes['arrayindex'], '[1]');
      expect(element.scalar, '9223372036854775806');
    });

    test('multiline <value> text keeps its literal LFs', () {
      final doc = _doc(
        data:
            "\t<Data classname='Obj'>\n"
            '\t\t<subprops>\n'
            "\t\t\t<Expr classname='ExprValue'>\n"
            '\t\t\t\t<value>line one \nline two &lt; &amp; &gt; end</value>\n'
            '\t\t\t</Expr>\n'
            '\t\t</subprops>\n'
            '\t</Data>\n',
      );
      final file = _roundTrips(doc);
      expect(file.data.prop('Expr')!.scalar, 'line one \nline two < & > end');
    });

    test('extdata children are retained as ordered attr-maps, after <value>, before <subprops>', () {
      final doc = _doc(
        data:
            "\t<Data classname='Obj'>\n"
            '\t\t<subprops>\n'
            "\t\t\t<Param name='x' classname='Num'>\n"
            '\t\t\t\t<value>0</value>\n'
            "\t\t\t\t<extdata controllername='C/C++ DLL' allowstructpassing='false' exclude='false'/>\n"
            "\t\t\t\t<extdata controllername='LabVIEW' allowclusterpassing='true' memberlabel='x'/>\n"
            '\t\t\t</Param>\n'
            '\t\t</subprops>\n'
            '\t</Data>\n',
      );
      final file = _roundTrips(doc);
      final param = file.data.prop('x')!;
      expect(param.extData, hasLength(2));
      expect(param.extData[0].keys.toList(), ['controllername', 'allowstructpassing', 'exclude']);
      expect(param.extData[1]['memberlabel'], 'x');
    });

    test('numericfmt is retained verbatim after <value>', () {
      final doc = _doc(
        data:
            "\t<Data classname='Obj'>\n"
            '\t\t<subprops>\n'
            "\t\t\t<Mask classname='Num'>\n"
            '\t\t\t\t<value>255</value>\n'
            '\t\t\t\t<numericfmt>%#x</numericfmt>\n'
            '\t\t\t</Mask>\n'
            '\t\t</subprops>\n'
            '\t</Data>\n',
      );
      final file = _roundTrips(doc);
      expect(file.data.prop('Mask')!.numericFormat, '%#x');
    });

    test("scalar <value representation='…'> attributes are retained (corpus: Int64/UInt64)", () {
      final doc = _doc(
        data:
            "\t<Data classname='Obj'>\n"
            '\t\t<subprops>\n'
            "\t\t\t<Big classname='Num'>\n"
            "\t\t\t\t<value representation='Int64'>-5</value>\n"
            '\t\t\t</Big>\n'
            '\t\t</subprops>\n'
            '\t</Data>\n',
      );
      final file = _roundTrips(doc);
      expect(file.data.prop('Big')!.valueAttributes, {'representation': 'Int64'});
      expect(file.data.prop('Big')!.scalar, '-5');
    });

    test('typedef wrapper attributes and interleaved <protected> blobs round-trip in order', () {
      final doc = _doc(
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
      );
      final file = _roundTrips(doc);
      final entries = file.typelistEntries!;
      expect(entries, hasLength(3));
      expect(entries[0].attributes['typelistordernum'], '2');
      expect(entries[1].isProtected, isTrue);
      expect(entries[1].protectedData, contains('<dfASB`]CF^aUXa]Y&4WmD>203'));
      expect(entries[2].root!.name, 'NumericLimitTest');
      // The plaintext roots still surface through the legacy lens, in order.
      expect(file.types.map((t) => t.name), ['Expression', 'NumericLimitTest']);
    });

    test('model deep-equals: write→parse preserves the model; a mutation is detected', () {
      final doc = _doc(
        data:
            "\t<Data classname='Obj'>\n"
            '\t\t<subprops>\n'
            "\t\t\t<A classname='Str'>\n"
            '\t\t\t\t<value>x</value>\n'
            '\t\t\t</A>\n'
            '\t\t</subprops>\n'
            '\t</Data>\n',
      );
      final file = parseSeqFile(_bytes(doc));
      final reparsed = parseSeqFile(writeSeqFileXml(file));
      expect(seqFileDeepEquals(file, reparsed), isTrue);
      final other = parseSeqFile(_bytes(doc.replaceFirst('<value>x</value>', '<value>y</value>')));
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

  if (!corpusSeqDir.existsSync()) {
    test('seq writer corpus round-trip', () {}, skip: 'corpus absent — run tool/fetch_seq_corpus.dart');
    return;
  }

  group('writeSeqFileXml (corpus)', () {
    // Every XML-flavor .seq in the corpus (rosetta twins included — the gate
    // is over the on-disk XML encoding, whatever produced it).
    final xmlSeqs =
        corpusSeqDir
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.toLowerCase().endsWith('.seq'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));

    test('BYTE-EXACT: write(parse(f)) == f for every XML .seq', () {
      var xmlCount = 0, exact = 0;
      final mismatches = <String>[];
      for (final f in xmlSeqs) {
        final bytes = f.readAsBytesSync();
        if (detectSeqFormat(bytes) != SeqFormat.xml) continue;
        xmlCount++;
        final rewritten = writeSeqFileXml(parseSeqFile(bytes));
        if (_bytesEqual(bytes, rewritten)) {
          exact++;
        } else {
          mismatches.add(f.path);
        }
      }
      // The fraction is the campaign's tracked metric — report it even on success.
      print('XML .seq byte-exact round-trip: $exact/$xmlCount');
      expect(xmlCount, _pinnedXmlSeqCount, reason: 'XML corpus population changed — re-verify the writer over it');
      expect(mismatches, isEmpty, reason: 'every XML corpus file must round-trip byte-exactly');
      expect(exact, _pinnedXmlSeqCount);
    });

    test('MODEL: parse(write(parse(f))) deep-equals parse(f) for every XML .seq', () {
      var checked = 0;
      for (final f in xmlSeqs) {
        final bytes = f.readAsBytesSync();
        if (detectSeqFormat(bytes) != SeqFormat.xml) continue;
        final first = parseSeqFile(bytes);
        final second = parseSeqFile(writeSeqFileXml(first));
        expect(seqFileDeepEquals(first, second), isTrue, reason: 'model drift after rewrite: ${f.path}');
        checked++;
      }
      expect(checked, _pinnedXmlSeqCount);
    });
  });
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
