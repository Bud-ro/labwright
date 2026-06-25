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
                    <value><Step typename='Statement' xsi:type='Statement' name='Pass &amp; go'>
                      <subprops>
                        <TS classname='Obj'><subprops>
                          <PreCond classname='ExprValue'><value>Locals.X == 1</value></PreCond>
                          <LoopType classname='Str'><value>FixedNumLoops</value></LoopType>
                          <PassAct classname='Str'><value>GotoStep</value></PassAct>
                          <FailAct classname='Str'><value>Next</value></FailAct>
                          <PostExpr classname='ExprValue'><value/></PostExpr>
                          <SData classname='Obj'><subprops>
                            <ViCall classname='VICall'><subprops>
                              <VIPath classname='PathValue'><value>My Computer\\Foo.vi</value></VIPath>
                            </subprops></ViCall>
                          </subprops></SData>
                        </subprops></TS>
                      </subprops>
                    </Step></value>
                    <value><Step typename='MessagePopup' name='Show "hi"'/></value>
                    <value><Step typename='Action' name='Call Sleep'>
                      <subprops><TS classname='Obj'><subprops>
                        <SData classname='Obj'><subprops>
                          <Call classname='ExternalCall'><subprops>
                            <LibPath classname='Str'><value>kernel32.dll</value></LibPath>
                            <Func classname='Str'><value>Sleep</value></Func>
                          </subprops></Call>
                        </subprops></SData>
                      </subprops></TS></subprops>
                    </Step></value>
                  </value>
                </Main>
                <Cleanup classname='Objs'><value lbound='[0]' ubound='[]'/></Cleanup>
                <Comment classname='Str'><value>a comment</value></Comment>
                <Locals classname='Obj'><subprops>
                  <Count classname='Num'><value>3</value></Count>
                  <Label classname='Str'><value>hi</value></Label>
                  <ResultList classname='Objs'><value lbound='[0]' ubound='[]'/></ResultList>
                </subprops></Locals>
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
      expect(seq.main.map((s) => s.name), ['Pass & go', 'Show "hi"', 'Call Sleep']);
      expect(seq.main.map((s) => s.type), ['Statement', 'MessagePopup', 'Action']);
      expect(seq.steps, hasLength(3)); // setup(0) + main(3) + cleanup(0)
    });

    test('decodes the module-adapter binding per step', () {
      final main = f.sequences.single.main;
      // LabVIEW VI adapter (ViCall → VIPath)
      expect(main[0].module.adapter, SeqAdapter.labView);
      expect(main[0].module.viPath, r'My Computer\Foo.vi');
      expect(main[0].module.target, r'My Computer\Foo.vi');
      // No SData → no adapter, honestly.
      expect(main[1].module.adapter, SeqAdapter.none);
      expect(main[1].module.target, isNull);
      // C/DLL adapter (Call → LibPath/Func)
      expect(main[2].module.adapter, SeqAdapter.cModule);
      expect(main[2].module.libPath, 'kernel32.dll');
      expect(main[2].module.function, 'Sleep');
      expect(main[2].module.target, 'kernel32.dll:Sleep');
    });

    test('decodes step settings from the TS sub-container', () {
      final s0 = f.sequences.single.main[0].settings;
      expect(s0.precondition, 'Locals.X == 1');
      expect(s0.loopType, 'FixedNumLoops');
      expect(s0.isLooping, isTrue);
      expect(s0.passAction, 'GotoStep');
      expect(s0.failAction, 'Next');
      expect(s0.postExpression, isNull); // empty <value/> → not set, not ""
      // A step without a TS container reports everything as unset, no throw.
      final s1 = f.sequences.single.main[1].settings;
      expect(s1.precondition, isNull);
      expect(s1.loopType, isNull);
      expect(s1.isLooping, isFalse);
    });

    test('decodes sequence locals and (empty) parameters', () {
      final seq = f.sequences.single;
      expect(seq.locals.map((v) => v.name), ['Count', 'Label', 'ResultList']);
      final count = seq.locals[0];
      expect(count.type, 'Num');
      expect(count.value, '3');
      expect(seq.locals[1].value, 'hi');
      final list = seq.locals[2];
      expect(list.type, 'Objs');
      expect(list.value, isNull); // array container, no scalar default
      expect(list.isContainer, isTrue);
      expect(seq.parameters, isEmpty); // this sequence takes none
    });

    test('measures model coverage (modeled subset of total nodes)', () {
      final c = measureCoverage(f);
      expect(c.total, greaterThan(0));
      expect(c.modeled, greaterThan(0));
      expect(c.modeled, lessThanOrEqualTo(c.total));
      expect(c.ratio, inInclusiveRange(0, 1));
      // The lens surfaces the sequence, its groups, steps, settings, module
      // fields and locals — so coverage is a meaningful fraction, not ~0.
      expect(c.ratio, greaterThan(0.1));
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
