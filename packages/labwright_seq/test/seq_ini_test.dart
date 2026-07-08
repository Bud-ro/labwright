import 'dart:convert';

import 'package:labwright_seq/labwright_seq.dart';
import 'package:test/test.dart';

/// Instance path of the single Main step every [_stepIni] fixture declares.
const _p = 'SF.Seq[0].Main[0]';

const _header = '''
[__Header__]
ProductName = "TestStand"
Version = 354
Type = "SequenceFile"
''';

/// A one-object SequenceFile in Rosetta INI form; [body] follows `%NAME = "Data"`.
String _doc(String body, {String root = '%OBJROOT', String header = _header, String extraRoot = ''}) =>
    '$header\n[DEF, $root]\nSF = SequenceFileData\n$extraRoot[DEF, SF]\nSeq = Objs\n%NAME = "Data"\n$body';

/// A MainSequence with one Main step of [type]; [sections] continues from the
/// step's own `[DEF, $_p]` section body.
String _stepIni(String type, String sections) => _doc(
  '[DEF, SF.Seq]\n%[0] = Sequence\n[DEF, SF.Seq[0]]\nMain = Objs\n%NAME = "MainSequence"\n'
  '[DEF, SF.Seq[0].Main]\n%[0] = Step\n%TYPE: %[0] = "$type"\n[DEF, $_p]\n$sections',
);

/// A step whose TS declares [tsKeys] as Strings, each valued in [values] (or "v").
String _tsIni(List<String> tsKeys, [List<String>? values]) => _stepIni(
  'Action',
  'TS = Obj\n%NAME = "s"\n[DEF, $_p.TS]\n${tsKeys.map((k) => '$k = String').join('\n')}\n'
      '[$_p.TS]\n${List.generate(tsKeys.length, (i) => '${tsKeys[i]} = "${values?[i] ?? 'v'}"').join('\n')}\n',
);

SeqFile _parse(String ini) => parseSeqFile(latin1.encode(ini));
Step _step(String ini) => _parse(ini).sequences.single.main.single;

final _ini = _doc(
  '[SF]\n%HI: Seq = [0]\n%FLG: Seq = 4194304\nVersion = "0.0.0.0"\n'
  '[DEF, SF.Seq]\n%[0] = Sequence\n[DEF, SF.Seq[0]]\nMain = Objs\n%NAME = "MainSequence"\n'
  '[DEF, SF.Seq[0].Main]\n%[0] = Step\n%TYPE: %[0] = "Action"\n[DEF, $_p]\n%NAME = "myStep"\n',
  header: '[__Header__]\nProductName = "TestStand"\nProductVersion = 3.5.0.365\nVersion = 354\nType = "SequenceFile"\n',
);

void main() {
  group('parseIniSeq', () {
    final f = parseIniSeq(_ini);

    test('recovers the header, and detectSeqHeader agrees', () {
      expect(
        (f.header.format, f.header.fileType, f.header.productName, f.header.fileVersion),
        (
          SeqFormat.ini,
          'SequenceFile',
          'TestStand',
          '354',
        ),
      );
      final bytes = latin1.encode(_ini);
      expect(detectSeqFormat(bytes), SeqFormat.ini);
      final h = detectSeqHeader(bytes);
      expect((h.fileType, h.productName, h.fileVersion), ('SequenceFile', 'TestStand', '354'));
    });

    test('classifies DEF vs value sections; members vs directives', () {
      final objroot = f.sections.firstWhere((s) => s.path == '%OBJROOT');
      expect(objroot.isDef, isTrue);
      expect(objroot.members['SF'], 'SequenceFileData');
      final sfVal = f.sections.firstWhere((s) => s.path == 'SF' && !s.isDef);
      expect(sfVal.members['Version'], '"0.0.0.0"');
      expect(sfVal.members.containsKey('%FLG: Seq'), isFalse);
      expect(sfVal.directives['%FLG: Seq'], '4194304');
      expect(sfVal.directives['%HI: Seq'], '[0]');
    });

    test('exposes object names via %NAME and element types via %[i]', () {
      expect(f.sections.firstWhere((s) => s.isDef && s.path == 'SF').name, 'Data');
      expect(f.sections.firstWhere((s) => s.isDef && s.path == 'SF.Seq[0]').name, 'MainSequence');
      expect(f.sections.firstWhere((s) => s.isDef && s.path == 'SF.Seq').directives['%[0]'], 'Sequence');
    });
  });

  group('iniDataTree', () {
    final tree = iniDataTree(parseIniSeq(_ini))!;

    test('roots at the SequenceFileData object named "Data"', () {
      expect((tree.name, tree.className), ('Data', 'SequenceFileData'));
    });

    test('reconstructs the Seq array, its MainSequence element, and scalar members', () {
      final seq = tree.subProps.firstWhere((p) => p.name == 'Seq');
      expect((seq.className, seq.isArray), ('Objs', true));
      final mainSeq = seq.array!.single;
      expect(mainSeq.name, 'MainSequence');
      expect(mainSeq.subProps.map((p) => p.name), contains('Main'));
      final version = tree.subProps.firstWhere((p) => p.name == 'Version');
      expect((version.scalar, version.isLeaf), ('0.0.0.0', true));
    });
  });

  group('parseSeqFile on INI (typed lens)', () {
    final sf = _parse(_ini);

    test('recovers the sequence + typed step; no fabricated settings/module', () {
      expect(sf.header.fileType, 'SequenceFile');
      final seq = sf.sequences.single;
      expect(seq.name, 'MainSequence');
      final step = seq.main.single;
      expect((step.name, step.type), ('myStep', 'Action'));
      expect(step.settings.mode, isNull);
      expect(step.module.adapter, SeqAdapter.none);
    });
  });

  group('type inheritance (instance inherits from its [DEF, <Type>])', () {
    final step = _step(
      _stepIni('Action', '''
%NAME = "myStep"
[DEF, Action]
TS = "TYPE, TEInf"
[DEF, Action.TS]
Mode = String
LoopType = String
SData = "TYPE, FlexGStepAdditions"
[Action.TS]
Mode = "Normal"
LoopType = "NoLooping"
[DEF, Action.TS.SData]
ViCall = Obj
[DEF, Action.TS.SData.ViCall]
VIPath = String
[Action.TS.SData.ViCall]
VIPath = "measure.vi"
'''),
    );

    test('keeps identity; inherits run-mode, looping, and the module binding', () {
      expect((step.name, step.type), ('myStep', 'Action'));
      expect((step.settings.mode, step.settings.loopType), ('Normal', 'NoLooping'));
      expect((step.module.adapter, step.module.viPath), (SeqAdapter.labView, 'measure.vi'));
    });
  });

  test('an empty inherited SData classifies as SeqAdapter.none (not unknown)', () {
    final step = _step(
      _stepIni('NI_Flow_End', '''
%NAME = "End"
[DEF, NI_Flow_End]
TS = "TYPE, TEInf"
[DEF, NI_Flow_End.TS]
Mode = String
SData = "TYPE, FlexGStepAdditions"
[NI_Flow_End.TS]
Mode = "Normal"
[DEF, NI_Flow_End.TS.SData]
'''),
    );
    expect((step.type, step.settings.mode, step.module.adapter), ('NI_Flow_End', 'Normal', SeqAdapter.none));
  });

  group('older-version forms', () {
    final legacy = _parse(
      _doc(
        '[DEF, SF.Seq]\n%[0] = Sequence\n[DEF, SF.Seq[0]]\nMain = Objs\n%NAME = "MainSequence"\n'
        '[DEF, SF.Seq[0].Main]\n%[0] = Step\n%TYPE: %[0] = "Action"\n[DEF, $_p]\n%NAME = "legacyStep"\n'
        '[DEF, $_p.TS]\nSData = Obj\n[DEF, $_p.TS.SData]\nViPath = PathValue\n[$_p.TS.SData]\nViPath = "legacy.vi"\n',
        root: '%OBJECTS',
        extraRoot: 'Path = PathValue\n',
        header: '[__Header__]\nProductName = "TestStand"\nVersion = 143\nType = "SequenceFile"\n',
      ),
    );

    test('resolves the older %OBJECTS root alias and the direct-ViPath adapter', () {
      expect(legacy.header.fileType, 'SequenceFile');
      final seq = legacy.sequences.single;
      expect(seq.name, 'MainSequence');
      final step = seq.main.single;
      expect((step.name, step.type), ('legacyStep', 'Action'));
      expect((step.module.adapter, step.module.viPath), (SeqAdapter.labView, 'legacy.vi'));
    });
  });

  test('marks instance-overridden members via %INSTOVRD; parses flags defensively', () {
    final step = _step(
      _stepIni(
        'Action',
        'TS = Obj\n%NAME = "ovrStep"\n[DEF, $_p.TS]\nMode = String\n[$_p.TS]\nMode = "Skip"\n[$_p]\n%INSTOVRD: TS = 5046297\n',
      ),
    );
    final ts = step.raw.prop('TS')!;
    expect(ts.isInstanceOverride, isTrue);
    expect(ts.attributes['%INSTOVRD'], '5046297');
    expect(ts.instanceOverrideFlags, 5046297);
    expect((ts.instanceOverrideFlags! >> 16) & 1, 1);
    expect(ts.prop('Mode')?.isInstanceOverride, isFalse);
    expect(ts.prop('Mode')?.instanceOverrideFlags, isNull);
    expect(ts.propertyFlags, isNull, reason: 'no %FLG recorded');
    expect(SeqProperty(name: 'x').instanceOverrideFlags, isNull);
    expect(SeqProperty(name: 'x', attributes: const {'%INSTOVRD': 'bad'}).instanceOverrideFlags, isNull);
  });

  test('recovers type-level PropertyFlags via %FLG (raw bitmask); defensive parse', () {
    final step = _step(
      _stepIni(
        'Action',
        'TS = Obj\n%NAME = "flagStep"\n[DEF, $_p.TS]\nSData = Obj\nMode = String\n'
            '%FLG: SData = 2097152\n%FLG: Mode = 4\n[$_p.TS]\nMode = "Skip"\n[$_p]\n%FLG: TS = 4194304\n',
      ),
    );
    final ts = step.raw.prop('TS')!;
    expect(ts.propertyFlags, 0x400000);
    expect(ts.attributes['%FLG'], '4194304');
    expect(ts.prop('SData')?.propertyFlags, 0x200000);
    expect(ts.prop('Mode')?.propertyFlags, 0x4);
    expect(SeqProperty(name: 'x').propertyFlags, isNull);
    expect(SeqProperty(name: 'x', attributes: const {'%FLG': 'oops'}).propertyFlags, isNull);
    expect(SeqProperty(name: 'x', attributes: const {'%FLG': '4194304'}).propertyFlags, 0x400000);
  });

  test('retains bare own-section %FLG/%INSTFLG and the %INSTFLG member form', () {
    final bare = _step(
      _stepIni(
        'Action',
        'TS = Obj\n%NAME = "flagStep"\n[DEF, $_p.TS]\nMode = String\nResult = Obj\n'
            '[$_p.TS]\nMode = "Normal"\n%FLG = 37748760\n%INSTFLG = 524312\n',
      ),
    ).raw.prop('TS')!;
    expect(bare.attributes['%FLG'], '37748760');
    expect(bare.propertyFlags, 37748760);
    expect(bare.attributes['%INSTFLG'], '524312');

    final member = _step(
      _stepIni(
        'Action',
        'Result = Obj\n%NAME = "s"\n[DEF, $_p.Result]\nStatus = String\n[$_p]\n%INSTFLG: Result = 4194304\n',
      ),
    );
    expect(member.raw.prop('Result')!.attributes['%INSTFLG'], '4194304');
  });

  test('recovers the loop expressions of a looping step (and the dump lines)', () {
    final sf = _parse(
      _tsIni(
        ['LoopType', 'LoopInitialize', 'LoopWhile', 'LoopIncrement', 'LoopStatus'],
        [
          'FixedNumLoops',
          'RunState.LoopIndex = 0',
          'RunState.LoopIndex < 10',
          'RunState.LoopIndex += 1',
          'RunState.LoopNumPassed >= 1',
        ],
      ),
    );
    final set = sf.sequences.single.main.single.settings;
    expect(set.isLooping, isTrue);
    expect(
      (set.loopType, set.loopInitialize, set.loopWhile, set.loopIncrement, set.loopStatus),
      (
        'FixedNumLoops',
        'RunState.LoopIndex = 0',
        'RunState.LoopIndex < 10',
        'RunState.LoopIndex += 1',
        'RunState.LoopNumPassed >= 1',
      ),
    );
    final out = dumpSeqFile(sf);
    for (final chip in [
      'loop FixedNumLoops [',
      'while RunState.LoopIndex < 10',
      'init RunState.LoopIndex = 0',
      'incr RunState.LoopIndex += 1',
    ]) {
      expect(out, contains(chip));
    }
  });

  group('comments (%COMMENT)', () {
    final sf = _parse(
      _doc(
        '[DEF, SF.Seq]\n%[0] = Sequence\n[DEF, SF.Seq[0]]\nMain = Objs\n%NAME = "MainSequence"\n'
        '[SF.Seq[0]]\n%COMMENT = "Runs once at startup"\n'
        '[DEF, SF.Seq[0].Main]\n%[0] = Step\n%[1] = Step\n%TYPE: %[0] = "Action"\n%TYPE: %[1] = "Action"\n'
        '[DEF, $_p]\n%NAME = "lockStep"\n[$_p]\n%COMMENT = "Lock sequence"\n'
        '[DEF, SF.Seq[0].Main[1]]\n%NAME = "plainStep"\n',
      ),
    );

    test('step and sequence free-text comments surface; absent stays null', () {
      final steps = sf.sequences.single.main;
      expect(steps.map((s) => s.name), ['lockStep', 'plainStep']);
      expect(steps[0].comment, 'Lock sequence');
      expect(steps[1].comment, isNull);
      expect(sf.sequences.single.comment, 'Runs once at startup');
      expect(steps.first.settings.icon, isNull);
    });

    test('dumpSeqFile includes the recovered comments', () {
      final out = dumpSeqFile(sf);
      expect(out, contains('// Runs once at startup'));
      expect(out, contains('lockStep'));
      expect(out, contains('// Lock sequence'));
      expect(out, isNot(contains('mutex')));
    });
  });

  group('variables (Locals/Parameters)', () {
    final objSf = _parse(
      _doc(
        '[DEF, SF.Seq]\n%[0] = Sequence\n[DEF, SF.Seq[0]]\nLocals = Obj\n%NAME = "MainSequence"\n'
        '[DEF, SF.Seq[0].Locals]\nCount = Num\nLimits = Obj\n[SF.Seq[0].Locals]\nCount = "3"\n'
        '[DEF, SF.Seq[0].Locals.Limits]\nLow = Num\nHigh = Num\n'
        '[SF.Seq[0].Locals.Limits]\nLow = "9"\nHigh = "11"\n%COMMENT = "DUT pass band"\n',
      ),
    );

    test('reports container field counts and variable comments', () {
      final locals = objSf.sequences.single.locals;
      expect(locals.map((v) => v.name), ['Count', 'Limits']);
      expect((locals[0].isContainer, locals[0].containerCount, locals[0].comment), (false, null, null));
      final limits = locals[1];
      expect(
        (limits.isContainer, limits.isArray, limits.containerCount, limits.comment),
        (true, false, 2, 'DUT pass band'),
      );
      final out = dumpSeqFile(objSf);
      expect(out, contains('Limits : Obj {2 fields}'));
      expect(out, contains('// DUT pass band'));
    });

    test('counts elements of a populated array variable', () {
      final sf = _parse(
        _doc(
          '[DEF, SF.Seq]\n%[0] = Sequence\n[DEF, SF.Seq[0]]\nLocals = Obj\n%NAME = "MainSequence"\n'
          '[DEF, SF.Seq[0].Locals]\nItems = Objs\n[DEF, SF.Seq[0].Locals.Items]\n%[0] = Obj\n%[1] = Obj\n%[2] = Obj\n'
          '[DEF, SF.Seq[0].Locals.Items[0]]\n%NAME = "a"\n[DEF, SF.Seq[0].Locals.Items[1]]\n%NAME = "b"\n'
          '[DEF, SF.Seq[0].Locals.Items[2]]\n%NAME = "c"\n',
        ),
      );
      final items = sf.sequences.single.locals.single;
      expect(
        (items.name, items.isArray, items.isContainer, items.containerCount, items.value),
        ('Items', true, true, 3, null),
      );
      expect(dumpSeqFile(sf), contains('• Items : Objs [3]'));
    });

    test('a sequence with both parameters and locals is surfaced + dumped', () {
      final sf = _parse(
        _doc(
          '[DEF, SF.Seq]\n%[0] = Sequence\n[DEF, SF.Seq[0]]\nParameters = Obj\nLocals = Obj\n%NAME = "MainSequence"\n'
          '[DEF, SF.Seq[0].Parameters]\nVoltage = Num\n[SF.Seq[0].Parameters]\nVoltage = "5"\n'
          '[DEF, SF.Seq[0].Locals]\nCount = Num\n[SF.Seq[0].Locals]\nCount = "3"\n',
        ),
      );
      final seq = sf.sequences.single;
      expect(seq.parameters.map((v) => v.name), ['Voltage']);
      expect(seq.parameters.single.value, '5');
      expect(seq.locals.map((v) => v.name), ['Count']);
      final out = dumpSeqFile(sf);
      for (final line in ['Parameters:', '• Voltage : Num = 5', 'Locals:', '• Count : Num = 3']) {
        expect(out, contains(line));
      }
    });
  });

  group('flow actions, module timing, icon', () {
    final sf = _parse(
      _tsIni(
        ['PassAct', 'FailAct', 'FailActTarget', 'Icon', 'LoadOpt', 'UnloadOpt'],
        ['Next', 'Goto', r'\"<Cleanup>\"', r'FlowControl\\NI_While.ico', 'DynamicLoad', 'UnloadAfterStepExecution'],
      ),
    );

    test('recovers the fail jump target, load/unload timing, and icon basename', () {
      final set = sf.sequences.single.main.single.settings;
      expect(
        (set.passAction, set.failAction, set.passActionTarget, set.failActionTarget),
        ('Next', 'Goto', null, '<Cleanup>'),
      );
      expect(set.flowSummary, 'Next/Goto→<Cleanup>');
      expect((set.loadOption, set.unloadOption, set.icon), ('DynamicLoad', 'UnloadAfterStepExecution', 'NI_While'));
      final out = dumpSeqFile(sf);
      for (final chip in [
        'load DynamicLoad',
        'unload UnloadAfterStepExecution',
        '{icon NI_While}',
        'flow Next/Goto→<Cleanup>',
      ]) {
        expect(out, contains(chip));
      }
    });

    test('flowSummary marks an unset side with ? (only pass action present)', () {
      final set = _step(_tsIni(['PassAct', 'PassActTarget'], ['Goto', r'\"<End>\"'])).settings;
      expect((set.passActionTarget, set.failAction), ('<End>', null));
      expect(set.flowSummary, 'Goto→<End>/?');
    });

    test('flowSummary shows both a pass and a fail jump target', () {
      final set = _step(
        _tsIni(
          ['PassAct', 'FailAct', 'PassActTarget', 'FailActTarget'],
          ['Goto', 'Goto', r'\"<End>\"', r'\"<Cleanup>\"'],
        ),
      ).settings;
      expect((set.passActionTarget, set.failActionTarget), ('<End>', '<Cleanup>'));
      expect(set.flowSummary, 'Goto→<End>/Goto→<Cleanup>');
    });
  });

  test('resolves an ID#: step reference to the destination step name', () {
    final sf = _parse(
      _doc(
        '[DEF, SF.Seq]\n%[0] = Sequence\n[DEF, SF.Seq[0]]\nMain = Objs\n%NAME = "MainSequence"\n'
        '[DEF, SF.Seq[0].Main]\n%[0] = Step\n%[1] = Step\n%TYPE: %[0] = "Action"\n%TYPE: %[1] = "Action"\n'
        '[DEF, $_p]\nTS = Obj\n%NAME = "condStep"\n[DEF, $_p.TS]\nCustFalseActTarget = String\n'
        '[$_p.TS]\nCustFalseActTarget = "\\"ID#:STEP2\\""\n'
        '[DEF, SF.Seq[0].Main[1]]\nTS = Obj\n%NAME = "targetStep"\n[DEF, SF.Seq[0].Main[1].TS]\nId = String\n'
        '[SF.Seq[0].Main[1].TS]\nId = "ID#:STEP2"\n',
      ),
    );
    expect(sf.sequences.single.main.first.settings.customFalseTarget, 'ID#:STEP2');
    expect(sf.stepNameForId('ID#:STEP2'), 'targetStep');
    expect(sf.stepNameForId('STEP2'), 'targetStep');
    expect(sf.stepNameForId('ID#:NOPE'), isNull);
    expect(dumpSeqFile(sf), contains('cust-false→targetStep'));
  });

  test('recovers a module call\'s bound arguments (name, expr, direction)', () {
    final step = _step(
      _stepIni(
        'Action',
        'TS = Obj\n%NAME = "Get User"\n[DEF, $_p.TS]\nSData = Obj\n[DEF, $_p.TS.SData]\nCall = Obj\n'
            '[DEF, $_p.TS.SData.Call]\nParameters = Objs\n[DEF, $_p.TS.SData.Call.Parameters]\n%[0] = Obj\n%[1] = Obj\n'
            '[$_p.TS.SData.Call.Parameters[0]]\nName = "Return Value"\nArgVal = "Locals.userToLogin"\n'
            'DisplayType = "User (Object Reference)"\nDirection = 2\n'
            '[$_p.TS.SData.Call.Parameters[1]]\nName = "LoginName"\nArgVal = "FileGlobals.UserToAutoLogin"\n'
            'DisplayType = "String"\nDirection = 1\n',
      ),
    );
    final args = step.module.callParameters;
    expect(args, hasLength(2));
    expect(
      (args[0].name, args[0].boundExpression, args[0].displayType, args[0].directionCode, args[0].direction),
      ('Return Value', 'Locals.userToLogin', 'User (Object Reference)', '2', 'out'),
    );
    expect(
      (args[1].name, args[1].boundExpression, args[1].direction),
      ('LoginName', 'FileGlobals.UserToAutoLogin', 'in'),
    );
  });

  group('limit tests and result fields', () {
    test('recovers a step\'s comparison, limits, and measurement units', () {
      final sf = _parse(
        _stepIni(
          'NumericLimitTest',
          'Comp = String\nDataSource = String\nLimits = Obj\nResult = Obj\n%NAME = "Check Current"\n'
              '[DEF, $_p.Limits]\nLow = Number\nHigh = Number\n[DEF, $_p.Result]\nUnits = String\n'
              '[$_p]\nComp = "GELE"\nDataSource = "Step.Result.Numeric"\n'
              '[$_p.Limits]\nLow = 9\nHigh = 11\n[$_p.Result]\nUnits = "mA"\n',
        ),
      );
      final step = sf.sequences.single.main.single;
      expect((step.type, step.resultUnits, step.limits?.summary), ('NumericLimitTest', 'mA', 'GELE [9, 11]'));
      expect(dumpSeqFile(sf), contains('{limits GELE [9, 11] mA}'));
    });

    test('recovers a PassFailTest data-source criterion (no limits)', () {
      final sf = _parse(
        _stepIni(
          'PassFailTest',
          'DataSource = String\n%NAME = "Motor running"\n[$_p]\nDataSource = "Step.Result.PassFail"\n',
        ),
      );
      final step = sf.sequences.single.main.single;
      expect((step.type, step.limits, step.dataSource), ('PassFailTest', null, 'Step.Result.PassFail'));
      expect(dumpSeqFile(sf), contains('{data-source Step.Result.PassFail}'));
    });

    test('dump shows standalone {units} for a non-limit step', () {
      final sf = _parse(
        _stepIni(
          'Action',
          'Result = Obj\n%NAME = "Measure rail"\n[DEF, $_p.Result]\nUnits = String\n[$_p.Result]\nUnits = "V"\n',
        ),
      );
      final step = sf.sequences.single.main.single;
      expect((step.limits, step.resultUnits), (null, 'V'));
      final out = dumpSeqFile(sf);
      expect(out, contains('{units V}'));
      expect(out, isNot(contains('{limits')));
    });

    test('result accessors return null/empty on absent or empty members', () {
      final main = _parse(
        _doc(
          '[DEF, SF.Seq]\n%[0] = Sequence\n[DEF, SF.Seq[0]]\nMain = Objs\n%NAME = "MainSequence"\n'
          '[DEF, SF.Seq[0].Main]\n%[0] = Step\n%TYPE: %[0] = "Action"\n%[1] = Step\n%TYPE: %[1] = "Action"\n'
          '[DEF, $_p]\n%NAME = "Bare"\n'
          '[DEF, SF.Seq[0].Main[1]]\nResult = Obj\n%NAME = "Empty bits"\n'
          '[DEF, SF.Seq[0].Main[1].Result]\nUnits = String\n'
          '[DEF, SF.Seq[0].Main[1].TS]\nSData = Obj\n[DEF, SF.Seq[0].Main[1].TS.SData]\nCall = Obj\n'
          '[DEF, SF.Seq[0].Main[1].TS.SData.Call]\nParameters = Objs\n'
          '[DEF, SF.Seq[0].Main[1].TS.SData.Call.Parameters]\n%[0] = Obj\n'
          '[SF.Seq[0].Main[1].Result]\nUnits = ""\n'
          '[SF.Seq[0].Main[1].TS.SData.Call.Parameters[0]]\nName = "flag"\nDirection = 0\n',
        ),
      ).sequences.single.main;
      final bare = main[0];
      expect((bare.resultUnits, bare.dataSource), (null, null));
      expect(bare.module.callParameters, isEmpty);
      final step = main[1];
      expect(step.resultUnits, isNull);
      final arg = step.module.callParameters.single;
      expect((arg.boundExpression, arg.directionCode, arg.direction), (null, '0', null));
    });
  });

  test('CallParameter.direction code mapping', () {
    CallParameter withDirection(String? code) => CallParameter(
      SeqProperty(
        name: 'arg',
        subProps: [
          SeqProperty(name: 'Name', scalar: 'arg'),
          if (code != null) SeqProperty(name: 'Direction', scalar: code),
        ],
      ),
    );
    const cases = [('1', 'in'), ('2', 'out'), ('3', 'in/out'), ('0', null), ('5', null), (null, null)];
    for (final (code, want) in cases) {
      final p = withDirection(code);
      expect(p.directionCode, code, reason: 'code $code');
      expect(p.direction, want, reason: 'code $code');
    }
  });

  test('measureCoverage counts the loop/unload TS step-settings', () {
    int modeledFor(List<String> tsKeys) => measureCoverage(_parse(_tsIni(tsKeys))).modeled;
    final base = modeledFor(['Mode']);
    const keys = [
      'Id',
      'UnloadOpt',
      'LoopInitialize',
      'LoopIncrement',
      'LoopStatus',
      'Icon',
      'StepFCSeqF',
      'IgnoreRTE',
      'ResultOption',
    ];
    for (final k in keys) {
      expect(modeledFor(['Mode', k]), base + 1, reason: '$k not counted');
    }
  });

  test('Step.id recovers the step unique id (TS.Id)', () {
    expect(_step(_tsIni(['Id'])).id, 'v');
    expect(_step(_tsIni(['Mode'])).id, isNull);
  });

  test('StepSettings recovers boolean step flags (true/false and 1/0)', () {
    StepSettings settingsWith(String key, String value) => _step(_tsIni([key], [value])).settings;
    expect(settingsWith('StepFCSeqF', 'true').failureCausesSequenceFailure, isTrue);
    expect(settingsWith('StepFCSeqF', 'false').failureCausesSequenceFailure, isFalse);
    expect(settingsWith('IgnoreRTE', 'true').ignoresRunTimeErrors, isTrue);
    expect(settingsWith('ResultOption', '1').recordsResult, isTrue);
    expect(settingsWith('ResultOption', '0').recordsResult, isFalse);
    expect(settingsWith('Mode', 'Normal').recordsResult, isNull);
  });

  test('quoted-value escape decoding inverts the writer escapes; unknown escapes stay verbatim', () {
    String? decoded(String escaped) => _step(
      _stepIni('Action', 'TS = Obj\n%NAME = "s"\n[DEF, $_p.TS]\nPreCond = ExprValue\n[$_p.TS]\nPreCond = "$escaped"\n'),
    ).settings.precondition;
    const cases = [
      (r'Locals.M != \"S001\"', 'Locals.M != "S001"'),
      (r'line1\nC:\\dir', 'line1\nC:\\dir'),
      (r'a\tb', 'a\tb'),
      (r'a\rb', 'a\rb'),
      ('Locals.X > 0', 'Locals.X > 0'),
      (r'a\qb', r'a\qb'),
    ];
    for (final (escaped, want) in cases) {
      expect(decoded(escaped), want, reason: escaped);
    }
  });

  group('multi-line value continuation', () {
    const splitIni =
        '''
$_header
[SomeObj]
Plain = "untouched"
DescriptionFormat Line0001 = "ResStr(\\"NI\\", \\"NAME\\") + ((\\"%Mod\\" == \\"\\") ? \\"\\" : \\",  %Mod"
DescriptionFormat Line0002 = "uleDescription\\")"
%COMMENT Line0001 = "first half "
%COMMENT Line0002 = "second half"
''';

    test('reassembles split members and directives into the single base key', () {
      final s = parseIniSeq(splitIni).sections.single;
      expect(s.members.keys, ['Plain', 'DescriptionFormat']);
      expect(s.members['Plain'], '"untouched"');
      expect(
        s.members['DescriptionFormat'],
        '"ResStr(\\"NI\\", \\"NAME\\") + ((\\"%Mod\\" == \\"\\") ? \\"\\" : \\",  %ModuleDescription\\")"',
      );
      expect(s.directives.keys, ['%COMMENT']);
      expect(s.directives['%COMMENT'], '"first half second half"');
    });

    test('leaves single-line values untouched (no residual fragments)', () {
      for (final s in parseIniSeq(_ini).sections) {
        expect(s.members.keys.any((k) => k.contains(' Line')), isFalse);
        expect(s.directives.keys.any((k) => k.contains(' Line')), isFalse);
      }
    });

    test('reassembles a value whose content contains " = "', () {
      const ini =
          '[__Header__]\nType = "SequenceFile"\n\n[Obj]\n'
          'Expr Line0001 = "Locals.x "\nExpr Line0002 = "= Locals.y + 1"\n';
      final s = parseIniSeq(ini).sections.single;
      expect(s.members.keys, ['Expr']);
      expect(s.members['Expr'], '"Locals.x = Locals.y + 1"');
    });

    test('reassembles split [__Header__] fields the same way as section values', () {
      const ini =
          '[__Header__]\nProductName = "TestStand"\nVersion = 577\nType = "SequenceFile"\n'
          'Path Line0001 = "C:\\\\Tests\\\\IVIPowerSupply\\\\TestIVIPowerSupplyReferen"\n'
          'Path Line0002 = "ces.seq"\n\n[DEF, %OBJROOT]\nSF = SequenceFileData\n';
      final f = parseIniSeq(ini);
      expect(f.headerFields['Path'], r'"C:\\Tests\\IVIPowerSupply\\TestIVIPowerSupplyReferences.seq"');
      expect(f.headerFields.keys.any((k) => k.contains(' Line')), isFalse);
      expect(f.headerFields['ProductName'], '"TestStand"');
      expect(f.headerFields['Version'], '577');
      expect(f.header.fileVersion, '577');
    });
  });

  group('declared array bounds (%LO/%HI)', () {
    final step = _step(
      _stepIni(
        'NI_Database_ExecuteSQLStatement',
        'ColumnList = Objs\nParms = Objs\n%NAME = "dbStep"\n'
            '[$_p]\n%LO: ColumnList = [1]\n%HI: ColumnList = [2]\n%HI: Parms = [63]\n',
      ),
    ).raw;

    test('retains %LO alongside %HI; declared length is hi - lo + 1 per dimension', () {
      final cols = step.prop('ColumnList')!;
      expect((cols.attributes['%LO'], cols.attributes['%HI']), ('[1]', '[2]'));
      expect(cols.lowIndices, [1]);
      expect(cols.highIndices, [2]);
      expect(cols.declaredArrayLength, 2);
      final parms = step.prop('Parms')!;
      expect(parms.lowIndices, isNull, reason: 'low bound defaults to 0 when %LO is absent');
      expect(parms.declaredArrayLength, 64);
    });

    test('bounds arithmetic is total over crafted inputs', () {
      int? lengthOf(Map<String, String> attrs) => SeqProperty(name: 'x', attributes: attrs).declaredArrayLength;
      const cases = [
        ({'%LO': '[1]', '%HI': '[1]'}, 1),
        ({'%LO': '[0]', '%HI': '[0]'}, 1),
        ({'%LO': '[0][0]', '%HI': '[1][7]'}, 16),
        ({'%LO': '[1]', '%HI': '[2][3]'}, 8), // short %LO pads with 0
        ({'%HI': '[-1]'}, 0), // unobserved, defensive
        ({'%LO': '[2]', '%HI': '[1]'}, 0), // unobserved, defensive
        ({'%LO': '[1]'}, null), // no %HI: no declared length
        (<String, String>{}, null),
      ];
      for (final (attrs, want) in cases) {
        expect(lengthOf(attrs), want, reason: '$attrs');
      }
      expect(SeqProperty(name: 'x').lowIndices, isNull);
    });
  });

  test('iniTypes carries the root-alias class, not the quoted display name', () {
    final types = iniTypes(
      parseIniSeq(
        '$_header\n[DEF, %OBJROOT]\nSF = SequenceFileData\nAction = StepType\nTEInf = Obj\n'
        '[DEF, SF]\nSeq = Objs\n%NAME = "Data"\n[%TYPES]\nAction = "Action"\nTEInf = "TEInf"\n'
        '[DEF, Action]\nTS = "TYPE, TEInf"\n[DEF, TEInf]\nMode = String\n',
      ),
    );
    expect(types.map((t) => t.name), ['Action', 'TEInf']);
    expect(types.map((t) => t.className), ['StepType', 'Obj']);
  });

  group('EXTDATA sections', () {
    final f = parseIniSeq(
      '$_header\n[DEF, %OBJROOT]\nSF = SequenceFileData\n[DEF, SF]\nSeq = Objs\n%NAME = "Data"\n'
      '[EXTDATA, SF.Payload, STRUCT]\nDataVersion = 1\nType = 6\n'
      '[EXTDATA, SF.Payload, CLUST]\nDataVersion = 1\nClusterMemberLabelName = "code"\n',
    );

    test('classify as a distinct section kind, path + kind decomposed', () {
      final ext = f.extDataSections.toList();
      expect(ext, hasLength(2));
      expect((ext[0].isExtData, ext[0].isDef, ext[0].path, ext[0].extDataKind), (true, false, 'SF.Payload', 'STRUCT'));
      expect(ext[0].members['Type'], '6');
      expect(ext[1].extDataKind, 'CLUST');
      expect(f.sections.where((s) => !s.isExtData).every((s) => s.extDataKind == null), isTrue);
    });

    test('do not pollute the data tree with pseudo-members', () {
      expect(iniDataTree(f)!.subProps.map((p) => p.name), isNot(contains('Payload')));
    });
  });

  group('%NAME scoping: on a NAMED member it is the enum value label, not the name', () {
    final f = parseIniSeq(
      '$_header\n[%TYPES]\nARX_UI_LED = "ARX_UI_LED"\n[DEF, ARX_UI_LED]\n%ROOT_TYPE = True\n'
      '[ARX_UI_LED]\n%NAME = "NONE"\n"NONE" = 0\n"LED_TRACE" = 1\n'
      '[DEF, %OBJROOT]\nSF = SequenceFileData\nARX_UI_LED = Enum\n'
      '[DEF, SF]\nProto = Obj\n%NAME = "Data"\n[DEF, SF.Proto]\nUILEDType = "TYPE, ARX_UI_LED"\nSetValue = Str\n'
      '[SF.Proto]\nUILEDType = 0\n[SF.Proto.UILEDType]\n%NAME = "NONE"\n',
    );

    test('a named member keeps its member key; the label rides as an attribute', () {
      final proto = iniDataTree(f)!.subProps.singleWhere((p) => p.name == 'Proto');
      final led = proto.subProps.firstWhere((p) => p.typeName == 'ARX_UI_LED');
      expect(led.name, 'UILEDType', reason: 'the property name is the member key, not the enum value label');
      expect(led.attributes['%NAME'], 'NONE', reason: 'the enum value label is retained, never dropped');
      expect(proto.subProps.map((p) => p.name), contains('SetValue'));
    });

    test('an enum typedef root keeps the type name, not its default label', () {
      final led = iniTypes(f).singleWhere((t) => t.className == 'Enum');
      expect(led.name, 'ARX_UI_LED');
    });
  });
}
