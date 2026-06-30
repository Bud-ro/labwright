import 'dart:convert';
import 'dart:typed_data';

import 'package:xml/xml.dart';

import 'seq_format.dart';
import 'seq_ini.dart';
import 'seq_property.dart';

/// A parsed TestStand sequence file: the header, the type list, and the root
/// `Data` property object, with a typed lens over the sequences and their steps.
///
/// Built from the **XML** encoding (M1). The binary `TOF1` encoding maps onto the
/// same model and is a later milestone — [parseSeqFile] throws for it rather than
/// guessing.
class SeqFile {
  SeqFile({required this.header, required this.types, required this.data});

  final SeqFileHeader header;

  /// The `<typelist>` entries (each a type's root property object).
  final List<SeqProperty> types;

  /// The `<typelist>` entries as typed [SeqType] wrappers — each type's name,
  /// base class, and declared fields. The raw roots remain available as [types].
  List<SeqType> get typeDefs => [for (final t in types) SeqType(t)];

  /// The Semiconductor-Test-System measurement plug-in resource set this file
  /// declares (`Data > FileGlobalDefaults > MeasurementPlugIns`) — the pin map
  /// and specifications/levels/timing/pattern files the test program depends on.
  /// null when the file declares no such block. See [MeasurementPlugIns].
  MeasurementPlugIns? get measurementPlugIns {
    final mp = data.prop('FileGlobalDefaults')?.prop('MeasurementPlugIns');
    return mp == null ? null : MeasurementPlugIns(mp);
  }

  /// The root `Data` property object holding the file's contents.
  final SeqProperty data;

  /// The process model file this sequence file uses (`Data.ModelFile`), e.g. a
  /// `.seq` station-model path; null when it inherits the station default.
  String? get modelFile => _nz(data.prop('ModelFile')?.scalar);

  /// The model-option code (`Data.ModelOption`) — how the file selects its model
  /// (use station model / require specific / none). Verbatim; NI-internal
  /// code→name not invented. null when absent.
  int? get modelOptionCode => int.tryParse(data.prop('ModelOption')?.scalar ?? '');

  /// The file-wide default module load/unload options (`Data.LoadOpt` /
  /// `Data.UnloadOpt`), e.g. `UseStepLoadOpt` — the fallback a step inherits when
  /// it defers to the file. null when absent.
  String? get loadOption => _nz(data.prop('LoadOpt')?.scalar);
  String? get unloadOption => _nz(data.prop('UnloadOpt')?.scalar);

  /// The file's content version string (`Data.Version`, e.g. `2022.2.9`) — the
  /// TestStand version stamp on the file contents, distinct from the
  /// header/format version ([SeqFileHeader.fileVersion]). null when absent.
  String? get contentVersion => _nz(data.prop('Version')?.scalar);

  /// The file's batch-synchronization code (`Data.BatchSync`). Verbatim;
  /// NI-internal code→name not invented. null when absent.
  int? get batchSyncCode => int.tryParse(data.prop('BatchSync')?.scalar ?? '');

  /// The file-globals scope code (`Data.SFGlobalsScope`) governing how this
  /// file's globals are shared. Verbatim; null when absent.
  int? get sequenceFileGlobalsScopeCode =>
      int.tryParse(data.prop('SFGlobalsScope')?.scalar ?? '');

  /// The file-type code (`Data.Type`) classifying the sequence file (model /
  /// ordinary / …). Verbatim; NI-internal code→name not invented. null when
  /// absent.
  int? get fileTypeCode => int.tryParse(data.prop('Type')?.scalar ?? '');

  /// The requirement-traceability links the file declares (`Data.Requirements.
  /// Links`). Empty when none.
  List<String> get requirementLinks => [
        for (final e in data.prop('Requirements')?.prop('Links')?.array ??
            const <SeqProperty>[])
          if (_nz(e.scalar) case final s?) s,
      ];

  /// The file's global variables (`Data.FileGlobalDefaults` children) — the
  /// FileGlobals a sequence references as `FileGlobals.…`. Empty when the file
  /// declares none. (The Semiconductor-Test-System resource block among them is
  /// also surfaced, typed, via [measurementPlugIns].)
  List<SeqVariable> get fileGlobals => [
        for (final p in data.prop('FileGlobalDefaults')?.subProps ??
            const <SeqProperty>[])
          SeqVariable(p),
      ];

  /// The sequences in the file (`Data > Seq` array). Empty if the path is absent
  /// (e.g. a type-palette file) — honest rather than throwing.
  List<Sequence> get sequences =>
      [for (final s in data.prop('Seq')?.array ?? const <SeqProperty>[]) Sequence(s)];

  /// The sequence named [name] in this file, or null.
  Sequence? sequence(String name) {
    for (final s in sequences) {
      if (s.name == name) return s;
    }
    return null;
  }

  /// Maps each step's unique id (`TS.Id`, e.g. `ID#:HWpAiIXA…`) to its display
  /// name, across every sequence in the file. Built once and cached. Lets an
  /// `ID#:` reference (a flow-action target like `CustFalseActTarget`) be shown as
  /// the destination step's name instead of an opaque id.
  late final Map<String, String> _stepNamesById = _buildStepIdIndex();

  Map<String, String> _buildStepIdIndex() {
    final m = <String, String>{};
    for (final seq in sequences) {
      for (final step in seq.steps) {
        final id = step.raw.prop('TS')?.prop('Id')?.scalar;
        if (id != null && id.isNotEmpty) m[id] = step.name;
      }
    }
    return m;
  }

  /// Resolves a step reference [idRef] (a `TS.Id` value, with or without the
  /// `ID#:` prefix) to the destination step's name, or null when no step in the
  /// file has that id. Used to make `ID#:`-form flow-action targets readable.
  String? stepNameForId(String idRef) {
    final hit = _stepNamesById[idRef];
    if (hit != null) return hit;
    return idRef.startsWith('ID#:') ? null : _stepNamesById['ID#:$idRef'];
  }

  /// For a SequenceCall [step], the called sequence **within this file**, or null
  /// when the step isn't a sequence call or the target lives in another file
  /// (an external call — see [Step.module] `sequenceFile`).
  Sequence? resolveCall(Step step) {
    final m = step.module;
    if (m.adapter != SeqAdapter.sequenceCall || m.sequenceName == null) return null;
    return sequence(m.sequenceName!);
  }

  @override
  String toString() =>
      'SeqFile(${header.fileType}, v${header.fileVersion}, '
      '${types.length} types, ${sequences.length} sequences)';
}

/// The three ordered step groups a sequence runs, in execution order. The single
/// source of truth for the group names: [key] is the TestStand property name
/// under which a group's steps live in the `.seq` model (matched by
/// [Sequence.stepsIn] / [Sequence.setup] etc.), so callers iterate
/// `StepGroup.values` rather than hard-coding `'Setup'`/`'Main'`/`'Cleanup'`.
enum StepGroup {
  setup('Setup'),
  main('Main'),
  cleanup('Cleanup');

  const StepGroup(this.key);

  /// The property name holding this group's step array.
  final String key;
}

/// A single sequence: a name and its three ordered step groups.
class Sequence {
  Sequence(this.raw);

  /// The underlying property object — full access to every sequence property.
  final SeqProperty raw;

  String get name => raw.name;

  /// The sequence's free-text comment — the editor's per-sequence note (e.g. a
  /// callback's "This entry point is executed only once…" description) — or null
  /// when it has none. Recovered from the sequence object's `%COMMENT`; long
  /// comments are reassembled from continuation fragments. (Carried as a
  /// `%COMMENT` attribute by the INI reader; XML sequences in the corpus store
  /// none, so this is null for them.)
  String? get comment => _nz(raw.attributes['%COMMENT']);

  /// The steps in [group] (its array property), in declaration order.
  List<Step> stepsIn(StepGroup group) => _group(group.key);

  List<Step> get setup => stepsIn(StepGroup.setup);
  List<Step> get main => stepsIn(StepGroup.main);
  List<Step> get cleanup => stepsIn(StepGroup.cleanup);

  /// All steps in editor order (Setup, then Main, then Cleanup).
  List<Step> get steps => [for (final g in StepGroup.values) ...stepsIn(g)];

  List<Step> _group(String name) =>
      [for (final s in raw.prop(name)?.array ?? const <SeqProperty>[]) Step(s)];

  /// The sequence's local variables (`Locals`), in declaration order.
  List<SeqVariable> get locals => _vars('Locals');

  /// The sequence's parameters (`Parameters`), in declaration order. Empty when
  /// the sequence takes none.
  List<SeqVariable> get parameters => _vars('Parameters');

  List<SeqVariable> _vars(String group) =>
      [for (final p in raw.prop(group)?.subProps ?? const <SeqProperty>[]) SeqVariable(p)];

  /// Whether the sequence records its steps' results into the report
  /// (`RecordResults`). null when the sequence stores no value.
  bool? get recordsResults => _flag(raw.prop('RecordResults')?.scalar);

  /// Whether a step failure jumps straight to the Cleanup group
  /// (`GotoCleanupOnFail`). null when unset.
  bool? get gotoCleanupOnFail => _flag(raw.prop('GotoCleanupOnFail')?.scalar);

  /// The sequence-level on-failure action code (`FailureAction`) — what the
  /// sequence does when it fails. Surfaced verbatim; the NI-internal code→name
  /// mapping is not invented. null when unset.
  int? get failureActionCode => int.tryParse(raw.prop('FailureAction')?.scalar ?? '');

  /// The requirement-traceability links the sequence declares
  /// (`Requirements.Links`) — free-text requirement identifiers the sequence is
  /// tagged with. Empty when the sequence declares none.
  List<String> get requirementLinks => [
        for (final e in raw.prop('Requirements')?.prop('Links')?.array ??
            const <SeqProperty>[])
          if (_nz(e.scalar) case final s?) s,
      ];

  /// The sequence's run-time / entry-point settings (`RTS`) — how it appears and
  /// behaves as a callable entry point — or null when it carries none.
  SequenceRuntimeSettings? get runtimeSettings {
    final rts = raw.prop('RTS');
    return rts == null ? null : SequenceRuntimeSettings(rts);
  }

  @override
  String toString() => 'Sequence($name, ${steps.length} steps)';
}

/// A sequence's run-time / entry-point settings (`RTS`) — the editor's
/// "Sequence Properties" run-time tab. A sequence usable as an *entry point*
/// (e.g. `MainSequence`, a process-model callback) carries display rules for
/// where it appears (`ShowEPFor…`), its menu name/hint, an enabled expression,
/// and execution options (reentrancy optimization, priority). Every getter is
/// null/empty when its field is absent — no fabricated default.
class SequenceRuntimeSettings {
  SequenceRuntimeSettings(this.raw);

  /// The underlying `RTS` property object — full access to every field.
  final SeqProperty raw;

  bool? _bool(String key) => _flag(raw.prop(key)?.scalar);
  String? _str(String key) => _nz(raw.prop(key)?.scalar);

  /// The expression the editor evaluates to display the entry point's name
  /// (`EPNameExpr`, e.g. `"MainSequence"`); null when unset.
  String? get entryPointNameExpression => _str('EPNameExpr');

  /// The expression that enables/disables the entry point (`EPEnabledExpr`);
  /// null when unset.
  String? get entryPointEnabledExpression => _str('EPEnabledExpr');

  /// The entry point's menu hint/category (`EPMenuHint`); null when unset.
  String? get entryPointMenuHint => _str('EPMenuHint');

  /// Whether the entry point starts hidden (`EPInitiallyHidden`). null when unset.
  bool? get entryPointInitiallyHidden => _bool('EPInitiallyHidden');

  /// Where the entry point is offered — always (`ShowEPAlways`), in the editor
  /// only (`ShowEPForEditorOnly`), in execution windows (`ShowEPForExeWin`), and
  /// in file windows (`ShowEPForFileWin`). Each null when unset.
  bool? get showEntryPointAlways => _bool('ShowEPAlways');
  bool? get showEntryPointForEditorOnly => _bool('ShowEPForEditorOnly');
  bool? get showEntryPointForExecutionWindow => _bool('ShowEPForExeWin');
  bool? get showEntryPointForFileWindow => _bool('ShowEPForFileWin');

  /// Whether the entry point may be run interactively (`AllowIntExeOfEP`). null
  /// when unset.
  bool? get allowInteractiveExecution => _bool('AllowIntExeOfEP');

  /// Whether the editor copies steps when overriding the sequence
  /// (`CopyStepsOnOverriding`). null when unset.
  bool? get copyStepsOnOverriding => _bool('CopyStepsOnOverriding');

  /// Whether the entry point prompts to save a titled file (`EPCheckToSaveTitledFile`)
  /// / ignores its client (`EPIgnoreClient`). Each null when unset.
  bool? get entryPointCheckToSaveTitledFile => _bool('EPCheckToSaveTitledFile');
  bool? get entryPointIgnoreClient => _bool('EPIgnoreClient');

  /// Whether non-reentrant calls into this sequence are optimized
  /// (`OptimizeNonReentrantCalls`). null when unset.
  bool? get optimizeNonReentrantCalls => _bool('OptimizeNonReentrantCalls');

  /// The sequence's run priority (`Priority`) as the raw stored integer; null
  /// when unset. The value is TestStand's internal priority encoding.
  int? get priorityCode => int.tryParse(raw.prop('Priority')?.scalar ?? '');

  /// The sequence run-time `Type` code; surfaced verbatim, NI-internal meaning
  /// not invented. null when unset.
  int? get typeCode => int.tryParse(raw.prop('Type')?.scalar ?? '');
}

/// A sequence variable — a local or a parameter. Locals/Parameters are property
/// containers whose sub-properties are the variables, so a variable is just a
/// property with a name, a type, and an optional default value.
class SeqVariable {
  SeqVariable(this.raw);

  /// The underlying property object — full access to the variable's details.
  final SeqProperty raw;

  String get name => raw.name;

  /// The custom type name (`typename`) if any, else the built-in value-kind
  /// (`classname`: `Num`, `Str`, `Boolean`, `Obj`, `Objs`, …). null if neither.
  String? get type => raw.typeName ?? raw.className;

  /// The variable's free-text comment — the editor's note describing what it
  /// holds (e.g. `"InfoTableRC: [row][col]"`) — or null when it has none.
  /// Recovered from the variable's `%COMMENT`. (Carried as a `%COMMENT` attribute
  /// by the INI reader; XML variables in the corpus store none.)
  String? get comment => _nz(raw.attributes['%COMMENT']);

  /// The scalar default value, or null for container/array variables and empty
  /// values.
  String? get value => (raw.scalar == null || raw.scalar!.isEmpty) ? null : raw.scalar;

  /// True for an array/object container variable (no scalar value).
  bool get isContainer => raw.isArray || raw.subProps.isNotEmpty;

  /// True when this container is an array (vs. an object/cluster). Only
  /// meaningful when [isContainer].
  bool get isArray => raw.isArray;

  /// The container's size: the number of array elements for an array, or the
  /// number of fields (sub-properties) for an object/cluster. null for a scalar
  /// variable. An array recovered with no stored elements is `0` (e.g. an empty
  /// default `ResultList`), distinct from a scalar's null.
  int? get containerCount {
    if (raw.isArray) return raw.array?.length ?? 0;
    if (raw.subProps.isNotEmpty) return raw.subProps.length;
    return null;
  }

  @override
  String toString() => 'SeqVariable($name : ${type ?? '?'}${value != null ? ' = $value' : ''})';
}

/// A single step within a sequence group.
class Step {
  Step(this.raw);

  /// The underlying property object — full access to every step property.
  final SeqProperty raw;

  /// The step's display name (its `name=` attribute).
  String get name => raw.name;

  /// The step type, e.g. `Statement`, `NI_MultipleNumericLimitTest`,
  /// `SequenceCall`, `MessagePopup`. null if untyped.
  String? get type => raw.typeName;

  /// The step's free-text comment — the editor's per-step note (e.g.
  /// `"Lock sequence"`), or null when the step has none. Recovered from the
  /// step's `%COMMENT`; long comments are reassembled from their continuation
  /// fragments. (Carried as a `%COMMENT` attribute by the INI reader; XML steps
  /// in the corpus store none, so this is null for them.)
  String? get comment => _nz(raw.attributes['%COMMENT']);

  /// The step's run-time settings (preconditions, looping, pass/fail actions),
  /// read from its `TS` (TestStand system) sub-container.
  StepSettings get settings => StepSettings(raw.prop('TS'));

  /// The code module the step invokes (its module-adapter binding), read from
  /// `TS > SData`. [StepModule.adapter] is [SeqAdapter.none] when the step has no
  /// SData.
  StepModule get module => StepModule.fromSData(raw.at(['TS', 'SData']));

  /// The structured control-flow construct this step is, when it is one of the
  /// `NI_Flow_*` step types (If/ElseIf/Else/While/For/ForEach/End/Break/Continue)
  /// — with the recovered condition / loop expressions. null for an ordinary
  /// (non-flow) step. See [FlowControl]; drives the nested logic export.
  FlowControl? get flowControl => FlowControl.fromStep(this);

  /// The test limits (pass/fail criteria) for a limit-test step, or null when
  /// this step is not a limit test (no `Comp`/`Limits`).
  StepLimits? get limits => StepLimits.fromStep(raw);

  /// The measurement units the step's result records in (`Result.Units`) — e.g.
  /// `V`, `mA`, `nS` — the unit paired with a numeric limit test's value, or
  /// null when the step records none. Stored on the step's `Result` sub-object
  /// (a sibling of `TS`), not under `Limits`.
  String? get resultUnits => _nz(raw.prop('Result')?.prop('Units')?.scalar);

  /// The step's recorded-result slot (`Result`) — its per-step outcome record
  /// (status, report text, error info), or null when the step has none. See
  /// [StepResult]; the measured-value unit is exposed separately as
  /// [resultUnits].
  StepResult? get result {
    final r = raw.prop('Result');
    return r == null ? null : StepResult(r);
  }

  /// The step's data-source expression (`DataSource`) — what the step measures
  /// or evaluates: the measured value for a numeric limit test (e.g.
  /// `Locals.A.High_Value`), or the pass/fail criterion for a `PassFailTest`
  /// (e.g. `Step.Result.PassFail`). null when the step has none. This is the same
  /// value as [StepLimits.dataSource] for a limit test, but is exposed here too
  /// so it's recovered for non-limit steps (e.g. `PassFailTest`), where there is
  /// no [StepLimits].
  String? get dataSource => _nz(raw.prop('DataSource')?.scalar);

  /// The step's unique id (`TS.Id`, e.g. `ID#:1m8fotxw7RGuNrjdh1OqZD`) — the
  /// stable handle other steps' flow-action targets reference (see
  /// [SeqFile.stepNameById], which resolves such a reference back to this step's
  /// name). null when the step records none. Opaque by design; its value is the
  /// link identity, not human-meaningful text.
  String? get id => _nz(raw.prop('TS')?.prop('Id')?.scalar);

  /// The typed formal parameters of a **measurement step** — the NI measurement
  /// adapter's `Measurement.Parameters` list (each a [MeasurementParameter]):
  /// the named, typed inputs/outputs the measurement routine takes (e.g.
  /// `voltage_level : TypeDouble In = 6`). Empty for non-measurement steps. This
  /// is distinct from [StepModule.callParameters] (the ActiveX/C and Python
  /// adapter argument lists), which a measurement step does not use.
  List<MeasurementParameter> get measurementParameters {
    final params = raw.prop('Measurement')?.prop('Parameters');
    final kids = params?.array ?? params?.subProps ?? const <SeqProperty>[];
    return [for (final p in kids) MeasurementParameter(p)];
  }

  /// The step's "Additional Results" recording spec — the extra values it logs
  /// to the report. Collected from every `AdditionalResults` container in the
  /// step's subtree (these attach to module-call parameters, e.g. a Python or
  /// C/CVI call's `Input`/`Output` directions). Each [AdditionalResult] names a
  /// recorded slot and carries its gating `Condition` expression; the
  /// `Flags`/`CheckedState` siblings are left raw (meaning not yet decoded).
  List<AdditionalResult> get additionalResults {
    final out = <AdditionalResult>[];
    void walk(SeqProperty p) {
      if (p.name == 'AdditionalResults') {
        for (final e in [...p.subProps, ...?p.array]) {
          out.add(AdditionalResult(e));
        }
        return;
      }
      for (final c in [...p.subProps, ...?p.array]) {
        walk(c);
      }
    }

    walk(raw);
    return out;
  }

  @override
  String toString() => 'Step($name : ${type ?? '?'})';
}

/// The kind of an `NI_Flow_*` control-flow step — what structured construct it
/// represents in the sequence's logic.
enum FlowKind {
  ifBlock('if'),
  elseIf('else if'),
  elseBlock('else'),
  whileLoop('while'),
  doWhile('do-while'),
  forLoop('for'),
  forEach('for each'),
  end('end'),
  breakStmt('break'),
  continueStmt('continue');

  const FlowKind(this.label);

  /// A short readable keyword (`if`, `for each`, `end`, …).
  final String label;

  /// Whether this construct opens a nested block (its body is the following
  /// steps until the matching [end]).
  bool get opensBlock =>
      this == ifBlock ||
      this == whileLoop ||
      this == doWhile ||
      this == forLoop ||
      this == forEach;

  /// Whether this construct closes a block (`NI_Flow_End`).
  bool get closesBlock => this == end;

  /// Whether this is a mid-block continuation (`else`/`else if`) — it dedents to
  /// the opener's level then re-indents, without its own [end].
  bool get isContinuation => this == elseIf || this == elseBlock;
}

/// The recovered control-flow construct of an `NI_Flow_*` step: its [kind] and
/// the condition / loop expressions TestStand stores for it. Corpus-confirmed
/// field locations (100% populated where applicable):
/// `If`/`Else If`/`While` → `ConditionExpr`; `For` →
/// `InitializationExpr`/`ConditionExpr`/`IncrementExpr`; `For Each` →
/// `ArrayExpr`/`ArrayElementExpr`/`OffsetExpr`. These are clean expression
/// strings — the sequence's actual control logic — drawn straight from the step.
class FlowControl {
  FlowControl._(this.kind, this._node);

  /// The control-flow kind.
  final FlowKind kind;

  /// The step's property tree — the construct's expression fields
  /// (`ConditionExpr`, `InitializationExpr`, …) live as direct children here.
  final SeqProperty? _node;

  /// Builds the [FlowControl] for [step], or null when it is not an `NI_Flow_*`
  /// step. The construct's expression fields are flat direct children of the
  /// step (`ConditionExpr` for if/else-if/while; `InitializationExpr`/
  /// `ConditionExpr`/`IncrementExpr` for for; `ArrayExpr`/`ArrayElementExpr` for
  /// for-each) — verified across the corpus (100% populated where applicable).
  static FlowControl? fromStep(Step step) {
    final kind = switch (step.type) {
      'NI_Flow_If' => FlowKind.ifBlock,
      'NI_Flow_ElseIf' => FlowKind.elseIf,
      'NI_Flow_Else' => FlowKind.elseBlock,
      'NI_Flow_While' => FlowKind.whileLoop,
      'NI_Flow_DoWhile' => FlowKind.doWhile,
      'NI_Flow_For' => FlowKind.forLoop,
      'NI_Flow_ForEach' => FlowKind.forEach,
      'NI_Flow_End' => FlowKind.end,
      'NI_Flow_Break' || 'NI_Flow_Break_Custom' => FlowKind.breakStmt,
      'NI_Flow_Continue' => FlowKind.continueStmt,
      _ => null,
    };
    if (kind == null) return null;
    return FlowControl._(kind, step.raw);
  }

  /// The branch/loop condition (`ConditionExpr`) — for `if`/`else if`/`while`/
  /// `do-while`; null otherwise.
  String? get condition => _nz(_node?.prop('ConditionExpr')?.scalar);

  /// The `for` loop's initialization expression (`InitializationExpr`).
  String? get initialization => _nz(_node?.prop('InitializationExpr')?.scalar);

  /// The `for` loop's increment expression (`IncrementExpr`).
  String? get increment => _nz(_node?.prop('IncrementExpr')?.scalar);

  /// The `for each` array expression (`ArrayExpr`) — the collection iterated.
  String? get arrayExpr => _nz(_node?.prop('ArrayExpr')?.scalar);

  /// The `for each` element expression (`ArrayElementExpr`) — the loop variable.
  String? get arrayElement => _nz(_node?.prop('ArrayElementExpr')?.scalar);

  /// A readable one-line header for the construct, e.g. `if (Locals.x > 0)`,
  /// `for (Locals.i = 0; Locals.i < N; Locals.i += 1)`,
  /// `for each (Locals.e in RunState.…)`, `while (True)`, `end`.
  String get header => switch (kind) {
    FlowKind.ifBlock => 'if (${condition ?? ''})',
    FlowKind.elseIf => 'else if (${condition ?? ''})',
    FlowKind.elseBlock => 'else',
    FlowKind.whileLoop => 'while (${condition ?? ''})',
    FlowKind.doWhile => 'do-while (${condition ?? ''})',
    FlowKind.forLoop => 'for (${[
        initialization,
        condition,
        increment,
      ].whereType<String>().join('; ')})',
    FlowKind.forEach =>
      'for each (${arrayElement ?? '?'} in ${arrayExpr ?? '?'})',
    FlowKind.end => 'end',
    FlowKind.breakStmt => 'break',
    FlowKind.continueStmt => 'continue',
  };

  @override
  String toString() => 'FlowControl(${kind.name})';
}

/// One entry in a step's "Additional Results" recording spec (see
/// [Step.additionalResults]): a value the step logs to the report. The entry's
/// [name] identifies the recorded slot — for a module-call parameter result it
/// is the parameter direction (`Input`/`Output`); its `classname` (e.g.
/// `PythonParameterResult`, `CommonCParameterResult`) says which adapter it came
/// from. [condition] is the gating expression under which the value is recorded
/// (an `ExprValue`; null/empty means always recorded — the only case seen in the
/// corpus so far). The sibling `Flags`/`CheckedState` numbers are not yet decoded
/// and are deliberately not surfaced here.
class AdditionalResult {
  AdditionalResult(this.raw);

  /// The underlying entry property — full access including the not-yet-decoded
  /// `Flags`/`CheckedState`.
  final SeqProperty raw;

  /// The recorded slot's name, e.g. `Input` / `Output`.
  String get name => raw.name;

  /// The entry's class (`PythonParameterResult`, `CommonCParameterResult`, …),
  /// or null when absent.
  String? get kind => _nz(raw.attributes['classname']);

  /// The gating `Condition` expression (an `ExprValue`); null when the entry has
  /// no condition or an empty one (record unconditionally).
  String? get condition => _nz(raw.prop('Condition')?.scalar);
}

/// One formal parameter of a **measurement step** (an NI measurement adapter's
/// `Measurement.Parameters` entry) — a named, typed input/output the step's
/// measurement routine takes. Every field is self-describing in the corpus:
/// [name] (`voltage_level`), [dataType] (the TestStand type token `TypeDouble` /
/// `TypeString` / `TypeEnum` / `TypeInt32` / `TypeBool` / `TypeUint32` /
/// `TypeUint64`), [direction] (`In` / `Out`), [isArray] from `Dimension`
/// (`0` = scalar, ≥1 = array), and [value] the bound `ArgumentValue` expression
/// (null when unbound). The sibling `ID` / `Log` / `TypeSpecialization` /
/// `MessageType` / `EnumDefinition` are left raw (not surfaced with meaning).
class MeasurementParameter {
  MeasurementParameter(this.raw);

  /// The underlying parameter property object — full access to every field.
  final SeqProperty raw;

  /// The parameter name (`Name`), e.g. `voltage_level`.
  String get name => _nz(raw.prop('Name')?.scalar) ?? raw.name;

  /// The TestStand data-type token (`Type`), e.g. `TypeDouble`; null if absent.
  String? get dataType => _nz(raw.prop('Type')?.scalar);

  /// The parameter direction (`Direction`) — `In` / `Out`; null if absent.
  String? get direction => _nz(raw.prop('Direction')?.scalar);

  /// The bound value expression (`ArgumentValue`, e.g. `6`), or null when unbound.
  String? get value => _nz(raw.prop('ArgumentValue')?.scalar);

  /// Whether the parameter is an array — `Dimension` ≥ 1 (0 = scalar).
  bool get isArray {
    final d = int.tryParse(raw.prop('Dimension')?.scalar ?? '');
    return d != null && d > 0;
  }

  /// A refinement of [dataType] (`TypeSpecialization`) — `IOResource`, `Path`,
  /// `Pin`, or `Enum`: e.g. a `TypeString` parameter that is actually an
  /// instrument I/O resource, a file path, or a pin reference. null for an
  /// unspecialized parameter (`None`, the common case).
  String? get typeSpecialization {
    final s = _nz(raw.prop('TypeSpecialization')?.scalar);
    return (s == null || s == 'None') ? null : s;
  }

  /// Whether this parameter's value is recorded to the report (`Log`). True for
  /// most parameters; false for those explicitly excluded from logging. null
  /// when the parameter records no `Log` flag.
  bool? get logged => switch (raw.prop('Log')?.scalar) {
        'true' || '1' => true,
        'false' || '0' => false,
        _ => null,
      };

  /// For a [dataType] of `TypeEnum`, the enum's allowed values as `(name, value)`
  /// pairs — each `EnumDefinition` element is a named constant (e.g. `DC_VOLTS`)
  /// whose scalar is its integer code (e.g. `1`). Empty for a non-enum parameter
  /// (or an enum whose definition is absent).
  List<({String name, String? value})> get enumValues {
    final elems = raw.prop('EnumDefinition')?.array ?? const <SeqProperty>[];
    return [for (final e in elems) (name: e.name, value: _nz(e.scalar))];
  }

  /// The parameter's message-type token (`MessageType`) — the measurement
  /// plug-in's classification of the parameter; null when unset (empty in the
  /// current corpus, where the field is present but blank on most parameters).
  String? get messageType => _nz(raw.prop('MessageType')?.scalar);
}

/// A step's recorded-result slot (`Result`) — the per-step outcome record. In a
/// sequence *file* (an un-run step) these carry their compile-time defaults:
/// [status]/[reportText] empty, [errorOccurred] false, [errorCode] `0`. The lens
/// surfaces them for completeness; real values appear once a run is recorded.
/// (The measured value's unit is exposed separately as [Step.resultUnits], and a
/// limit test's numeric result rides [StepLimits].)
class StepResult {
  StepResult(this.raw);

  /// The underlying `Result` property object — full access to every field.
  final SeqProperty raw;

  /// The recorded run status (`Status`), e.g. `Passed`/`Failed`/`Done`; null
  /// when unset (an un-run step in a file).
  String? get status => _nz(raw.prop('Status')?.scalar);

  /// The report text the step contributed (`ReportText`); null when unset.
  String? get reportText => _nz(raw.prop('ReportText')?.scalar);

  SeqProperty? get _error => raw.prop('Error');

  /// The recorded error code (`Error.Code`); null when unset. `0` is the
  /// no-error default.
  String? get errorCode => _nz(_error?.prop('Code')?.scalar);

  /// The recorded error message (`Error.Msg`); null when unset/empty.
  String? get errorMessage => _nz(_error?.prop('Msg')?.scalar);

  /// Whether an error was recorded (`Error.Occurred`); null when the step has no
  /// `Error` slot. `false` is the default.
  bool? get errorOccurred => switch (_error?.prop('Occurred')?.scalar) {
        'true' || '1' => true,
        'false' || '0' => false,
        _ => null,
      };

  /// Whether this result holds any non-default value — true once a real run is
  /// recorded (status/report text set, or an error occurred). false for the
  /// compile-time default state seen in a sequence file.
  bool get hasRecordedOutcome =>
      status != null || reportText != null || errorOccurred == true;
}

String? _nz(String? s) => (s == null || s.isEmpty) ? null : s;

/// Parses a TestStand boolean stored either as `true`/`false` (XML, any case) or
/// `1`/`0` (some numeric flags). null when absent or unrecognized.
bool? _flag(String? s) => switch (s?.toLowerCase()) {
      'true' || '1' => true,
      'false' || '0' => false,
      _ => null,
    };

/// Unwraps a TestStand string-literal expression for display: strips one layer of
/// surrounding quotes, whether backslash-escaped (`\"…\"`, as the INI form stores
/// a quoted target after its own outer quotes are removed) or plain (`"…"`).
/// Returns the input unchanged when it is not a wrapped string literal, and null
/// for null. Used for flow-action targets like `\"<Cleanup>\"` → `<Cleanup>`.
String? _unwrapExprString(String? s) {
  if (s == null) return null;
  final t = s.trim();
  if (t.length >= 4 && t.startsWith(r'\"') && t.endsWith(r'\"')) {
    return t.substring(2, t.length - 2);
  }
  if (t.length >= 2 && t.startsWith('"') && t.endsWith('"')) {
    return t.substring(1, t.length - 1);
  }
  return t;
}

/// A limit-test step's pass/fail criteria: the comparison operator and the
/// numeric limits, read from the step's `Comp` + `Limits` + `DataSource`
/// properties. Fields are null when absent/empty. The measurement **units** are
/// recorded separately, on the step's `Result` sub-object — see
/// [Step.resultUnits] — not under `Limits`. Comparison codes seen: `GELE`
/// (low ≤ x ≤ high); others include `EQ`/`NE`/`LT`/`LE`/`GT`/`GE`/`GTLT`/`LTGT`.
class StepLimits {
  StepLimits({
    this.comparison,
    this.low,
    this.high,
    this.nominal,
    this.thresholdType,
    this.dataSource,
    this.raw,
  });

  /// The comparison operator (`Comp`), e.g. `GELE`.
  final String? comparison;

  /// Lower / upper / nominal limit values (`Limits.Low/High/Nominal`).
  final String? low;
  final String? high;
  final String? nominal;

  /// How limits are interpreted (`Limits.ThresholdType`), e.g. `PERCENTAGE`.
  final String? thresholdType;

  /// The measured value expression being tested (`DataSource`).
  final String? dataSource;

  /// The raw `Limits` property for full access; null if the step had none.
  final SeqProperty? raw;

  /// Whether the step carries any limit information.
  static StepLimits? fromStep(SeqProperty step) {
    final comp = _nz(step.prop('Comp')?.scalar);
    final lim = step.prop('Limits');
    if (comp == null && lim == null) return null;
    return StepLimits(
      comparison: comp,
      low: _nz(lim?.prop('Low')?.scalar),
      high: _nz(lim?.prop('High')?.scalar),
      nominal: _nz(lim?.prop('Nominal')?.scalar),
      thresholdType: _nz(lim?.prop('ThresholdType')?.scalar),
      dataSource: _nz(step.prop('DataSource')?.scalar),
      raw: lim,
    );
  }

  /// A short readable summary, e.g. `GELE [9, 11]`.
  String get summary {
    final range = '[${low ?? '?'}, ${high ?? '?'}]';
    return '${comparison ?? '?'} $range';
  }

  @override
  String toString() => 'StepLimits($summary)';
}

/// The module-adapter kinds observed in the corpus — the bridge from a step to
/// the code it runs. Only kinds seen in real files are modeled (honesty); others
/// (e.g. .NET, HTBasic) surface as [unknown] until a sample is decoded.
enum SeqAdapter {
  /// LabVIEW VI adapter (`ViCall`/`VICall`) — calls a `.vi`. Older TestStand
  /// (e.g. versions 127/143) instead stores the VI path as a direct `ViPath`
  /// member of `SData` (alongside `PassInBuf`/`PassInvocInfo`), not nested under
  /// a `ViCall` sub-object.
  labView,

  /// C/CVI / DLL adapter (`Call`/`ExternalCall`) — calls a function in a DLL or
  /// a source module.
  cModule,

  /// Python adapter (`PythonCall`/`CPythonCall`). Recognized; its target fields
  /// are not yet decoded.
  python,

  /// Sequence Call (`SeqName`/`SFPath`) — calls another sequence.
  sequenceCall,

  /// The step carries no code module — either no `SData` at all, or an empty
  /// `SData` container (e.g. a flow-control step like `NI_Flow_If`/`NI_Flow_End`,
  /// a `Statement`, `Label`, `NI_Wait`/`NI_Lock`). Across the INI corpus every
  /// empty-`SData` step is one of these no-module types, so an empty `SData`
  /// (often inherited as a bare default from the step's type) means "no adapter",
  /// not "an adapter we failed to read".
  none,

  /// `SData` is present with members, but its adapter record is not yet
  /// recognized (e.g. .NET/HTBasic/an NI plug-in shape not yet decoded). No such
  /// step exists in the current corpus — reserved for shapes we have not seen.
  unknown;
}

/// A step's code-module binding: which adapter and what it targets. Fields are
/// null when absent/empty or not yet decoded — never fabricated.
class StepModule {
  StepModule({
    required this.adapter,
    this.target,
    this.viPath,
    this.libPath,
    this.function,
    this.sequenceName,
    this.sequenceFile,
    this.raw,
  });

  final SeqAdapter adapter;

  /// A best-effort human-readable target (VI path, `dll:function`, sequence
  /// name), or null when not yet recovered.
  final String? target;

  /// LabVIEW VI path ([SeqAdapter.labView]).
  final String? viPath;

  /// DLL/source path and function name ([SeqAdapter.cModule]).
  final String? libPath;
  final String? function;

  /// Called sequence name and file ([SeqAdapter.sequenceCall]).
  final String? sequenceName;
  final String? sequenceFile;

  /// The raw `SData` property for full access; null when the step had none.
  final SeqProperty? raw;

  /// The arguments this step's code-module call binds, in declaration order —
  /// the editor's "Module > Parameters" rows. Recovered from the adapter's
  /// `Parameters` list: `SData.Call.Parameters` (the ActiveX/C-module adapter)
  /// or `SData.PythonCall.Parameters` (the Python adapter). The two store a
  /// parameter's bound value under different keys (`ArgVal` vs `ArgumentValue`);
  /// [CallParameter] reads either. Empty when the call passes none, or when an
  /// adapter stores its arguments elsewhere (not yet decoded for other adapters).
  List<CallParameter> get callParameters {
    final params =
        raw?.prop('Call')?.prop('Parameters') ??
        raw?.prop('PythonCall')?.prop('Parameters');
    if (params == null) return const [];
    final kids = params.array ?? params.subProps;
    return [for (final p in kids) CallParameter(p)];
  }

  SeqProperty? get _viCall => raw?.prop('ViCall');

  /// The LabVIEW library namespace that owns the called VI (`ViCall.Namespace`),
  /// e.g. `NIDCPowerSourceDCVoltage.lvlib` — the `.lvlib`/`.lvclass` the VI lives
  /// in. null for a non-LabVIEW step or when not set.
  String? get viNamespace => _nz(_viCall?.prop('Namespace')?.scalar);

  /// The LabVIEW project the VI call resolves through (`ViCall.ProjectPath`),
  /// e.g. `NIDCPowerSourceDCVoltage.lvproj`. null when absent.
  String? get viProjectPath => _nz(_viCall?.prop('ProjectPath')?.scalar);

  /// An explicit call-name override the editor shows for the VI call
  /// (`ViCall.CallName`); null when the VI's own name is used.
  String? get viCallName => _nz(_viCall?.prop('CallName')?.scalar);

  /// The called VI's documented description (`ViCall.VIDescription`); null when
  /// the VI carries none.
  String? get viDescription => _nz(_viCall?.prop('VIDescription')?.scalar);

  /// Whether the call is configured to show the VI's front panel at run time
  /// (`ViCall.ShowFrnPnl`). false when absent.
  bool get showsFrontPanel => _viCall?.prop('ShowFrnPnl')?.scalar == 'true';

  /// The LabVIEW VI call's connector-pane parameters (`ViCall.Parms`), in
  /// declaration order — the terminals wired to the subVI. Each [CallParameter]
  /// exposes its label, display type, bound expression and connector index. The
  /// numeric type codes (`Type`/`NumType`/`ArrayType`/`ClusterType`) are left
  /// raw on [CallParameter.raw] (not yet decoded). Empty for a non-LabVIEW step
  /// or a VI call that wires nothing.
  List<CallParameter> get viParameters {
    final parms = _viCall?.prop('Parms');
    if (parms == null) return const [];
    final kids = parms.array ?? parms.subProps;
    return [for (final p in kids) CallParameter(p)];
  }

  SeqProperty? get _pyCall => raw?.prop('PythonCall');

  /// The Python function or attribute this step invokes
  /// (`PythonCall.FunctionOrAttributeName`), e.g. `create_instrument_sessions`.
  /// null for a non-Python step or when not set.
  String? get pythonFunction => _nz(_pyCall?.prop('FunctionOrAttributeName')?.scalar);

  /// The Python module file the call loads (`PythonCall.ModulePath`), e.g.
  /// `..\measurements\source_measure_dc_voltage_fal\test.py`. null when absent.
  String? get pythonModulePath => _nz(_pyCall?.prop('ModulePath')?.scalar);

  /// The Python class that owns [pythonFunction] (`PythonCall.ClassName`), when
  /// the call targets a class method; null for a module-level function.
  String? get pythonClassName => _nz(_pyCall?.prop('ClassName')?.scalar);

  /// The Python version the adapter runs the module under
  /// (`PythonCall.PythonVersion`), e.g. `3.9`. null when absent.
  String? get pythonVersion => _nz(_pyCall?.prop('PythonVersion')?.scalar);

  /// The virtual-environment the call resolves its interpreter from
  /// (`PythonCall.PythonVirtualEnvironmentPath`); null when none is configured.
  String? get pythonVenvPath =>
      _nz(_pyCall?.prop('PythonVirtualEnvironmentPath')?.scalar);

  /// The on-disk source file backing the step's code module (`SData.ModuleSrcPath`,
  /// e.g. `numericTests.c`, `64BitSupport\64BitSupport.cpp`) — the C/C++ source
  /// the DLL was built from, where the editor records it. null when absent (the
  /// adapter records the *built* module elsewhere, e.g. [libPath]).
  String? get moduleSourcePath => _nz(raw?.prop('ModuleSrcPath')?.scalar);

  /// The project/solution file the code module builds from (`SData.ModulePrjPath`,
  /// e.g. `64BitSupport\64BitSupport.vcproj`); null when absent.
  String? get moduleProjectPath => _nz(raw?.prop('ModulePrjPath')?.scalar);

  /// The source-creation-type code (`SData.ModuleCreateSrcType`) recording how the
  /// module's source was created/linked. Verbatim; the NI-internal code→name
  /// mapping is not invented. null when absent.
  int? get moduleSourceTypeCode =>
      int.tryParse(_nz(raw?.prop('ModuleCreateSrcType')?.scalar) ?? '');

  static String? _e(String? s) => (s == null || s.isEmpty) ? null : s;

  factory StepModule.fromSData(SeqProperty? sdata) {
    if (sdata == null || sdata.subProps.isEmpty) {
      return StepModule(adapter: SeqAdapter.none);
    }

    final vi = sdata.prop('ViCall');
    if (vi != null) {
      final p = _e(vi.prop('VIPath')?.scalar);
      return StepModule(adapter: SeqAdapter.labView, viPath: p, target: p, raw: sdata);
    }

    final directVi = _e(sdata.prop('ViPath')?.scalar);
    if (directVi != null) {
      return StepModule(
          adapter: SeqAdapter.labView, viPath: directVi, target: directVi, raw: sdata);
    }

    final call = sdata.prop('Call');
    if (call != null) {
      final lib = _e(call.prop('LibPath')?.scalar);
      final fn = _e(call.prop('Func')?.scalar);
      final target = lib == null ? fn : (fn == null ? lib : '$lib:$fn');
      return StepModule(
        adapter: SeqAdapter.cModule,
        libPath: lib,
        function: fn,
        target: target,
        raw: sdata,
      );
    }

    final py = sdata.prop('PythonCall');
    if (py != null) {
      final fn = _e(py.prop('FunctionOrAttributeName')?.scalar);
      final cls = _e(py.prop('ClassName')?.scalar);
      final callee = fn == null ? null : (cls != null ? '$cls.$fn' : fn);
      return StepModule(adapter: SeqAdapter.python, target: callee, raw: sdata);
    }

    if (sdata.prop('SeqName') != null || sdata.prop('SFPath') != null) {
      final sn = _e(sdata.prop('SeqName')?.scalar);
      final sf = _e(sdata.prop('SFPath')?.scalar);
      return StepModule(
        adapter: SeqAdapter.sequenceCall,
        sequenceName: sn,
        sequenceFile: sf,
        target: sn ?? sf,
        raw: sdata,
      );
    }

    return StepModule(adapter: SeqAdapter.unknown, raw: sdata);
  }

  @override
  String toString() => 'StepModule(${adapter.name}${target != null ? ': $target' : ''})';
}

/// A single argument a step's code-module call binds — one "Module >
/// Parameters" row in the Sequence Editor: a parameter [name], the
/// [boundExpression] supplying its value, the declared [displayType], and the
/// [direction] (in/out). Read from a `Call.Parameters[n]` property object.
class CallParameter {
  CallParameter(this.raw);

  /// The underlying parameter property object — full access to its details.
  final SeqProperty raw;

  /// The parameter's name, e.g. `LoginName`, `Return Value`, `sequence context`.
  /// The ActiveX/C `Parameters` and Python `Parameters` adapters store it as
  /// `Name`; the LabVIEW VI-call connector list (`ViCall.Parms`) stores it as
  /// `Label`. Either is read, falling back to the element name.
  String get name =>
      _nz(raw.prop('Name')?.scalar) ?? _nz(raw.prop('Label')?.scalar) ?? raw.name;

  /// The connector-pane terminal index this parameter wires to
  /// (`ConnectorNumber`), for a LabVIEW VI call (`ViCall.Parms`); null when
  /// absent (the non-LabVIEW adapters don't store a connector index).
  int? get connectorNumber {
    final s = _nz(raw.prop('ConnectorNumber')?.scalar);
    return s == null ? null : int.tryParse(s);
  }

  /// The expression bound to the parameter — what the call passes, e.g.
  /// `Locals.userToLogin`, `ThisContext`,
  /// `FileGlobals.MeasurementPlugIns.PinMapPath` — or null when the call leaves
  /// it unbound. Stored as `ArgVal` by the ActiveX/C adapter and as
  /// `ArgumentValue` by the Python adapter; either is read.
  String? get boundExpression =>
      _nz(raw.prop('ArgVal')?.scalar) ?? _nz(raw.prop('ArgumentValue')?.scalar);

  /// The human-readable parameter type the editor shows (`DisplayType`), e.g.
  /// `String`, `User (Object Reference)`; null when absent.
  String? get displayType => _nz(raw.prop('DisplayType')?.scalar);

  /// The raw `Direction` code exactly as stored (`1`, `2`, `3`, …), or null
  /// when absent. Exposed alongside [direction] so an unrecognized code is left
  /// readable rather than dropped.
  String? get directionCode => _nz(raw.prop('Direction')?.scalar);

  /// A readable parameter direction — `in` (`1`), `out` (`2`), `in/out` (`3`) —
  /// mapped from [directionCode] using the standard TestStand parameter
  /// directions (consistent across the corpus: a `Return Value` reads `2`,
  /// supplied inputs read `1`). null for an absent or unrecognized code, which
  /// stays available raw in [directionCode] rather than being guessed.
  String? get direction => switch (directionCode) {
        '1' => 'in',
        '2' => 'out',
        '3' => 'in/out',
        _ => null,
      };

  int? _int(String key) => int.tryParse(_nz(raw.prop(key)?.scalar) ?? '');

  /// The editor's display rendering of the bound value (`ArgDisplayVal`, the
  /// ActiveX/C adapter; `ArgumentDisplayValue`, the Python adapter) — the
  /// formatted form shown next to the parameter, distinct from the live
  /// [boundExpression]. null when absent.
  String? get displayValue =>
      _nz(raw.prop('ArgDisplayVal')?.scalar) ??
      _nz(raw.prop('ArgumentDisplayValue')?.scalar);

  /// The parameter's TestStand data-type code (`Type`) — the broad kind of the
  /// C/LabVIEW connector value. Surfaced verbatim; the code→name mapping is
  /// NI-internal and not invented. null when absent.
  int? get typeCode => _int('Type');

  /// Sub-type codes refining [typeCode] for a C-module / VI-call connector: the
  /// numeric-format code (`NumType`), the object/reference-type code (`ObjType`),
  /// and the struct/cluster-type code (`StructType`). Each verbatim; null when
  /// absent. Their NI-internal meanings are not invented.
  int? get numberTypeCode => _int('NumType');
  int? get objectTypeCode => _int('ObjType');
  int? get structTypeCode => _int('StructType');

  /// The parameter descriptor's flags word (`Flags`) — a packed bit set of
  /// per-parameter options. Surfaced verbatim as an integer; the individual bit
  /// meanings are NI-internal and not decoded here. null when absent.
  int? get flagsCode => _int('Flags');

  /// The number of elements (`NumEls`) for an array parameter; null when absent
  /// (a scalar parameter records none).
  int? get elementCount => _int('NumEls');

  /// The parameter's result-action code (`ResultAct`) — how the call's value for
  /// this parameter feeds the step result. Verbatim; null when absent.
  int? get resultActionCode => _int('ResultAct');

  /// The parameter's "additional results" recording spec (`AdditionalResults`),
  /// with `Input`/`Output` sub-objects, or null when the parameter records none.
  /// Surfaced as raw structure; the per-side `Flags`/`CheckedState` codes are
  /// NI-internal and not decoded.
  SeqProperty? get additionalResults => raw.prop('AdditionalResults');

  @override
  String toString() =>
      'CallParameter($name${boundExpression != null ? ' ← $boundExpression' : ''})';
}

/// The step settings the Sequence Editor surfaces — flow control and the
/// pre/post expressions — read from a step's `TS` sub-container. Every getter is
/// null when the underlying property is absent or empty (no fabricated default),
/// so "not set" is honestly distinguishable from a real value.
class StepSettings {
  StepSettings(this._ts);

  /// The `TS` property object, or null if the step has none.
  final SeqProperty? _ts;

  String? _scalar(String key) {
    final s = _ts?.prop(key)?.scalar;
    return (s == null || s.isEmpty) ? null : s;
  }

  /// The run mode (`Mode`): `Normal`, `Skip`, `Pass`, `Fail`, … — how the step
  /// executes (Skip/force-pass/force-fail are editor-visible overrides).
  String? get mode => _scalar('Mode');

  /// True unless the step is forced to a non-normal run mode.
  bool get isNormalMode => mode == null || mode == 'Normal';

  /// The module load timing (`LoadOpt`), e.g. `PreloadWhenExecuted` (the common
  /// default), `DynamicLoad`.
  String? get loadOption => _scalar('LoadOpt');

  /// The module unload timing (`UnloadOpt`), e.g. `UnloadWithFile` (the common
  /// default), `UnloadAfterStepExecution`, `UnloadAfterSequenceExecution`. The
  /// symmetric counterpart to [loadOption].
  String? get unloadOption => _scalar('UnloadOpt');

  /// The step's editor icon (`TS.Icon`), as a readable basename without its
  /// folder or `.ico` extension (e.g. `NI_While`, `Measurement`, `MsgBox`), or
  /// null when the step uses the default blank icon (`ni_blank`) or has none.
  /// This is the glyph TestStand shows beside the step in the editor.
  String? get icon {
    var name = _scalar('Icon');
    if (name == null) return null;
    final slash = name.lastIndexOf(RegExp(r'[\\/]'));
    if (slash >= 0) name = name.substring(slash + 1);
    if (name.toLowerCase().endsWith('.ico')) {
      name = name.substring(0, name.length - 4);
    }
    return (name.isEmpty || name.toLowerCase() == 'ni_blank') ? null : name;
  }

  /// The precondition expression (`PreCond`); null when the step runs
  /// unconditionally.
  String? get precondition => _scalar('PreCond');

  /// The looping mode (`LoopType`), e.g. `NoLooping`, `FixedNumLoops`,
  /// `WhileBreak`, `PassFailCount`. null if unspecified.
  String? get loopType => _scalar('LoopType');

  /// The loop expressions a looping step runs. TestStand loops are
  /// expression-driven: [loopInitialize] sets up the loop (`LoopInitialize`,
  /// e.g. `RunState.LoopIndex = 0`), [loopWhile] is the continue condition
  /// (`LoopWhile`), [loopIncrement] advances each pass (`LoopIncrement`), and
  /// [loopStatus] computes the loop's overall status (`LoopStatus`). Each is null
  /// when absent — non-looping steps have none.
  String? get loopInitialize => _scalar('LoopInitialize');
  String? get loopWhile => _scalar('LoopWhile');
  String? get loopIncrement => _scalar('LoopIncrement');
  String? get loopStatus => _scalar('LoopStatus');

  /// True when the step loops (any `LoopType` other than `NoLooping`).
  bool get isLooping => loopType != null && loopType != 'NoLooping';

  /// The on-pass flow action (`PassAct`), e.g. `Next`, `Goto`. null if unset.
  String? get passAction => _scalar('PassAct');

  /// The on-fail flow action (`FailAct`). null if unset.
  String? get failAction => _scalar('FailAct');

  /// The pass-action jump target (`PassActTarget`), e.g. the bookmark
  /// `<Cleanup>` or a step reference `ID#:…`, for a non-`Next` [passAction];
  /// null when the action just falls through. The stored value is a TestStand
  /// expression (a quoted string literal); the surrounding quotes are unwrapped
  /// for display.
  String? get passActionTarget => _flowTarget('PassActTarget');

  /// The fail-action jump target (`FailActTarget`); see [passActionTarget].
  String? get failActionTarget => _flowTarget('FailActTarget');

  /// The custom-condition jump targets (`CustTrueActTarget` /
  /// `CustFalseActTarget`) of a step with a custom pass/fail condition, or null
  /// when unset. Stored like the other targets — a bookmark (`<Cleanup>`) or a
  /// step reference (`ID#:…`), the latter resolvable via [SeqFile.stepNameForId].
  String? get customTrueTarget => _flowTarget('CustTrueActTarget');
  String? get customFalseTarget => _flowTarget('CustFalseActTarget');

  /// The custom-condition expression (`CustExpr`) a step evaluates to choose
  /// between its true/false branches — the counterpart to [precondition] for a
  /// step with a *custom* condition. null when the step uses no custom condition.
  String? get customExpression => _scalar('CustExpr');

  /// The action taken when [customExpression] is true / false (`CustTrueAct` /
  /// `CustFalseAct`), e.g. `Next`, `GotoStep` — the same action vocabulary as
  /// [passAction]/[failAction]. Their jump targets are [customTrueTarget] /
  /// [customFalseTarget]. null when unset.
  String? get customTrueAction => _scalar('CustTrueAct');
  String? get customFalseAction => _scalar('CustFalseAct');

  String? _flowTarget(String key) => _nz(_unwrapExprString(_scalar(key)));

  /// Parses a TS boolean step-setting: stored either as `true`/`false` or `1`/`0`.
  /// null when the key is absent or unrecognized.
  bool? _bool(String key) => switch (_scalar(key)) {
        'true' || '1' => true,
        'false' || '0' => false,
        _ => null,
      };

  /// Whether this step's failure fails the whole sequence (`StepFCSeqF` — "step
  /// failure causes sequence failure"). null when the step records no value.
  bool? get failureCausesSequenceFailure => _bool('StepFCSeqF');

  /// Whether the step ignores run-time errors (`IgnoreRTE`) instead of letting
  /// them abort execution. null when unset.
  bool? get ignoresRunTimeErrors => _bool('IgnoreRTE');

  /// Whether the step records its result into the report/`ResultList`
  /// (`ResultOption`, stored `1`/`0`). null when unset. (The flag is the step's
  /// "record results" toggle; `1` is the enabled/record state in the corpus.)
  bool? get recordsResult => _bool('ResultOption');

  /// A compact flow-action summary `pass[→target]/fail[→target]` (e.g.
  /// `Next/Goto→<Cleanup>`), or null when neither action is set. The `→target`
  /// suffix is added only for a non-`Next` action that carries a jump target.
  String? get flowSummary {
    if (passAction == null && failAction == null) return null;
    String side(String? act, String? target) {
      final a = act ?? '?';
      return (a != 'Next' && target != null) ? '$a→$target' : a;
    }

    return '${side(passAction, passActionTarget)}/'
        '${side(failAction, failActionTarget)}';
  }

  /// Pre-/post-/status expressions evaluated around the step, if any.
  String? get preExpression => _scalar('PreExpr');
  String? get postExpression => _scalar('PostExpr');
  String? get statusExpression => _scalar('StatusExpr');

  /// Whether the step acquires a mutex for synchronization (`UseMutex`) — the
  /// editor's "Synchronization > use a mutex" setting that serializes a shared
  /// resource across threads/executions. null when unset; `false` is the default
  /// (no mutex), the only value in the current corpus.
  bool? get usesMutex => _bool('UseMutex');

  /// The mutex name or reference expression the step locks (`MutexNameOrRef`),
  /// paired with [usesMutex]; null when no mutex is configured (empty in the
  /// current corpus, since no step uses one).
  String? get mutexName => _scalar('MutexNameOrRef');

  /// Parses an integer TS step-setting (an option *code*). null when absent or
  /// non-numeric. TestStand stores many enumerated step options as small
  /// integers; the code is surfaced verbatim — its `name` is NI-internal and is
  /// not invented here (see the per-accessor docs for the option each selects).
  int? _int(String key) => int.tryParse(_scalar(key) ?? '');

  // --- Edit-permission flags (what a sequence editor may change on the step) ---

  /// Whether the step type permits editing the step's code module
  /// (`CanEditCode`). null when unset. Part of TestStand's step-type permission
  /// set — `true` for ordinary steps.
  bool? get canEditCode => _bool('CanEditCode');

  /// Whether the step's module *prototype* (its parameter list) may be edited
  /// (`CanEditModulePrototype`). null when unset.
  bool? get canEditModulePrototype => _bool('CanEditModulePrototype');

  /// Whether the user may (re)specify which code module the step calls
  /// (`CanSpecifyModule`). null when unset; `false` for steps whose module is
  /// fixed by their type.
  bool? get canSpecifyModule => _bool('CanSpecifyModule');

  /// Whether the step's parameter "additional results" recording may be edited
  /// (`CanEditParameterAdditionalResults`). null when unset.
  bool? get canEditParameterAdditionalResults =>
      _bool('CanEditParameterAdditionalResults');

  // --- Switch/IVI settings (the editor's "Switching" step tab) ---

  /// Whether IVI switching is enabled for the step (`SwitchEnabled`) — the
  /// "use switching" toggle. null when unset; `false` is the common default.
  bool? get switchEnabled => _bool('SwitchEnabled');

  /// The switch operation code (`SwitchOperation`) selecting connect/disconnect/
  /// disconnect-all behaviour around the step. null when unset; raw NI code.
  int? get switchOperationCode => _int('SwitchOperation');

  /// The multi-connect mode code (`MulticonnectMode`) governing whether multiple
  /// connections may coexist on a route. null when unset; raw NI code.
  int? get multiconnectModeCode => _int('MulticonnectMode');

  /// The connect/disconnect ordering code (`OperationOrder`) — when switching
  /// happens relative to the step. null when unset; raw NI code.
  int? get switchOperationOrderCode => _int('OperationOrder');

  /// The connection-lifetime code (`ConnectionLifetime`) — how long a switch
  /// connection persists (step / sequence / …). null when unset; raw NI code.
  int? get connectionLifetimeCode => _int('ConnectionLifetime');

  /// Whether the step waits for switch debounce before proceeding
  /// (`WaitForDebounce`). null when unset.
  bool? get waitForDebounce => _bool('WaitForDebounce');

  /// The IVI virtual device name the switching targets (`VirtualDeviceName`);
  /// null when switching is unused/empty. A name or TestStand expression.
  String? get virtualDeviceName => _scalar('VirtualDeviceName');

  /// The route group to connect / disconnect for the step (`RouteGroupConnect` /
  /// `RouteGroupDisconnect`); null when unused. A name or TestStand expression.
  String? get routeGroupConnect => _scalar('RouteGroupConnect');
  String? get routeGroupDisconnect => _scalar('RouteGroupDisconnect');

  // --- Execution / batch / window options ---

  /// The batch-synchronization code (`BatchSyncOpt`) for the step under a batch
  /// process model (serial / parallel / one-thread-only). null when unset; raw
  /// NI code.
  int? get batchSyncCode => _int('BatchSyncOpt');

  /// The post-action loop option code (`LoopOpt`). null when unset; raw NI code.
  int? get loopOptionCode => _int('LoopOpt');

  /// The precondition interactive-execution code (`PrecondIntExe`) — whether the
  /// precondition is honoured when the step is run interactively. null when
  /// unset; raw NI code.
  int? get preconditionInteractiveCode => _int('PrecondIntExe');

  /// The window-activation setting (`WindowActivation`), e.g. `None` — how the
  /// step affects the application window. null when unset.
  String? get windowActivation => _scalar('WindowActivation');
}

/// A `<typelist>` type definition: a named type and the fields it declares.
///
/// This is **recovered structure only** — the type's [name], its base class
/// ([baseClass], the root's `classname`), and the ordered list of declared
/// [fields] (each a name + its own `classname` type token). TestStand's
/// `<typelist>` is NI's internal type system (mostly built-in machinery such as
/// `NI_PropertyObjectType`, `CommonResults`, step-type definitions, alongside
/// any user/cluster types); the *semantics* of an individual field's internal
/// attributes are NI-internal and not claimed here. Surfacing names/structure
/// makes the typedef table — previously hidden behind a bare count — visible.
class SeqType {
  SeqType(this.raw);

  /// The type root property object (one entry from [SeqFile.types]).
  final SeqProperty raw;

  /// The type's name (e.g. `NI_CustomResult`, `CommonResults`, a step type).
  String get name => raw.name;

  /// The type's base class — the root's `classname` token (null when absent).
  String? get baseClass => raw.className;

  /// The directly-declared fields, in document order. Each is a `(name, type)`
  /// pair where `type` is the field's own `classname` token (may be null).
  /// Empty for a leaf/scalar type that declares no sub-fields.
  List<({String name, String? type})> get fields => [
        for (final c in [...raw.subProps, ...?raw.array])
          (name: c.name, type: c.className),
      ];
}

/// The Semiconductor-Test-System (STS) measurement plug-in resource set a
/// sequence file declares under `FileGlobalDefaults > MeasurementPlugIns` — the
/// external test-program files the sequence depends on: the **pin map** and the
/// **specifications / levels / timing / pattern** file lists. All clean file
/// paths (self-evident); `EnableMonitoring` is a plain flag. Surfacing these
/// answers "what external resources does this sequence need".
class MeasurementPlugIns {
  MeasurementPlugIns(this.raw);

  /// The raw `MeasurementPlugIns` property object — full access to its details.
  final SeqProperty raw;

  /// The pin-map file the test program loads (`PinMapPath`), e.g.
  /// `PinMap.pinmap`; null when the file declares none.
  String? get pinMapPath => _nz(raw.prop('PinMapPath')?.scalar);

  /// Whether result monitoring is enabled (`EnableMonitoring`). false when absent.
  bool get monitoringEnabled => raw.prop('EnableMonitoring')?.scalar == 'true';

  /// Specification files (`SpecificationsFilePaths`), in order; empty when none.
  List<String> get specificationFiles => _paths('SpecificationsFilePaths');

  /// Pin-levels files (`LevelsFilePaths`), in order; empty when none.
  List<String> get levelsFiles => _paths('LevelsFilePaths');

  /// Timing files (`TimingFilePaths`), in order; empty when none.
  List<String> get timingFiles => _paths('TimingFilePaths');

  /// Pattern files (`PatternFilePaths`), in order; empty when none.
  List<String> get patternFiles => _paths('PatternFilePaths');

  List<String> _paths(String key) {
    final p = raw.prop(key);
    if (p == null) return const [];
    return [
      for (final e in p.array ?? const <SeqProperty>[])
        if (_nz(e.scalar) != null) e.scalar!,
    ];
  }

  /// True when the file actually declares any STS resource (a pin map or any
  /// file list) — i.e. the block carries more than a bare monitoring flag.
  bool get isNotEmpty =>
      pinMapPath != null ||
      specificationFiles.isNotEmpty ||
      levelsFiles.isNotEmpty ||
      timingFiles.isNotEmpty ||
      patternFiles.isNotEmpty;
}

/// Parses TestStand sequence-file [bytes] into a [SeqFile].
///
/// Supports the **XML** encoding. Throws [UnsupportedError] for the binary
/// `TOF1` encoding (not yet decoded) and [FormatException] for unrecognized
/// input — never a silent partial result.
SeqFile parseSeqFile(Uint8List bytes) {
  final fmt = detectSeqFormat(bytes);
  switch (fmt) {
    case SeqFormat.xml:
      return _parseXml(bytes);
    case SeqFormat.binary:
      throw UnsupportedError('binary TOF1 .seq decoding is not yet implemented (M2)');
    case SeqFormat.ini:
      return parseIniSeqFile(bytes);
    case SeqFormat.unknown:
      throw FormatException('not a recognized XML TestStand sequence file ($fmt)');
  }
}

SeqFile _parseXml(Uint8List bytes) {
  final root = XmlDocument.parse(_stripBom(utf8.decode(bytes))).rootElement;
  if (root.name.local != 'teststandfileheader') {
    throw FormatException('unexpected root element <${root.name.local}>');
  }
  final types = <SeqProperty>[];
  final typelist = childElement(root, 'typelist');
  if (typelist != null) {
    for (final typedef in childElementsNamed(typelist, 'typedef')) {
      final kids = typedef.childElements;
      if (kids.isNotEmpty) types.add(buildProperty(kids.first));
    }
  }
  final dataEl = childElement(root, 'Data');
  if (dataEl == null) throw const FormatException('missing <Data> element');
  return SeqFile(
    header: detectSeqHeader(bytes),
    types: types,
    data: buildProperty(dataEl),
  );
}

/// Removes a leading UTF-8 BOM (`U+FEFF`) so the XML parser sees a clean prolog.
String _stripBom(String s) =>
    s.isNotEmpty && s.codeUnitAt(0) == 0xFEFF ? s.substring(1) : s;
