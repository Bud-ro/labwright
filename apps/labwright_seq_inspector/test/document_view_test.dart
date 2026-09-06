import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_seq/labwright_seq.dart';
import 'package:labwright_seq_inspector/src/document_view.dart';
import 'package:labwright_seq_inspector/src/property_outline.dart';
import 'package:labwright_seq_inspector/src/recent_files.dart';
import 'package:labwright_seq_inspector/src/sequence_outline.dart';

import 'util.dart';

StepOutline stepOf(String typename, String name, [String subprops = '']) {
  final doc =
      SeqDocument.parse(seqXml(steps: step(typename, name, subprops)))
          as XmlSeqDocument;
  return SeqOutline.of(doc.file).sequences.single.groups.single.steps.single;
}

IniSeqDocument iniDoc(List<String> lines) =>
    SeqDocument.parse(
          Uint8List.fromList(
            ascii.encode(
              [
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
                ...lines,
                '',
              ].join('\n'),
            ),
          ),
        )
        as IniSeqDocument;

Uint8List binarySeq() {
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
  return Uint8List.fromList(
    (BytesBuilder()
          ..add(header)
          ..add(zlib.encode(pool)))
        .toBytes(),
  );
}

Map<String, String> headerRows(BinarySeqDocument d) => {
  for (final (k, v) in binaryHeaderRows(d)) k: v,
};

void expectMatches(StepOutline s, Map<String, bool> queries) => queries.forEach(
  (q, want) => expect(stepMatches(s, q), want, reason: 'query $q'),
);

void main() {
  final xmlDoc =
      SeqDocument.parse(seqXml(steps: step('Statement', 'S1')))
          as XmlSeqDocument;

  test('XML document renders title and dump text', () {
    expect(documentTitle(xmlDoc), contains('1 sequences'));
    expect(documentTitle(xmlDoc), contains('xml'));
    expect(documentText(xmlDoc), contains('MainSequence'));
    expect(documentText(xmlDoc), contains('S1'));
  });

  test('legacy INI document renders title, text, and outline', () {
    final doc = iniDoc([
      '[DEF, SF.Seq[0].Main]',
      '%[0] = Step',
      '%TYPE: %[0] = "Action"',
      '[DEF, SF.Seq[0].Main[0]]',
      '%NAME = "iniStep"',
    ]);
    expect(documentTitle(doc), contains('1 sequences'));
    expect(documentTitle(doc), contains('ini'));
    expect(documentText(doc), contains('MainSequence'));
    expect(documentText(doc), contains('iniStep'));
    expect(SeqOutline.of(doc.file).sequences.single.name, 'MainSequence');
  });

  test('outline note shows a flow-action jump target (INI)', () {
    final doc = iniDoc([
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
    ]);
    final s = SeqOutline.of(doc.file).sequences.single.groups.single.steps;
    expect(s.single.notes, contains('flow Next/Goto→<Cleanup>'));
  });

  test('outline note resolves an ID#: condition target to a step name', () {
    final doc = iniDoc([
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
    ]);
    final s = SeqOutline.of(doc.file).sequences.single.groups.single.steps;
    expect(s.first.notes, contains('cust-false→targetStep'));
  });

  test('SeqOutline.of shapes sequences → groups → steps', () {
    final outline = SeqOutline.of(xmlDoc.file);
    expect(outline.sequences, hasLength(1));
    expect(outline.indexOf('MainSequence'), 0);
    expect(outline.indexOf('NoSuchSequence'), isNull);
    final seq = outline.sequences.single;
    expect(seq.name, 'MainSequence');
    expect(seq.stepCount, 1);
    expect(seq.groups.map((g) => g.name), ['Main']);
    final s = seq.groups.single.steps.single;
    expect(s.name, 'S1');
    expect(s.type, 'Statement');
    expect(s.isInFileCall, isFalse);
    expect(s.summary, contains('S1 [Statement]'));
    expect(s.runMode, isNull, reason: 'default run mode is not noteworthy');
    expect(s.summary, isNot(contains('mode')));
  });

  test('outlineSummary/totalSteps count and pluralize', () {
    final outline = SeqOutline.of(xmlDoc.file);
    expect(outline.totalSteps, 1);
    expect(outlineSummary(outline), '1 sequence · 1 step');
    expect(
      outlineSummary(outline, typeCount: 5),
      '1 sequence · 1 step · 5 types',
    );
    final two =
        SeqDocument.parse(
              seqXml(
                steps: step('Action', 'A') + step('Action', 'B'),
                ubound: '[2]',
              ),
            )
            as XmlSeqDocument;
    expect(outlineSummary(SeqOutline.of(two.file)), '1 sequence · 2 steps');
  });

  test('addRecent moves to front, dedups, caps, and is non-mutating', () {
    const rows = <(List<String>, String, int, List<String>)>[
      ([], 'a', 10, ['a']),
      (['a'], 'a', 10, ['a']),
      (['a', 'b'], 'c', 10, ['c', 'a', 'b']),
      (['a', 'b', 'c'], 'c', 10, ['c', 'a', 'b']),
      (['a', 'b', 'c'], 'd', 3, ['d', 'a', 'b']),
      (['a', 'b'], 'c', 1, ['c']),
    ];
    for (final (input, added, cap, want) in rows) {
      expect(addRecent(input, added, cap: cap), want, reason: '$input+$added');
    }
    final input = ['a', 'b'];
    expect(addRecent(input, 'x'), ['x', 'a', 'b']);
    expect(input, ['a', 'b'], reason: 'input must not be mutated');
  });

  test('structured limits populate, omitting absent fields', () {
    final s = stepOf(
      'NumericLimitTest',
      'Check V',
      prop('Comp', 'GELE') +
          obj('Limits', prop('Low', '9') + prop('High', '11')) +
          prop('DataSource', 'Locals.V'),
    );
    expect(s.name, 'Check V');
    expect(s.limits, isNotNull);
    final d = s.limitsDetail!;
    expect(
      (d.comparison, d.low, d.high, d.dataSource, d.nominal, d.thresholdType),
      ('GELE', '9', '11', 'Locals.V', null, null),
    );
    final labels = d.rows.map((r) => r.$1);
    expect(labels, containsAll(['Comparison', 'Low', 'High', 'Data source']));
    expect(labels, isNot(contains('Nominal')));
  });

  test('a forced run mode (Skip) surfaces as runMode + summary + search', () {
    final s = stepOf('Statement', 'Skipped', ts(prop('Mode', 'Skip')));
    expect(s.runMode, 'Skip');
    expect(s.summary, contains('{mode Skip}'));
    expectMatches(s, {'skip': true});
  });

  test('a step status expression surfaces + is searchable', () {
    final s = stepOf(
      'Statement',
      'Decide',
      ts(prop('StatusExpr', 'Locals.x == 1')),
    );
    expect(s.expressions, contains(('Status', 'Locals.x == 1')));
    expect(s.summary, contains('Status: Locals.x == 1'));
    expectMatches(s, {'locals.x': true});
  });

  test('notable step flags surface as searchable notes', () {
    final s = stepOf(
      'Action',
      'Flagged',
      ts(
        prop('IgnoreRTE', 'true') +
            prop('StepFCSeqF', 'false') +
            prop('ResultOption', '0'),
      ),
    );
    expect(s.notes, containsAll(['ignore-RTE', 'no-seq-fail', 'no-record']));
    expect(s.summary, contains('no-seq-fail'));
    expectMatches(s, {'no-record': true});
  });

  test('an Additional Results recording spec surfaces as a note', () {
    String result(String name, String condition, String state) => obj(
      name,
      prop('Condition', condition, 'ExprValue') +
          prop('Flags', '8192', 'Num') +
          prop('CheckedState', state, 'Num'),
      cls: 'PythonParameterResult',
    );
    final s = stepOf(
      'Action',
      'Run Python',
      sdata(
        obj(
          'Param',
          obj(
            'AdditionalResults',
            result('Input', '', '1') +
                result('Output', 'Locals.Save == True', '2'),
          ),
          cls: 'NI_PythonParameter',
        ),
      ),
    );
    expect(s.notes, contains('+results: Input, Output if Locals.Save == True'));
    expect(s.summary, contains('+results: Input'));
    expectMatches(s, {'output': true, 'locals.save': true});
  });

  test('measurement parameters surface with type/direction/enum detail', () {
    String param(
      String name,
      String type,
      String dir,
      String dim,
      String arg, [
      String extra = '',
    ]) => entry(
      prop('Name', name, 'Str') +
          prop('Type', type, 'Str') +
          prop('Direction', dir, 'Str') +
          prop('Dimension', dim, 'Num') +
          prop('ArgumentValue', arg, 'ExprValue') +
          extra,
    );
    final s = stepOf(
      'NI_Measurement',
      'Measure V',
      obj(
        'Measurement',
        objs('Parameters', [
          param('voltage_level', 'TypeDouble', 'In', '0', '6'),
          param(
            'readings',
            'TypeString',
            'Out',
            '1',
            '',
            prop('TypeSpecialization', 'IOResource', 'Str') +
                prop('Log', 'false', 'Bool'),
          ),
          param(
            'measurement_type',
            'TypeEnum',
            'In',
            '0',
            '',
            objs('EnumDefinition', [
              prop('NONE', '0', 'Num'),
              prop('DC_VOLTS', '1', 'Num'),
            ]),
          ),
        ]),
      ),
    );
    final p = s.measurementParams;
    expect(p, hasLength(3));
    expect(
      (p[0].name, p[0].dataType, p[0].direction, p[0].isArray),
      ('voltage_level', 'TypeDouble', 'In', false),
    );
    expect(p[0].cell, 'TypeDouble = 6');
    expect(p[0].line, 'voltage_level in TypeDouble = 6');
    expect(
      (p[1].isArray, p[1].typeSpecialization, p[1].logged),
      (true, 'IOResource', false),
    );
    expect(p[1].cell, 'TypeString (IOResource)[] · not logged');
    expect(p[1].line, 'readings out TypeString (IOResource)[] [not logged]');
    expect(p[2].name, 'measurement_type');
    expect(p[2].enumValues, ['NONE=0', 'DC_VOLTS=1']);
    expect(p[2].cell, 'TypeEnum {NONE=0, DC_VOLTS=1}');
    expect(p[2].line, contains('{NONE=0, DC_VOLTS=1}'));
    expect(s.summary, contains('voltage_level in TypeDouble = 6'));
    expectMatches(s, {
      'voltage_level': true,
      'typedouble': true,
      'ioresource': true,
      'dc_volts': true,
    });
  });

  test('a LabVIEW VI-call surfaces descriptor + connector pane', () {
    String parm(String label, String type, String arg, String conn) => entry(
      prop('Label', label, 'Str') +
          prop('DisplayType', type, 'Str') +
          prop('ArgVal', arg, 'ExprValue') +
          prop('ConnectorNumber', conn, 'Num'),
    );
    final s = stepOf(
      'Action',
      'Init DCPower',
      sdata(
        cls: 'FGModule',
        obj(
          'ViCall',
          cls: 'VICall',
          prop('VIPath', r'My Computer\NIDCPower.vi', 'PathValue') +
              prop('Namespace', 'NIDCPower.lvlib', 'Str') +
              prop('ProjectPath', 'NIDCPower.lvproj', 'PathValue') +
              objs('Parms', [
                parm(
                  'sequence context',
                  'Object Reference',
                  'ThisContext',
                  '11',
                ),
                parm('error out', 'Container', 'Step.Result.Error', '0'),
              ]),
        ),
      ),
    );
    expect(s.adapter, SeqAdapter.labView);
    expect(s.notes, contains('vi: lib NIDCPower.lvlib, proj NIDCPower.lvproj'));
    final c = s.connectorParams;
    expect(c, hasLength(2));
    expect(c[0].label, '#11 sequence context');
    expect(c[0].cell, 'Object Reference ←ThisContext');
    expect(c[0].line, '#11 sequence context (Object Reference)←ThisContext');
    expect(c[1].label, '#0 error out');
    expect(c[1].cell, 'Container ←Step.Result.Error');
    expect(
      s.summary,
      contains('#11 sequence context (Object Reference)←ThisContext'),
    );
    expectMatches(s, {'object reference': true, 'nidcpower.lvlib': true});
  });

  test('a Python call surfaces module/function/version', () {
    final s = stepOf(
      'Action',
      'Create sessions',
      sdata(
        cls: 'CPythonModule',
        obj(
          'PythonCall',
          cls: 'CPythonCall',
          prop('PythonVersion', '3.9', 'Str') +
              prop('ModulePath', r'..\smu\test.py', 'PathValue') +
              prop(
                'FunctionOrAttributeName',
                'create_instrument_sessions',
                'Str',
              ),
        ),
      ),
    );
    expect(s.adapter, SeqAdapter.python);
    expect(s.target, 'create_instrument_sessions');
    expect(s.notes, contains(r'python: mod ..\smu\test.py, py 3.9'));
    expectMatches(s, {'create_instrument_sessions': true, 'test.py': true});
  });

  test('custom condition, mutex, and result outcome surface', () {
    final s = stepOf(
      'Action',
      'Extras',
      ts(
            prop('CustExpr', 'Locals.go == True', 'ExprValue') +
                prop('UseMutex', 'true', 'Bool') +
                prop('MutexNameOrRef', '"Bus"', 'ExprValue'),
          ) +
          obj(
            'Result',
            prop('Status', 'Passed', 'Str') +
                obj(
                  'Error',
                  prop('Code', '0', 'Num') +
                      prop('Msg', '', 'Str') +
                      prop('Occurred', 'false', 'Bool'),
                ),
          ),
    );
    expect(s.expressions, contains(('Custom condition', 'Locals.go == True')));
    expect(s.notes, contains('mutex "Bus"'));
    expect(s.notes, contains('result status Passed'));
    expect(s.summary, contains('mutex "Bus"'));
    expectMatches(s, {'locals.go': true, 'mutex': true, 'passed': true});
  });

  test('MeasurementPlugIns resources surface; absent → null', () {
    final doc =
        SeqDocument.parse(
              seqXml(
                ubound: '[]',
                extra: obj(
                  'FileGlobalDefaults',
                  obj(
                    'MeasurementPlugIns',
                    prop('PinMapPath', 'PinMap.pinmap', 'PathValue') +
                        objs('SpecificationsFilePaths', [
                          'Specifications.specs',
                        ], cls: 'Strs') +
                        objs('PatternFilePaths', [
                          'Pattern.digipat',
                        ], cls: 'Strs'),
                  ),
                ),
              ),
            )
            as XmlSeqDocument;
    final mp = SeqOutline.of(doc.file).plugins!;
    expect(mp.pinMap, 'PinMap.pinmap');
    expect(mp.specifications, ['Specifications.specs']);
    expect(mp.patterns, ['Pattern.digipat']);
    expect(
      mp.rows,
      containsAll([
        ('Pin map', 'PinMap.pinmap'),
        ('Specifications', 'Specifications.specs'),
        ('Patterns', 'Pattern.digipat'),
      ]),
    );
    expect(SeqOutline.of(xmlDoc.file).plugins, isNull);
  });

  test(
    'free-text comment, units, data source, and call args are searchable',
    () {
      expectMatches(
        StepOutline(
          name: 'Lock',
          type: 'Action',
          comment: 'Lock the calibration fixture',
          notes: const [],
        ),
        {'calibration': true, 'fixture': true, 'nope': false},
      );
      final s = StepOutline(
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
      expectMatches(s, {
        'ma': true,
        'step.result.passfail': true,
        'loginname': true,
        'usertoautologin': true,
        'string': true,
        'get user': true,
        'action': true,
        'absent': false,
      });
      expect(s.summary, contains('{units mA}'));
      expect(s.summary, contains('{data-source Step.Result.PassFail}'));
      expect(
        s.summary,
        contains('{args: LoginName in←FileGlobals.UserToAutoLogin}'),
      );
    },
  );

  test('pathBasename handles / and \\ separators and edge cases', () {
    const rows = {
      r'C:\a\b\Foo.vi': 'Foo.vi',
      '/x/y/Bar.seq': 'Bar.seq',
      'bare': 'bare',
      '': '',
      r'/x\y/z\End.seq': 'End.seq',
      '/x/y/': '',
      r'x\': '',
      'a/b.c': 'b.c',
      '.hidden': '.hidden',
    };
    rows.forEach((p, want) => expect(pathBasename(p), want, reason: '"$p"'));
  });

  test('StepOutline.targetDisplay shows basename + full-path tooltip', () {
    ({String label, String tooltip})? disp(String? target) => StepOutline(
      name: 'x',
      type: 'y',
      adapter: target == null ? null : SeqAdapter.labView,
      target: target,
      notes: const [],
    ).targetDisplay;
    expect(disp(r'C:\a\b\Foo.vi'), (
      label: 'Foo.vi',
      tooltip: r'C:\a\b\Foo.vi',
    ));
    expect(disp('/x/y/Bar.vi'), (label: 'Bar.vi', tooltip: '/x/y/Bar.vi'));
    expect(disp('MySequence'), (label: 'MySequence', tooltip: 'MySequence'));
    expect(disp(null), isNull);
  });

  test('VarOutline.label shows scalar value, container size, comment', () {
    final rows = <(VarOutline, String)>[
      (VarOutline(name: 'Count', type: 'Num', value: '3'), 'Count : Num = 3'),
      (
        VarOutline(
          name: 'List',
          type: 'Objs',
          isArray: true,
          containerCount: 0,
        ),
        'List : Objs [0]',
      ),
      (
        VarOutline(name: 'A', type: 'Objs', isArray: true, containerCount: 3),
        'A : Objs [3]',
      ),
      (
        VarOutline(name: 'Limits', type: 'Obj', containerCount: 2),
        'Limits : Obj {2 fields}',
      ),
      (
        VarOutline(name: 'One', type: 'Obj', containerCount: 1),
        'One : Obj {1 field}',
      ),
      (VarOutline(name: 'X', type: 'Str'), 'X : Str'),
      (
        VarOutline(name: 'Off', type: 'Num', value: '4', comment: 'bitmask'),
        'Off : Num = 4  // bitmask',
      ),
      (
        VarOutline(
          name: 'T',
          type: 'Obj',
          containerCount: 2,
          comment: 'pass band',
        ),
        'T : Obj {2 fields}  // pass band',
      ),
    ];
    for (final (v, want) in rows) {
      expect(v.label, want, reason: v.name);
    }
  });

  test('filterSequences keeps matches; empty query is identity', () {
    final outline = SeqOutline.of(xmlDoc.file);
    expect(filterSequences(outline, ''), same(outline));
    expect(filterSequences(outline, '   '), same(outline));
    final byStep = filterSequences(outline, 's1');
    expect(byStep.sequences.single.name, 'MainSequence');
    expect(
      byStep.sequences.single.groups.expand((g) => g.steps).map((s) => s.name),
      contains('S1'),
    );
    expect(
      filterSequences(outline, 'mainseq').sequences.single.name,
      'MainSequence',
    );
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
    final byComment = filterSequences(outline, 'bitmask');
    expect(byComment.sequences.single.locals.single.name, 'Off');
    expect(filterSequences(outline, 'zzz-nope').sequences, isEmpty);
  });

  test('propertyTree shapes the raw PropertyObject tree', () {
    final root = propertyTree(xmlDoc.file);
    expect(root.name, 'Data');
    expect(root.className, 'Obj');
    expect(root.isLeaf, isFalse);
    expect(root.typeLabel, contains('Obj'));
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
    expect(overridden.attributes['%INSTOVRD'], '5046297');
    final plain = PropertyNode.of(SeqProperty(name: 'Mode', scalar: 'Normal'));
    expect(plain.isInstanceOverride, isFalse);
  });

  test('filterTree keeps matches with ancestors; empty query is identity', () {
    final root = propertyTree(xmlDoc.file);
    expect(filterTree(root, ''), same(root));
    expect(filterTree(root, '   '), same(root));
    final f = filterTree(root, 'S1')!;
    expect(f.name, 'Data');
    final mainSeq = f.children
        .firstWhere((c) => c.name == 'Seq')
        .children
        .single;
    expect(mainSeq.name, 'MainSequence');
    bool hasStep(PropertyNode n) => n.name == 'S1' || n.children.any(hasStep);
    expect(hasStep(mainSeq), isTrue);
    expect(filterTree(root, 'zzz-no-such-token'), isNull);
  });

  test('coverageLabel formats the modeled/total ratio', () {
    final c = measureCoverage(xmlDoc.file);
    final label = coverageLabel(c);
    expect(label, startsWith('model coverage '));
    expect(label, contains('${c.modeled}/${c.total}'));
    expect(label, matches(RegExp(r'\d+\.\d%')));
    expect(c.modeled, greaterThan(0));
    expect(c.modeled, lessThanOrEqualTo(c.total));
  });

  test('binaryHeaderRows surfaces recon facts + datum counts (TOF1)', () {
    final doc = SeqDocument.parse(binarySeq());
    expect(doc, isA<BinarySeqDocument>());
    final map = headerRows(doc as BinarySeqDocument);
    expect(map['Encoding'], 'binary');
    expect(map['File type'], 'SequenceFile');
    expect(map['Product'], 'TestStand');
    expect(map['Inflated body'], endsWith('bytes'));
    expect(int.parse(map['Strings recovered']!), greaterThan(0));
    expect(map.containsKey('Record region'), isTrue);
    expect(map.containsKey('Record sentinels'), isTrue);
    expect(int.parse(map['Strings in region']!), greaterThanOrEqualTo(5));
    expect(map['Property-name table'], endsWith('entries'));
    expect(
      int.parse(map['Property-name table']!.split(' ').first),
      greaterThan(0),
    );
    expect(int.parse(map['Object names']!), greaterThan(0));
    expect(int.parse(map['Module call-targets']!), greaterThanOrEqualTo(1));
    expect(int.parse(map['Step references']!), greaterThanOrEqualTo(1));
    expect(int.parse(map['Expressions']!), greaterThanOrEqualTo(1));
    expect(int.parse(map['Quoted literals']!), greaterThanOrEqualTo(1));
  });

  test('documentText surfaces all recovered datums for a TOF1 file', () {
    final text = documentText(SeqDocument.parse(binarySeq()));
    for (final part in [
      'recovered property/object names',
      'MainSequence',
      'Step',
      'Locals',
      'Parameters',
      'module call-targets',
      r'My Computer\Lib\Read.vi',
      'expressions (test logic)',
      'Locals.x == 1',
      'step references',
      'ID#:abc123XYZ',
      'quoted literals (values)',
      '"6105A"',
      'record tree not yet decoded',
      'record links not yet decoded',
    ]) {
      expect(text, contains(part), reason: 'missing "$part"');
    }
  });

  test('binaryRecoverySections groups non-empty recovered datums', () {
    final doc = SeqDocument.parse(binarySeq()) as BinarySeqDocument;
    final sections = binaryRecoverySections(doc);
    expect(
      [for (final s in sections) s.title],
      [
        'Object names',
        'Module call-targets',
        'Step references',
        'Expressions (test logic)',
        'Quoted literals (values)',
      ],
    );
    for (final s in sections) {
      expect(s.items, isNotEmpty, reason: s.title);
    }
    final byTitle = {for (final s in sections) s.title: s.items};
    expect(
      byTitle['Module call-targets'],
      contains(r'My Computer\Lib\Read.vi'),
    );
    expect(byTitle['Expressions (test logic)'], contains('Locals.x == 1'));
    expect(byTitle['Quoted literals (values)'], contains('"6105A"'));
  });

  test('binaryRecoverySections surfaces named + inline numeric values', () {
    final doc = BinarySeqDocument(
      header: detectSeqHeader(binarySeq()),
      inflatedSize: 0,
      strings: const [],
      stringTable: const [],
      namedScalars: const [
        BinaryNamedScalar(
          name: 'Parameters',
          rawTag: 0,
          rawTypeCode: 62,
          value: 8192.0,
          wordIndex: 2,
        ),
      ],
      scalarDoubles: const [8192.0, -2.0],
      namedRecords: const [
        BinaryNamedRecord(name: 'ResultList', count: 10, rawTag: 2),
      ],
    );
    final byTitle = {
      for (final s in binaryRecoverySections(doc)) s.title: s.items,
    };
    expect(byTitle['Named scalar values'], [
      'Parameters = 8192.0  (raw type 62, not modeled)',
    ]);
    expect(byTitle['Inline numeric values'], ['8192.0', '-2.0']);
    expect(byTitle['Named-record headers'], [
      'ResultList ×10  (raw tag 2, not modeled)',
    ]);
    final rows = headerRows(doc);
    expect(rows['Inline numbers'], '2');
    expect(rows['Named scalars'], '1');
    expect(rows['Named records'], '1');
  });

  test('writeCapped lists up to the cap, then an honest "and N more"', () {
    final small = StringBuffer();
    writeCapped(small, ['a', 'b', 'c'], (s) => s);
    expect(small.toString(), '  a\n  b\n  c\n');
    expect(small.toString(), isNot(contains('more')));
    final big = StringBuffer();
    writeCapped(big, [
      for (var i = 0; i < maxListedEntries + 7; i++) 'n$i',
    ], (s) => s);
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
