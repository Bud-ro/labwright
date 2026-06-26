import 'dart:convert';
import 'dart:typed_data';

import 'package:labwright_teststand/labwright_teststand.dart';
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
      // %-directives are separated from plain members.
      expect(sfVal.members.containsKey('%FLG: Seq'), isFalse);
      expect(sfVal.directives['%FLG: Seq'], '4194304');
      expect(sfVal.directives['%HI: Seq'], '[0]');
    });

    test('exposes object names via %NAME (unquoted)', () {
      final data = f.sections.firstWhere((s) => s.isDef && s.path == 'SF');
      expect(data.name, 'Data');
      final mainSeq =
          f.sections.firstWhere((s) => s.isDef && s.path == 'SF.Seq[0]');
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
      // The element's declared member (Main) is reconstructed.
      expect(mainSeq.subProps.map((p) => p.name), contains('Main'));
    });

    test('surfaces a scalar member with its value and declared type', () {
      // Version is value-only in [SF]; it still surfaces (member union) as a leaf.
      final version = tree.subProps.firstWhere((p) => p.name == 'Version');
      expect(version.scalar, '0.0.0.0');
      expect(version.isLeaf, isTrue);
    });
  });

  group('parseSeqFile on INI (typed lens)', () {
    final sf = parseSeqFile(Uint8List.fromList(latin1.encode(_ini)));

    test('builds a SeqFile whose lens recovers the sequence + step', () {
      expect(sf.header.fileType, 'SequenceFile');
      expect(sf.sequences, hasLength(1));
      final seq = sf.sequences.single;
      expect(seq.name, 'MainSequence');
      expect(seq.main, hasLength(1));
      final step = seq.main.single;
      expect(step.name, 'myStep');
      // The step type comes from the array DEF's %TYPE: %[0].
      expect(step.type, 'Action');
    });

    test('the step has no instance-level settings/module to surface yet', () {
      // _ini declares no [DEF, Action], so there is nothing to inherit — the
      // run mode and module adapter are honestly absent (instance-only model).
      final step = sf.sequences.single.main.single;
      expect(step.settings.mode, isNull);
      expect(step.module.adapter, SeqAdapter.none);
    });
  });

  // A step instance usually stores only its overrides; its run-mode, looping and
  // module-adapter defaults live in the step's TYPE definition ([DEF, <Type>]).
  // This fixture exercises that: `myStep` (type Action) declares only %NAME, and
  // inherits TS.Mode/TS.LoopType and the VI-adapter binding from [DEF, Action].
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
    final sf = parseSeqFile(Uint8List.fromList(latin1.encode(inheritIni)));
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

  // Flow-control / no-module step types inherit a *bare* (empty) SData container
  // from their type. An empty SData carries no binding, so it must classify as
  // SeqAdapter.none — not `unknown` (which is reserved for SData shapes we can't
  // yet parse). This mirrors the full corpus, where every empty-SData step is a
  // no-module type (Statement, NI_Flow_*, Label, NI_Wait, …).
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
    final sf = parseSeqFile(Uint8List.fromList(latin1.encode(emptySDataIni)));
    final step = sf.sequences.single.main.single;
    expect(step.type, 'NI_Flow_End');
    // Settings still inherit (run mode), but there is no code module.
    expect(step.settings.mode, 'Normal');
    expect(step.module.adapter, SeqAdapter.none);
  });

  // Older TestStand INI (e.g. versions 127/143) declares its top-level objects
  // under [DEF, %OBJECTS] instead of the newer [DEF, %OBJROOT]; the data root is
  // still `SF = SequenceFileData`. The reader resolves both aliases.
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
    final sf = parseSeqFile(Uint8List.fromList(latin1.encode(objectsAliasIni)));
    expect(sf.header.fileType, 'SequenceFile');
    final seq = sf.sequences.single;
    expect(seq.name, 'MainSequence');
    expect(seq.main.single.name, 'legacyStep');
    expect(seq.main.single.type, 'Action');
  });

  test('recognizes the older direct-ViPath LabVIEW adapter (no ViCall wrapper)',
      () {
    final sf = parseSeqFile(Uint8List.fromList(latin1.encode(objectsAliasIni)));
    final module = sf.sequences.single.main.single.module;
    expect(module.adapter, SeqAdapter.labView);
    expect(module.viPath, 'legacy.vi');
  });

  // `%INSTOVRD: <member> = <flags>` marks a member the object overrides relative
  // to its base type; a bare `%INSTOVRD` marks the whole object. The reader keeps
  // the flags verbatim and exposes presence via SeqProperty.isInstanceOverride.
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
    final sf = parseSeqFile(Uint8List.fromList(latin1.encode(overrideIni)));
    final step = sf.sequences.single.main.single;
    final ts = step.raw.prop('TS');
    expect(ts, isNotNull);
    // TS is flagged overridden by the step's `%INSTOVRD: TS`; its flags are kept.
    expect(ts!.isInstanceOverride, isTrue);
    expect(ts.attributes['%INSTOVRD'], '5046297');
    // A member with no override marker stays a plain inherited/default value.
    expect(ts.prop('Mode')?.isInstanceOverride, isFalse);
  });

  // TestStand loops are expression-driven: a looping step carries
  // LoopInitialize / LoopWhile / LoopIncrement / LoopStatus under its TS.
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
    final sf = parseSeqFile(Uint8List.fromList(latin1.encode(loopIni)));
    final set = sf.sequences.single.main.single.settings;
    expect(set.isLooping, isTrue);
    expect(set.loopType, 'FixedNumLoops');
    expect(set.loopInitialize, 'RunState.LoopIndex = 0');
    expect(set.loopWhile, 'RunState.LoopIndex < 10');
    expect(set.loopIncrement, 'RunState.LoopIndex += 1');
    expect(set.loopStatus, 'RunState.LoopNumPassed >= 1');
  });

  // A step's free-text comment is stored as a `%COMMENT` directive on the step
  // instance section; the reader carries it onto the step as a `%COMMENT`
  // attribute and the shared lens exposes it as Step.comment.
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
    final sf = parseSeqFile(Uint8List.fromList(latin1.encode(commentIni)));
    final steps = sf.sequences.single.main;
    expect(steps.map((s) => s.name), ['lockStep', 'plainStep']);
    expect(steps[0].comment, 'Lock sequence');
    // A step without a %COMMENT has no comment (not an empty string).
    expect(steps[1].comment, isNull);
  });

  test('recovers a sequence free-text comment via Sequence.comment', () {
    final sf = parseSeqFile(Uint8List.fromList(latin1.encode(commentIni)));
    expect(sf.sequences.single.comment, 'Runs once at startup');
  });

  // An object/cluster local reports its field count; a scalar reports none.
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
    final sf = parseSeqFile(Uint8List.fromList(latin1.encode(objLocalIni)));
    final locals = sf.sequences.single.locals;
    expect(locals.map((v) => v.name), ['Count', 'Limits']);
    expect(locals[0].isContainer, isFalse);
    expect(locals[0].containerCount, isNull);
    final limits = locals[1];
    expect(limits.isContainer, isTrue);
    expect(limits.isArray, isFalse);
    expect(limits.containerCount, 2); // Low + High
  });

  test('recovers a variable free-text comment via SeqVariable.comment', () {
    final sf = parseSeqFile(Uint8List.fromList(latin1.encode(objLocalIni)));
    final locals = sf.sequences.single.locals;
    expect(locals[1].comment, 'DUT pass band'); // on the Limits container
    expect(locals[0].comment, isNull); // Count has none
  });

  // An array local with actual elements: containerCount counts them (the corpus
  // arrays are mostly empty defaults, so this exercises the populated path).
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
    final sf = parseSeqFile(Uint8List.fromList(latin1.encode(arrayLocalIni)));
    final items = sf.sequences.single.locals.single;
    expect(items.name, 'Items');
    expect(items.isArray, isTrue);
    expect(items.isContainer, isTrue);
    expect(items.containerCount, 3); // a, b, c
    expect(items.value, isNull); // arrays carry no scalar
  });

  // A step whose on-fail action jumps to a target (`FailAct = "Goto"`,
  // `FailActTarget = "\"<Cleanup>\""`) — the target is a TestStand string-literal
  // expression; the lens unwraps it for display.
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
    final sf = parseSeqFile(Uint8List.fromList(latin1.encode(flowIni)));
    final set = sf.sequences.single.main.single.settings;
    expect(set.passAction, 'Next');
    expect(set.failAction, 'Goto');
    expect(set.passActionTarget, isNull); // Next falls through, no target
    expect(set.failActionTarget, '<Cleanup>'); // unwrapped from \"<Cleanup>\"
    expect(set.flowSummary, 'Next/Goto→<Cleanup>');
  });

  test('recovers non-default module load/unload timing', () {
    final sf = parseSeqFile(Uint8List.fromList(latin1.encode(flowIni)));
    final set = sf.sequences.single.main.single.settings;
    expect(set.loadOption, 'DynamicLoad');
    expect(set.unloadOption, 'UnloadAfterStepExecution');
    // The dump surfaces both (they differ from the common defaults).
    final out = dumpSeqFile(sf);
    expect(out, contains('load DynamicLoad'));
    expect(out, contains('unload UnloadAfterStepExecution'));
  });

  test('recovers the step editor icon basename (folder + .ico stripped)', () {
    final sf = parseSeqFile(Uint8List.fromList(latin1.encode(flowIni)));
    // `FlowControl\NI_While.ico` -> `NI_While`.
    expect(sf.sequences.single.main.single.settings.icon, 'NI_While');
    // A step with no Icon member has no icon.
    final plain = parseSeqFile(Uint8List.fromList(latin1.encode(commentIni)));
    expect(plain.sequences.single.main.first.settings.icon, isNull);
    // The dump surfaces it.
    expect(dumpSeqFile(sf), contains('{icon NI_While}'));
  });

  // A step with a custom-condition jump to another step by id reference
  // (`CustFalseActTarget = "\"ID#:STEP2\""`); the destination step carries that
  // id in its `TS.Id`, so the reference resolves to the step's name.
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
    final sf = parseSeqFile(Uint8List.fromList(latin1.encode(idRefIni)));
    final cond = sf.sequences.single.main.first;
    expect(cond.settings.customFalseTarget, 'ID#:STEP2'); // unwrapped reference
    // The file resolves the id (with or without the ID#: prefix) to the name.
    expect(sf.stepNameForId('ID#:STEP2'), 'targetStep');
    expect(sf.stepNameForId('STEP2'), 'targetStep');
    expect(sf.stepNameForId('ID#:NOPE'), isNull);
    // The dump shows the resolved destination, not the raw id.
    expect(dumpSeqFile(sf), contains('cust-false→targetStep'));
  });

  test('dumpSeqFile includes recovered comments and container sizes', () {
    final cf = parseSeqFile(Uint8List.fromList(latin1.encode(commentIni)));
    final out = dumpSeqFile(cf);
    expect(out, contains('// Runs once at startup')); // sequence comment
    expect(out, contains('lockStep')); // step present
    expect(out, contains('// Lock sequence')); // step comment

    final of = parseSeqFile(Uint8List.fromList(latin1.encode(objLocalIni)));
    final out2 = dumpSeqFile(of);
    expect(out2, contains('Limits : Obj {2 fields}')); // container size
    expect(out2, contains('// DUT pass band')); // variable comment

    final ff = parseSeqFile(Uint8List.fromList(latin1.encode(flowIni)));
    expect(dumpSeqFile(ff), contains('flow Next/Goto→<Cleanup>')); // flow target
  });

  // NI splits a value past a line-length cap across continuation lines named
  // `KEY Line0001`, `KEY Line0002`, … — each a separately-quoted fragment. The
  // reader rejoins them, in order, into the single base key with no separator.
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
      // The spurious ` LineNNNN` members are gone; one reassembled base remains
      // at the position of the first fragment, single-line members untouched.
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
      // The line splitter cuts on the FIRST " = " (so the key is the LHS); a
      // value with its own " = " (a TestStand expression) must survive intact
      // across the fragment join.
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
    final set = parseSeqFile(Uint8List.fromList(latin1.encode(ini)))
        .sequences
        .single
        .main
        .single
        .settings;
    expect(set.passActionTarget, '<End>');
    expect(set.failActionTarget, '<Cleanup>');
    expect(set.flowSummary, 'Goto→<End>/Goto→<Cleanup>');
  });

  // A code-module call (here an Automation/ActiveX step) binds named arguments
  // under SData.Call.Parameters: each carries a Name, the ArgVal expression
  // supplying its value, a DisplayType, and a Direction (1=in, 2=out). Mirrors
  // the real corpus (e.g. ni_nitsm-python FrontEndCallbacks "Get User To Login").
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
    final step =
        parseSeqFile(Uint8List.fromList(latin1.encode(ini))).sequences.single.main.single;
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

  // A numeric limit-test step records its measurement unit on a `Result`
  // sub-object (a sibling of `TS`), not under `Limits` — e.g. a current check
  // reads `mA`. Mirrors the real corpus (noffz FCT "Numeric Limit Test 1").
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
    final sf = parseSeqFile(Uint8List.fromList(latin1.encode(ini)));
    final step = sf.sequences.single.main.single;
    expect(step.type, 'NumericLimitTest');
    expect(step.resultUnits, 'mA');
    expect(step.limits?.summary, 'GELE [9, 11]');
    // The dump folds the unit into the limits chip.
    expect(dumpSeqFile(sf), contains('{limits GELE [9, 11] mA}'));
  });

  // A PassFailTest evaluates a boolean criterion via its `DataSource` expression
  // but carries no numeric `Comp`/`Limits`, so it has no StepLimits — yet the
  // criterion is real and editor-visible. Step.dataSource recovers it generally,
  // and the dump shows it as a `{data-source …}` note. Mirrors the corpus, where
  // 113 such steps (mostly PassFailTest) set DataSource without limits.
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
    final sf = parseSeqFile(Uint8List.fromList(latin1.encode(ini)));
    final step = sf.sequences.single.main.single;
    expect(step.type, 'PassFailTest');
    expect(step.limits, isNull); // no Comp/Limits
    expect(step.dataSource, 'Step.Result.PassFail');
    expect(dumpSeqFile(sf), contains('{data-source Step.Result.PassFail}'));
  });

  // Edge cases for the recently-added result accessors: a step with no Result /
  // no DataSource / no call yields null/empty (never a fabricated value), an
  // empty `Result.Units` reads as null (not ''), and an unrecognized call-arg
  // `Direction` code passes through raw while [CallParameter.direction] stays
  // null rather than guessing.
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
    final main = parseSeqFile(Uint8List.fromList(latin1.encode(ini)))
        .sequences
        .single
        .main;

    // Bare step: nothing recorded.
    final bare = main[0];
    expect(bare.resultUnits, isNull);
    expect(bare.dataSource, isNull);
    expect(bare.module.callParameters, isEmpty);

    // Empty-bits step: present-but-empty members read as null/raw, not fabricated.
    final step = main[1];
    expect(step.resultUnits, isNull); // empty Units string -> null, not ''
    final args = step.module.callParameters;
    expect(args.length, 1);
    expect(args.single.boundExpression, isNull); // no ArgVal
    expect(args.single.directionCode, '0'); // raw code preserved
    expect(args.single.direction, isNull); // unknown code -> not guessed
  });

  // A step can record units without being a limit test (e.g. a plain Action that
  // logs a measured value). The dump shows these as a standalone `{units X}`
  // note rather than folding them into a limits chip.
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
    final sf = parseSeqFile(Uint8List.fromList(latin1.encode(ini)));
    final step = sf.sequences.single.main.single;
    expect(step.limits, isNull); // not a limit test
    expect(step.resultUnits, 'V');
    final out = dumpSeqFile(sf);
    expect(out, contains('{units V}'));
    expect(out, isNot(contains('{limits'))); // not folded into a limits chip
  });

  // CallParameter.direction maps the standard TestStand codes. The corpus only
  // exercises 1 (in) and 2 (out); `3` (in/out) is a defensive mapping with no
  // corpus example, so pin it (and the unknown-code passthrough) directly from a
  // synthetic property rather than an INI fixture.
  group('CallParameter.direction code mapping', () {
    CallParameter withDirection(String? code) => CallParameter(SeqProperty(
          name: 'arg',
          subProps: [
            SeqProperty(name: 'Name', scalar: 'arg'),
            if (code != null) SeqProperty(name: 'Direction', scalar: code),
          ],
        ));

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

  // Sequence-level Parameters are empty across the whole corpus, so the populated
  // `Sequence.parameters` path and the dump's `Parameters:` section are otherwise
  // untested. A synthetic sequence that declares both a parameter and a local
  // exercises both — and confirms the dump renders the two sections distinctly.
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
    final sf = parseSeqFile(Uint8List.fromList(latin1.encode(ini)));
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
}
