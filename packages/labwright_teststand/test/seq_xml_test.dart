import 'dart:convert';
import 'dart:typed_data';

import 'package:labwright_teststand/labwright_teststand.dart';
import 'package:test/test.dart';

/// A minimal XML sequence file mirroring the real TestStand shape:
/// header → typelist → Data > subprops > Seq[array] > Sequence > Main[array] > Step.
const _seqXml = '''<?xml version="1.0" encoding="UTF-8"?>
<teststandfileheader type='SequenceFile' fileversion='920' productname='TestStand' productversion='2019'>
  <typelist>
    <typedef>
      <Expression classname='ExprValue'><value/></Expression>
    </typedef>
  </typelist>
  <Data classname='Obj'>
    <subprops>
      <Seq classname='Objs'>
        <value lbound='[0]' ubound='[1]'>
          <value>
            <Sequence name='MainSequence' classname='Obj'>
              <subprops>
                <Setup classname='Objs'><value lbound='[0]' ubound='[]'/></Setup>
                <Main classname='Objs'>
                  <value lbound='[0]' ubound='[2]'>
                    <value><Step typename='Statement' xsi:type='Statement' name='Pass &amp; go'/></value>
                    <value><Step typename='MessagePopup' name='Show "hi"'/></value>
                  </value>
                </Main>
                <Cleanup classname='Objs'><value lbound='[0]' ubound='[]'/></Cleanup>
                <Comment classname='Str'><value>a comment</value></Comment>
              </subprops>
            </Sequence>
          </value>
        </value>
      </Seq>
    </subprops>
  </Data>
</teststandfileheader>''';

Uint8List _bytes(String s, {bool bom = true}) =>
    Uint8List.fromList([if (bom) ...[0xef, 0xbb, 0xbf], ...utf8.encode(s)]);

void main() {
  group('parseSeqFile (XML)', () {
    late SeqFile f;
    setUp(() => f = parseSeqFile(_bytes(_seqXml)));

    test('reads the header', () {
      expect(f.header.format, SeqFormat.xml);
      expect(f.header.fileType, 'SequenceFile');
      expect(f.header.fileVersion, '920');
      expect(f.header.productName, 'TestStand');
    });

    test('reads the type list', () {
      expect(f.types, hasLength(1));
      expect(f.types.single.name, 'Expression');
      expect(f.types.single.className, 'ExprValue');
    });

    test('recovers the sequence list', () {
      expect(f.sequences, hasLength(1));
      expect(f.sequences.single.name, 'MainSequence');
    });

    test('recovers steps with names and types, in editor order', () {
      final seq = f.sequences.single;
      expect(seq.setup, isEmpty);
      expect(seq.cleanup, isEmpty);
      expect(seq.main.map((s) => s.name), ['Pass & go', 'Show "hi"']);
      expect(seq.main.map((s) => s.type), ['Statement', 'MessagePopup']);
      expect(seq.steps, hasLength(2)); // setup(0) + main(2) + cleanup(0)
    });

    test('keeps full property visibility (scalars + attributes)', () {
      final seq = f.sequences.single.raw;
      expect(seq.prop('Comment')!.scalar, 'a comment');
      expect(seq.attributes['classname'], 'Obj');
      // The empty Setup array is an array (not a scalar/leaf), honestly empty.
      expect(seq.prop('Setup')!.isArray, isTrue);
      expect(seq.prop('Setup')!.array, isEmpty);
    });
  });

  group('parseSeqFile rejects non-XML honestly', () {
    test('binary TOF1 is unsupported (not silently mis-parsed)', () {
      final bin = Uint8List.fromList([...ascii.encode('TOF1'), 0, 0, 0, 0, 0, 0, ...ascii.encode('SequenceFile'), 0]);
      expect(() => parseSeqFile(bin), throwsA(isA<UnsupportedError>()));
    });

    test('unknown bytes throw FormatException', () {
      expect(() => parseSeqFile(Uint8List.fromList([1, 2, 3])), throwsFormatException);
    });
  });
}
