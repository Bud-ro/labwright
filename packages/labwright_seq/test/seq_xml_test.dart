import 'dart:convert';
import 'dart:typed_data';

import 'package:labwright_seq/labwright_seq.dart';
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
                          <Mode classname='Str'><value>Skip</value></Mode>
                          <LoadOpt classname='Str'><value>PreloadWhenExecuted</value></LoadOpt>
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
                    <value><Step typename='NumericLimitTest' name='Check V'>
                      <subprops>
                        <Comp classname='Str'><value>GELE</value></Comp>
                        <DataSource classname='Str'><value>Step.Result.Numeric</value></DataSource>
                        <Limits classname='Obj'><subprops>
                          <Low classname='Num'><value>9</value></Low>
                          <High classname='Num'><value>11</value></High>
                          <Nominal classname='Num'><value>10</value></Nominal>
                          <ThresholdType classname='Str'><value>PERCENTAGE</value></ThresholdType>
                        </subprops></Limits>
                      </subprops>
                    </Step></value>
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

/// A minimal file with one sequence that calls itself (intra-file SequenceCall).
const _seqCallXml = '''<?xml version="1.0" encoding="UTF-8"?>
<teststandfileheader type='SequenceFile' fileversion='920' productname='TestStand'>
  <typelist/>
  <Data classname='Obj'><subprops>
    <Seq classname='Objs'><value lbound='[0]' ubound='[1]'><value>
      <Sequence name='MainSequence' classname='Obj'><subprops>
        <Main classname='Objs'><value lbound='[0]' ubound='[1]'>
          <value><Step typename='SequenceCall' name='Call Self'><subprops>
            <TS classname='Obj'><subprops><SData classname='Obj'><subprops>
              <SeqName classname='Str'><value>MainSequence</value></SeqName>
              <UseCurFile classname='Bool'><value>true</value></UseCurFile>
            </subprops></SData></subprops></TS>
          </subprops></Step></value>
        </value></Main>
      </subprops></Sequence>
    </value></value></Seq>
  </subprops></Data>
</teststandfileheader>''';

/// A sequence whose single step calls a sequence in *another* file (an external
/// SequenceCall: `SeqName` + `SFPath`, no `UseCurFile`) — the logic export marks
/// it `→ <seq> in <file>`.
const _seqExtCallXml = '''<?xml version="1.0" encoding="UTF-8"?>
<teststandfileheader type='SequenceFile' fileversion='920' productname='TestStand'>
  <typelist/>
  <Data classname='Obj'><subprops>
    <Seq classname='Objs'><value lbound='[0]' ubound='[1]'><value>
      <Sequence name='MainSequence' classname='Obj'><subprops>
        <Main classname='Objs'><value lbound='[0]' ubound='[1]'>
          <value><Step typename='SequenceCall' name='Call Other'><subprops>
            <TS classname='Obj'><subprops><SData classname='Obj'><subprops>
              <SeqName classname='Str'><value>Helper</value></SeqName>
              <SFPath classname='Str'><value>Other.seq</value></SFPath>
            </subprops></SData></subprops></TS>
          </subprops></Step></value>
        </value></Main>
      </subprops></Sequence>
    </value></value></Seq>
  </subprops></Data>
</teststandfileheader>''';

/// A minimal file whose single step carries an "Additional Results" recording
/// spec — the real shape: a call parameter holds an `AdditionalResults`
/// container whose entries (`Input`/`Output`) each carry a gating `Condition`
/// (here one empty/always, one set) plus the not-yet-decoded `Flags`/
/// `CheckedState` siblings.
const _seqAddlXml = '''<?xml version="1.0" encoding="UTF-8"?>
<teststandfileheader type='SequenceFile' fileversion='920' productname='TestStand'>
  <typelist/>
  <Data classname='Obj'><subprops>
    <Seq classname='Objs'><value lbound='[0]' ubound='[1]'><value>
      <Sequence name='MainSequence' classname='Obj'><subprops>
        <Main classname='Objs'><value lbound='[0]' ubound='[1]'>
          <value><Step typename='Action' name='Run Python'><subprops>
            <TS classname='Obj'><subprops><SData classname='Obj'><subprops>
              <Param classname='NI_PythonParameter'><subprops>
                <AdditionalResults classname='Obj'><subprops>
                  <Input classname='PythonParameterResult'><subprops>
                    <Condition classname='ExprValue'><value/></Condition>
                    <Flags classname='Num'><value>8192</value></Flags>
                    <CheckedState classname='Num'><value>1</value></CheckedState>
                  </subprops></Input>
                  <Output classname='PythonParameterResult'><subprops>
                    <Condition classname='ExprValue'><value>Locals.Save == True</value></Condition>
                    <Flags classname='Num'><value>8192</value></Flags>
                    <CheckedState classname='Num'><value>2</value></CheckedState>
                  </subprops></Output>
                </subprops></AdditionalResults>
              </subprops></Param>
            </subprops></SData></subprops></TS>
          </subprops></Step></value>
        </value></Main>
      </subprops></Sequence>
    </value></value></Seq>
  </subprops></Data>
</teststandfileheader>''';

/// A minimal file whose single step is a measurement step carrying a
/// `Measurement.Parameters` list — the real shape: each typed parameter has
/// Name / Type / Direction / Dimension / ArgumentValue (plus raw siblings).
const _seqMeasXml = '''<?xml version="1.0" encoding="UTF-8"?>
<teststandfileheader type='SequenceFile' fileversion='920' productname='TestStand'>
  <typelist/>
  <Data classname='Obj'><subprops>
    <Seq classname='Objs'><value lbound='[0]' ubound='[1]'><value>
      <Sequence name='MainSequence' classname='Obj'><subprops>
        <Main classname='Objs'><value lbound='[0]' ubound='[1]'>
          <value><Step typename='NI_Measurement' name='Measure V'><subprops>
            <Measurement classname='Obj'><subprops>
              <Parameters classname='Objs'><value lbound='[0]' ubound='[3]'>
                <value><_NAME_IN_ATTRIBUTE_ name='' classname='Obj'><subprops>
                  <Name classname='Str'><value>voltage_level</value></Name>
                  <Type classname='Str'><value>TypeDouble</value></Type>
                  <Direction classname='Str'><value>In</value></Direction>
                  <Dimension classname='Num'><value>0</value></Dimension>
                  <ArgumentValue classname='ExprValue'><value>6</value></ArgumentValue>
                  <TypeSpecialization classname='Str'><value>None</value></TypeSpecialization>
                  <Log classname='Bool'><value>true</value></Log>
                  <ID classname='Num'><value>1</value></ID>
                </subprops></_NAME_IN_ATTRIBUTE_></value>
                <value><_NAME_IN_ATTRIBUTE_ name='' classname='Obj'><subprops>
                  <Name classname='Str'><value>pin_map</value></Name>
                  <Type classname='Str'><value>TypeString</value></Type>
                  <Direction classname='Str'><value>Out</value></Direction>
                  <Dimension classname='Num'><value>1</value></Dimension>
                  <ArgumentValue classname='ExprValue'><value/></ArgumentValue>
                  <TypeSpecialization classname='Str'><value>IOResource</value></TypeSpecialization>
                  <Log classname='Bool'><value>false</value></Log>
                  <ID classname='Num'><value>2</value></ID>
                </subprops></_NAME_IN_ATTRIBUTE_></value>
                <value><_NAME_IN_ATTRIBUTE_ name='' classname='Obj'><subprops>
                  <Name classname='Str'><value>measurement_type</value></Name>
                  <Type classname='Str'><value>TypeEnum</value></Type>
                  <Direction classname='Str'><value>In</value></Direction>
                  <Dimension classname='Num'><value>0</value></Dimension>
                  <ArgumentValue classname='ExprValue'><value/></ArgumentValue>
                  <TypeSpecialization classname='Str'><value>Enum</value></TypeSpecialization>
                  <EnumDefinition classname='Objs'><value lbound='[0]' ubound='[3]'>
                    <value><NONE classname='Num'><value>0</value></NONE></value>
                    <value><DC_VOLTS classname='Num'><value>1</value></DC_VOLTS></value>
                    <value><AC_VOLTS classname='Num'><value>2</value></AC_VOLTS></value>
                  </value></EnumDefinition>
                  <ID classname='Num'><value>3</value></ID>
                </subprops></_NAME_IN_ATTRIBUTE_></value>
              </value></Parameters>
            </subprops></Measurement>
          </subprops></Step></value>
        </value></Main>
      </subprops></Sequence>
    </value></value></Seq>
  </subprops></Data>
</teststandfileheader>''';

/// A Python-adapter step whose call binds parameters under
/// `SData.PythonCall.Parameters` — the Python form stores the bound value as
/// `ArgumentValue` (not the C adapter's `ArgVal`) and carries no Direction.
const _seqPyCallXml = '''<?xml version="1.0" encoding="UTF-8"?>
<teststandfileheader type='SequenceFile' fileversion='920' productname='TestStand'>
  <typelist/>
  <Data classname='Obj'><subprops>
    <Seq classname='Objs'><value lbound='[0]' ubound='[1]'><value>
      <Sequence name='MainSequence' classname='Obj'><subprops>
        <Main classname='Objs'><value lbound='[0]' ubound='[1]'>
          <value><Step typename='Action' name='Run measurement'><subprops>
            <TS classname='Obj'><subprops><SData classname='Obj'><subprops>
              <PythonCall classname='Obj'><subprops>
                <Parameters classname='Objs'><value lbound='[0]' ubound='[2]'>
                  <value><_NAME_IN_ATTRIBUTE_ name='' classname='Obj'><subprops>
                    <Name classname='Str'><value>sequence_context</value></Name>
                    <Type classname='Num'><value>7</value></Type>
                    <ArgumentValue classname='ExprValue'><value>ThisContext</value></ArgumentValue>
                  </subprops></_NAME_IN_ATTRIBUTE_></value>
                  <value><_NAME_IN_ATTRIBUTE_ name='' classname='Obj'><subprops>
                    <Name classname='Str'><value>Return Value</value></Name>
                    <Type classname='Num'><value>7</value></Type>
                    <ArgumentValue classname='ExprValue'><value/></ArgumentValue>
                  </subprops></_NAME_IN_ATTRIBUTE_></value>
                </value></Parameters>
              </subprops></PythonCall>
            </subprops></SData></subprops></TS>
          </subprops></Step></value>
        </value></Main>
      </subprops></Sequence>
    </value></value></Seq>
  </subprops></Data>
</teststandfileheader>''';

/// A step using a custom condition: `CustExpr` chooses the branch, `CustTrueAct`
/// / `CustFalseAct` are the per-branch actions (same vocabulary as PassAct).
const _seqCustCondXml = '''<?xml version="1.0" encoding="UTF-8"?>
<teststandfileheader type='SequenceFile' fileversion='920' productname='TestStand'>
  <typelist/>
  <Data classname='Obj'><subprops>
    <Seq classname='Objs'><value lbound='[0]' ubound='[1]'><value>
      <Sequence name='MainSequence' classname='Obj'><subprops>
        <Main classname='Objs'><value lbound='[0]' ubound='[1]'>
          <value><Step typename='Action' name='Branch'><subprops>
            <TS classname='Obj'><subprops>
              <CustExpr classname='ExprValue'><value>Locals.x &gt; 0</value></CustExpr>
              <CustTrueAct classname='Str'><value>GotoStep</value></CustTrueAct>
              <CustFalseAct classname='Str'><value>Next</value></CustFalseAct>
            </subprops></TS>
          </subprops></Step></value>
        </value></Main>
      </subprops></Sequence>
    </value></value></Seq>
  </subprops></Data>
</teststandfileheader>''';

/// A step whose `Result` slot carries a recorded (non-default) outcome: a
/// status, report text, and an error with code/message. (In real files these
/// are defaults; the fixture exercises the StepResult lens + dump surfacing.)
const _seqResultXml = '''<?xml version="1.0" encoding="UTF-8"?>
<teststandfileheader type='SequenceFile' fileversion='920' productname='TestStand'>
  <typelist/>
  <Data classname='Obj'><subprops>
    <Seq classname='Objs'><value lbound='[0]' ubound='[1]'><value>
      <Sequence name='MainSequence' classname='Obj'><subprops>
        <Main classname='Objs'><value lbound='[0]' ubound='[1]'>
          <value><Step typename='Action' name='Ran'><subprops>
            <Result classname='Obj'><subprops>
              <Status classname='Str'><value>Failed</value></Status>
              <ReportText classname='Str'><value>measured 5V</value></ReportText>
              <Error classname='Obj'><subprops>
                <Code classname='Num'><value>-17</value></Code>
                <Msg classname='Str'><value>boom</value></Msg>
                <Occurred classname='Bool'><value>true</value></Occurred>
              </subprops></Error>
            </subprops></Result>
          </subprops></Step></value>
        </value></Main>
      </subprops></Sequence>
    </value></value></Seq>
  </subprops></Data>
</teststandfileheader>''';

/// A step configured to acquire a named mutex for synchronization.
const _seqMutexXml = '''<?xml version="1.0" encoding="UTF-8"?>
<teststandfileheader type='SequenceFile' fileversion='920' productname='TestStand'>
  <typelist/>
  <Data classname='Obj'><subprops>
    <Seq classname='Objs'><value lbound='[0]' ubound='[1]'><value>
      <Sequence name='MainSequence' classname='Obj'><subprops>
        <Main classname='Objs'><value lbound='[0]' ubound='[1]'>
          <value><Step typename='Action' name='Locked'><subprops>
            <TS classname='Obj'><subprops>
              <UseMutex classname='Bool'><value>true</value></UseMutex>
              <MutexNameOrRef classname='ExprValue'><value>"InstrumentLock"</value></MutexNameOrRef>
            </subprops></TS>
          </subprops></Step></value>
        </value></Main>
      </subprops></Sequence>
    </value></value></Seq>
  </subprops></Data>
</teststandfileheader>''';

Uint8List _bytes(String s) =>
    Uint8List.fromList([0xef, 0xbb, 0xbf, ...utf8.encode(s)]);

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
      expect(seq.main.map((s) => s.name), ['Pass & go', 'Show "hi"', 'Check V', 'Call Sleep']);
      expect(seq.main.map((s) => s.type), ['Statement', 'MessagePopup', 'NumericLimitTest', 'Action']);
      expect(seq.steps, hasLength(4));
    });

    test('decodes the module-adapter binding per step', () {
      final main = f.sequences.single.main;
      expect(main[0].module.adapter, SeqAdapter.labView);
      expect(main[0].module.viPath, r'My Computer\Foo.vi');
      expect(main[0].module.target, r'My Computer\Foo.vi');
      expect(main[1].module.adapter, SeqAdapter.none);
      expect(main[1].module.target, isNull);
      expect(main[3].module.adapter, SeqAdapter.cModule);
      expect(main[3].module.libPath, 'kernel32.dll');
      expect(main[3].module.function, 'Sleep');
      expect(main[3].module.target, 'kernel32.dll:Sleep');
    });

    test('decodes limit-test pass/fail criteria', () {
      final main = f.sequences.single.main;
      final lim = main[2].limits!;
      expect(lim.comparison, 'GELE');
      expect(lim.low, '9');
      expect(lim.high, '11');
      expect(lim.nominal, '10');
      expect(lim.thresholdType, 'PERCENTAGE');
      expect(lim.dataSource, 'Step.Result.Numeric');
      expect(lim.summary, 'GELE [9, 11]');
      expect(main[0].limits, isNull);
    });

    test('decodes step settings from the TS sub-container', () {
      final s0 = f.sequences.single.main[0].settings;
      expect(s0.precondition, 'Locals.X == 1');
      expect(s0.loopType, 'FixedNumLoops');
      expect(s0.isLooping, isTrue);
      expect(s0.passAction, 'GotoStep');
      expect(s0.failAction, 'Next');
      expect(s0.postExpression, isNull);
      expect(s0.mode, 'Skip');
      expect(s0.isNormalMode, isFalse);
      expect(s0.loadOption, 'PreloadWhenExecuted');
      final s1 = f.sequences.single.main[1].settings;
      expect(s1.precondition, isNull);
      expect(s1.loopType, isNull);
      expect(s1.isLooping, isFalse);
      expect(s1.mode, isNull);
      expect(s1.isNormalMode, isTrue);
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
      expect(list.value, isNull);
      expect(list.isContainer, isTrue);
      expect(list.isArray, isTrue);
      expect(list.containerCount, 0);
      expect(count.isArray, isFalse);
      expect(count.containerCount, isNull);
      expect(seq.parameters, isEmpty);
    });

    test('dumpSeqFile renders a faithful text view', () {
      final out = dumpSeqFile(f);
      expect(out, contains('SequenceFile'));
      expect(out, contains('Sequence: MainSequence'));
      expect(out, contains('Pass & go [Statement]'));
      expect(out, contains('Call Sleep [Action]'));
      expect(out, contains(r'labView: My Computer\Foo.vi'));
      expect(out, contains('cModule: kernel32.dll:Sleep'));
      expect(out, contains('limits GELE [9, 11]'));
      expect(out, contains('mode Skip'));
      expect(out, contains('loop FixedNumLoops'));
      expect(out, contains('if Locals.X == 1'));
      expect(out, contains('Count : Num = 3'));
    });

    test('resolves intra-file SequenceCall targets', () {
      final cf = parseSeqFile(_bytes(_seqCallXml));
      final call = cf.sequences.single.main.single;
      expect(call.module.adapter, SeqAdapter.sequenceCall);
      expect(call.module.sequenceName, 'MainSequence');
      expect(cf.resolveCall(call)?.name, 'MainSequence');
      expect(cf.sequence('Nope'), isNull);
      expect(dumpSeqFile(cf), contains('sequenceCall: MainSequence (in this file)'));
    });

    test('measures model coverage (modeled subset of total nodes)', () {
      final c = measureCoverage(f);
      expect(c.total, greaterThan(0));
      expect(c.modeled, greaterThan(0));
      expect(c.modeled, lessThanOrEqualTo(c.total));
      expect(c.ratio, inInclusiveRange(0, 1));
      expect(c.ratio, greaterThan(0.1));
    });

    test('keeps full property visibility (scalars + attributes)', () {
      final seq = f.sequences.single.raw;
      expect(seq.prop('Comment')!.scalar, 'a comment');
      expect(seq.attributes['classname'], 'Obj');
      expect(seq.prop('Setup')!.isArray, isTrue);
      expect(seq.prop('Setup')!.array, isEmpty);
    });
  });

  group('StepGroup', () {
    test('keys are the .seq property names, in execution order', () {
      expect(StepGroup.values.map((g) => g.key), ['Setup', 'Main', 'Cleanup']);
    });

    test('stepsIn matches the named getters', () {
      final seq = parseSeqFile(_bytes(_seqXml)).sequences.single;
      List<String> names(List<Step> s) => [for (final x in s) x.name];
      expect(names(seq.stepsIn(StepGroup.setup)), names(seq.setup));
      expect(names(seq.stepsIn(StepGroup.main)), names(seq.main));
      expect(names(seq.stepsIn(StepGroup.cleanup)), names(seq.cleanup));
      expect(
        names(seq.steps),
        [...names(seq.setup), ...names(seq.main), ...names(seq.cleanup)],
      );
    });
  });

  group('Additional Results recording spec', () {
    late Step step;
    setUp(() {
      final f = parseSeqFile(_bytes(_seqAddlXml));
      step = f.sequences.single.main.single;
    });

    test('recovers each recorded entry and its gating Condition', () {
      final addl = step.additionalResults;
      expect(addl.map((a) => a.name), ['Input', 'Output']);
      expect(addl.map((a) => a.kind),
          ['PythonParameterResult', 'PythonParameterResult']);
      expect(addl[0].condition, isNull);
      expect(addl[1].condition, 'Locals.Save == True');
      expect(addl[0].raw.prop('Flags')?.scalar, '8192');
      expect(addl[1].raw.prop('CheckedState')?.scalar, '2');
    });

    test('a step without the spec reports an empty list', () {
      final f = parseSeqFile(_bytes(_seqCallXml));
      expect(f.sequences.single.main.single.additionalResults, isEmpty);
    });

    test('the dump surfaces the recorded results with conditions', () {
      final out = dumpSeqFile(parseSeqFile(_bytes(_seqAddlXml)));
      expect(out, contains('{+results: Input, Output if Locals.Save == True}'));
    });

    test('coverage marks the container, entries and their Conditions', () {
      final f = parseSeqFile(_bytes(_seqAddlXml));
      final cov = measureCoverage(f);
      expect(cov.modeled, greaterThan(0));
      final addl = f.sequences.single.main.single.additionalResults;
      expect(addl, hasLength(2));
    });
  });

  group('Measurement step parameters', () {
    late Step step;
    setUp(() {
      step = parseSeqFile(_bytes(_seqMeasXml)).sequences.single.main.single;
    });

    test('recovers each typed parameter (name/type/direction/dim/value)', () {
      final p = step.measurementParameters;
      expect(p, hasLength(3));
      expect(p[0].name, 'voltage_level');
      expect(p[0].dataType, 'TypeDouble');
      expect(p[0].direction, 'In');
      expect(p[0].isArray, isFalse);
      expect(p[0].value, '6');
      expect(p[1].name, 'pin_map');
      expect(p[1].direction, 'Out');
      expect(p[1].isArray, isTrue);
      expect(p[1].value, isNull);
    });

    test('recovers TypeSpecialization (refinement) and the Log flag', () {
      final p = step.measurementParameters;
      expect(p[0].typeSpecialization, isNull);
      expect(p[0].logged, isTrue);
      expect(p[1].typeSpecialization, 'IOResource');
      expect(p[1].logged, isFalse);
    });

    test('recovers the enum allowed-value list for a TypeEnum param', () {
      final p = step.measurementParameters;
      expect(p[2].name, 'measurement_type');
      expect(p[2].dataType, 'TypeEnum');
      final ev = p[2].enumValues;
      expect(ev.map((e) => e.name), ['NONE', 'DC_VOLTS', 'AC_VOLTS']);
      expect(ev.map((e) => e.value), ['0', '1', '2']);
      expect(p[0].enumValues, isEmpty);
    });

    test('a non-measurement step reports no measurement parameters', () {
      final s = parseSeqFile(_bytes(_seqCallXml)).sequences.single.main.single;
      expect(s.measurementParameters, isEmpty);
    });

    test('the dump surfaces measurement params with type, refinement, logging', () {
      final out = dumpSeqFile(parseSeqFile(_bytes(_seqMeasXml)));
      expect(out, contains('voltage_level in TypeDouble = 6'));
      expect(out, contains('pin_map out TypeString (IOResource)[] [not logged]'));
      expect(out, contains('{NONE=0, DC_VOLTS=1, AC_VOLTS=2}'));
    });

    test('coverage credits the measurement-parameter cluster', () {
      final cov = measureCoverage(parseSeqFile(_bytes(_seqMeasXml)));
      expect(cov.modeled, greaterThan(8));
    });
  });

  group('Python adapter call parameters', () {
    late StepModule m;
    setUp(() {
      m = parseSeqFile(_bytes(_seqPyCallXml)).sequences.single.main.single.module;
    });

    test('recognizes the Python adapter', () {
      expect(m.adapter, SeqAdapter.python);
    });

    test('recovers Python call params (Name + ArgumentValue bound value)', () {
      final args = m.callParameters;
      expect(args.map((a) => a.name), ['sequence_context', 'Return Value']);
      expect(args[0].boundExpression, 'ThisContext');
      expect(args[1].boundExpression, isNull);
      expect(args[0].direction, isNull);
    });

    test('the dump shows the Python call args', () {
      final out = dumpSeqFile(parseSeqFile(_bytes(_seqPyCallXml)));
      expect(out, contains('sequence_context←ThisContext'));
    });
  });

  group('Custom-condition flow control', () {
    late StepSettings s;
    setUp(() {
      s = parseSeqFile(_bytes(_seqCustCondXml)).sequences.single.main.single.settings;
    });

    test('recovers the custom expression and its true/false actions', () {
      expect(s.customExpression, 'Locals.x > 0');
      expect(s.customTrueAction, 'GotoStep');
      expect(s.customFalseAction, 'Next');
    });

    test('the dump surfaces the custom condition', () {
      final out = dumpSeqFile(parseSeqFile(_bytes(_seqCustCondXml)));
      expect(out, contains('cust-cond Locals.x > 0'));
    });

    test('a step without a custom condition reports nulls', () {
      final s0 = parseSeqFile(_bytes(_seqXml)).sequences.single.main.first.settings;
      expect(s0.customExpression, isNull);
      expect(s0.customTrueAction, isNull);
    });
  });

  group('Step result outcome record', () {
    test('recovers status / report text / error from a recorded Result', () {
      final step = parseSeqFile(_bytes(_seqResultXml)).sequences.single.main.single;
      final r = step.result!;
      expect(r.status, 'Failed');
      expect(r.reportText, 'measured 5V');
      expect(r.errorOccurred, isTrue);
      expect(r.errorCode, '-17');
      expect(r.errorMessage, 'boom');
      expect(r.hasRecordedOutcome, isTrue);
      final out = dumpSeqFile(parseSeqFile(_bytes(_seqResultXml)));
      expect(out, contains('{result: status Failed; error -17 "boom"; report "measured 5V"}'));
    });

    test('a default (un-run) Result reads as no recorded outcome', () {
      final step = parseSeqFile(_bytes(_seqMeasXml)).sequences.single.main.single;
      final r = step.result;
      if (r != null) {
        expect(r.hasRecordedOutcome, isFalse);
      }
      expect(dumpSeqFile(parseSeqFile(_bytes(_seqMeasXml))), isNot(contains('{result:')));
    });
  });

  group('Step mutex synchronization', () {
    test('recovers UseMutex + MutexNameOrRef and surfaces it in the dump', () {
      final s = parseSeqFile(_bytes(_seqMutexXml)).sequences.single.main.single.settings;
      expect(s.usesMutex, isTrue);
      expect(s.mutexName, '"InstrumentLock"');
      expect(dumpSeqFile(parseSeqFile(_bytes(_seqMutexXml))),
          contains('mutex "InstrumentLock"'));
    });

    test('a step without a mutex reports false/null and no dump note', () {
      final s = parseSeqFile(_bytes(_seqXml)).sequences.single.main.first.settings;
      expect(s.usesMutex, anyOf(isNull, isFalse));
      expect(dumpSeqFile(parseSeqFile(_bytes(_seqXml))), isNot(contains('mutex')));
    });
  });

  group('type-list typedef recovery', () {
    test('recovers a typedef name, base class and declared fields', () {
      final f = parseSeqFile(_bytes(_seqTypeDefXml));
      expect(f.typeDefs, hasLength(1));
      final t = f.typeDefs.single;
      expect(t.name, 'MeasCluster');
      expect(t.baseClass, 'Obj');
      expect(t.fields.map((x) => x.name), ['Voltage', 'Label']);
      expect(t.fields.map((x) => x.type), ['Number', 'String']);
    });

    test('a scalar typedef recovers an empty field list (no fabrication)', () {
      final t = parseSeqFile(_bytes(_seqXml)).typeDefs.single;
      expect(t.name, 'Expression');
      expect(t.baseClass, 'ExprValue');
      expect(t.fields, isEmpty);
    });

    test('the dump lists the Types section with fields', () {
      final dump = dumpSeqFile(parseSeqFile(_bytes(_seqTypeDefXml)));
      expect(dump, contains('Types (1):'));
      expect(dump, contains('MeasCluster : Obj'));
      expect(dump, contains('.Voltage [Number]'));
      expect(dump, contains('.Label [String]'));
    });
  });

  group('LabVIEW VI-call recovery', () {
    late StepModule m;
    setUp(() {
      m = parseSeqFile(_bytes(_seqViCallXml)).sequences.single.main.single.module;
    });

    test('recovers the VI-call descriptor', () {
      expect(m.adapter, SeqAdapter.labView);
      expect(m.viPath, r'My Computer\NIDCPower.vi');
      expect(m.viNamespace, 'NIDCPower.lvlib');
      expect(m.viProjectPath, 'NIDCPower.lvproj');
    });

    test('recovers the connector-pane parameters in order', () {
      final p = m.viParameters;
      expect(p.map((x) => x.name), ['sequence context', 'error out']);
      expect(p.map((x) => x.displayType), ['Object Reference', 'Container']);
      expect(p.map((x) => x.connectorNumber), [11, 0]);
      expect(p.first.boundExpression, 'ThisContext');
      expect(p[1].boundExpression, 'Step.Result.Error');
    });

    test('the dump shows the library and connector pane', () {
      final dump = dumpSeqFile(parseSeqFile(_bytes(_seqViCallXml)));
      expect(dump, contains('{vi: lib NIDCPower.lvlib, proj NIDCPower.lvproj}'));
      expect(dump, contains('#11 sequence context (Object Reference)←ThisContext'));
      expect(dump, contains('#0 error out (Container)←Step.Result.Error'));
    });
  });

  group('Python call descriptor recovery', () {
    late StepModule m;
    setUp(() {
      m = parseSeqFile(_bytes(_seqPyXml)).sequences.single.main.single.module;
    });

    test('recovers the called module/function and interpreter', () {
      expect(m.adapter, SeqAdapter.python);
      expect(m.pythonFunction, 'create_instrument_sessions');
      expect(m.pythonModulePath, r'..\measurements\smu\test.py');
      expect(m.pythonVersion, '3.9');
      expect(m.pythonVenvPath, r'..\measurements\smu\.venv');
      expect(m.pythonClassName, isNull);
      expect(m.target, 'create_instrument_sessions');
    });

    test('the dump shows the python target and module chip', () {
      final dump = dumpSeqFile(parseSeqFile(_bytes(_seqPyXml)));
      expect(dump, contains('-> python: create_instrument_sessions'));
      expect(dump, contains(r'{python: mod ..\measurements\smu\test.py, py 3.9}'));
    });
  });

  group('measurement plug-in resource set', () {
    test('recovers the pin map and STS file lists', () {
      final mp = parseSeqFile(_bytes(_seqPluginsXml)).measurementPlugIns!;
      expect(mp.pinMapPath, 'PinMap.pinmap');
      expect(mp.monitoringEnabled, isTrue);
      expect(mp.specificationFiles, ['Specifications.specs']);
      expect(mp.levelsFiles, ['PinLevels.digilevels']);
      expect(mp.timingFiles, ['Timing.digitiming']);
      expect(mp.patternFiles, ['Pattern.digipat']);
      expect(mp.isNotEmpty, isTrue);
    });

    test('a file without the block reports null (no fabrication)', () {
      expect(parseSeqFile(_bytes(_seqXml)).measurementPlugIns, isNull);
    });

    test('the dump lists the plug-in files', () {
      final dump = dumpSeqFile(parseSeqFile(_bytes(_seqPluginsXml)));
      expect(dump, contains('Measurement plug-ins:'));
      expect(dump, contains('pin map: PinMap.pinmap'));
      expect(dump, contains('specifications: Specifications.specs'));
      expect(dump, contains('patterns: Pattern.digipat'));
    });
  });

  group('flow-control structured-logic export', () {
    late SeqFile f;
    setUp(() => f = parseSeqFile(_bytes(_seqFlowXml)));

    test('recognizes NI_Flow_* steps as FlowControl constructs', () {
      final steps = f.sequences.single.main;
      final kinds = steps.map((s) => s.flowControl?.kind).toList();
      expect(kinds, [
        FlowKind.ifBlock,
        null,
        FlowKind.end,
        FlowKind.forEach,
        null,
        FlowKind.end,
      ]);
    });

    test('recovers the branch/loop condition expressions (flat fields)', () {
      final steps = f.sequences.single.main;
      expect(steps[0].flowControl!.condition, 'Locals.X > 0');
      expect(steps[0].flowControl!.header, 'if (Locals.X > 0)');
      final each = steps[3].flowControl!;
      expect(each.arrayExpr, 'Locals.Items');
      expect(each.arrayElement, 'Locals.Item');
      expect(each.header, 'for each (Locals.Item in Locals.Items)');
    });

    test('exportSequenceLogic nests the blocks with matching braces', () {
      final out = exportSequenceLogic(f);
      expect(out, contains('if (Locals.X > 0) {'));
      expect(out, contains('for each (Locals.Item in Locals.Items) {'));
      expect(out, contains('\n      Do Work'));
      expect('}'.allMatches(out).length, 2);
    });

    test('a non-flow step has no FlowControl (no fabrication)', () {
      final s = parseSeqFile(_bytes(_seqXml)).sequences.single.main.first;
      expect(s.flowControl, isNull);
    });

    test('the dump carries a Sequence logic section', () {
      final dump = dumpSeqFile(f);
      expect(dump, contains('=== Sequence logic ==='));
      expect(dump, contains('if (Locals.X > 0) {'));
    });
  });

  group('looping step in the logic export', () {
    const loopXml = '''<?xml version="1.0" encoding="UTF-8"?>
<teststandfileheader type='SequenceFile' fileversion='920' productname='TestStand'>
  <typelist/>
  <Data classname='Obj'><subprops>
    <Seq classname='Objs'><value lbound='[0]' ubound='[1]'><value>
      <Sequence name='MainSequence' classname='Obj'><subprops>
        <Main classname='Objs'><value lbound='[0]' ubound='[2]'>
          <value><Step typename='Action' name='Spin'><subprops>
            <TS classname='Obj'><subprops>
              <LoopType classname='Str'><value>FixedNumLoops</value></LoopType>
              <LoopWhile classname='ExprValue'><value>RunState.LoopIndex &lt; 10</value></LoopWhile>
            </subprops></TS>
          </subprops></Step></value>
          <value><Step typename='Action' name='Once'/></value>
        </value></Main>
      </subprops></Sequence>
    </value></value></Seq>
  </subprops></Data>
</teststandfileheader>''';

    test('annotates a looping step with its type + while condition', () {
      final out = exportSequenceLogic(parseSeqFile(_bytes(loopXml)));
      expect(out, contains('[loop FixedNumLoops while RunState.LoopIndex < 10]'));
    });

    test('a non-looping step gets no loop annotation', () {
      final out = exportSequenceLogic(parseSeqFile(_bytes(loopXml)));
      final onceLine = out.split('\n').firstWhere((l) => l.contains('Once'));
      expect(onceLine, isNot(contains('[loop')));
    });
  });

  group('per-sequence summary header in the logic export', () {
    test('summarizes step/param/local counts with correct pluralization', () {
      final seq = parseSeqFile(_bytes(_seqXml)).sequences.single;
      final out = exportSequenceLogic(parseSeqFile(_bytes(_seqXml)));
      final header = out.split('\n').first;
      expect(header, startsWith('sequence MainSequence:'));
      expect(header, contains('${seq.steps.length} steps'));
      expect(header, contains('${seq.locals.length} locals'));
      expect(header, isNot(contains('param')));
    });

    test('a single-step sequence uses the singular form', () {
      final out = exportSequenceLogic(parseSeqFile(_bytes(_seqCallXml)));
      expect(out.split('\n').first, contains('// 1 step'));
      expect(out.split('\n').first, isNot(contains('1 steps')));
    });

    test('renders typed parameters as a function-style signature', () {
      final header =
          exportSequenceLogic(parseSeqFile(_bytes(_seqParamsXml))).split('\n').first;
      expect(header,
          startsWith('sequence MainSequence(TestSocketName: Str, Voltage: Num = 5):'));
      expect(header, isNot(contains('param')));
      expect(header, contains('// 1 step'));
    });

    test('a parameterless sequence has no empty parens', () {
      final header =
          exportSequenceLogic(parseSeqFile(_bytes(_seqXml))).split('\n').first;
      expect(header, startsWith('sequence MainSequence:'));
      expect(header, isNot(contains('()')));
    });
  });

  group('SequenceCall cross-file reference in the logic export', () {
    test('an external call shows the target sequence and its file', () {
      final out = exportSequenceLogic(parseSeqFile(_bytes(_seqExtCallXml)));
      expect(out, contains('Call Other → Helper in Other.seq'));
    });

    test('an in-file (self) call shows the target without a file', () {
      final out = exportSequenceLogic(parseSeqFile(_bytes(_seqCallXml)));
      expect(out, contains('Call Self → MainSequence'));
      final line = out.split('\n').firstWhere((l) => l.contains('Call Self'));
      expect(line, isNot(contains(' in ')));
    });
  });

  group('pass/fail jump in the logic export', () {
    test('annotates a non-default fail jump with its target', () {
      final out = exportSequenceLogic(parseSeqFile(_bytes(_seqJumpXml)));
      expect(out, contains('Check V'));
      expect(out, contains('[on fail → <Cleanup>]'));
    });

    test('a fall-through (Next/Next) step gets no jump annotation', () {
      final out = exportSequenceLogic(parseSeqFile(_bytes(_seqJumpXml)));
      final plainLine =
          out.split('\n').firstWhere((l) => l.contains('Plain'));
      expect(plainLine, isNot(contains('on fail')));
      expect(plainLine, isNot(contains('on pass')));
    });
  });

  group('parseSeqFile rejects non-XML honestly', () {
    test('a binary TOF1 header without an inflatable body throws FormatException', () {
      // Real binary TOF1 files now parse to the partial typed model (see
      // binary_parse_seq_file_test.dart, oracle-validated); a header-only stub
      // with no zlib body must still be refused, not guessed at.
      final bin = Uint8List.fromList([...ascii.encode('TOF1'), 0, 0, 0, 0, 0, 0, ...ascii.encode('SequenceFile'), 0]);
      expect(() => parseSeqFile(bin), throwsFormatException);
    });

    test('unknown bytes throw FormatException', () {
      expect(() => parseSeqFile(Uint8List.fromList([1, 2, 3])), throwsFormatException);
    });
  });
}

/// A file declaring a Semiconductor-Test-System resource set under
/// `FileGlobalDefaults > MeasurementPlugIns` — the real corpus shape.
const _seqPluginsXml = '''<?xml version="1.0" encoding="UTF-8"?>
<teststandfileheader type='SequenceFile' fileversion='920' productname='TestStand'>
  <typelist/>
  <Data classname='Obj'><subprops>
    <Seq classname='Objs'><value lbound='[0]' ubound='[]'/></Seq>
    <FileGlobalDefaults classname='Obj'><subprops>
      <MeasurementPlugIns classname='Obj'><subprops>
        <EnableMonitoring classname='Bool'><value>true</value></EnableMonitoring>
        <PinMapPath classname='PathValue'><value>PinMap.pinmap</value></PinMapPath>
        <SpecificationsFilePaths classname='Strs'><value lbound='[0]' ubound='[1]'><value>Specifications.specs</value></value></SpecificationsFilePaths>
        <LevelsFilePaths classname='Strs'><value lbound='[0]' ubound='[1]'><value>PinLevels.digilevels</value></value></LevelsFilePaths>
        <TimingFilePaths classname='Strs'><value lbound='[0]' ubound='[1]'><value>Timing.digitiming</value></value></TimingFilePaths>
        <PatternFilePaths classname='Strs'><value lbound='[0]' ubound='[1]'><value>Pattern.digipat</value></value></PatternFilePaths>
      </subprops></MeasurementPlugIns>
    </subprops></FileGlobalDefaults>
  </subprops></Data>
</teststandfileheader>''';

/// A Python (CPythonModule) step whose `SData.PythonCall` names the module,
/// function and interpreter — the real shape probed from the corpus.
const _seqPyXml = '''<?xml version="1.0" encoding="UTF-8"?>
<teststandfileheader type='SequenceFile' fileversion='920' productname='TestStand'>
  <typelist/>
  <Data classname='Obj'><subprops>
    <Seq classname='Objs'><value lbound='[0]' ubound='[1]'><value>
      <Sequence name='MainSequence' classname='Obj'><subprops>
        <Main classname='Objs'><value lbound='[0]' ubound='[1]'>
          <value><Step typename='Action' name='Create sessions'><subprops>
            <TS classname='Obj'><subprops>
            <SData classname='CPythonModule'><subprops>
              <PythonCall classname='CPythonCall'><subprops>
                <PythonVersion classname='Str'><value>3.9</value></PythonVersion>
                <PythonVirtualEnvironmentPath classname='Str'><value>..\\measurements\\smu\\.venv</value></PythonVirtualEnvironmentPath>
                <ModulePath classname='PathValue'><value>..\\measurements\\smu\\test.py</value></ModulePath>
                <ClassName classname='Str'><value/></ClassName>
                <FunctionOrAttributeName classname='Str'><value>create_instrument_sessions</value></FunctionOrAttributeName>
                <OperationType classname='Num'><value>1</value></OperationType>
              </subprops></PythonCall>
            </subprops></SData>
            </subprops></TS>
          </subprops></Step></value>
        </value></Main>
      </subprops></Sequence>
    </value></value></Seq>
  </subprops></Data>
</teststandfileheader>''';

/// A LabVIEW (FGModule) step whose `SData.ViCall` carries the VI descriptor and
/// a `Parms` connector pane — the real shape probed from the corpus.
const _seqViCallXml = '''<?xml version="1.0" encoding="UTF-8"?>
<teststandfileheader type='SequenceFile' fileversion='920' productname='TestStand'>
  <typelist/>
  <Data classname='Obj'><subprops>
    <Seq classname='Objs'><value lbound='[0]' ubound='[1]'><value>
      <Sequence name='MainSequence' classname='Obj'><subprops>
        <Main classname='Objs'><value lbound='[0]' ubound='[1]'>
          <value><Step typename='Action' name='Init DCPower'><subprops>
            <TS classname='Obj'><subprops>
            <SData classname='FGModule'><subprops>
              <ViCall classname='VICall'><subprops>
                <VIPath classname='PathValue'><value>My Computer\\NIDCPower.vi</value></VIPath>
                <Namespace classname='Str'><value>NIDCPower.lvlib</value></Namespace>
                <ProjectPath classname='PathValue'><value>NIDCPower.lvproj</value></ProjectPath>
                <Parms classname='Objs'><value lbound='[0]' ubound='[2]'>
                  <value><_NAME_IN_ATTRIBUTE_ name='' classname='Obj'><subprops>
                    <Label classname='Str'><value>sequence context</value></Label>
                    <DisplayType classname='Str'><value>Object Reference</value></DisplayType>
                    <ArgVal classname='ExprValue'><value>ThisContext</value></ArgVal>
                    <Direction classname='Num'><value>0</value></Direction>
                    <ConnectorNumber classname='Num'><value>11</value></ConnectorNumber>
                  </subprops></_NAME_IN_ATTRIBUTE_></value>
                  <value><_NAME_IN_ATTRIBUTE_ name='' classname='Obj'><subprops>
                    <Label classname='Str'><value>error out</value></Label>
                    <DisplayType classname='Str'><value>Container</value></DisplayType>
                    <ArgVal classname='ExprValue'><value>Step.Result.Error</value></ArgVal>
                    <Direction classname='Num'><value>0</value></Direction>
                    <ConnectorNumber classname='Num'><value>0</value></ConnectorNumber>
                  </subprops></_NAME_IN_ATTRIBUTE_></value>
                </value></Parms>
              </subprops></ViCall>
            </subprops></SData>
            </subprops></TS>
          </subprops></Step></value>
        </value></Main>
      </subprops></Sequence>
    </value></value></Seq>
  </subprops></Data>
</teststandfileheader>''';

/// A sequence with a test step that jumps to the `<Cleanup>` bookmark on
/// failure (`FailAct=Goto` + `FailActTarget`) — the recovered pass/fail jump the
/// logic export annotates as `[on fail → <Cleanup>]`. A second step falls
/// through (Next/Next) and gets no jump annotation.
const _seqJumpXml = '''<?xml version="1.0" encoding="UTF-8"?>
<teststandfileheader type='SequenceFile' fileversion='920' productname='TestStand'>
  <typelist/>
  <Data classname='Obj'><subprops>
    <Seq classname='Objs'><value lbound='[0]' ubound='[1]'><value>
      <Sequence name='MainSequence' classname='Obj'><subprops>
        <Main classname='Objs'><value lbound='[0]' ubound='[2]'>
          <value><Step typename='NumericLimitTest' name='Check V'><subprops>
            <TS classname='Obj'><subprops>
              <PassAct classname='Str'><value>Next</value></PassAct>
              <FailAct classname='Str'><value>Goto</value></FailAct>
              <FailActTarget classname='ExprValue'><value>"&lt;Cleanup&gt;"</value></FailActTarget>
            </subprops></TS>
          </subprops></Step></value>
          <value><Step typename='Action' name='Plain'/></value>
        </value></Main>
      </subprops></Sequence>
    </value></value></Seq>
  </subprops></Data>
</teststandfileheader>''';

/// A sequence that declares two typed parameters (one with a default value) —
/// the logic export renders them as a function-style signature.
const _seqParamsXml = '''<?xml version="1.0" encoding="UTF-8"?>
<teststandfileheader type='SequenceFile' fileversion='920' productname='TestStand'>
  <typelist/>
  <Data classname='Obj'><subprops>
    <Seq classname='Objs'><value lbound='[0]' ubound='[1]'><value>
      <Sequence name='MainSequence' classname='Obj'><subprops>
        <Main classname='Objs'><value lbound='[0]' ubound='[1]'>
          <value><Step typename='Action' name='Work'/></value>
        </value></Main>
        <Parameters classname='Obj'><subprops>
          <TestSocketName classname='Str'><value/></TestSocketName>
          <Voltage classname='Num'><value>5</value></Voltage>
        </subprops></Parameters>
      </subprops></Sequence>
    </value></value></Seq>
  </subprops></Data>
</teststandfileheader>''';

/// A sequence whose Main holds two structured flow-control blocks — an `if`
/// guarding one action, and a `for each` looping one action — each opened by an
/// `NI_Flow_*` step and closed by a matching `NI_Flow_End`. The branch/loop
/// expressions are flat direct children of the step (`ConditionExpr`,
/// `ArrayExpr`, `ArrayElementExpr`), as in the corpus.
const _seqFlowXml = '''<?xml version="1.0" encoding="UTF-8"?>
<teststandfileheader type='SequenceFile' fileversion='920' productname='TestStand'>
  <typelist/>
  <Data classname='Obj'><subprops>
    <Seq classname='Objs'><value lbound='[0]' ubound='[1]'><value>
      <Sequence name='MainSequence' classname='Obj'><subprops>
        <Main classname='Objs'><value lbound='[0]' ubound='[6]'>
          <value><Step typename='NI_Flow_If' name='If'><subprops>
            <ConditionExpr classname='ExprValue'><value>Locals.X &gt; 0</value></ConditionExpr>
          </subprops></Step></value>
          <value><Step typename='Action' name='Do Work'/></value>
          <value><Step typename='NI_Flow_End' name='End'/></value>
          <value><Step typename='NI_Flow_ForEach' name='For Each'><subprops>
            <ArrayExpr classname='ExprValue'><value>Locals.Items</value></ArrayExpr>
            <ArrayElementExpr classname='ExprValue'><value>Locals.Item</value></ArrayElementExpr>
          </subprops></Step></value>
          <value><Step typename='Action' name='Process Item'/></value>
          <value><Step typename='NI_Flow_End' name='End'/></value>
        </value></Main>
      </subprops></Sequence>
    </value></value></Seq>
  </subprops></Data>
</teststandfileheader>''';

/// A type list whose typedef declares two named fields, each with a type token.
const _seqTypeDefXml = '''<?xml version="1.0" encoding="UTF-8"?>
<teststandfileheader type='SequenceFile' fileversion='920' productname='TestStand' productversion='2019'>
  <typelist>
    <typedef>
      <MeasCluster classname='Obj'>
        <subprops>
          <Voltage classname='Number'><value/></Voltage>
          <Label classname='String'><value/></Label>
        </subprops>
      </MeasCluster>
    </typedef>
  </typelist>
  <Data classname='Obj'>
    <subprops>
      <Seq classname='Objs'><value lbound='[0]' ubound='[]'/></Seq>
    </subprops>
  </Data>
</teststandfileheader>''';
