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
  });
}
