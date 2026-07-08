import 'dart:convert';
import 'dart:typed_data';

import 'package:labwright_seq/labwright_seq.dart';
import 'package:test/test.dart';

/// The standard file scaffold: header → [typelist] → Data > Seq > one
/// MainSequence whose subprops are [seqSubprops] (+ [dataExtra] Data siblings).
String _file(String seqSubprops, {String typelist = '<typelist/>', String dataExtra = ''}) =>
    '<?xml version="1.0" encoding="UTF-8"?>\n'
    "<teststandfileheader type='SequenceFile' fileversion='920' productname='TestStand' productversion='2019'>"
    "$typelist<Data classname='Obj'><subprops>"
    "<Seq classname='Objs'><value lbound='[0]' ubound='[1]'><value>"
    "<Sequence name='MainSequence' classname='Obj'><subprops>$seqSubprops</subprops></Sequence>"
    '</value></value></Seq>$dataExtra</subprops></Data></teststandfileheader>';

String _main(List<String> steps) =>
    "<Main classname='Objs'><value lbound='[0]' ubound='[${steps.length}]'>"
    '${steps.map((s) => '<value>$s</value>').join()}</value></Main>';

String _step(String type, String name, [String subprops = '']) =>
    "<Step typename='$type' name='$name'>${subprops.isEmpty ? '' : '<subprops>$subprops</subprops>'}</Step>";

String _ts(String inner) => "<TS classname='Obj'><subprops>$inner</subprops></TS>";

String _el(String tag, String cls, [String? value]) =>
    "<$tag classname='$cls'>${value == null ? '<value/>' : '<value>$value</value>'}</$tag>";

/// An anonymous `_NAME_IN_ATTRIBUTE_` object array element.
String _anon(String subprops) =>
    "<_NAME_IN_ATTRIBUTE_ name='' classname='Obj'><subprops>$subprops</subprops></_NAME_IN_ATTRIBUTE_>";

SeqFile _parse(String xml) => parseSeqFile(Uint8List.fromList([0xef, 0xbb, 0xbf, ...utf8.encode(xml)]));

final _statementTs = _ts(
  '${_el('Mode', 'Str', 'Skip')}${_el('LoadOpt', 'Str', 'PreloadWhenExecuted')}'
  '${_el('PreCond', 'ExprValue', 'Locals.X == 1')}${_el('LoopType', 'Str', 'FixedNumLoops')}'
  '${_el('PassAct', 'Str', 'GotoStep')}${_el('FailAct', 'Str', 'Next')}${_el('PostExpr', 'ExprValue')}'
  "<SData classname='Obj'><subprops><ViCall classname='VICall'><subprops>"
  "${_el('VIPath', 'PathValue', r'My Computer\Foo.vi')}"
  '</subprops></ViCall></subprops></SData>',
);

final _limitsProps =
    '${_el('Comp', 'Str', 'GELE')}${_el('DataSource', 'Str', 'Step.Result.Numeric')}'
    "<Limits classname='Obj'><subprops>"
    '${_el('Low', 'Num', '9')}${_el('High', 'Num', '11')}'
    '${_el('Nominal', 'Num', '10')}${_el('ThresholdType', 'Str', 'PERCENTAGE')}'
    '</subprops></Limits>';

final _cModuleTs = _ts(
  "<SData classname='Obj'><subprops><Call classname='ExternalCall'><subprops>"
  "${_el('LibPath', 'Str', 'kernel32.dll')}${_el('Func', 'Str', 'Sleep')}"
  '</subprops></Call></subprops></SData>',
);

/// The kitchen-sink fixture mirroring the real TestStand shape.
final _seqXml = _file(
  "<Setup classname='Objs'><value lbound='[0]' ubound='[]'/></Setup>"
  '${_main([
    "<Step typename='Statement' xsi:type='Statement' name='Pass &amp; go'><subprops>$_statementTs</subprops></Step>",
    "<Step typename='MessagePopup' name='Show &quot;hi&quot;'/>",
    _step('NumericLimitTest', 'Check V', _limitsProps),
    _step('Action', 'Call Sleep', _cModuleTs),
  ])}'
  "<Cleanup classname='Objs'><value lbound='[0]' ubound='[]'/></Cleanup>"
  "${_el('Comment', 'Str', 'a comment')}"
  "<Locals classname='Obj'><subprops>${_el('Count', 'Num', '3')}${_el('Label', 'Str', 'hi')}<ResultList classname='Objs'><value lbound='[0]' ubound='[]'/></ResultList></subprops></Locals>",
  typelist: "<typelist><typedef><Expression classname='ExprValue'><value/></Expression></typedef></typelist>",
);

/// One sequence calling itself (intra-file SequenceCall).
final _seqCallXml = _file(
  _main([
    _step(
      'SequenceCall',
      'Call Self',
      _ts(
        "<SData classname='Obj'><subprops>${_el('SeqName', 'Str', 'MainSequence')}${_el('UseCurFile', 'Bool', 'true')}</subprops></SData>",
      ),
    ),
  ]),
);

void main() {
  group('parseSeqFile (XML)', () {
    final f = _parse(_seqXml);

    test('reads the header and type list', () {
      expect(
        (f.header.format, f.header.fileType, f.header.fileVersion, f.header.productName),
        (
          SeqFormat.xml,
          'SequenceFile',
          '920',
          'TestStand',
        ),
      );
      expect(f.types, hasLength(1));
      expect((f.types.single.name, f.types.single.className), ('Expression', 'ExprValue'));
    });

    test('recovers sequences and steps with names and types, in editor order', () {
      final seq = f.sequences.single;
      expect(seq.name, 'MainSequence');
      expect(seq.setup, isEmpty);
      expect(seq.cleanup, isEmpty);
      expect(seq.main.map((s) => s.name), ['Pass & go', 'Show "hi"', 'Check V', 'Call Sleep']);
      expect(seq.main.map((s) => s.type), ['Statement', 'MessagePopup', 'NumericLimitTest', 'Action']);
      expect(seq.steps, hasLength(4));
    });

    test('decodes the module-adapter binding per step', () {
      final main = f.sequences.single.main;
      expect(
        (main[0].module.adapter, main[0].module.viPath, main[0].module.target),
        (
          SeqAdapter.labView,
          r'My Computer\Foo.vi',
          r'My Computer\Foo.vi',
        ),
      );
      expect((main[1].module.adapter, main[1].module.target), (SeqAdapter.none, null));
      expect(
        (main[3].module.adapter, main[3].module.libPath, main[3].module.function, main[3].module.target),
        (
          SeqAdapter.cModule,
          'kernel32.dll',
          'Sleep',
          'kernel32.dll:Sleep',
        ),
      );
    });

    test('decodes limit-test pass/fail criteria', () {
      final lim = f.sequences.single.main[2].limits!;
      expect(
        (lim.comparison, lim.low, lim.high, lim.nominal, lim.thresholdType),
        ('GELE', '9', '11', '10', 'PERCENTAGE'),
      );
      expect(lim.dataSource, 'Step.Result.Numeric');
      expect(lim.summary, 'GELE [9, 11]');
      expect(f.sequences.single.main[0].limits, isNull);
    });

    test('decodes step settings from the TS sub-container', () {
      final s0 = f.sequences.single.main[0].settings;
      expect((s0.precondition, s0.loopType, s0.isLooping), ('Locals.X == 1', 'FixedNumLoops', true));
      expect((s0.passAction, s0.failAction, s0.postExpression), ('GotoStep', 'Next', null));
      expect((s0.mode, s0.isNormalMode, s0.loadOption), ('Skip', false, 'PreloadWhenExecuted'));
      final s1 = f.sequences.single.main[1].settings;
      expect((s1.precondition, s1.loopType, s1.isLooping, s1.mode, s1.isNormalMode), (null, null, false, null, true));
    });

    test('decodes sequence locals and (empty) parameters', () {
      final seq = f.sequences.single;
      expect(seq.locals.map((v) => v.name), ['Count', 'Label', 'ResultList']);
      final count = seq.locals[0];
      expect((count.type, count.value, count.isArray, count.containerCount), ('Num', '3', false, null));
      expect(seq.locals[1].value, 'hi');
      final list = seq.locals[2];
      expect(
        (list.type, list.value, list.isContainer, list.isArray, list.containerCount),
        ('Objs', null, true, true, 0),
      );
      expect(seq.parameters, isEmpty);
    });

    test('dumpSeqFile renders a faithful text view', () {
      final out = dumpSeqFile(f);
      for (final chip in [
        'SequenceFile',
        'Sequence: MainSequence',
        'Pass & go [Statement]',
        'Call Sleep [Action]',
        r'labView: My Computer\Foo.vi',
        'cModule: kernel32.dll:Sleep',
        'limits GELE [9, 11]',
        'mode Skip',
        'loop FixedNumLoops',
        'if Locals.X == 1',
        'Count : Num = 3',
      ]) {
        expect(out, contains(chip));
      }
    });

    test('resolves intra-file SequenceCall targets', () {
      final cf = _parse(_seqCallXml);
      final call = cf.sequences.single.main.single;
      expect((call.module.adapter, call.module.sequenceName), (SeqAdapter.sequenceCall, 'MainSequence'));
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

    test('StepGroup keys are the .seq property names; stepsIn matches the getters', () {
      expect(StepGroup.values.map((g) => g.key), ['Setup', 'Main', 'Cleanup']);
      final seq = f.sequences.single;
      List<String> names(List<Step> s) => [for (final x in s) x.name];
      expect(names(seq.stepsIn(StepGroup.setup)), names(seq.setup));
      expect(names(seq.stepsIn(StepGroup.main)), names(seq.main));
      expect(names(seq.stepsIn(StepGroup.cleanup)), names(seq.cleanup));
      expect(names(seq.steps), [...names(seq.setup), ...names(seq.main), ...names(seq.cleanup)]);
    });
  });

  group('Additional Results recording spec', () {
    // A call parameter's AdditionalResults container: entries carry a gating
    // Condition plus the not-yet-decoded Flags/CheckedState siblings.
    final addlXml = _file(
      _main([
        _step(
          'Action',
          'Run Python',
          _ts(
            "<SData classname='Obj'><subprops><Param classname='NI_PythonParameter'><subprops><AdditionalResults classname='Obj'><subprops><Input classname='PythonParameterResult'><subprops>${_el('Condition', 'ExprValue')}${_el('Flags', 'Num', '8192')}${_el('CheckedState', 'Num', '1')}</subprops></Input><Output classname='PythonParameterResult'><subprops>${_el('Condition', 'ExprValue', 'Locals.Save == True')}${_el('Flags', 'Num', '8192')}${_el('CheckedState', 'Num', '2')}</subprops></Output></subprops></AdditionalResults></subprops></Param></subprops></SData>",
          ),
        ),
      ]),
    );

    test('recovers each recorded entry, its gating Condition, and raw siblings', () {
      final f = _parse(addlXml);
      final addl = f.sequences.single.main.single.additionalResults;
      expect(addl.map((a) => a.name), ['Input', 'Output']);
      expect(addl.map((a) => a.kind), ['PythonParameterResult', 'PythonParameterResult']);
      expect(addl[0].condition, isNull);
      expect(addl[1].condition, 'Locals.Save == True');
      expect(addl[0].raw.prop('Flags')?.scalar, '8192');
      expect(addl[1].raw.prop('CheckedState')?.scalar, '2');
      expect(measureCoverage(f).modeled, greaterThan(0));
      expect(dumpSeqFile(f), contains('{+results: Input, Output if Locals.Save == True}'));
    });

    test('a step without the spec reports an empty list', () {
      expect(_parse(_seqCallXml).sequences.single.main.single.additionalResults, isEmpty);
    });
  });

  group('Measurement step parameters', () {
    final measXml = _file(
      _main([
        _step(
          'NI_Measurement',
          'Measure V',
          "<Measurement classname='Obj'><subprops><Parameters classname='Objs'><value lbound='[0]' ubound='[3]'><value>${_anon("${_el('Name', 'Str', 'voltage_level')}${_el('Type', 'Str', 'TypeDouble')}${_el('Direction', 'Str', 'In')}${_el('Dimension', 'Num', '0')}${_el('ArgumentValue', 'ExprValue', '6')}${_el('TypeSpecialization', 'Str', 'None')}${_el('Log', 'Bool', 'true')}${_el('ID', 'Num', '1')}")}</value><value>${_anon("${_el('Name', 'Str', 'pin_map')}${_el('Type', 'Str', 'TypeString')}${_el('Direction', 'Str', 'Out')}${_el('Dimension', 'Num', '1')}${_el('ArgumentValue', 'ExprValue')}${_el('TypeSpecialization', 'Str', 'IOResource')}${_el('Log', 'Bool', 'false')}${_el('ID', 'Num', '2')}")}</value><value>${_anon("${_el('Name', 'Str', 'measurement_type')}${_el('Type', 'Str', 'TypeEnum')}${_el('Direction', 'Str', 'In')}${_el('Dimension', 'Num', '0')}${_el('ArgumentValue', 'ExprValue')}${_el('TypeSpecialization', 'Str', 'Enum')}<EnumDefinition classname='Objs'><value lbound='[0]' ubound='[3]'><value>${_el('NONE', 'Num', '0')}</value><value>${_el('DC_VOLTS', 'Num', '1')}</value><value>${_el('AC_VOLTS', 'Num', '2')}</value></value></EnumDefinition>${_el('ID', 'Num', '3')}")}</value></value></Parameters></subprops></Measurement>",
        ),
      ]),
    );

    test('recovers each typed parameter: name/type/direction/dim/value/refinement/log/enum', () {
      final f = _parse(measXml);
      final p = f.sequences.single.main.single.measurementParameters;
      expect(p, hasLength(3));
      expect(
        (p[0].name, p[0].dataType, p[0].direction, p[0].isArray, p[0].value),
        ('voltage_level', 'TypeDouble', 'In', false, '6'),
      );
      expect((p[0].typeSpecialization, p[0].logged), (null, true));
      expect((p[1].name, p[1].direction, p[1].isArray, p[1].value), ('pin_map', 'Out', true, null));
      expect((p[1].typeSpecialization, p[1].logged), ('IOResource', false));
      expect((p[2].name, p[2].dataType), ('measurement_type', 'TypeEnum'));
      expect(p[2].enumValues.map((e) => e.name), ['NONE', 'DC_VOLTS', 'AC_VOLTS']);
      expect(p[2].enumValues.map((e) => e.value), ['0', '1', '2']);
      expect(p[0].enumValues, isEmpty);
      expect(measureCoverage(f).modeled, greaterThan(8), reason: 'coverage credits the parameter cluster');
    });

    test('a non-measurement step reports no measurement parameters', () {
      expect(_parse(_seqCallXml).sequences.single.main.single.measurementParameters, isEmpty);
    });

    test('the dump surfaces measurement params with type, refinement, logging, enums', () {
      final out = dumpSeqFile(_parse(measXml));
      expect(out, contains('voltage_level in TypeDouble = 6'));
      expect(out, contains('pin_map out TypeString (IOResource)[] [not logged]'));
      expect(out, contains('{NONE=0, DC_VOLTS=1, AC_VOLTS=2}'));
    });
  });

  group('Python adapter call parameters', () {
    // The Python form binds under SData.PythonCall.Parameters with
    // ArgumentValue (not the C adapter's ArgVal) and no Direction.
    final pyCallXml = _file(
      _main([
        _step(
          'Action',
          'Run measurement',
          _ts(
            "<SData classname='Obj'><subprops><PythonCall classname='Obj'><subprops><Parameters classname='Objs'><value lbound='[0]' ubound='[2]'><value>${_anon("${_el('Name', 'Str', 'sequence_context')}${_el('Type', 'Num', '7')}${_el('ArgumentValue', 'ExprValue', 'ThisContext')}")}</value><value>${_anon("${_el('Name', 'Str', 'Return Value')}${_el('Type', 'Num', '7')}${_el('ArgumentValue', 'ExprValue')}")}</value></value></Parameters></subprops></PythonCall></subprops></SData>",
          ),
        ),
      ]),
    );

    test('recovers the adapter and its params (Name + ArgumentValue bound value)', () {
      final m = _parse(pyCallXml).sequences.single.main.single.module;
      expect(m.adapter, SeqAdapter.python);
      final args = m.callParameters;
      expect(args.map((a) => a.name), ['sequence_context', 'Return Value']);
      expect((args[0].boundExpression, args[0].direction), ('ThisContext', null));
      expect(args[1].boundExpression, isNull);
      expect(dumpSeqFile(_parse(pyCallXml)), contains('sequence_context←ThisContext'));
    });
  });

  group('Custom-condition flow control', () {
    final custXml = _file(
      _main([
        _step(
          'Action',
          'Branch',
          _ts(
            "${_el('CustExpr', 'ExprValue', 'Locals.x &gt; 0')}${_el('CustTrueAct', 'Str', 'GotoStep')}${_el('CustFalseAct', 'Str', 'Next')}",
          ),
        ),
      ]),
    );

    test('recovers the custom expression and its true/false actions', () {
      final s = _parse(custXml).sequences.single.main.single.settings;
      expect((s.customExpression, s.customTrueAction, s.customFalseAction), ('Locals.x > 0', 'GotoStep', 'Next'));
      expect(dumpSeqFile(_parse(custXml)), contains('cust-cond Locals.x > 0'));
    });

    test('a step without a custom condition reports nulls', () {
      final s0 = _parse(_seqXml).sequences.single.main.first.settings;
      expect((s0.customExpression, s0.customTrueAction), (null, null));
    });
  });

  group('Step result outcome record', () {
    test('recovers status / report text / error from a recorded Result', () {
      final resultXml = _file(
        _main([
          _step(
            'Action',
            'Ran',
            "<Result classname='Obj'><subprops>${_el('Status', 'Str', 'Failed')}${_el('ReportText', 'Str', 'measured 5V')}<Error classname='Obj'><subprops>${_el('Code', 'Num', '-17')}${_el('Msg', 'Str', 'boom')}${_el('Occurred', 'Bool', 'true')}</subprops></Error></subprops></Result>",
          ),
        ]),
      );
      final r = _parse(resultXml).sequences.single.main.single.result!;
      expect(
        (r.status, r.reportText, r.errorOccurred, r.errorCode, r.errorMessage),
        ('Failed', 'measured 5V', true, '-17', 'boom'),
      );
      expect(r.hasRecordedOutcome, isTrue);
      expect(
        dumpSeqFile(_parse(resultXml)),
        contains('{result: status Failed; error -17 "boom"; report "measured 5V"}'),
      );
    });

    test('a default (un-run) Result reads as no recorded outcome', () {
      final step = _parse(_seqCallXml).sequences.single.main.single;
      if (step.result != null) {
        expect(step.result!.hasRecordedOutcome, isFalse);
      }
      expect(dumpSeqFile(_parse(_seqCallXml)), isNot(contains('{result:')));
    });
  });

  group('Step mutex synchronization', () {
    test('recovers UseMutex + MutexNameOrRef and surfaces it in the dump', () {
      final mutexXml = _file(
        _main([
          _step(
            'Action',
            'Locked',
            _ts(
              "${_el('UseMutex', 'Bool', 'true')}${_el('MutexNameOrRef', 'ExprValue', '&quot;InstrumentLock&quot;')}",
            ),
          ),
        ]),
      );
      final s = _parse(mutexXml).sequences.single.main.single.settings;
      expect((s.usesMutex, s.mutexName), (true, '"InstrumentLock"'));
      expect(dumpSeqFile(_parse(mutexXml)), contains('mutex "InstrumentLock"'));
    });

    test('a step without a mutex reports false/null and no dump note', () {
      final s = _parse(_seqXml).sequences.single.main.first.settings;
      expect(s.usesMutex, anyOf(isNull, isFalse));
      expect(dumpSeqFile(_parse(_seqXml)), isNot(contains('mutex')));
    });
  });

  group('type-list typedef recovery', () {
    final typeDefXml = _file(
      "<Main classname='Objs'><value lbound='[0]' ubound='[]'/></Main>",
      typelist:
          "<typelist><typedef><MeasCluster classname='Obj'><subprops>${_el('Voltage', 'Number')}${_el('Label', 'String')}</subprops></MeasCluster></typedef></typelist>",
    );

    test('recovers a typedef name, base class and declared fields', () {
      final f = _parse(typeDefXml);
      final t = f.typeDefs.single;
      expect((t.name, t.baseClass), ('MeasCluster', 'Obj'));
      expect(t.fields.map((x) => x.name), ['Voltage', 'Label']);
      expect(t.fields.map((x) => x.type), ['Number', 'String']);
      final dump = dumpSeqFile(f);
      for (final chip in ['Types (1):', 'MeasCluster : Obj', '.Voltage [Number]', '.Label [String]']) {
        expect(dump, contains(chip));
      }
    });

    test('a scalar typedef recovers an empty field list (no fabrication)', () {
      final t = _parse(_seqXml).typeDefs.single;
      expect((t.name, t.baseClass), ('Expression', 'ExprValue'));
      expect(t.fields, isEmpty);
    });
  });

  group('LabVIEW VI-call recovery', () {
    final viCallXml = _file(
      _main([
        _step(
          'Action',
          'Init DCPower',
          _ts(
            "<SData classname='FGModule'><subprops><ViCall classname='VICall'><subprops>${_el('VIPath', 'PathValue', r'My Computer\NIDCPower.vi')}${_el('Namespace', 'Str', 'NIDCPower.lvlib')}${_el('ProjectPath', 'PathValue', 'NIDCPower.lvproj')}<Parms classname='Objs'><value lbound='[0]' ubound='[2]'><value>${_anon("${_el('Label', 'Str', 'sequence context')}${_el('DisplayType', 'Str', 'Object Reference')}${_el('ArgVal', 'ExprValue', 'ThisContext')}${_el('Direction', 'Num', '0')}${_el('ConnectorNumber', 'Num', '11')}")}</value><value>${_anon("${_el('Label', 'Str', 'error out')}${_el('DisplayType', 'Str', 'Container')}${_el('ArgVal', 'ExprValue', 'Step.Result.Error')}${_el('Direction', 'Num', '0')}${_el('ConnectorNumber', 'Num', '0')}")}</value></value></Parms></subprops></ViCall></subprops></SData>",
          ),
        ),
      ]),
    );

    test('recovers the VI-call descriptor and connector-pane parameters in order', () {
      final m = _parse(viCallXml).sequences.single.main.single.module;
      expect(
        (m.adapter, m.viPath, m.viNamespace, m.viProjectPath),
        (
          SeqAdapter.labView,
          r'My Computer\NIDCPower.vi',
          'NIDCPower.lvlib',
          'NIDCPower.lvproj',
        ),
      );
      final p = m.viParameters;
      expect(p.map((x) => x.name), ['sequence context', 'error out']);
      expect(p.map((x) => x.displayType), ['Object Reference', 'Container']);
      expect(p.map((x) => x.connectorNumber), [11, 0]);
      expect(p.map((x) => x.boundExpression), ['ThisContext', 'Step.Result.Error']);
    });

    test('the dump shows the library and connector pane', () {
      final dump = dumpSeqFile(_parse(viCallXml));
      expect(dump, contains('{vi: lib NIDCPower.lvlib, proj NIDCPower.lvproj}'));
      expect(dump, contains('#11 sequence context (Object Reference)←ThisContext'));
      expect(dump, contains('#0 error out (Container)←Step.Result.Error'));
    });
  });

  group('Python call descriptor recovery', () {
    final pyXml = _file(
      _main([
        _step(
          'Action',
          'Create sessions',
          _ts(
            "<SData classname='CPythonModule'><subprops><PythonCall classname='CPythonCall'><subprops>${_el('PythonVersion', 'Str', '3.9')}${_el('PythonVirtualEnvironmentPath', 'Str', r'..\measurements\smu\.venv')}${_el('ModulePath', 'PathValue', r'..\measurements\smu\test.py')}${_el('ClassName', 'Str')}${_el('FunctionOrAttributeName', 'Str', 'create_instrument_sessions')}${_el('OperationType', 'Num', '1')}</subprops></PythonCall></subprops></SData>",
          ),
        ),
      ]),
    );

    test('recovers the called module/function and interpreter', () {
      final m = _parse(pyXml).sequences.single.main.single.module;
      expect(
        (m.adapter, m.pythonFunction, m.pythonModulePath),
        (SeqAdapter.python, 'create_instrument_sessions', r'..\measurements\smu\test.py'),
      );
      expect((m.pythonVersion, m.pythonVenvPath, m.pythonClassName), ('3.9', r'..\measurements\smu\.venv', null));
      expect(m.target, 'create_instrument_sessions');
      final dump = dumpSeqFile(_parse(pyXml));
      expect(dump, contains('-> python: create_instrument_sessions'));
      expect(dump, contains(r'{python: mod ..\measurements\smu\test.py, py 3.9}'));
    });
  });

  group('measurement plug-in resource set', () {
    String strs(String tag, String v) =>
        "<$tag classname='Strs'><value lbound='[0]' ubound='[1]'><value>$v</value></value></$tag>";
    final pluginsXml =
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        "<teststandfileheader type='SequenceFile' fileversion='920' productname='TestStand'>"
        "<typelist/><Data classname='Obj'><subprops>"
        "<Seq classname='Objs'><value lbound='[0]' ubound='[]'/></Seq>"
        "<FileGlobalDefaults classname='Obj'><subprops><MeasurementPlugIns classname='Obj'><subprops>"
        "${_el('EnableMonitoring', 'Bool', 'true')}${_el('PinMapPath', 'PathValue', 'PinMap.pinmap')}"
        '${strs('SpecificationsFilePaths', 'Specifications.specs')}${strs('LevelsFilePaths', 'PinLevels.digilevels')}'
        '${strs('TimingFilePaths', 'Timing.digitiming')}${strs('PatternFilePaths', 'Pattern.digipat')}'
        '</subprops></MeasurementPlugIns></subprops></FileGlobalDefaults>'
        '</subprops></Data></teststandfileheader>';

    test('recovers the pin map and STS file lists; the dump lists them', () {
      final mp = _parse(pluginsXml).measurementPlugIns!;
      expect((mp.pinMapPath, mp.monitoringEnabled, mp.isNotEmpty), ('PinMap.pinmap', true, true));
      expect(mp.specificationFiles, ['Specifications.specs']);
      expect(mp.levelsFiles, ['PinLevels.digilevels']);
      expect(mp.timingFiles, ['Timing.digitiming']);
      expect(mp.patternFiles, ['Pattern.digipat']);
      final dump = dumpSeqFile(_parse(pluginsXml));
      for (final chip in [
        'Measurement plug-ins:',
        'pin map: PinMap.pinmap',
        'specifications: Specifications.specs',
        'patterns: Pattern.digipat',
      ]) {
        expect(dump, contains(chip));
      }
    });

    test('a file without the block reports null (no fabrication)', () {
      expect(_parse(_seqXml).measurementPlugIns, isNull);
    });
  });

  group('flow-control structured-logic export', () {
    // NI_Flow_* steps open/close blocks; the branch/loop expressions are flat
    // direct children (ConditionExpr / ArrayExpr / ArrayElementExpr).
    final flowXml = _file(
      _main([
        _step('NI_Flow_If', 'If', _el('ConditionExpr', 'ExprValue', 'Locals.X &gt; 0')),
        _step('Action', 'Do Work'),
        _step('NI_Flow_End', 'End'),
        _step(
          'NI_Flow_ForEach',
          'For Each',
          "${_el('ArrayExpr', 'ExprValue', 'Locals.Items')}${_el('ArrayElementExpr', 'ExprValue', 'Locals.Item')}",
        ),
        _step('Action', 'Process Item'),
        _step('NI_Flow_End', 'End'),
      ]),
    );
    final f = _parse(flowXml);

    test('recognizes NI_Flow_* steps and recovers the branch/loop expressions', () {
      final steps = f.sequences.single.main;
      expect(steps.map((s) => s.flowControl?.kind), [
        FlowKind.ifBlock,
        null,
        FlowKind.end,
        FlowKind.forEach,
        null,
        FlowKind.end,
      ]);
      expect(steps[0].flowControl!.condition, 'Locals.X > 0');
      expect(steps[0].flowControl!.header, 'if (Locals.X > 0)');
      final each = steps[3].flowControl!;
      expect(
        (each.arrayExpr, each.arrayElement, each.header),
        ('Locals.Items', 'Locals.Item', 'for each (Locals.Item in Locals.Items)'),
      );
      expect(_parse(_seqXml).sequences.single.main.first.flowControl, isNull, reason: 'non-flow step: no fabrication');
    });

    test('exportSequenceLogic nests the blocks with matching braces; dump carries the section', () {
      final out = exportSequenceLogic(f);
      expect(out, contains('if (Locals.X > 0) {'));
      expect(out, contains('for each (Locals.Item in Locals.Items) {'));
      expect(out, contains('\n      Do Work'));
      expect('}'.allMatches(out).length, 2);
      final dump = dumpSeqFile(f);
      expect(dump, contains('=== Sequence logic ==='));
      expect(dump, contains('if (Locals.X > 0) {'));
    });
  });

  group('logic export annotations', () {
    test('a looping step gets its type + while condition; a plain one does not', () {
      final loopXml = _file(
        _main([
          _step(
            'Action',
            'Spin',
            _ts(
              "${_el('LoopType', 'Str', 'FixedNumLoops')}${_el('LoopWhile', 'ExprValue', 'RunState.LoopIndex &lt; 10')}",
            ),
          ),
          _step('Action', 'Once'),
        ]),
      );
      final out = exportSequenceLogic(_parse(loopXml));
      expect(out, contains('[loop FixedNumLoops while RunState.LoopIndex < 10]'));
      expect(out.split('\n').firstWhere((l) => l.contains('Once')), isNot(contains('[loop')));
    });

    test('an external call shows its target file; a self call does not', () {
      final extCallXml = _file(
        _main([
          _step(
            'SequenceCall',
            'Call Other',
            _ts(
              "<SData classname='Obj'><subprops>${_el('SeqName', 'Str', 'Helper')}${_el('SFPath', 'Str', 'Other.seq')}</subprops></SData>",
            ),
          ),
        ]),
      );
      expect(exportSequenceLogic(_parse(extCallXml)), contains('Call Other → Helper in Other.seq'));
      final selfOut = exportSequenceLogic(_parse(_seqCallXml));
      expect(selfOut, contains('Call Self → MainSequence'));
      expect(selfOut.split('\n').firstWhere((l) => l.contains('Call Self')), isNot(contains(' in ')));
    });

    test('a non-default fail jump is annotated; a fall-through step is not', () {
      final jumpXml = _file(
        _main([
          _step(
            'NumericLimitTest',
            'Check V',
            _ts(
              "${_el('PassAct', 'Str', 'Next')}${_el('FailAct', 'Str', 'Goto')}${_el('FailActTarget', 'ExprValue', '&quot;&lt;Cleanup&gt;&quot;')}",
            ),
          ),
          _step('Action', 'Plain'),
        ]),
      );
      final out = exportSequenceLogic(_parse(jumpXml));
      expect(out, contains('Check V'));
      expect(out, contains('[on fail → <Cleanup>]'));
      final plainLine = out.split('\n').firstWhere((l) => l.contains('Plain'));
      expect(plainLine, isNot(contains('on fail')));
      expect(plainLine, isNot(contains('on pass')));
    });

    test('summary header: counts, pluralization, and function-style signatures', () {
      final seq = _parse(_seqXml).sequences.single;
      final header = exportSequenceLogic(_parse(_seqXml)).split('\n').first;
      expect(header, startsWith('sequence MainSequence:'));
      expect(header, contains('${seq.steps.length} steps'));
      expect(header, contains('${seq.locals.length} locals'));
      expect(header, isNot(contains('param')));
      expect(header, isNot(contains('()')), reason: 'a parameterless sequence has no empty parens');

      final single = exportSequenceLogic(_parse(_seqCallXml)).split('\n').first;
      expect(single, contains('// 1 step'));
      expect(single, isNot(contains('1 steps')));

      final paramsXml = _file(
        '${_main([_step('Action', 'Work')])}'
        "<Parameters classname='Obj'><subprops>${_el('TestSocketName', 'Str')}${_el('Voltage', 'Num', '5')}</subprops></Parameters>",
      );
      final signed = exportSequenceLogic(_parse(paramsXml)).split('\n').first;
      expect(signed, startsWith('sequence MainSequence(TestSocketName: Str, Voltage: Num = 5):'));
      expect(signed, isNot(contains('param')));
      expect(signed, contains('// 1 step'));
    });
  });

  group('parseSeqFile rejects non-XML honestly', () {
    test('a binary TOF1 header without an inflatable body throws FormatException', () {
      final bin = Uint8List.fromList([...ascii.encode('TOF1'), 0, 0, 0, 0, 0, 0, ...ascii.encode('SequenceFile'), 0]);
      expect(() => parseSeqFile(bin), throwsFormatException);
    });

    test('unknown bytes throw FormatException', () {
      expect(() => parseSeqFile(Uint8List.fromList([1, 2, 3])), throwsFormatException);
    });
  });

  group('sparse scalar arrays (arrayindex on element wrappers)', () {
    test('the element keeps its true arrayindex; nothing fabricated dense-from-0', () {
      final sparseXml = _file(
        "<Locals classname='Obj'><subprops><ArrayOfInt64 classname='Nums'>"
        "<value lbound='[0]' ubound='[2]' representation='Int64'>"
        "<value arrayindex='[1]'>9223372036854775806</value>"
        '</value></ArrayOfInt64></subprops></Locals>',
      );
      final arr = _parse(sparseXml).sequences.single.raw.at(['Locals', 'ArrayOfInt64'])!;
      expect(arr.isArray, isTrue);
      expect(arr.array, hasLength(1));
      expect(arr.array!.single.scalar, '9223372036854775806');
      expect(arr.array!.single.attributes['arrayindex'], '[1]');
    });

    test('elements without wrapper attributes read as before (empty attributes)', () {
      final main = _parse(_seqXml).sequences.single.raw.prop('Main')!;
      expect(main.array, isNotEmpty);
      expect(main.array!.first.attributes.containsKey('arrayindex'), isFalse);
    });
  });
}
