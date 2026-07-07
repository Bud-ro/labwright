import 'dart:convert';
import 'dart:typed_data';

import 'package:labwright_seq/labwright_seq.dart';
import 'package:test/test.dart';

const _ini = '''
[__Header__]
ProductName = "TestStand"
ProductVersion = 3.5.0.365
Version = 354
Type = "SequenceFile"

[DEF, %OBJROOT]
SF = SequenceFileData

[DEF, SF]
Seq = Objs
%NAME = "Data"

[SF]
%HI: Seq = [0]
%FLG: Seq = 4194304
Version = "0.0.0.0"

[DEF, SF.Seq]
%[0] = Sequence

[DEF, SF.Seq[0]]
Main = Objs
%NAME = "MainSequence"

[DEF, SF.Seq[0].Main]
%[0] = Step
%TYPE: %[0] = "Action"

[DEF, SF.Seq[0].Main[0]]
%NAME = "myStep"
''';

void main() {
  SeqFile parseIni(String ini) => parseSeqFile(Uint8List.fromList(latin1.encode(ini)));

  group('parseIniSeq', () {
    final f = parseIniSeq(_ini);

    test('recovers the header (Type/ProductName/Version)', () {
      expect(f.header.format, SeqFormat.ini);
      expect(f.header.fileType, 'SequenceFile');
      expect(f.header.productName, 'TestStand');
      expect(f.header.fileVersion, '354');
    });

    test('classifies DEF vs value sections by path', () {
      final objroot = f.sections.firstWhere((s) => s.path == '%OBJROOT');
      expect(objroot.isDef, isTrue);
      expect(objroot.members['SF'], 'SequenceFileData');

      final sfVal = f.sections.firstWhere((s) => s.path == 'SF' && !s.isDef);
      expect(sfVal.members['Version'], '"0.0.0.0"');
      expect(sfVal.members.containsKey('%FLG: Seq'), isFalse);
      expect(sfVal.directives['%FLG: Seq'], '4194304');
      expect(sfVal.directives['%HI: Seq'], '[0]');
    });

    test('exposes object names via %NAME (unquoted)', () {
      final data = f.sections.firstWhere((s) => s.isDef && s.path == 'SF');
      expect(data.name, 'Data');
      final mainSeq = f.sections.firstWhere((s) => s.isDef && s.path == 'SF.Seq[0]');
      expect(mainSeq.name, 'MainSequence');
    });

    test('array element type declaration is captured as a directive', () {
      final seqDef = f.sections.firstWhere((s) => s.isDef && s.path == 'SF.Seq');
      expect(seqDef.directives['%[0]'], 'Sequence');
    });

    test('detectSeqHeader now recovers the INI header (was null)', () {
      final bytes = Uint8List.fromList(latin1.encode(_ini));
      expect(detectSeqFormat(bytes), SeqFormat.ini);
      final h = detectSeqHeader(bytes);
      expect(h.fileType, 'SequenceFile');
      expect(h.productName, 'TestStand');
      expect(h.fileVersion, '354');
    });
  });

  group('iniDataTree', () {
    final tree = iniDataTree(parseIniSeq(_ini))!;

    test('roots at the SequenceFileData object named "Data"', () {
      expect(tree.name, 'Data');
      expect(tree.className, 'SequenceFileData');
    });

    test('reconstructs the Seq array and its MainSequence element', () {
      final seq = tree.subProps.firstWhere((p) => p.name == 'Seq');
      expect(seq.className, 'Objs');
      expect(seq.isArray, isTrue);
      expect(seq.array, hasLength(1));
      final mainSeq = seq.array!.single;
      expect(mainSeq.name, 'MainSequence');
      expect(mainSeq.subProps.map((p) => p.name), contains('Main'));
    });

    test('surfaces a scalar member with its value and declared type', () {
      final version = tree.subProps.firstWhere((p) => p.name == 'Version');
      expect(version.scalar, '0.0.0.0');
      expect(version.isLeaf, isTrue);
    });
  });

  group('parseSeqFile on INI (typed lens)', () {
    final sf = parseIni(_ini);

    test('builds a SeqFile whose lens recovers the sequence + step', () {
      expect(sf.header.fileType, 'SequenceFile');
      expect(sf.sequences, hasLength(1));
      final seq = sf.sequences.single;
      expect(seq.name, 'MainSequence');
      expect(seq.main, hasLength(1));
      final step = seq.main.single;
      expect(step.name, 'myStep');
      expect(step.type, 'Action');
    });

    test('the step has no instance-level settings/module to surface yet', () {
      final step = sf.sequences.single.main.single;
      expect(step.settings.mode, isNull);
      expect(step.module.adapter, SeqAdapter.none);
    });
  });

  const inheritIni = '''
[__Header__]
ProductName = "TestStand"
Version = 354
Type = "SequenceFile"

[DEF, %OBJROOT]
SF = SequenceFileData
[DEF, SF]
Seq = Objs
%NAME = "Data"
[DEF, SF.Seq]
%[0] = Sequence
[DEF, SF.Seq[0]]
Main = Objs
%NAME = "MainSequence"
[DEF, SF.Seq[0].Main]
%[0] = Step
%TYPE: %[0] = "Action"
[DEF, SF.Seq[0].Main[0]]
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
''';

  group('INI type inheritance (instance inherits from its [DEF, <Type>])', () {
    final sf = parseIni(inheritIni);
    final step = sf.sequences.single.main.single;

    test('the instance keeps its identity', () {
      expect(step.name, 'myStep');
      expect(step.type, 'Action');
    });

    test('inherits run-mode + looping defaults from the type', () {
      expect(step.settings.mode, 'Normal');
      expect(step.settings.loopType, 'NoLooping');
    });

    test('inherits the module-adapter binding from the type', () {
      expect(step.module.adapter, SeqAdapter.labView);
      expect(step.module.viPath, 'measure.vi');
    });
  });

  const emptySDataIni = '''
[__Header__]
ProductName = "TestStand"
Version = 354
Type = "SequenceFile"

[DEF, %OBJROOT]
SF = SequenceFileData
[DEF, SF]
Seq = Objs
%NAME = "Data"
[DEF, SF.Seq]
%[0] = Sequence
[DEF, SF.Seq[0]]
Main = Objs
%NAME = "MainSequence"
[DEF, SF.Seq[0].Main]
%[0] = Step
%TYPE: %[0] = "NI_Flow_End"
[DEF, SF.Seq[0].Main[0]]
%NAME = "End"

[DEF, NI_Flow_End]
TS = "TYPE, TEInf"
[DEF, NI_Flow_End.TS]
Mode = String
SData = "TYPE, FlexGStepAdditions"
[NI_Flow_End.TS]
Mode = "Normal"
[DEF, NI_Flow_End.TS.SData]
''';

  test('an empty inherited SData classifies as SeqAdapter.none (not unknown)', () {
    final sf = parseIni(emptySDataIni);
    final step = sf.sequences.single.main.single;
    expect(step.type, 'NI_Flow_End');
    expect(step.settings.mode, 'Normal');
    expect(step.module.adapter, SeqAdapter.none);
  });

  const objectsAliasIni = '''
[__Header__]
ProductName = "TestStand"
Version = 143
Type = "SequenceFile"

[DEF, %OBJECTS]
SF = SequenceFileData
Path = PathValue
[DEF, SF]
Seq = Objs
%NAME = "Data"
[DEF, SF.Seq]
%[0] = Sequence
[DEF, SF.Seq[0]]
Main = Objs
%NAME = "MainSequence"
[DEF, SF.Seq[0].Main]
%[0] = Step
%TYPE: %[0] = "Action"
[DEF, SF.Seq[0].Main[0]]
%NAME = "legacyStep"
[DEF, SF.Seq[0].Main[0].TS]
SData = Obj
[DEF, SF.Seq[0].Main[0].TS.SData]
ViPath = PathValue
[SF.Seq[0].Main[0].TS.SData]
ViPath = "legacy.vi"
''';

  test('resolves the older %OBJECTS root alias (not just %OBJROOT)', () {
    final sf = parseIni(objectsAliasIni);
    expect(sf.header.fileType, 'SequenceFile');
    final seq = sf.sequences.single;
    expect(seq.name, 'MainSequence');
    expect(seq.main.single.name, 'legacyStep');
    expect(seq.main.single.type, 'Action');
  });

  test('recognizes the older direct-ViPath LabVIEW adapter (no ViCall wrapper)', () {
    final sf = parseIni(objectsAliasIni);
    final module = sf.sequences.single.main.single.module;
    expect(module.adapter, SeqAdapter.labView);
    expect(module.viPath, 'legacy.vi');
  });

  const overrideIni = '''
[__Header__]
ProductName = "TestStand"
Version = 354
Type = "SequenceFile"

[DEF, %OBJROOT]
SF = SequenceFileData
[DEF, SF]
Seq = Objs
%NAME = "Data"
[DEF, SF.Seq]
%[0] = Sequence
[DEF, SF.Seq[0]]
Main = Objs
%NAME = "MainSequence"
[DEF, SF.Seq[0].Main]
%[0] = Step
%TYPE: %[0] = "Action"
[DEF, SF.Seq[0].Main[0]]
TS = Obj
%NAME = "ovrStep"
[DEF, SF.Seq[0].Main[0].TS]
Mode = String
[SF.Seq[0].Main[0].TS]
Mode = "Skip"
[SF.Seq[0].Main[0]]
%INSTOVRD: TS = 5046297
''';

  test('marks instance-overridden members via %INSTOVRD', () {
    final sf = parseIni(overrideIni);
    final step = sf.sequences.single.main.single;
    final ts = step.raw.prop('TS');
    expect(ts, isNotNull);
    expect(ts!.isInstanceOverride, isTrue);
    expect(ts.attributes['%INSTOVRD'], '5046297');
    expect(ts.prop('Mode')?.isInstanceOverride, isFalse);
    expect(ts.instanceOverrideFlags, 5046297);
    expect(ts.prop('Mode')?.instanceOverrideFlags, isNull);
    expect((ts.instanceOverrideFlags! >> 16) & 1, 1);
    expect(SeqProperty(name: 'x').instanceOverrideFlags, isNull);
    expect(SeqProperty(name: 'x', attributes: const {'%INSTOVRD': 'bad'}).instanceOverrideFlags, isNull);
  });

  const flagsIni = '''
[__Header__]
ProductName = "TestStand"
Version = 354
Type = "SequenceFile"

[DEF, %OBJROOT]
SF = SequenceFileData
[DEF, SF]
Seq = Objs
%NAME = "Data"
[DEF, SF.Seq]
%[0] = Sequence
[DEF, SF.Seq[0]]
Main = Objs
%NAME = "MainSequence"
[DEF, SF.Seq[0].Main]
%[0] = Step
%TYPE: %[0] = "Action"
[DEF, SF.Seq[0].Main[0]]
TS = Obj
%NAME = "flagStep"
[DEF, SF.Seq[0].Main[0].TS]
SData = Obj
Mode = String
%FLG: SData = 2097152
%FLG: Mode = 4
[SF.Seq[0].Main[0].TS]
Mode = "Skip"
[SF.Seq[0].Main[0]]
%FLG: TS = 4194304
''';

  test('recovers type-level PropertyFlags via %FLG (raw bitmask)', () {
    final sf = parseIni(flagsIni);
    final step = sf.sequences.single.main.single;
    final ts = step.raw.prop('TS')!;
    expect(ts.propertyFlags, 0x400000);
    expect(ts.attributes['%FLG'], '4194304');
    expect(ts.prop('SData')?.propertyFlags, 0x200000);
    expect(ts.prop('Mode')?.propertyFlags, 0x4);
  });

  test('propertyFlags is null when no %FLG was recorded; parses defensively', () {
    final sf = parseIni(overrideIni);
    final ts = sf.sequences.single.main.single.raw.prop('TS')!;
    expect(ts.propertyFlags, isNull);
    expect(SeqProperty(name: 'x').propertyFlags, isNull);
    expect(SeqProperty(name: 'x', attributes: const {'%FLG': 'oops'}).propertyFlags, isNull);
    expect(SeqProperty(name: 'x', attributes: const {'%FLG': '4194304'}).propertyFlags, 0x400000);
  });

  const loopIni = '''
[__Header__]
ProductName = "TestStand"
Version = 354
Type = "SequenceFile"

[DEF, %OBJROOT]
SF = SequenceFileData
[DEF, SF]
Seq = Objs
%NAME = "Data"
[DEF, SF.Seq]
%[0] = Sequence
[DEF, SF.Seq[0]]
Main = Objs
%NAME = "MainSequence"
[DEF, SF.Seq[0].Main]
%[0] = Step
%TYPE: %[0] = "Action"
[DEF, SF.Seq[0].Main[0]]
TS = Obj
%NAME = "loopStep"
[DEF, SF.Seq[0].Main[0].TS]
LoopType = String
LoopInitialize = String
LoopWhile = String
LoopIncrement = String
LoopStatus = String
[SF.Seq[0].Main[0].TS]
LoopType = "FixedNumLoops"
LoopInitialize = "RunState.LoopIndex = 0"
LoopWhile = "RunState.LoopIndex < 10"
LoopIncrement = "RunState.LoopIndex += 1"
LoopStatus = "RunState.LoopNumPassed >= 1"
''';

  test('recovers the loop expressions of a looping step', () {
    final sf = parseIni(loopIni);
    final set = sf.sequences.single.main.single.settings;
    expect(set.isLooping, isTrue);
    expect(set.loopType, 'FixedNumLoops');
    expect(set.loopInitialize, 'RunState.LoopIndex = 0');
    expect(set.loopWhile, 'RunState.LoopIndex < 10');
    expect(set.loopIncrement, 'RunState.LoopIndex += 1');
    expect(set.loopStatus, 'RunState.LoopNumPassed >= 1');
    final out = dumpSeqFile(sf);
    expect(out, contains('loop FixedNumLoops ['));
    expect(out, contains('while RunState.LoopIndex < 10'));
    expect(out, contains('init RunState.LoopIndex = 0'));
    expect(out, contains('incr RunState.LoopIndex += 1'));
  });

  const commentIni = '''
[__Header__]
ProductName = "TestStand"
Version = 354
Type = "SequenceFile"

[DEF, %OBJROOT]
SF = SequenceFileData
[DEF, SF]
Seq = Objs
%NAME = "Data"
[DEF, SF.Seq]
%[0] = Sequence
[DEF, SF.Seq[0]]
Main = Objs
%NAME = "MainSequence"
[SF.Seq[0]]
%COMMENT = "Runs once at startup"
[DEF, SF.Seq[0].Main]
%[0] = Step
%[1] = Step
%TYPE: %[0] = "Action"
%TYPE: %[1] = "Action"
[DEF, SF.Seq[0].Main[0]]
%NAME = "lockStep"
[SF.Seq[0].Main[0]]
%COMMENT = "Lock sequence"
[DEF, SF.Seq[0].Main[1]]
%NAME = "plainStep"
''';

  test('recovers a step free-text comment via Step.comment', () {
    final sf = parseIni(commentIni);
    final steps = sf.sequences.single.main;
    expect(steps.map((s) => s.name), ['lockStep', 'plainStep']);
    expect(steps[0].comment, 'Lock sequence');
    expect(steps[1].comment, isNull);
  });

  test('recovers a sequence free-text comment via Sequence.comment', () {
    final sf = parseIni(commentIni);
    expect(sf.sequences.single.comment, 'Runs once at startup');
  });

  const objLocalIni = '''
[__Header__]
ProductName = "TestStand"
Version = 354
Type = "SequenceFile"

[DEF, %OBJROOT]
SF = SequenceFileData
[DEF, SF]
Seq = Objs
%NAME = "Data"
[DEF, SF.Seq]
%[0] = Sequence
[DEF, SF.Seq[0]]
Locals = Obj
%NAME = "MainSequence"
[DEF, SF.Seq[0].Locals]
Count = Num
Limits = Obj
[SF.Seq[0].Locals]
Count = "3"
[DEF, SF.Seq[0].Locals.Limits]
Low = Num
High = Num
[SF.Seq[0].Locals.Limits]
Low = "9"
High = "11"
%COMMENT = "DUT pass band"
''';

  test('reports container field/element counts on variables', () {
    final sf = parseIni(objLocalIni);
    final locals = sf.sequences.single.locals;
    expect(locals.map((v) => v.name), ['Count', 'Limits']);
    expect(locals[0].isContainer, isFalse);
    expect(locals[0].containerCount, isNull);
    final limits = locals[1];
    expect(limits.isContainer, isTrue);
    expect(limits.isArray, isFalse);
    expect(limits.containerCount, 2);
  });

  test('recovers a variable free-text comment via SeqVariable.comment', () {
    final sf = parseIni(objLocalIni);
    final locals = sf.sequences.single.locals;
    expect(locals[1].comment, 'DUT pass band');
    expect(locals[0].comment, isNull);
  });

  const arrayLocalIni = '''
[__Header__]
ProductName = "TestStand"
Version = 354
Type = "SequenceFile"

[DEF, %OBJROOT]
SF = SequenceFileData
[DEF, SF]
Seq = Objs
%NAME = "Data"
[DEF, SF.Seq]
%[0] = Sequence
[DEF, SF.Seq[0]]
Locals = Obj
%NAME = "MainSequence"
[DEF, SF.Seq[0].Locals]
Items = Objs
[DEF, SF.Seq[0].Locals.Items]
%[0] = Obj
%[1] = Obj
%[2] = Obj
[DEF, SF.Seq[0].Locals.Items[0]]
%NAME = "a"
[DEF, SF.Seq[0].Locals.Items[1]]
%NAME = "b"
[DEF, SF.Seq[0].Locals.Items[2]]
%NAME = "c"
''';

  test('counts elements of a populated array variable', () {
    final sf = parseIni(arrayLocalIni);
    final items = sf.sequences.single.locals.single;
    expect(items.name, 'Items');
    expect(items.isArray, isTrue);
    expect(items.isContainer, isTrue);
    expect(items.containerCount, 3);
    expect(items.value, isNull);
    expect(dumpSeqFile(sf), contains('• Items : Objs [3]'));
  });

  const flowIni = '''
[__Header__]
ProductName = "TestStand"
Version = 354
Type = "SequenceFile"

[DEF, %OBJROOT]
SF = SequenceFileData
[DEF, SF]
Seq = Objs
%NAME = "Data"
[DEF, SF.Seq]
%[0] = Sequence
[DEF, SF.Seq[0]]
Main = Objs
%NAME = "MainSequence"
[DEF, SF.Seq[0].Main]
%[0] = Step
%TYPE: %[0] = "Action"
[DEF, SF.Seq[0].Main[0]]
TS = Obj
%NAME = "gotoStep"
[DEF, SF.Seq[0].Main[0].TS]
PassAct = String
FailAct = String
FailActTarget = String
Icon = String
LoadOpt = String
UnloadOpt = String
[SF.Seq[0].Main[0].TS]
PassAct = "Next"
FailAct = "Goto"
FailActTarget = "\\"<Cleanup>\\""
Icon = "FlowControl\\NI_While.ico"
LoadOpt = "DynamicLoad"
UnloadOpt = "UnloadAfterStepExecution"
''';

  test('recovers a step flow-action jump target (Goto -> <Cleanup>)', () {
    final sf = parseIni(flowIni);
    final set = sf.sequences.single.main.single.settings;
    expect(set.passAction, 'Next');
    expect(set.failAction, 'Goto');
    expect(set.passActionTarget, isNull);
    expect(set.failActionTarget, '<Cleanup>');
    expect(set.flowSummary, 'Next/Goto→<Cleanup>');
  });

  test('recovers non-default module load/unload timing', () {
    final sf = parseIni(flowIni);
    final set = sf.sequences.single.main.single.settings;
    expect(set.loadOption, 'DynamicLoad');
    expect(set.unloadOption, 'UnloadAfterStepExecution');
    final out = dumpSeqFile(sf);
    expect(out, contains('load DynamicLoad'));
    expect(out, contains('unload UnloadAfterStepExecution'));
  });

  test('recovers the step editor icon basename (folder + .ico stripped)', () {
    final sf = parseIni(flowIni);
    expect(sf.sequences.single.main.single.settings.icon, 'NI_While');
    final plain = parseIni(commentIni);
    expect(plain.sequences.single.main.first.settings.icon, isNull);
    expect(dumpSeqFile(sf), contains('{icon NI_While}'));
  });

  const idRefIni = '''
[__Header__]
ProductName = "TestStand"
Version = 354
Type = "SequenceFile"

[DEF, %OBJROOT]
SF = SequenceFileData
[DEF, SF]
Seq = Objs
%NAME = "Data"
[DEF, SF.Seq]
%[0] = Sequence
[DEF, SF.Seq[0]]
Main = Objs
%NAME = "MainSequence"
[DEF, SF.Seq[0].Main]
%[0] = Step
%[1] = Step
%TYPE: %[0] = "Action"
%TYPE: %[1] = "Action"
[DEF, SF.Seq[0].Main[0]]
TS = Obj
%NAME = "condStep"
[DEF, SF.Seq[0].Main[0].TS]
CustFalseActTarget = String
[SF.Seq[0].Main[0].TS]
CustFalseActTarget = "\\"ID#:STEP2\\""
[DEF, SF.Seq[0].Main[1]]
TS = Obj
%NAME = "targetStep"
[DEF, SF.Seq[0].Main[1].TS]
Id = String
[SF.Seq[0].Main[1].TS]
Id = "ID#:STEP2"
''';

  test('resolves an ID#: step reference to the destination step name', () {
    final sf = parseIni(idRefIni);
    final cond = sf.sequences.single.main.first;
    expect(cond.settings.customFalseTarget, 'ID#:STEP2');
    expect(sf.stepNameForId('ID#:STEP2'), 'targetStep');
    expect(sf.stepNameForId('STEP2'), 'targetStep');
    expect(sf.stepNameForId('ID#:NOPE'), isNull);
    expect(dumpSeqFile(sf), contains('cust-false→targetStep'));
  });

  test('dumpSeqFile includes recovered comments and container sizes', () {
    final cf = parseIni(commentIni);
    final out = dumpSeqFile(cf);
    expect(out, contains('// Runs once at startup'));
    expect(out, contains('lockStep'));
    expect(out, contains('// Lock sequence'));

    final of = parseIni(objLocalIni);
    final out2 = dumpSeqFile(of);
    expect(out2, contains('Limits : Obj {2 fields}'));
    expect(out2, contains('// DUT pass band'));

    final ff = parseIni(flowIni);
    expect(dumpSeqFile(ff), contains('flow Next/Goto→<Cleanup>'));
  });

  group('multi-line value continuation', () {
    const splitIni = '''
[__Header__]
ProductName = "TestStand"
Version = 354
Type = "SequenceFile"

[SomeObj]
Plain = "untouched"
DescriptionFormat Line0001 = "ResStr(\\"NI\\", \\"NAME\\") + ((\\"%Mod\\" == \\"\\") ? \\"\\" : \\",  %Mod"
DescriptionFormat Line0002 = "uleDescription\\")"
%COMMENT Line0001 = "first half "
%COMMENT Line0002 = "second half"
''';

    test('reassembles a split member into the single base key', () {
      final f = parseIniSeq(splitIni);
      final s = f.sections.single;
      expect(s.members.keys, ['Plain', 'DescriptionFormat']);
      expect(s.members['Plain'], '"untouched"');
      expect(
        s.members['DescriptionFormat'],
        '"ResStr(\\"NI\\", \\"NAME\\") + ((\\"%Mod\\" == \\"\\") ? \\"\\" : \\",  %ModuleDescription\\")"',
      );
    });

    test('reassembles a split directive (e.g. %COMMENT)', () {
      final f = parseIniSeq(splitIni);
      final s = f.sections.single;
      expect(s.directives.keys, ['%COMMENT']);
      expect(s.directives['%COMMENT'], '"first half second half"');
    });

    test('leaves single-line values untouched (no residual fragments)', () {
      final f = parseIniSeq(_ini);
      for (final s in f.sections) {
        expect(s.members.keys.any((k) => k.contains(' Line')), isFalse);
        expect(s.directives.keys.any((k) => k.contains(' Line')), isFalse);
      }
    });

    test('reassembles a value whose content contains " = "', () {
      const ini = '''
[__Header__]
Type = "SequenceFile"

[Obj]
Expr Line0001 = "Locals.x "
Expr Line0002 = "= Locals.y + 1"
''';
      final s = parseIniSeq(ini).sections.single;
      expect(s.members.keys, ['Expr']);
      expect(s.members['Expr'], '"Locals.x = Locals.y + 1"');
    });
  });

  test('flowSummary marks an unset side with ? (only pass action present)', () {
    const ini = '''
[__Header__]
ProductName = "TestStand"
Version = 354
Type = "SequenceFile"

[DEF, %OBJROOT]
SF = SequenceFileData
[DEF, SF]
Seq = Objs
%NAME = "Data"
[DEF, SF.Seq]
%[0] = Sequence
[DEF, SF.Seq[0]]
Main = Objs
%NAME = "MainSequence"
[DEF, SF.Seq[0].Main]
%[0] = Step
%TYPE: %[0] = "Action"
[DEF, SF.Seq[0].Main[0]]
TS = Obj
%NAME = "branch"
[DEF, SF.Seq[0].Main[0].TS]
PassAct = String
PassActTarget = String
[SF.Seq[0].Main[0].TS]
PassAct = "Goto"
PassActTarget = "\\"<End>\\""
''';
    final set = parseIni(ini).sequences.single.main.single.settings;
    expect(set.passActionTarget, '<End>');
    expect(set.failAction, isNull);
    expect(set.flowSummary, 'Goto→<End>/?');
  });

  test('flowSummary shows both a pass and a fail jump target', () {
    const ini = '''
[__Header__]
ProductName = "TestStand"
Version = 354
Type = "SequenceFile"

[DEF, %OBJROOT]
SF = SequenceFileData
[DEF, SF]
Seq = Objs
%NAME = "Data"
[DEF, SF.Seq]
%[0] = Sequence
[DEF, SF.Seq[0]]
Main = Objs
%NAME = "MainSequence"
[DEF, SF.Seq[0].Main]
%[0] = Step
%TYPE: %[0] = "Action"
[DEF, SF.Seq[0].Main[0]]
TS = Obj
%NAME = "branch"
[DEF, SF.Seq[0].Main[0].TS]
PassAct = String
FailAct = String
PassActTarget = String
FailActTarget = String
[SF.Seq[0].Main[0].TS]
PassAct = "Goto"
FailAct = "Goto"
PassActTarget = "\\"<End>\\""
FailActTarget = "\\"<Cleanup>\\""
''';
    final set = parseIni(ini).sequences.single.main.single.settings;
    expect(set.passActionTarget, '<End>');
    expect(set.failActionTarget, '<Cleanup>');
    expect(set.flowSummary, 'Goto→<End>/Goto→<Cleanup>');
  });

  test('recovers a module call\'s bound arguments (name, expr, direction)', () {
    const ini = '''
[__Header__]
ProductName = "TestStand"
Version = 354
Type = "SequenceFile"

[DEF, %OBJROOT]
SF = SequenceFileData
[DEF, SF]
Seq = Objs
%NAME = "Data"
[DEF, SF.Seq]
%[0] = Sequence
[DEF, SF.Seq[0]]
Main = Objs
%NAME = "MainSequence"
[DEF, SF.Seq[0].Main]
%[0] = Step
%TYPE: %[0] = "Action"
[DEF, SF.Seq[0].Main[0]]
TS = Obj
%NAME = "Get User"
[DEF, SF.Seq[0].Main[0].TS]
SData = Obj
[DEF, SF.Seq[0].Main[0].TS.SData]
Call = Obj
[DEF, SF.Seq[0].Main[0].TS.SData.Call]
Parameters = Objs
[DEF, SF.Seq[0].Main[0].TS.SData.Call.Parameters]
%[0] = Obj
%[1] = Obj
[SF.Seq[0].Main[0].TS.SData.Call.Parameters[0]]
Name = "Return Value"
ArgVal = "Locals.userToLogin"
DisplayType = "User (Object Reference)"
Direction = 2
[SF.Seq[0].Main[0].TS.SData.Call.Parameters[1]]
Name = "LoginName"
ArgVal = "FileGlobals.UserToAutoLogin"
DisplayType = "String"
Direction = 1
''';
    final step = parseIni(ini).sequences.single.main.single;
    final args = step.module.callParameters;
    expect(args.length, 2);

    expect(args[0].name, 'Return Value');
    expect(args[0].boundExpression, 'Locals.userToLogin');
    expect(args[0].displayType, 'User (Object Reference)');
    expect(args[0].directionCode, '2');
    expect(args[0].direction, 'out');

    expect(args[1].name, 'LoginName');
    expect(args[1].boundExpression, 'FileGlobals.UserToAutoLogin');
    expect(args[1].direction, 'in');
  });

  test('recovers a step\'s recorded measurement units (Result.Units)', () {
    const ini = '''
[__Header__]
ProductName = "TestStand"
Version = 354
Type = "SequenceFile"

[DEF, %OBJROOT]
SF = SequenceFileData
[DEF, SF]
Seq = Objs
%NAME = "Data"
[DEF, SF.Seq]
%[0] = Sequence
[DEF, SF.Seq[0]]
Main = Objs
%NAME = "MainSequence"
[DEF, SF.Seq[0].Main]
%[0] = Step
%TYPE: %[0] = "NumericLimitTest"
[DEF, SF.Seq[0].Main[0]]
Comp = String
DataSource = String
Limits = Obj
Result = Obj
%NAME = "Check Current"
[DEF, SF.Seq[0].Main[0].Limits]
Low = Number
High = Number
[DEF, SF.Seq[0].Main[0].Result]
Units = String
[SF.Seq[0].Main[0]]
Comp = "GELE"
DataSource = "Step.Result.Numeric"
[SF.Seq[0].Main[0].Limits]
Low = 9
High = 11
[SF.Seq[0].Main[0].Result]
Units = "mA"
''';
    final sf = parseIni(ini);
    final step = sf.sequences.single.main.single;
    expect(step.type, 'NumericLimitTest');
    expect(step.resultUnits, 'mA');
    expect(step.limits?.summary, 'GELE [9, 11]');
    expect(dumpSeqFile(sf), contains('{limits GELE [9, 11] mA}'));
  });

  test('recovers a PassFailTest data-source criterion (no limits)', () {
    const ini = '''
[__Header__]
ProductName = "TestStand"
Version = 354
Type = "SequenceFile"

[DEF, %OBJROOT]
SF = SequenceFileData
[DEF, SF]
Seq = Objs
%NAME = "Data"
[DEF, SF.Seq]
%[0] = Sequence
[DEF, SF.Seq[0]]
Main = Objs
%NAME = "MainSequence"
[DEF, SF.Seq[0].Main]
%[0] = Step
%TYPE: %[0] = "PassFailTest"
[DEF, SF.Seq[0].Main[0]]
DataSource = String
%NAME = "Motor running"
[SF.Seq[0].Main[0]]
DataSource = "Step.Result.PassFail"
''';
    final sf = parseIni(ini);
    final step = sf.sequences.single.main.single;
    expect(step.type, 'PassFailTest');
    expect(step.limits, isNull);
    expect(step.dataSource, 'Step.Result.PassFail');
    expect(dumpSeqFile(sf), contains('{data-source Step.Result.PassFail}'));
  });

  test('result accessors return null/empty on absent or empty members', () {
    const ini = '''
[__Header__]
ProductName = "TestStand"
Version = 354
Type = "SequenceFile"

[DEF, %OBJROOT]
SF = SequenceFileData
[DEF, SF]
Seq = Objs
%NAME = "Data"
[DEF, SF.Seq]
%[0] = Sequence
[DEF, SF.Seq[0]]
Main = Objs
%NAME = "MainSequence"
[DEF, SF.Seq[0].Main]
%[0] = Step
%TYPE: %[0] = "Action"
%[1] = Step
%TYPE: %[1] = "Action"
[DEF, SF.Seq[0].Main[0]]
%NAME = "Bare"
[DEF, SF.Seq[0].Main[1]]
Result = Obj
%NAME = "Empty bits"
[DEF, SF.Seq[0].Main[1].Result]
Units = String
[DEF, SF.Seq[0].Main[1].TS]
SData = Obj
[DEF, SF.Seq[0].Main[1].TS.SData]
Call = Obj
[DEF, SF.Seq[0].Main[1].TS.SData.Call]
Parameters = Objs
[DEF, SF.Seq[0].Main[1].TS.SData.Call.Parameters]
%[0] = Obj
[SF.Seq[0].Main[1].Result]
Units = ""
[SF.Seq[0].Main[1].TS.SData.Call.Parameters[0]]
Name = "flag"
Direction = 0
''';
    final main = parseIni(ini).sequences.single.main;

    final bare = main[0];
    expect(bare.resultUnits, isNull);
    expect(bare.dataSource, isNull);
    expect(bare.module.callParameters, isEmpty);

    final step = main[1];
    expect(step.resultUnits, isNull);
    final args = step.module.callParameters;
    expect(args.length, 1);
    expect(args.single.boundExpression, isNull);
    expect(args.single.directionCode, '0');
    expect(args.single.direction, isNull);
  });

  test('dump shows standalone {units} for a non-limit step', () {
    const ini = '''
[__Header__]
ProductName = "TestStand"
Version = 354
Type = "SequenceFile"

[DEF, %OBJROOT]
SF = SequenceFileData
[DEF, SF]
Seq = Objs
%NAME = "Data"
[DEF, SF.Seq]
%[0] = Sequence
[DEF, SF.Seq[0]]
Main = Objs
%NAME = "MainSequence"
[DEF, SF.Seq[0].Main]
%[0] = Step
%TYPE: %[0] = "Action"
[DEF, SF.Seq[0].Main[0]]
Result = Obj
%NAME = "Measure rail"
[DEF, SF.Seq[0].Main[0].Result]
Units = String
[SF.Seq[0].Main[0].Result]
Units = "V"
''';
    final sf = parseIni(ini);
    final step = sf.sequences.single.main.single;
    expect(step.limits, isNull);
    expect(step.resultUnits, 'V');
    final out = dumpSeqFile(sf);
    expect(out, contains('{units V}'));
    expect(out, isNot(contains('{limits')));
  });

  group('CallParameter.direction code mapping', () {
    CallParameter withDirection(String? code) => CallParameter(
      SeqProperty(
        name: 'arg',
        subProps: [
          SeqProperty(name: 'Name', scalar: 'arg'),
          if (code != null) SeqProperty(name: 'Direction', scalar: code),
        ],
      ),
    );

    test('1/2/3 map to in/out/in-out', () {
      expect(withDirection('1').direction, 'in');
      expect(withDirection('2').direction, 'out');
      expect(withDirection('3').direction, 'in/out');
    });

    test('unknown code passes through raw, direction stays null', () {
      final p = withDirection('5');
      expect(p.directionCode, '5');
      expect(p.direction, isNull);
    });

    test('absent Direction yields null code and null direction', () {
      final p = withDirection(null);
      expect(p.directionCode, isNull);
      expect(p.direction, isNull);
    });
  });

  test('a sequence with both parameters and locals is surfaced + dumped', () {
    const ini = '''
[__Header__]
ProductName = "TestStand"
Version = 354
Type = "SequenceFile"

[DEF, %OBJROOT]
SF = SequenceFileData
[DEF, SF]
Seq = Objs
%NAME = "Data"
[DEF, SF.Seq]
%[0] = Sequence
[DEF, SF.Seq[0]]
Parameters = Obj
Locals = Obj
%NAME = "MainSequence"
[DEF, SF.Seq[0].Parameters]
Voltage = Num
[SF.Seq[0].Parameters]
Voltage = "5"
[DEF, SF.Seq[0].Locals]
Count = Num
[SF.Seq[0].Locals]
Count = "3"
''';
    final sf = parseIni(ini);
    final seq = sf.sequences.single;
    expect(seq.parameters.map((v) => v.name), ['Voltage']);
    expect(seq.parameters.single.value, '5');
    expect(seq.locals.map((v) => v.name), ['Count']);

    final out = dumpSeqFile(sf);
    expect(out, contains('Parameters:'));
    expect(out, contains('• Voltage : Num = 5'));
    expect(out, contains('Locals:'));
    expect(out, contains('• Count : Num = 3'));
  });

  String covIni(List<String> tsKeys) =>
      '''
[__Header__]
ProductName = "TestStand"
Version = 354
Type = "SequenceFile"

[DEF, %OBJROOT]
SF = SequenceFileData
[DEF, SF]
Seq = Objs
%NAME = "Data"
[DEF, SF.Seq]
%[0] = Sequence
[DEF, SF.Seq[0]]
Main = Objs
%NAME = "MainSequence"
[DEF, SF.Seq[0].Main]
%[0] = Step
%TYPE: %[0] = "Action"
[DEF, SF.Seq[0].Main[0]]
TS = Obj
%NAME = "s"
[DEF, SF.Seq[0].Main[0].TS]
${tsKeys.map((k) => '$k = String').join('\n')}
[SF.Seq[0].Main[0].TS]
${tsKeys.map((k) => '$k = "v"').join('\n')}
''';

  int modeledFor(List<String> tsKeys) => measureCoverage(
    parseIni(covIni(tsKeys)),
  ).modeled;

  test('measureCoverage counts the loop/unload TS step-settings', () {
    final base = modeledFor(['Mode']);
    for (final k in [
      'Id',
      'UnloadOpt',
      'LoopInitialize',
      'LoopIncrement',
      'LoopStatus',
      'Icon',
      'StepFCSeqF',
      'IgnoreRTE',
      'ResultOption',
    ]) {
      expect(modeledFor(['Mode', k]), base + 1, reason: '$k not counted');
    }
  });

  test('Step.id recovers the step unique id (TS.Id)', () {
    final f = parseIni(covIni(['Id']));
    expect(f.sequences.single.main.single.id, 'v');
    final g = parseIni(covIni(['Mode']));
    expect(g.sequences.single.main.single.id, isNull);
  });

  String boolIni(String key, String value) =>
      '''
[__Header__]
ProductName = "TestStand"
Version = 354
Type = "SequenceFile"

[DEF, %OBJROOT]
SF = SequenceFileData
[DEF, SF]
Seq = Objs
%NAME = "Data"
[DEF, SF.Seq]
%[0] = Sequence
[DEF, SF.Seq[0]]
Main = Objs
%NAME = "MainSequence"
[DEF, SF.Seq[0].Main]
%[0] = Step
%TYPE: %[0] = "Action"
[DEF, SF.Seq[0].Main[0]]
TS = Obj
%NAME = "s"
[DEF, SF.Seq[0].Main[0].TS]
$key = String
[SF.Seq[0].Main[0].TS]
$key = "$value"
''';

  test('StepSettings recovers boolean step flags (true/false and 1/0)', () {
    StepSettings settingsWith(String key, String value) =>
        parseIni(boolIni(key, value)).sequences.single.main.single.settings;
    expect(settingsWith('StepFCSeqF', 'true').failureCausesSequenceFailure, isTrue);
    expect(settingsWith('StepFCSeqF', 'false').failureCausesSequenceFailure, isFalse);
    expect(settingsWith('IgnoreRTE', 'true').ignoresRunTimeErrors, isTrue);
    expect(settingsWith('ResultOption', '1').recordsResult, isTrue);
    expect(settingsWith('ResultOption', '0').recordsResult, isFalse);
    expect(settingsWith('Mode', 'Normal').recordsResult, isNull);
  });

  group('quoted-value escape decoding', () {
    String preIni(String escaped) =>
        '''
[__Header__]
ProductName = "TestStand"
Version = 354
Type = "SequenceFile"

[DEF, %OBJROOT]
SF = SequenceFileData
[DEF, SF]
Seq = Objs
%NAME = "Data"
[DEF, SF.Seq]
%[0] = Sequence
[DEF, SF.Seq[0]]
Main = Objs
%NAME = "MainSequence"
[DEF, SF.Seq[0].Main]
%[0] = Step
%TYPE: %[0] = "Action"
[DEF, SF.Seq[0].Main[0]]
TS = Obj
%NAME = "s"
[DEF, SF.Seq[0].Main[0].TS]
PreCond = ExprValue
[SF.Seq[0].Main[0].TS]
PreCond = "$escaped"
''';

    StepSettings parse(String escaped) => parseIni(preIni(escaped)).sequences.single.main.single.settings;

    test(r'decodes \" to a literal double quote', () {
      expect(parse(r'Locals.M != \"S001\"').precondition, 'Locals.M != "S001"');
    });

    test(r'decodes a doubled backslash \\ to one, and \n to a newline', () {
      expect(parse(r'line1\nC:\\dir').precondition, 'line1\nC:\\dir');
    });

    test('leaves a value with no escapes untouched', () {
      expect(parse('Locals.X > 0').precondition, 'Locals.X > 0');
    });

    test('keeps an unrecognized escape verbatim (defensive)', () {
      expect(parse(r'a\qb').precondition, r'a\qb');
    });
  });

  const loHiIni = '''
[__Header__]
ProductName = "TestStand"
Version = 354
Type = "SequenceFile"

[DEF, %OBJROOT]
SF = SequenceFileData
[DEF, SF]
Seq = Objs
%NAME = "Data"
[DEF, SF.Seq]
%[0] = Sequence
[DEF, SF.Seq[0]]
Main = Objs
%NAME = "MainSequence"
[DEF, SF.Seq[0].Main]
%[0] = Step
%TYPE: %[0] = "NI_Database_ExecuteSQLStatement"
[DEF, SF.Seq[0].Main[0]]
ColumnList = Objs
Parms = Objs
%NAME = "dbStep"
[SF.Seq[0].Main[0]]
%LO: ColumnList = [1]
%HI: ColumnList = [2]
%HI: Parms = [63]
''';

  group('declared array bounds (%LO/%HI)', () {
    final step = parseIni(loHiIni).sequences.single.main.single.raw;

    test('retains %LO alongside %HI (corpus: DBSeq.seq ColumnList)', () {
      final cols = step.prop('ColumnList')!;
      expect(cols.attributes['%LO'], '[1]');
      expect(cols.attributes['%HI'], '[2]');
      expect(cols.lowIndices, [1]);
      expect(cols.highIndices, [2]);
    });

    test('declared length is hi - lo + 1 per dimension (not hi + 1)', () {
      expect(step.prop('ColumnList')!.declaredArrayLength, 2);
    });

    test('low bound defaults to 0 per dimension when %LO is absent', () {
      final parms = step.prop('Parms')!;
      expect(parms.lowIndices, isNull);
      expect(parms.declaredArrayLength, 64);
    });

    test('bounds arithmetic is total over crafted inputs', () {
      SeqProperty p(Map<String, String> attrs) => SeqProperty(name: 'x', attributes: attrs);
      expect(p({'%LO': '[1]', '%HI': '[1]'}).declaredArrayLength, 1); // corpus: 1-element sparse
      expect(p({'%LO': '[0][0]', '%HI': '[1][7]'}).declaredArrayLength, 16);
      expect(p({'%LO': '[1]', '%HI': '[2][3]'}).declaredArrayLength, 2 * 4); // short %LO pads with 0
      expect(p({'%HI': '[-1]'}).declaredArrayLength, 0); // unobserved, defensive
      expect(p({'%LO': '[2]', '%HI': '[1]'}).declaredArrayLength, 0); // unobserved, defensive
      expect(p({'%LO': '[1]'}).declaredArrayLength, isNull); // no %HI: no declared length
      expect(p({}).lowIndices, isNull);
    });
  });

  const bareFlagsIni = '''
[__Header__]
ProductName = "TestStand"
Version = 354
Type = "SequenceFile"

[DEF, %OBJROOT]
SF = SequenceFileData
[DEF, SF]
Seq = Objs
%NAME = "Data"
[DEF, SF.Seq]
%[0] = Sequence
[DEF, SF.Seq[0]]
Main = Objs
%NAME = "MainSequence"
[DEF, SF.Seq[0].Main]
%[0] = Step
%TYPE: %[0] = "Action"
[DEF, SF.Seq[0].Main[0]]
TS = Obj
%NAME = "flagStep"
[DEF, SF.Seq[0].Main[0].TS]
Mode = String
Result = Obj
[SF.Seq[0].Main[0].TS]
Mode = "Normal"
%FLG = 37748760
%INSTFLG = 524312
''';

  test('retains bare own-section %FLG and %INSTFLG under their literal keys', () {
    final step = parseIni(bareFlagsIni).sequences.single.main.single;
    final ts = step.raw.prop('TS')!;
    expect(ts.attributes['%FLG'], '37748760');
    expect(ts.propertyFlags, 37748760);
    expect(ts.attributes['%INSTFLG'], '524312');
  });

  test('retains the %INSTFLG member form when no bare form exists', () {
    const ini = '''
[__Header__]
ProductName = "TestStand"
Version = 354
Type = "SequenceFile"

[DEF, %OBJROOT]
SF = SequenceFileData
[DEF, SF]
Seq = Objs
%NAME = "Data"
[DEF, SF.Seq]
%[0] = Sequence
[DEF, SF.Seq[0]]
Main = Objs
%NAME = "MainSequence"
[DEF, SF.Seq[0].Main]
%[0] = Step
%TYPE: %[0] = "Action"
[DEF, SF.Seq[0].Main[0]]
Result = Obj
%NAME = "s"
[DEF, SF.Seq[0].Main[0].Result]
Status = String
[SF.Seq[0].Main[0]]
%INSTFLG: Result = 4194304
''';
    final step = parseIni(ini).sequences.single.main.single;
    expect(step.raw.prop('Result')!.attributes['%INSTFLG'], '4194304');
  });

  group('[__Header__] continuation lines', () {
    const headerContIni = '''
[__Header__]
ProductName = "TestStand"
Version = 577
Type = "SequenceFile"
Path Line0001 = "C:\\\\Tests\\\\IVIPowerSupply\\\\TestIVIPowerSupplyReferen"
Path Line0002 = "ces.seq"

[DEF, %OBJROOT]
SF = SequenceFileData
''';

    test('reassembles split header fields the same way as section values', () {
      final f = parseIniSeq(headerContIni);
      expect(f.headerFields['Path'], r'"C:\\Tests\\IVIPowerSupply\\TestIVIPowerSupplyReferences.seq"');
      expect(f.headerFields.keys.any((k) => k.contains(' Line')), isFalse);
    });

    test('headerFields carries every header key verbatim', () {
      final f = parseIniSeq(headerContIni);
      expect(f.headerFields['ProductName'], '"TestStand"');
      expect(f.headerFields['Version'], '577');
      expect(f.header.fileVersion, '577');
    });
  });

  const typesIni = '''
[__Header__]
ProductName = "TestStand"
Version = 354
Type = "SequenceFile"

[DEF, %OBJROOT]
SF = SequenceFileData
Action = StepType
TEInf = Obj
[DEF, SF]
Seq = Objs
%NAME = "Data"
[%TYPES]
Action = "Action"
TEInf = "TEInf"
[DEF, Action]
TS = "TYPE, TEInf"
[DEF, TEInf]
Mode = String
''';

  test('iniTypes carries the root-alias class, not the quoted display name', () {
    final types = iniTypes(parseIniSeq(typesIni));
    expect(types.map((t) => t.name), ['Action', 'TEInf']);
    // The [%TYPES] member VALUE is only a display name ("Action"); the class
    // the XML flavor would carry lives in the root alias DEF (Action = StepType).
    expect(types[0].className, 'StepType');
    expect(types[1].className, 'Obj');
  });

  group('EXTDATA sections', () {
    const extIni = '''
[__Header__]
ProductName = "TestStand"
Version = 577
Type = "SequenceFile"

[DEF, %OBJROOT]
SF = SequenceFileData
[DEF, SF]
Seq = Objs
%NAME = "Data"
[EXTDATA, SF.Payload, STRUCT]
DataVersion = 1
Type = 6
[EXTDATA, SF.Payload, CLUST]
DataVersion = 1
ClusterMemberLabelName = "code"
''';

    test('are classified as a distinct section kind, path + kind decomposed', () {
      final f = parseIniSeq(extIni);
      final ext = f.extDataSections.toList();
      expect(ext, hasLength(2));
      expect(ext[0].isExtData, isTrue);
      expect(ext[0].isDef, isFalse);
      expect(ext[0].path, 'SF.Payload');
      expect(ext[0].extDataKind, 'STRUCT');
      expect(ext[0].members['Type'], '6');
      expect(ext[1].extDataKind, 'CLUST');
      // Ordinary sections are untouched.
      expect(f.sections.where((s) => !s.isExtData).every((s) => s.extDataKind == null), isTrue);
    });

    test('do not pollute the data tree with pseudo-members', () {
      final tree = iniDataTree(parseIniSeq(extIni))!;
      // A misclassified EXTDATA value section for SF.Payload would surface a
      // phantom 'Payload' member (with DataVersion/Type children) under SF.
      expect(tree.subProps.map((p) => p.name), isNot(contains('Payload')));
    });
  });
}
