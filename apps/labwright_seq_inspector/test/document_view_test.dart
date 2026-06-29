import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_seq/labwright_seq.dart';
import 'package:labwright_seq_inspector/src/document_view.dart';
import 'package:labwright_seq_inspector/src/property_outline.dart';
import 'package:labwright_seq_inspector/src/recent_files.dart';
import 'package:labwright_seq_inspector/src/sequence_outline.dart';

Uint8List _xml() => Uint8List.fromList([
  0xef,
  0xbb,
  0xbf,
  ...utf8.encode(
    "<?xml version='1.0'?>\n"
    "<teststandfileheader type='SequenceFile' fileversion='920' productname='TestStand'>"
    "<typelist/><Data classname='Obj'><subprops>"
    "<Seq classname='Objs'><value lbound='[0]' ubound='[1]'><value>"
    "<Sequence name='MainSequence' classname='Obj'><subprops>"
    "<Main classname='Objs'><value lbound='[0]' ubound='[1]'>"
    "<value><Step typename='Statement' name='S1'/></value></value></Main>"
    "</subprops></Sequence></value></value></Seq></subprops></Data>"
    "</teststandfileheader>",
  ),
]);

Uint8List _xmlWithLimits() => Uint8List.fromList([
  0xef,
  0xbb,
  0xbf,
  ...utf8.encode(
    "<?xml version='1.0'?>\n"
    "<teststandfileheader type='SequenceFile' fileversion='920' productname='TestStand'>"
    "<typelist/><Data classname='Obj'><subprops>"
    "<Seq classname='Objs'><value lbound='[0]' ubound='[1]'><value>"
    "<Sequence name='MainSequence' classname='Obj'><subprops>"
    "<Main classname='Objs'><value lbound='[0]' ubound='[1]'><value>"
    "<Step typename='NumericLimitTest' name='Check V'><subprops>"
    "<Comp><value>GELE</value></Comp>"
    "<Limits classname='Obj'><subprops>"
    "<Low><value>9</value></Low><High><value>11</value></High>"
    "</subprops></Limits>"
    "<DataSource><value>Locals.V</value></DataSource>"
    "</subprops></Step>"
    "</value></value></Main>"
    "</subprops></Sequence></value></value></Seq></subprops></Data>"
    "</teststandfileheader>",
  ),
]);

Uint8List _xmlWithSkip() => Uint8List.fromList([
  0xef,
  0xbb,
  0xbf,
  ...utf8.encode(
    "<?xml version='1.0'?>\n"
    "<teststandfileheader type='SequenceFile' fileversion='920' productname='TestStand'>"
    "<typelist/><Data classname='Obj'><subprops>"
    "<Seq classname='Objs'><value lbound='[0]' ubound='[1]'><value>"
    "<Sequence name='MainSequence' classname='Obj'><subprops>"
    "<Main classname='Objs'><value lbound='[0]' ubound='[1]'><value>"
    "<Step typename='Statement' name='Skipped'><subprops>"
    "<TS classname='Obj'><subprops>"
    "<Mode><value>Skip</value></Mode>"
    "</subprops></TS>"
    "</subprops></Step>"
    "</value></value></Main>"
    "</subprops></Sequence></value></value></Seq></subprops></Data>"
    "</teststandfileheader>",
  ),
]);

Uint8List _xmlWithStatusExpr() => Uint8List.fromList([
  0xef,
  0xbb,
  0xbf,
  ...utf8.encode(
    "<?xml version='1.0'?>\n"
    "<teststandfileheader type='SequenceFile' fileversion='920' productname='TestStand'>"
    "<typelist/><Data classname='Obj'><subprops>"
    "<Seq classname='Objs'><value lbound='[0]' ubound='[1]'><value>"
    "<Sequence name='MainSequence' classname='Obj'><subprops>"
    "<Main classname='Objs'><value lbound='[0]' ubound='[1]'><value>"
    "<Step typename='Statement' name='Decide'><subprops>"
    "<TS classname='Obj'><subprops>"
    "<StatusExpr><value>Locals.x == 1</value></StatusExpr>"
    "</subprops></TS>"
    "</subprops></Step>"
    "</value></value></Main>"
    "</subprops></Sequence></value></value></Seq></subprops></Data>"
    "</teststandfileheader>",
  ),
]);

Uint8List _xmlWithFlags() => Uint8List.fromList([
  0xef,
  0xbb,
  0xbf,
  ...utf8.encode(
    "<?xml version='1.0'?>\n"
    "<teststandfileheader type='SequenceFile' fileversion='920' productname='TestStand'>"
    "<typelist/><Data classname='Obj'><subprops>"
    "<Seq classname='Objs'><value lbound='[0]' ubound='[1]'><value>"
    "<Sequence name='MainSequence' classname='Obj'><subprops>"
    "<Main classname='Objs'><value lbound='[0]' ubound='[1]'><value>"
    "<Step typename='Action' name='Flagged'><subprops>"
    "<TS classname='Obj'><subprops>"
    "<IgnoreRTE><value>true</value></IgnoreRTE>"
    "<StepFCSeqF><value>false</value></StepFCSeqF>"
    "<ResultOption><value>0</value></ResultOption>"
    "</subprops></TS>"
    "</subprops></Step>"
    "</value></value></Main>"
    "</subprops></Sequence></value></value></Seq></subprops></Data>"
    "</teststandfileheader>",
  ),
]);

/// A step carrying an "Additional Results" recording spec: a call parameter with
/// an `AdditionalResults` container whose `Input`/`Output` entries each hold a
/// gating `Condition` (one empty/always, one set) plus raw `Flags`/`CheckedState`.
Uint8List _xmlWithAddlResults() => Uint8List.fromList([
  0xef,
  0xbb,
  0xbf,
  ...utf8.encode(
    "<?xml version='1.0'?>\n"
    "<teststandfileheader type='SequenceFile' fileversion='920' productname='TestStand'>"
    "<typelist/><Data classname='Obj'><subprops>"
    "<Seq classname='Objs'><value lbound='[0]' ubound='[1]'><value>"
    "<Sequence name='MainSequence' classname='Obj'><subprops>"
    "<Main classname='Objs'><value lbound='[0]' ubound='[1]'><value>"
    "<Step typename='Action' name='Run Python'><subprops>"
    "<TS classname='Obj'><subprops><SData classname='Obj'><subprops>"
    "<Param classname='NI_PythonParameter'><subprops>"
    "<AdditionalResults classname='Obj'><subprops>"
    "<Input classname='PythonParameterResult'><subprops>"
    "<Condition classname='ExprValue'><value/></Condition>"
    "<Flags classname='Num'><value>8192</value></Flags>"
    "<CheckedState classname='Num'><value>1</value></CheckedState>"
    "</subprops></Input>"
    "<Output classname='PythonParameterResult'><subprops>"
    "<Condition classname='ExprValue'><value>Locals.Save == True</value></Condition>"
    "<Flags classname='Num'><value>8192</value></Flags>"
    "<CheckedState classname='Num'><value>2</value></CheckedState>"
    "</subprops></Output>"
    "</subprops></AdditionalResults>"
    "</subprops></Param>"
    "</subprops></SData></subprops></TS>"
    "</subprops></Step>"
    "</value></value></Main>"
    "</subprops></Sequence></value></value></Seq></subprops></Data>"
    "</teststandfileheader>",
  ),
]);

/// A measurement step with a `Measurement.Parameters` list (one scalar In, one
/// array Out) — the real shape, each element wrapped in `_NAME_IN_ATTRIBUTE_`.
Uint8List _xmlWithMeasParams() => Uint8List.fromList([
  0xef,
  0xbb,
  0xbf,
  ...utf8.encode(
    "<?xml version='1.0'?>\n"
    "<teststandfileheader type='SequenceFile' fileversion='920' productname='TestStand'>"
    "<typelist/><Data classname='Obj'><subprops>"
    "<Seq classname='Objs'><value lbound='[0]' ubound='[1]'><value>"
    "<Sequence name='MainSequence' classname='Obj'><subprops>"
    "<Main classname='Objs'><value lbound='[0]' ubound='[1]'><value>"
    "<Step typename='NI_Measurement' name='Measure V'><subprops>"
    "<Measurement classname='Obj'><subprops>"
    "<Parameters classname='Objs'><value lbound='[0]' ubound='[3]'>"
    "<value><_NAME_IN_ATTRIBUTE_ name='' classname='Obj'><subprops>"
    "<Name classname='Str'><value>voltage_level</value></Name>"
    "<Type classname='Str'><value>TypeDouble</value></Type>"
    "<Direction classname='Str'><value>In</value></Direction>"
    "<Dimension classname='Num'><value>0</value></Dimension>"
    "<ArgumentValue classname='ExprValue'><value>6</value></ArgumentValue>"
    "</subprops></_NAME_IN_ATTRIBUTE_></value>"
    "<value><_NAME_IN_ATTRIBUTE_ name='' classname='Obj'><subprops>"
    "<Name classname='Str'><value>readings</value></Name>"
    "<Type classname='Str'><value>TypeString</value></Type>"
    "<Direction classname='Str'><value>Out</value></Direction>"
    "<Dimension classname='Num'><value>1</value></Dimension>"
    "<ArgumentValue classname='ExprValue'><value/></ArgumentValue>"
    "<TypeSpecialization classname='Str'><value>IOResource</value></TypeSpecialization>"
    "<Log classname='Bool'><value>false</value></Log>"
    "</subprops></_NAME_IN_ATTRIBUTE_></value>"
    "<value><_NAME_IN_ATTRIBUTE_ name='' classname='Obj'><subprops>"
    "<Name classname='Str'><value>measurement_type</value></Name>"
    "<Type classname='Str'><value>TypeEnum</value></Type>"
    "<Direction classname='Str'><value>In</value></Direction>"
    "<Dimension classname='Num'><value>0</value></Dimension>"
    "<ArgumentValue classname='ExprValue'><value/></ArgumentValue>"
    "<EnumDefinition classname='Objs'><value lbound='[0]' ubound='[2]'>"
    "<value><NONE classname='Num'><value>0</value></NONE></value>"
    "<value><DC_VOLTS classname='Num'><value>1</value></DC_VOLTS></value>"
    "</value></EnumDefinition>"
    "</subprops></_NAME_IN_ATTRIBUTE_></value>"
    "</value></Parameters>"
    "</subprops></Measurement>"
    "</subprops></Step>"
    "</value></value></Main>"
    "</subprops></Sequence></value></value></Seq></subprops></Data>"
    "</teststandfileheader>",
  ),
]);

/// A LabVIEW (FGModule) step whose `SData.ViCall` carries the VI descriptor and
/// a `Parms` connector pane.
Uint8List _xmlWithViCall() => Uint8List.fromList([
  0xef,
  0xbb,
  0xbf,
  ...utf8.encode(
    "<?xml version='1.0'?>\n"
    "<teststandfileheader type='SequenceFile' fileversion='920' productname='TestStand'>"
    "<typelist/><Data classname='Obj'><subprops>"
    "<Seq classname='Objs'><value lbound='[0]' ubound='[1]'><value>"
    "<Sequence name='MainSequence' classname='Obj'><subprops>"
    "<Main classname='Objs'><value lbound='[0]' ubound='[1]'><value>"
    "<Step typename='Action' name='Init DCPower'><subprops>"
    "<TS classname='Obj'><subprops>"
    "<SData classname='FGModule'><subprops>"
    "<ViCall classname='VICall'><subprops>"
    "<VIPath classname='PathValue'><value>My Computer\\NIDCPower.vi</value></VIPath>"
    "<Namespace classname='Str'><value>NIDCPower.lvlib</value></Namespace>"
    "<ProjectPath classname='PathValue'><value>NIDCPower.lvproj</value></ProjectPath>"
    "<Parms classname='Objs'><value lbound='[0]' ubound='[2]'>"
    "<value><_NAME_IN_ATTRIBUTE_ name='' classname='Obj'><subprops>"
    "<Label classname='Str'><value>sequence context</value></Label>"
    "<DisplayType classname='Str'><value>Object Reference</value></DisplayType>"
    "<ArgVal classname='ExprValue'><value>ThisContext</value></ArgVal>"
    "<ConnectorNumber classname='Num'><value>11</value></ConnectorNumber>"
    "</subprops></_NAME_IN_ATTRIBUTE_></value>"
    "<value><_NAME_IN_ATTRIBUTE_ name='' classname='Obj'><subprops>"
    "<Label classname='Str'><value>error out</value></Label>"
    "<DisplayType classname='Str'><value>Container</value></DisplayType>"
    "<ArgVal classname='ExprValue'><value>Step.Result.Error</value></ArgVal>"
    "<ConnectorNumber classname='Num'><value>0</value></ConnectorNumber>"
    "</subprops></_NAME_IN_ATTRIBUTE_></value>"
    "</value></Parms>"
    "</subprops></ViCall>"
    "</subprops></SData>"
    "</subprops></TS>"
    "</subprops></Step>"
    "</value></value></Main>"
    "</subprops></Sequence></value></value></Seq></subprops></Data>"
    "</teststandfileheader>",
  ),
]);

/// A Python (CPythonModule) step whose `SData.PythonCall` names the module and
/// function.
Uint8List _xmlWithPyCall() => Uint8List.fromList([
  0xef,
  0xbb,
  0xbf,
  ...utf8.encode(
    "<?xml version='1.0'?>\n"
    "<teststandfileheader type='SequenceFile' fileversion='920' productname='TestStand'>"
    "<typelist/><Data classname='Obj'><subprops>"
    "<Seq classname='Objs'><value lbound='[0]' ubound='[1]'><value>"
    "<Sequence name='MainSequence' classname='Obj'><subprops>"
    "<Main classname='Objs'><value lbound='[0]' ubound='[1]'><value>"
    "<Step typename='Action' name='Create sessions'><subprops>"
    "<TS classname='Obj'><subprops>"
    "<SData classname='CPythonModule'><subprops>"
    "<PythonCall classname='CPythonCall'><subprops>"
    "<PythonVersion classname='Str'><value>3.9</value></PythonVersion>"
    "<ModulePath classname='PathValue'><value>..\\smu\\test.py</value></ModulePath>"
    "<FunctionOrAttributeName classname='Str'><value>create_instrument_sessions</value></FunctionOrAttributeName>"
    "</subprops></PythonCall>"
    "</subprops></SData>"
    "</subprops></TS>"
    "</subprops></Step>"
    "</value></value></Main>"
    "</subprops></Sequence></value></value></Seq></subprops></Data>"
    "</teststandfileheader>",
  ),
]);

/// A file declaring a Semiconductor-Test-System resource set under
/// FileGlobalDefaults > MeasurementPlugIns.
Uint8List _xmlWithPlugins() => Uint8List.fromList([
  0xef,
  0xbb,
  0xbf,
  ...utf8.encode(
    "<?xml version='1.0'?>\n"
    "<teststandfileheader type='SequenceFile' fileversion='920' productname='TestStand'>"
    "<typelist/><Data classname='Obj'><subprops>"
    "<Seq classname='Objs'><value lbound='[0]' ubound='[1]'><value>"
    "<Sequence name='MainSequence' classname='Obj'><subprops>"
    "<Main classname='Objs'><value lbound='[0]' ubound='[]'/></Main>"
    "</subprops></Sequence></value></value></Seq>"
    "<FileGlobalDefaults classname='Obj'><subprops>"
    "<MeasurementPlugIns classname='Obj'><subprops>"
    "<PinMapPath classname='PathValue'><value>PinMap.pinmap</value></PinMapPath>"
    "<SpecificationsFilePaths classname='Strs'><value lbound='[0]' ubound='[1]'><value>Specifications.specs</value></value></SpecificationsFilePaths>"
    "<PatternFilePaths classname='Strs'><value lbound='[0]' ubound='[1]'><value>Pattern.digipat</value></value></PatternFilePaths>"
    "</subprops></MeasurementPlugIns>"
    "</subprops></FileGlobalDefaults>"
    "</subprops></Data>"
    "</teststandfileheader>",
  ),
]);

/// A step exercising the previously app-missing facets: a custom condition,
/// a mutex, and a recorded (non-default) Result outcome.
Uint8List _xmlStepExtras() => Uint8List.fromList([
  0xef,
  0xbb,
  0xbf,
  ...utf8.encode(
    "<?xml version='1.0'?>\n"
    "<teststandfileheader type='SequenceFile' fileversion='920' productname='TestStand'>"
    "<typelist/><Data classname='Obj'><subprops>"
    "<Seq classname='Objs'><value lbound='[0]' ubound='[1]'><value>"
    "<Sequence name='MainSequence' classname='Obj'><subprops>"
    "<Main classname='Objs'><value lbound='[0]' ubound='[1]'><value>"
    "<Step typename='Action' name='Extras'><subprops>"
    "<TS classname='Obj'><subprops>"
    "<CustExpr classname='ExprValue'><value>Locals.go == True</value></CustExpr>"
    "<UseMutex classname='Bool'><value>true</value></UseMutex>"
    "<MutexNameOrRef classname='ExprValue'><value>\"Bus\"</value></MutexNameOrRef>"
    "</subprops></TS>"
    "<Result classname='Obj'><subprops>"
    "<Status classname='Str'><value>Passed</value></Status>"
    "<Error classname='Obj'><subprops>"
    "<Code classname='Num'><value>0</value></Code>"
    "<Msg classname='Str'><value/></Msg>"
    "<Occurred classname='Bool'><value>false</value></Occurred>"
    "</subprops></Error>"
    "</subprops></Result>"
    "</subprops></Step>"
    "</value></value></Main>"
    "</subprops></Sequence></value></value></Seq></subprops></Data>"
    "</teststandfileheader>",
  ),
]);

Uint8List _binary() {
  final pool = <int>[];
  for (final n in [
    'PaddingNameSoTheInflatedBodyExceedsTheSixtyFourByteGuardHere',
    'SequenceFileData',
    'MainSequence',
    'Step',
    'Locals',
    'Parameters',
    r'My Computer\Lib\Read.vi',
    'Locals.x == 1',
    'ID#:abc123XYZ',
    '"6105A"',
  ]) {
    pool
      ..addAll(ascii.encode(n))
      ..add(0);
  }
  final header = Uint8List(0x108);
  header.setAll(0, ascii.encode('TOF1'));
  header.setAll(0x0a, ascii.encode('SequenceFile'));
  header.setAll(0x40, ascii.encode('TestStand'));
  final b = BytesBuilder()
    ..add(header)
    ..add(zlib.encode(pool));
  return Uint8List.fromList(b.toBytes());
}

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

  test('documentText/Title render a legacy INI document', () {
    final ini = ascii.encode([
      '[__Header__]',
      'ProductName = "TestStand"',
      'Version = 354',
      'Type = "SequenceFile"',
      '[DEF, %OBJROOT]',
      'SF = SequenceFileData',
      '[DEF, SF]',
      'Seq = Objs',
      '%NAME = "Data"',
      '[DEF, SF.Seq]',
      '%[0] = Sequence',
      '[DEF, SF.Seq[0]]',
      'Main = Objs',
      '%NAME = "MainSequence"',
      '[DEF, SF.Seq[0].Main]',
      '%[0] = Step',
      '%TYPE: %[0] = "Action"',
      '[DEF, SF.Seq[0].Main[0]]',
      '%NAME = "iniStep"',
      '',
    ].join('\n'));
    final doc = SeqDocument.parse(Uint8List.fromList(ini));
    expect(doc, isA<IniSeqDocument>());
    expect(documentTitle(doc), contains('1 sequences'));
    expect(documentTitle(doc), contains('ini'));
    final text = documentText(doc);
    expect(text, contains('MainSequence'));
    expect(text, contains('iniStep'));
    // The structured outline shapes the INI doc just like XML.
    final outline = SeqOutline.of((doc as IniSeqDocument).file);
    expect(outline.sequences.single.name, 'MainSequence');
  });

  test('outline note shows a flow-action jump target', () {
    final ini = ascii.encode([
      '[__Header__]',
      'ProductName = "TestStand"',
      'Version = 354',
      'Type = "SequenceFile"',
      '[DEF, %OBJROOT]',
      'SF = SequenceFileData',
      '[DEF, SF]',
      'Seq = Objs',
      '%NAME = "Data"',
      '[DEF, SF.Seq]',
      '%[0] = Sequence',
      '[DEF, SF.Seq[0]]',
      'Main = Objs',
      '%NAME = "MainSequence"',
      '[DEF, SF.Seq[0].Main]',
      '%[0] = Step',
      '%TYPE: %[0] = "Action"',
      '[DEF, SF.Seq[0].Main[0]]',
      'TS = Obj',
      '%NAME = "gotoStep"',
      '[DEF, SF.Seq[0].Main[0].TS]',
      'PassAct = String',
      'FailAct = String',
      'FailActTarget = String',
      '[SF.Seq[0].Main[0].TS]',
      'PassAct = "Next"',
      'FailAct = "Goto"',
      'FailActTarget = "\\"<Cleanup>\\""',
      '',
    ].join('\n'));
    final doc = SeqDocument.parse(Uint8List.fromList(ini)) as IniSeqDocument;
    final outline = SeqOutline.of(doc.file);
    final step = outline.sequences.single.groups.single.steps.single;
    expect(step.notes, contains('flow Next/Goto→<Cleanup>'));
  });

  test('outline note resolves an ID#: custom-condition target to a step name',
      () {
    final ini = ascii.encode([
      '[__Header__]',
      'ProductName = "TestStand"',
      'Version = 354',
      'Type = "SequenceFile"',
      '[DEF, %OBJROOT]',
      'SF = SequenceFileData',
      '[DEF, SF]',
      'Seq = Objs',
      '%NAME = "Data"',
      '[DEF, SF.Seq]',
      '%[0] = Sequence',
      '[DEF, SF.Seq[0]]',
      'Main = Objs',
      '%NAME = "MainSequence"',
      '[DEF, SF.Seq[0].Main]',
      '%[0] = Step',
      '%[1] = Step',
      '%TYPE: %[0] = "Action"',
      '%TYPE: %[1] = "Action"',
      '[DEF, SF.Seq[0].Main[0]]',
      'TS = Obj',
      '%NAME = "condStep"',
      '[DEF, SF.Seq[0].Main[0].TS]',
      'CustFalseActTarget = String',
      '[SF.Seq[0].Main[0].TS]',
      'CustFalseActTarget = "\\"ID#:STEP2\\""',
      '[DEF, SF.Seq[0].Main[1]]',
      'TS = Obj',
      '%NAME = "targetStep"',
      '[DEF, SF.Seq[0].Main[1].TS]',
      'Id = String',
      '[SF.Seq[0].Main[1].TS]',
      'Id = "ID#:STEP2"',
      '',
    ].join('\n'));
    final doc = SeqDocument.parse(Uint8List.fromList(ini)) as IniSeqDocument;
    final outline = SeqOutline.of(doc.file);
    final cond = outline.sequences.single.groups.single.steps.first;
    expect(cond.notes, contains('cust-false→targetStep'));
  });

  test('SeqOutline.of shapes sequences → groups → steps', () {
    final doc = SeqDocument.parse(_xml()) as XmlSeqDocument;
    final outline = SeqOutline.of(doc.file);

    expect(outline.sequences, hasLength(1));
    expect(outline.indexOf('MainSequence'), 0);
    expect(outline.indexOf('NoSuchSequence'), isNull);

    final seq = outline.sequences.single;
    expect(seq.name, 'MainSequence');
    expect(seq.stepCount, 1);
    expect(seq.groups.map((g) => g.name), ['Main']);

    final step = seq.groups.single.steps.single;
    expect(step.name, 'S1');
    expect(step.type, 'Statement');
    expect(step.isInFileCall, isFalse);
    expect(step.summary, contains('S1 [Statement]'));
  });

  test('addRecent moves to front, dedups, caps, and is non-mutating', () {
    expect(addRecent(const [], 'a'), ['a']);

    // New entry goes to the front.
    expect(addRecent(const ['a', 'b'], 'c'), ['c', 'a', 'b']);

    // Re-adding an existing entry moves it to the front (dedup, no growth).
    expect(addRecent(const ['a', 'b', 'c'], 'c'), ['c', 'a', 'b']);

    // Cap is respected (oldest dropped).
    expect(addRecent(const ['a', 'b', 'c'], 'd', cap: 3), ['d', 'a', 'b']);

    // Input is not mutated.
    final input = ['a', 'b'];
    final out = addRecent(input, 'x');
    expect(input, ['a', 'b']);
    expect(out, ['x', 'a', 'b']);
  });

  test(
    'StepOutline.of populates structured limits, omitting absent fields',
    () {
      final doc = SeqDocument.parse(_xmlWithLimits()) as XmlSeqDocument;
      final outline = SeqOutline.of(doc.file);
      final step = outline.sequences.single.groups.single.steps.single;

      expect(step.name, 'Check V');
      expect(step.limits, isNotNull); // summary string still present
      final d = step.limitsDetail;
      expect(d, isNotNull);
      expect(d!.comparison, 'GELE');
      expect(d.low, '9');
      expect(d.high, '11');
      expect(d.dataSource, 'Locals.V');
      // Absent fields stay null (not invented) and are dropped from rows.
      expect(d.nominal, isNull);
      expect(d.thresholdType, isNull);
      final rowLabels = d.rows.map((r) => r.$1);
      expect(
        rowLabels,
        containsAll(['Comparison', 'Low', 'High', 'Data source']),
      );
      expect(rowLabels, isNot(contains('Nominal')));
    },
  );

  test('StepOutline.of surfaces a forced run mode (Skip) as runMode', () {
    final doc = SeqDocument.parse(_xmlWithSkip()) as XmlSeqDocument;
    final step = SeqOutline.of(doc.file).sequences.single.groups.single.steps.single;
    expect(step.name, 'Skipped');
    expect(step.runMode, 'Skip');
    // It is also reflected in the one-line summary and is searchable.
    expect(step.summary, contains('{mode Skip}'));
    expect(stepMatches(step, 'skip'), isTrue);
  });

  test('a step free-text comment is searchable via stepMatches', () {
    final step = StepOutline(
      name: 'Lock',
      type: 'Action',
      comment: 'Lock the calibration fixture',
      notes: const [],
    );
    // Query is pre-lowercased by the caller; match on comment substrings.
    expect(stepMatches(step, 'calibration'), isTrue);
    expect(stepMatches(step, 'fixture'), isTrue);
    expect(stepMatches(step, 'nope'), isFalse);
  });

  test('units, data source, and call args are searchable + in the summary', () {
    final step = StepOutline(
      name: 'Get User',
      type: 'Action',
      units: 'mA',
      dataSource: 'Step.Result.PassFail',
      callArgs: [
        CallArgOutline(
          name: 'LoginName',
          direction: 'in',
          boundExpression: 'FileGlobals.UserToAutoLogin',
          displayType: 'String',
        ),
      ],
      notes: const [],
    );
    // Each surfaced field is reachable via search (query pre-lowercased).
    expect(stepMatches(step, 'ma'), isTrue); // units
    expect(stepMatches(step, 'step.result.passfail'), isTrue); // data source
    expect(stepMatches(step, 'loginname'), isTrue); // call-arg name
    expect(stepMatches(step, 'usertoautologin'), isTrue); // call-arg expression
    expect(stepMatches(step, 'string'), isTrue); // call-arg display type
    expect(stepMatches(step, 'absent'), isFalse);
    // And each appears in the one-line summary.
    final s = step.summary;
    expect(s, contains('{units mA}'));
    expect(s, contains('{data-source Step.Result.PassFail}'));
    expect(s, contains('{args: LoginName in←FileGlobals.UserToAutoLogin}'));
  });

  test('StepOutline.of surfaces notable step flags as searchable notes', () {
    final doc = SeqDocument.parse(_xmlWithFlags()) as XmlSeqDocument;
    final step = SeqOutline.of(doc.file).sequences.single.groups.single.steps.single;
    expect(step.notes, containsAll(['ignore-RTE', 'no-seq-fail', 'no-record']));
    // Searchable and present in the one-line summary.
    expect(stepMatches(step, 'no-record'), isTrue);
    expect(step.summary, contains('no-seq-fail'));
  });

  test('StepOutline.of surfaces the Additional Results spec as a note', () {
    final doc = SeqDocument.parse(_xmlWithAddlResults()) as XmlSeqDocument;
    final step = SeqOutline.of(doc.file).sequences.single.groups.single.steps.single;
    // The recorded slots, with the set condition surfaced and the empty one not.
    expect(step.notes, contains('+results: Input, Output if Locals.Save == True'));
    // Searchable (by slot name and by gating expression) and in the summary.
    expect(stepMatches(step, 'output'), isTrue);
    expect(stepMatches(step, 'locals.save'), isTrue);
    expect(step.summary, contains('+results: Input'));
  });

  test('StepOutline.of surfaces measurement parameters with type/direction', () {
    final doc = SeqDocument.parse(_xmlWithMeasParams()) as XmlSeqDocument;
    final step = SeqOutline.of(doc.file).sequences.single.groups.single.steps.single;
    final p = step.measurementParams;
    expect(p, hasLength(3));
    expect(p[0].name, 'voltage_level');
    expect(p[0].dataType, 'TypeDouble');
    expect(p[0].direction, 'In');
    expect(p[0].isArray, isFalse);
    expect(p[0].cell, 'TypeDouble = 6');
    expect(p[0].line, 'voltage_level in TypeDouble = 6');
    // The array output carries a type specialization and is not logged.
    expect(p[1].isArray, isTrue);
    expect(p[1].typeSpecialization, 'IOResource');
    expect(p[1].logged, isFalse);
    expect(p[1].cell, 'TypeString (IOResource)[] · not logged');
    expect(p[1].line, 'readings out TypeString (IOResource)[] [not logged]');
    // The enum param renders its allowed values in the cell and search line.
    expect(p[2].name, 'measurement_type');
    expect(p[2].enumValues, ['NONE=0', 'DC_VOLTS=1']);
    expect(p[2].cell, 'TypeEnum {NONE=0, DC_VOLTS=1}');
    expect(p[2].line, contains('{NONE=0, DC_VOLTS=1}'));
    // Searchable (by name, type, specialization, enum constant) and in summary.
    expect(stepMatches(step, 'voltage_level'), isTrue);
    expect(stepMatches(step, 'typedouble'), isTrue);
    expect(stepMatches(step, 'ioresource'), isTrue);
    expect(stepMatches(step, 'dc_volts'), isTrue);
    expect(step.summary, contains('voltage_level in TypeDouble = 6'));
  });

  test('StepOutline.of surfaces the LabVIEW VI-call descriptor + connector pane', () {
    final doc = SeqDocument.parse(_xmlWithViCall()) as XmlSeqDocument;
    final step = SeqOutline.of(doc.file).sequences.single.groups.single.steps.single;
    expect(step.adapter, 'labView');
    // Library/project ride as a searchable note (parity with the dump {vi:} chip).
    expect(step.notes, contains('vi: lib NIDCPower.lvlib, proj NIDCPower.lvproj'));
    final c = step.connectorParams;
    expect(c, hasLength(2));
    expect(c[0].label, '#11 sequence context');
    expect(c[0].cell, 'Object Reference ←ThisContext');
    expect(c[0].line, '#11 sequence context (Object Reference)←ThisContext');
    expect(c[1].label, '#0 error out');
    expect(c[1].cell, 'Container ←Step.Result.Error');
    // Searchable by connector content + library, and present in summary.
    expect(stepMatches(step, 'object reference'), isTrue);
    expect(stepMatches(step, 'nidcpower.lvlib'), isTrue);
    expect(step.summary,
        contains('#11 sequence context (Object Reference)←ThisContext'));
  });

  test('StepOutline.of surfaces the Python call descriptor', () {
    final doc = SeqDocument.parse(_xmlWithPyCall()) as XmlSeqDocument;
    final step = SeqOutline.of(doc.file).sequences.single.groups.single.steps.single;
    expect(step.adapter, 'python');
    expect(step.target, 'create_instrument_sessions');
    expect(step.notes, contains(r'python: mod ..\smu\test.py, py 3.9'));
    // Searchable by the called function and the module file.
    expect(stepMatches(step, 'create_instrument_sessions'), isTrue);
    expect(stepMatches(step, 'test.py'), isTrue);
  });

  test('SeqOutline.of surfaces the measurement plug-in resource set', () {
    final doc = SeqDocument.parse(_xmlWithPlugins()) as XmlSeqDocument;
    final mp = SeqOutline.of(doc.file).plugins!;
    expect(mp.pinMap, 'PinMap.pinmap');
    expect(mp.specifications, ['Specifications.specs']);
    expect(mp.patterns, ['Pattern.digipat']);
    expect(mp.rows, contains(('Pin map', 'PinMap.pinmap')));
    expect(mp.rows, contains(('Specifications', 'Specifications.specs')));
    expect(mp.rows, contains(('Patterns', 'Pattern.digipat')));
  });

  test('SeqOutline.of has null plugins when the file declares none', () {
    final doc = SeqDocument.parse(_xmlWithLimits()) as XmlSeqDocument;
    expect(SeqOutline.of(doc.file).plugins, isNull);
  });

  test('StepOutline.of surfaces custom condition, mutex, and result outcome', () {
    final doc = SeqDocument.parse(_xmlStepExtras()) as XmlSeqDocument;
    final step = SeqOutline.of(doc.file).sequences.single.groups.single.steps.single;
    // Custom condition is an expression row; mutex + result are notes.
    expect(step.expressions, contains(('Custom condition', 'Locals.go == True')));
    expect(step.notes, contains('mutex "Bus"'));
    expect(step.notes, contains('result status Passed'));
    // All three are searchable and the summary carries them.
    expect(stepMatches(step, 'locals.go'), isTrue);
    expect(stepMatches(step, 'mutex'), isTrue);
    expect(stepMatches(step, 'passed'), isTrue);
    expect(step.summary, contains('mutex "Bus"'));
  });

  test('StepOutline.of surfaces a step status expression', () {
    final doc = SeqDocument.parse(_xmlWithStatusExpr()) as XmlSeqDocument;
    final step = SeqOutline.of(doc.file).sequences.single.groups.single.steps.single;
    expect(step.name, 'Decide');
    expect(step.expressions, contains(('Status', 'Locals.x == 1')));
    // It is searchable and reflected in the one-line summary.
    expect(stepMatches(step, 'locals.x'), isTrue);
    expect(step.summary, contains('Status: Locals.x == 1'));
  });

  test('a Normal-mode step has no runMode (default is not noteworthy)', () {
    final doc = SeqDocument.parse(_xml()) as XmlSeqDocument;
    final step = SeqOutline.of(doc.file).sequences.single.groups.single.steps.single;
    expect(step.runMode, isNull);
    expect(step.summary, isNot(contains('mode')));
  });

  test('outlineSummary/totalSteps count sequences and steps (pluralized)', () {
    final doc = SeqDocument.parse(_xml()) as XmlSeqDocument;
    final outline = SeqOutline.of(doc.file);

    expect(outline.totalSteps, 1);
    // Fixture has 1 sequence / 1 step → singular forms.
    expect(outlineSummary(outline), '1 sequence · 1 step');
    // With a type count appended.
    expect(
      outlineSummary(outline, typeCount: 5),
      '1 sequence · 1 step · 5 types',
    );
  });

  test('pathBasename handles / and \\ separators and edge cases', () {
    expect(pathBasename(r'C:\a\b\Foo.vi'), 'Foo.vi');
    expect(pathBasename('/x/y/Bar.seq'), 'Bar.seq');
    expect(pathBasename('bare'), 'bare');
    expect(pathBasename(''), '');
    // Mixed separators: the last separator of either kind wins.
    expect(pathBasename(r'/x\y/z\End.seq'), 'End.seq');
    // Trailing separator → empty (callers add their own fallback).
    expect(pathBasename('/x/y/'), '');
  });

  test('StepOutline.targetDisplay shows basename + full-path tooltip', () {
    ({String label, String tooltip})? disp(String? target) => StepOutline(
      name: 'x',
      type: 'y',
      adapter: target == null ? null : 'labView',
      target: target,
      notes: const [],
    ).targetDisplay;

    expect(disp(r'C:\a\b\Foo.vi'), (
      label: 'Foo.vi',
      tooltip: r'C:\a\b\Foo.vi',
    ));
    expect(disp('/x/y/Bar.vi'), (label: 'Bar.vi', tooltip: '/x/y/Bar.vi'));
    // A bare (non-path) target is shown verbatim.
    expect(disp('MySequence'), (label: 'MySequence', tooltip: 'MySequence'));
    // No target → no display.
    expect(disp(null), isNull);
  });

  test('VarOutline.label shows scalar value or container size', () {
    // Scalar with a default value.
    expect(VarOutline(name: 'Count', type: 'Num', value: '3').label,
        'Count : Num = 3');
    // Array container → element count in brackets.
    expect(
      VarOutline(name: 'List', type: 'Objs', isArray: true, containerCount: 0)
          .label,
      'List : Objs [0]',
    );
    // Object/cluster container → field count (singular vs plural).
    expect(
      VarOutline(name: 'Limits', type: 'Obj', containerCount: 2).label,
      'Limits : Obj {2 fields}',
    );
    expect(
      VarOutline(name: 'One', type: 'Obj', containerCount: 1).label,
      'One : Obj {1 field}',
    );
    // Bare scalar with neither value nor container info.
    expect(VarOutline(name: 'X', type: 'Str').label, 'X : Str');
    // A free-text comment is appended after value/container info.
    expect(
      VarOutline(name: 'Off', type: 'Num', value: '4', comment: 'bitmask').label,
      'Off : Num = 4  // bitmask',
    );
    expect(
      VarOutline(name: 'T', type: 'Obj', containerCount: 2, comment: 'pass band')
          .label,
      'T : Obj {2 fields}  // pass band',
    );
  });

  test('filterSequences keeps matches; empty query is identity', () {
    final doc = SeqDocument.parse(_xml()) as XmlSeqDocument;
    final outline = SeqOutline.of(doc.file);

    // Empty/blank query returns the same instance.
    expect(filterSequences(outline, ''), same(outline));
    expect(filterSequences(outline, '   '), same(outline));

    // A query matching the step 'S1' keeps its sequence (with the step).
    final byStep = filterSequences(outline, 's1');
    expect(byStep.sequences, hasLength(1));
    final seq = byStep.sequences.single;
    expect(seq.name, 'MainSequence');
    expect(
      seq.groups.expand((g) => g.steps).map((s) => s.name),
      contains('S1'),
    );

    // A query matching the sequence name keeps the whole sequence.
    final byName = filterSequences(outline, 'mainseq');
    expect(byName.sequences.single.name, 'MainSequence');

    // A non-matching query yields no sequences.
    expect(filterSequences(outline, 'zzz-nope').sequences, isEmpty);
  });

  test('filterSequences matches a variable by its free-text comment', () {
    final outline = SeqOutline([
      SequenceOutline(
        name: 'Seq',
        parameters: const [],
        locals: [
          VarOutline(name: 'Off', type: 'Num', comment: 'bitmask of lamps'),
        ],
        groups: const [],
      ),
    ]);
    // The comment text alone (query pre-lowercased) keeps the sequence.
    final byComment = filterSequences(outline, 'bitmask');
    expect(byComment.sequences, hasLength(1));
    expect(byComment.sequences.single.locals.single.name, 'Off');
    // A non-matching query drops it.
    expect(filterSequences(outline, 'zzz-nope').sequences, isEmpty);
  });

  test('propertyTree shapes the raw PropertyObject tree', () {
    final doc = SeqDocument.parse(_xml()) as XmlSeqDocument;
    final root = propertyTree(doc.file);

    // Root is the Data object; class Obj; has children (not a leaf).
    expect(root.name, 'Data');
    expect(root.className, 'Obj');
    expect(root.isLeaf, isFalse);
    expect(root.typeLabel, contains('Obj'));

    // Walk Data → Seq (Objs array) → its single element is the Sequence object
    // itself (name taken from the name= attribute).
    final seqContainer = root.children.firstWhere((c) => c.name == 'Seq');
    expect(seqContainer.isArray, isTrue);
    expect(seqContainer.typeLabel, contains('Objs['));
    final mainSeq = seqContainer.children.single;
    expect(mainSeq.name, 'MainSequence');
    expect(mainSeq.attributes['name'], 'MainSequence');
  });

  test('PropertyNode surfaces %INSTOVRD as isInstanceOverride', () {
    final overridden = PropertyNode.of(
      SeqProperty(name: 'TS', attributes: const {'%INSTOVRD': '5046297'}),
    );
    expect(overridden.isInstanceOverride, isTrue);
    // The raw flags stay visible in the attributes map (nothing hidden).
    expect(overridden.attributes['%INSTOVRD'], '5046297');

    final plain = PropertyNode.of(SeqProperty(name: 'Mode', scalar: 'Normal'));
    expect(plain.isInstanceOverride, isFalse);
  });

  test('filterTree keeps matches with ancestors; empty query is identity', () {
    final doc = SeqDocument.parse(_xml()) as XmlSeqDocument;
    final root = propertyTree(doc.file);

    // Empty query returns the tree unchanged (same instance).
    expect(filterTree(root, ''), same(root));
    expect(filterTree(root, '   '), same(root));

    // A query hitting the deep Step (name 'S1') keeps the ancestor chain.
    final f = filterTree(root, 'S1');
    expect(f, isNotNull);
    expect(f!.name, 'Data');
    final seq = f.children.firstWhere((c) => c.name == 'Seq');
    final mainSeq = seq.children.single; // MainSequence kept as an ancestor
    expect(mainSeq.name, 'MainSequence');
    // The matching leaf is reachable somewhere under MainSequence.
    bool hasStep(PropertyNode n) => n.name == 'S1' || n.children.any(hasStep);
    expect(hasStep(mainSeq), isTrue);

    // A query matching nothing prunes the whole tree to null.
    expect(filterTree(root, 'zzz-no-such-token'), isNull);
  });

  test('coverageLabel formats the modeled/total ratio', () {
    final doc = SeqDocument.parse(_xml()) as XmlSeqDocument;
    final c = measureCoverage(doc.file);
    final label = coverageLabel(c);
    expect(label, startsWith('model coverage '));
    expect(label, contains('${c.modeled}/${c.total}'));
    expect(label, matches(RegExp(r'\d+\.\d%')));
    // The fixture's typed lens recovers something but not everything.
    expect(c.modeled, greaterThan(0));
    expect(c.modeled, lessThanOrEqualTo(c.total));
  });

  test('binaryHeaderRows surfaces recon facts for a TOF1 file', () {
    final doc = SeqDocument.parse(_binary());
    expect(doc, isA<BinarySeqDocument>());
    final rows = binaryHeaderRows(doc as BinarySeqDocument);
    final map = {for (final (k, v) in rows) k: v};

    expect(map['Encoding'], 'binary');
    expect(map['File type'], 'SequenceFile');
    expect(map['Product'], 'TestStand');
    expect(map['Inflated body'], endsWith('bytes'));
    expect(int.parse(map['Strings recovered']!), greaterThan(0));
    // The framed-body layout rows are surfaced when the body frames.
    expect(map.containsKey('Record region'), isTrue);
    expect(map.containsKey('Record sentinels'), isTrue);
    expect(int.parse(map['Strings in region']!), greaterThanOrEqualTo(5));
    // The content-identified property-name table is surfaced.
    expect(map['Property-name table'], endsWith('entries'));
    expect(
      int.parse(map['Property-name table']!.split(' ').first),
      greaterThan(0),
    );
  });

  test('documentText surfaces all recovered datums for a TOF1 file', () {
    final doc = SeqDocument.parse(_binary());
    final text = documentText(doc);
    expect(text, contains('recovered property/object names'));
    // The fixture pool's model names are surfaced as recovered names.
    for (final n in ['MainSequence', 'Step', 'Locals', 'Parameters']) {
      expect(text, contains(n), reason: 'missing recovered name $n');
    }
    // The new recovered categories are each surfaced with their content.
    expect(text, contains('module call-targets'));
    expect(text, contains(r'My Computer\Lib\Read.vi'));
    expect(text, contains('expressions (test logic)'));
    expect(text, contains('Locals.x == 1'));
    expect(text, contains('step references'));
    expect(text, contains('ID#:abc123XYZ'));
    expect(text, contains('quoted literals (values)'));
    expect(text, contains('"6105A"'));
    // Honest framing: it must not claim the tree/values are decoded.
    expect(text, contains('record tree not yet decoded'));
    expect(text, contains('record links not yet decoded'));
  });

  test('binaryHeaderRows surfaces recovered-datum counts', () {
    final doc = SeqDocument.parse(_binary()) as BinarySeqDocument;
    final map = {for (final (k, v) in binaryHeaderRows(doc)) k: v};
    expect(int.parse(map['Object names']!), greaterThan(0));
    expect(int.parse(map['Module call-targets']!), greaterThanOrEqualTo(1));
    expect(int.parse(map['Step references']!), greaterThanOrEqualTo(1));
    expect(int.parse(map['Expressions']!), greaterThanOrEqualTo(1));
    expect(int.parse(map['Quoted literals']!), greaterThanOrEqualTo(1));
  });

  test('binaryRecoverySections groups non-empty recovered datums', () {
    final doc = SeqDocument.parse(_binary()) as BinarySeqDocument;
    final sections = binaryRecoverySections(doc);
    final titles = [for (final s in sections) s.title];
    // The fixture exercises every category, so all five are present and ordered.
    expect(titles, [
      'Object names',
      'Module call-targets',
      'Step references',
      'Expressions (test logic)',
      'Quoted literals (values)',
    ]);
    // Every listed section is non-empty (empties are dropped) with real content.
    for (final s in sections) {
      expect(s.items, isNotEmpty);
    }
    final byTitle = {for (final s in sections) s.title: s.items};
    expect(byTitle['Module call-targets'], contains(r'My Computer\Lib\Read.vi'));
    expect(byTitle['Expressions (test logic)'], contains('Locals.x == 1'));
    expect(byTitle['Quoted literals (values)'], contains('"6105A"'));
    // The pool-only fixture has no record region, so no named-scalar section.
    expect(titles, isNot(contains('Named scalar values')));
  });

  test('binaryRecoverySections surfaces named + inline numeric values', () {
    final doc = BinarySeqDocument(
      header: detectSeqHeader(_binary()),
      inflatedSize: 0,
      strings: const [],
      stringTable: const [],
      namedScalars: const [
        BinaryNamedScalar(
            name: 'Parameters',
            rawTag: 0,
            rawTypeCode: 62,
            value: 8192.0,
            wordIndex: 2),
      ],
      scalarDoubles: const [8192.0, -2.0],
      namedRecords: const [
        BinaryNamedRecord(name: 'ResultList', count: 10, rawTag: 2),
      ],
    );
    final byTitle = {for (final s in binaryRecoverySections(doc)) s.title: s.items};
    expect(byTitle['Named scalar values'], isNotNull);
    // Value is shown; the NI type code is carried verbatim, labelled not-modeled.
    expect(byTitle['Named scalar values']!.single,
        'Parameters = 8192.0  (raw type 62, not modeled)');
    // The full distinct inline-numeric superset gets its own section.
    expect(byTitle['Inline numeric values'], ['8192.0', '-2.0']);
    // The consistently-tagged named-record header census, raw tag verbatim.
    expect(byTitle['Named-record headers'],
        ['ResultList ×10  (raw tag 2, not modeled)']);
    // And all appear as count rows.
    final rows = {for (final (k, v) in binaryHeaderRows(doc)) k: v};
    expect(rows['Inline numbers'], '2');
    expect(rows['Named scalars'], '1');
    expect(rows['Named records'], '1');
  });

  test('writeCapped lists up to the cap, then an honest "and N more"', () {
    // Under the cap: every item listed, no summary line.
    final small = StringBuffer();
    writeCapped(small, ['a', 'b', 'c'], (s) => s);
    expect(small.toString(), '  a\n  b\n  c\n');
    expect(small.toString(), isNot(contains('more')));

    // Over the cap: exactly maxListedEntries listed + a truthful remainder line.
    final big = StringBuffer();
    final items = [for (var i = 0; i < maxListedEntries + 7; i++) 'n$i'];
    writeCapped(big, items, (s) => s);
    final lines = big.toString().trimRight().split('\n');
    expect(lines, hasLength(maxListedEntries + 1));
    expect(lines.first, '  n0');
    expect(lines[maxListedEntries - 1], '  n${maxListedEntries - 1}');
    expect(lines.last, '  … and 7 more');
  });

  test('documentText/Title handle unrecognized bytes without throwing', () {
    final doc = SeqDocument.parse(Uint8List.fromList([1, 2, 3, 4]));
    expect(doc, isA<UnknownSeqDocument>());
    expect(documentTitle(doc), contains('unrecognized'));
    expect(documentText(doc), contains('Not a recognized TestStand sequence.'));
  });
}
