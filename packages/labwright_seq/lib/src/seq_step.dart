import 'scalar_read.dart';
import 'seq_file.dart';
import 'seq_module.dart';
import 'seq_property.dart';
import 'seq_typedefs.dart';

/// A single step within a sequence group.
class Step {
  Step(this.raw);

  /// The underlying property object — full access to every step property.
  final SeqProperty raw;

  String? _scalarOf(String key) => nonEmpty(raw.prop(key)?.scalar);
  int? _intOf(String key) => int.tryParse(_scalarOf(key) ?? '');
  bool? _flagOf(String key) => parseFlag(_scalarOf(key));

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
  String? get comment => nonEmpty(raw.attributes['%COMMENT']);

  /// The step's editor description (`Description`) — the one-line summary shown
  /// in the step list, produced from the step type's
  /// [StepTypeInfo.descriptionFormat] (e.g. `This sequence will automatically
  /// login…`). null when the step records none. Distinct from the free-text
  /// [comment].
  String? get description => _scalarOf('Description');

  /// The step's active-state code (`Active`) governing whether it runs in the
  /// normal flow. Surfaced verbatim; the NI-internal code→name mapping is not
  /// invented (the run-mode override is exposed readably as [StepSettings.mode]).
  /// null when unset.
  int? get activeStateCode => _intOf('Active');

  /// The pin map path the step pins its operation to (`PinMapPath`), for a
  /// Semiconductor-Test-System step; null when unset.
  String? get pinMapPath => _scalarOf('PinMapPath');

  /// The step type's serialized input-buffer template (`InBuf`) — an NI-internal
  /// blob the editor uses when creating the step; surfaced raw (its internal
  /// structure is not decoded). null when absent.
  String? get inputBuffer => _scalarOf('InBuf');

  /// The step's editor category (`Category`, e.g. `Test`, `Action`) — how the
  /// editor groups the step; null when unset.
  String? get category => _scalarOf('Category');

  /// Whether the step suppresses the next step's result (`SuppressNextResult`).
  /// null when unset.
  bool? get suppressesNextResult => _flagOf('SuppressNextResult');

  /// The precondition as last evaluated (`EvaluatedConditionExpr`) — the resolved
  /// form of the step's precondition; null when absent.
  String? get evaluatedConditionExpression => _scalarOf('EvaluatedConditionExpr');

  /// Whether the step's limit comparison is driven by an expression
  /// (`UseCompExpr`) rather than a fixed operator; null when unset. Pairs with
  /// [limits] and [StepLimits.lowExpression]/[StepLimits.highExpression].
  bool? get usesComparisonExpression => _flagOf('UseCompExpr');

  /// For an array/For-Each iteration step: the subscript expression
  /// (`SubscriptExpr`) selecting the element, the integer offset (`Offset`), the
  /// iteration-type code (`IterationType`, verbatim), the local that restores the
  /// element after the loop (`ElementRestorerLocal`), whether the data file
  /// auto-closes at end (`AutoCloseAtEndofFile`), and a field-mapping expression
  /// (`FieldMappingExpr`). Each null when absent.
  String? get arraySubscriptExpression => _scalarOf('SubscriptExpr');
  int? get arrayOffset => _intOf('Offset');
  int? get iterationTypeCode => _intOf('IterationType');
  String? get elementRestorerLocal => _scalarOf('ElementRestorerLocal');
  bool? get autoClosesAtEndOfFile => _flagOf('AutoCloseAtEndofFile');
  String? get fieldMappingExpression => _scalarOf('FieldMappingExpr');

  /// The runtime-evaluated forms TestStand caches for the step's array/loop
  /// expressions (`EvaluatedArrayExpr` / `EvaluatedArrayElementExpr` /
  /// `EvaluatedSubscriptExpr` / `EvaluatedOffsetExpr`) — the resolved counterparts
  /// to the [FlowControl] expressions. Each null when absent.
  String? get evaluatedArrayExpression => _scalarOf('EvaluatedArrayExpr');
  String? get evaluatedArrayElementExpression => _scalarOf('EvaluatedArrayElementExpr');
  String? get evaluatedSubscriptExpression => _scalarOf('EvaluatedSubscriptExpr');
  String? get evaluatedOffsetExpression => _scalarOf('EvaluatedOffsetExpr');

  /// For a Wait (or timeout-bearing) step: the timeout expression (`TimeoutExpr`),
  /// whether the timeout is enabled (`TimeoutEnabled`), and whether a timeout
  /// raises an error (`ErrorOnTimeout`). Each null when absent.
  String? get timeoutExpression => _scalarOf('TimeoutExpr');
  bool? get timeoutEnabled => _flagOf('TimeoutEnabled');
  bool? get errorsOnTimeout => _flagOf('ErrorOnTimeout');

  /// For a database step: the statement / database handle expressions
  /// (`StatementHandle` / `DatabaseHandle`, e.g. `Locals.SelectStatement`) the
  /// step operates on. Each null when absent.
  String? get statementHandle => _scalarOf('StatementHandle');
  String? get databaseHandle => _scalarOf('DatabaseHandle');

  /// Further database step fields: the SQL statement (`SQLStatement`, a literal or
  /// expression), whether the statement requires parameters (`RequiresParameters`),
  /// the fetch page size (`PageSize`), and the records-selected output expression
  /// (`NumberOfRecordsSelected`). Each null when absent. The selected columns are
  /// in the raw `ColumnList`.
  String? get sqlStatement => _scalarOf('SQLStatement');
  bool? get requiresParameters => _flagOf('RequiresParameters');
  int? get pageSize => _intOf('PageSize');
  String? get numberOfRecordsSelectedExpression => _scalarOf('NumberOfRecordsSelected');

  /// The ADO recordset/command option codes for a database step
  /// (`CommandTimeout`, `CommandType`, `LockType`, `CursorLocation`,
  /// `CursorType`, `CacheSize`, `MarshalOptions`, `MaxRecordsToSelect`) — the
  /// underlying ADO settings the Open/Statement step uses. Each surfaced verbatim
  /// (the NI/ADO code→name mappings are not invented); null when absent. The
  /// remote-connection and error records live in the raw `RemoteSettings` /
  /// `StdError`.
  int? get dbCommandTimeoutCode => _intOf('CommandTimeout');
  int? get dbCommandTypeCode => _intOf('CommandType');
  int? get dbLockTypeCode => _intOf('LockType');
  int? get dbCursorLocationCode => _intOf('CursorLocation');
  int? get dbCursorTypeCode => _intOf('CursorType');
  int? get dbCacheSize => _intOf('CacheSize');
  int? get dbMarshalOptionsCode => _intOf('MarshalOptions');
  int? get dbMaxRecordsToSelect => _intOf('MaxRecordsToSelect');

  /// For a Run/Wait step that references a sequence call by name: the referenced
  /// SequenceCall step's name (`SeqCallName`) and step-group index code
  /// (`SeqCallStepGroupIdx`), whether the target is specified by that sequence
  /// call (`SpecifyBySeqCall`), and the wait-for-target code (`WaitForTarget`).
  /// Each null when absent.
  String? get referencedSequenceCallName => _scalarOf('SeqCallName');
  int? get referencedSequenceCallStepGroupCode => _intOf('SeqCallStepGroupIdx');
  bool? get specifiesBySequenceCall => _flagOf('SpecifyBySeqCall');
  int? get waitForTargetCode => _intOf('WaitForTarget');

  /// For a Wait step targeting a thread/execution: the thread / execution
  /// reference expressions (`ThreadRefExpr` / `ExecutionRefExpr`) and the wait
  /// time expression (`TimeExpr`, seconds). Each null when absent.
  String? get threadReferenceExpression => _scalarOf('ThreadRefExpr');
  String? get executionReferenceExpression => _scalarOf('ExecutionRefExpr');
  String? get waitTimeExpression => _scalarOf('TimeExpr');

  /// The step's run-time settings (preconditions, looping, pass/fail actions),
  /// read from its `TS` (TestStand system) sub-container.
  StepSettings get settings => StepSettings(raw.prop('TS'));

  /// The code module the step invokes (its module-adapter binding), read from
  /// `TS > SData`. [StepModule.adapter] is [SeqAdapter.none] when the step has no
  /// SData.
  StepModule get module => StepModule.fromSData(raw.at(['TS', 'SData']));

  /// The step **type** definition embedded alongside this step — its code
  /// templates, menu placement, name/description formats, and (for flow-control
  /// types) the block start/end step types. TestStand text/INI exports inline the
  /// full type definition next to each step; this lens reads it out. See
  /// [StepTypeInfo].
  StepTypeInfo get typeInfo => StepTypeInfo(raw);

  /// The structured control-flow construct this step is, when it is one of the
  /// `NI_Flow_*` step types (If/ElseIf/Else/While/For/ForEach/Select/Case/End/
  /// Break/Continue) — with the recovered condition / loop / case expressions.
  /// null for an ordinary (non-flow) step. See [FlowControl]; drives the nested
  /// logic export.
  FlowControl? get flowControl => FlowControl.fromStep(this);

  /// The test limits (pass/fail criteria) for a limit-test step, or null when
  /// this step is not a limit test (no `Comp`/`Limits`).
  StepLimits? get limits => StepLimits.fromStep(raw);

  /// The measurement units the step's result records in (`Result.Units`) — e.g.
  /// `V`, `mA`, `nS` — the unit paired with a numeric limit test's value, or
  /// null when the step records none. Stored on the step's `Result` sub-object
  /// (a sibling of `TS`), not under `Limits`.
  String? get resultUnits => nonEmpty(raw.prop('Result')?.prop('Units')?.scalar);

  /// The step's recorded-result slot (`Result`) — its per-step outcome record
  /// (status, report text, error info), or null when the step has none. See
  /// [StepResult]; the measured-value unit is exposed separately as
  /// [resultUnits].
  StepResult? get result {
    final result = raw.prop('Result');
    return result == null ? null : StepResult(result);
  }

  /// The step's data-source expression (`DataSource`) — what the step measures
  /// or evaluates: the measured value for a numeric limit test (e.g.
  /// `Locals.A.High_Value`), or the pass/fail criterion for a `PassFailTest`
  /// (e.g. `Step.Result.PassFail`). null when the step has none. This is the same
  /// value as [StepLimits.dataSource] for a limit test, but is exposed here too
  /// so it's recovered for non-limit steps (e.g. `PassFailTest`), where there is
  /// no [StepLimits].
  String? get dataSource => _scalarOf('DataSource');

  /// The step's unique id (`TS.Id`, e.g. `ID#:1m8fotxw7RGuNrjdh1OqZD`) — the
  /// stable handle other steps' flow-action targets reference (see
  /// [SeqFile.stepNameForId], which resolves such a reference back to this step's
  /// name). null when the step records none. Opaque by design; its value is the
  /// link identity, not human-meaningful text.
  String? get id => nonEmpty(raw.prop('TS')?.prop('Id')?.scalar);

  /// The typed formal parameters of a **measurement step** — the NI measurement
  /// adapter's `Measurement.Parameters` list (each a [MeasurementParameter]):
  /// the named, typed inputs/outputs the measurement routine takes (e.g.
  /// `voltage_level : TypeDouble In = 6`). Empty for non-measurement steps. This
  /// is distinct from [StepModule.callParameters] (the ActiveX/C and Python
  /// adapter argument lists), which a measurement step does not use.
  List<MeasurementParameter> get measurementParameters {
    final params = raw.prop('Measurement')?.prop('Parameters');
    final kids = params?.array ?? params?.subProps ?? const <SeqProperty>[];
    return [for (final parameter in kids) MeasurementParameter(parameter)];
  }

  /// The registered name of the measurement a measurement step invokes
  /// (`Measurement.Name`, e.g. `ni.examples.NIDCPowerSourceDCVoltage_Python`) —
  /// the measurement plug-in's service identifier. null for a non-measurement
  /// step or when unset.
  String? get measurementName => nonEmpty(raw.prop('Measurement')?.prop('Name')?.scalar);

  /// The step's "Additional Results" recording spec — the extra values it logs
  /// to the report. Collected from every `AdditionalResults` container in the
  /// step's subtree (these attach to module-call parameters, e.g. a Python or
  /// C/CVI call's `Input`/`Output` directions). Each [AdditionalResult] names a
  /// recorded slot and carries its gating `Condition` expression; the
  /// `Flags`/`CheckedState` siblings are left raw (meaning not yet decoded).
  List<AdditionalResult> get additionalResults {
    final out = <AdditionalResult>[];
    void walk(SeqProperty node) {
      final kids = [...node.subProps, ...?node.array];
      if (node.name == 'AdditionalResults') {
        out.addAll(kids.map(AdditionalResult.new));
        return;
      }
      kids.forEach(walk);
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
  selectBlock('select'),
  caseBlock('case'),
  end('end'),
  breakStmt('break'),
  continueStmt('continue')
  ;

  const FlowKind(this.label);

  /// A short readable keyword (`if`, `for each`, `select`, `case`, `end`, …).
  final String label;

  /// Whether this construct opens a nested block (its body is the following
  /// steps until the matching [end]). A `Select` opens the switch; each `Case`
  /// opens its own body — both are closed by their own `NI_Flow_End` (verified
  /// by opener/end balance across the corpus).
  bool get opensBlock => const {
    ifBlock,
    whileLoop,
    doWhile,
    forLoop,
    forEach,
    selectBlock,
    caseBlock,
  }.contains(this);

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
/// `ArrayExpr`/`ArrayElementExpr`/`OffsetExpr`; `Select`/`Case` → `ItemExpr`.
/// These are clean expression strings — the sequence's actual control logic —
/// drawn straight from the step.
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
      'NI_Flow_Select' => FlowKind.selectBlock,
      'NI_Flow_Case' => FlowKind.caseBlock,
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
  String? get condition => nonEmpty(_node?.prop('ConditionExpr')?.scalar);

  /// The `for` loop's initialization expression (`InitializationExpr`).
  String? get initialization => nonEmpty(_node?.prop('InitializationExpr')?.scalar);

  /// The `for` loop's increment expression (`IncrementExpr`).
  String? get increment => nonEmpty(_node?.prop('IncrementExpr')?.scalar);

  /// The `for each` array expression (`ArrayExpr`) — the collection iterated.
  String? get arrayExpr => nonEmpty(_node?.prop('ArrayExpr')?.scalar);

  /// The `for each` element expression (`ArrayElementExpr`) — the loop variable.
  String? get arrayElement => nonEmpty(_node?.prop('ArrayElementExpr')?.scalar);

  /// The `select`/`case` expression (`ItemExpr`) — the value a `Select` switches
  /// on, or the value a `Case` matches; null otherwise.
  String? get itemExpression => nonEmpty(_node?.prop('ItemExpr')?.scalar);

  /// Whether this is the default `Case` (`IsDefault`) — the fall-through arm of a
  /// `Select`; false/absent for an ordinary value case and for non-case kinds.
  bool get isDefaultCase => kind == FlowKind.caseBlock && parseFlag(_node?.prop('IsDefault')?.scalar) == true;

  /// A readable one-line header for the construct, e.g. `if (Locals.x > 0)`,
  /// `for (Locals.i = 0; Locals.i < N; Locals.i += 1)`,
  /// `for each (Locals.e in RunState.…)`, `while (True)`, `end`.
  String get header => switch (kind) {
    FlowKind.ifBlock => 'if (${condition ?? ''})',
    FlowKind.elseIf => 'else if (${condition ?? ''})',
    FlowKind.elseBlock => 'else',
    FlowKind.whileLoop => 'while (${condition ?? ''})',
    FlowKind.doWhile => 'do-while (${condition ?? ''})',
    FlowKind.forLoop =>
      'for (${[
        initialization,
        condition,
        increment,
      ].whereType<String>().join('; ')})',
    FlowKind.forEach => 'for each (${arrayElement ?? '?'} in ${arrayExpr ?? '?'})',
    FlowKind.selectBlock => 'select (${itemExpression ?? ''})',
    FlowKind.caseBlock => isDefaultCase ? 'case (default)' : 'case (${itemExpression ?? ''})',
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
  String? get kind => nonEmpty(raw.attributes['classname']);

  /// The gating `Condition` expression (an `ExprValue`); null when the entry has
  /// no condition or an empty one (record unconditionally).
  String? get condition => nonEmpty(raw.prop('Condition')?.scalar);
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
  String? get status => nonEmpty(raw.prop('Status')?.scalar);

  /// The report text the step contributed (`ReportText`); null when unset.
  String? get reportText => nonEmpty(raw.prop('ReportText')?.scalar);

  /// The recorded pass/fail outcome (`PassFail`) for a pass/fail step; null when
  /// the step records none (un-run, or not a pass/fail step).
  bool? get passFail => parseFlag(raw.prop('PassFail')?.scalar);

  SeqProperty? get _error => raw.prop('Error');

  /// The recorded error code (`Error.Code`); null when unset. `0` is the
  /// no-error default.
  String? get errorCode => nonEmpty(_error?.prop('Code')?.scalar);

  /// The recorded error message (`Error.Msg`); null when unset/empty.
  String? get errorMessage => nonEmpty(_error?.prop('Msg')?.scalar);

  /// Whether an error was recorded (`Error.Occurred`); null when the step has no
  /// `Error` slot. `false` is the default.
  bool? get errorOccurred => parseFlagStrict(_error?.prop('Occurred')?.scalar);

  /// Whether this result holds any non-default value — true once a real run is
  /// recorded (status/report text set, or an error occurred). false for the
  /// compile-time default state seen in a sequence file.
  bool get hasRecordedOutcome => status != null || reportText != null || errorOccurred == true;
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
    this.comparisonExpression,
    this.low,
    this.high,
    this.nominal,
    this.thresholdType,
    this.dataSource,
    this.raw,
  });

  /// The comparison operator (`Comp`), e.g. `GELE`.
  final String? comparison;

  /// The comparison as an expression (`CompExpr`), when the step selects its
  /// operator dynamically (paired with [Step.usesComparisonExpression]); null
  /// when the step uses the fixed [comparison] operator.
  final String? comparisonExpression;

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

  /// The expression forms of the limits (`Limits.LowExpr` / `HighExpr` /
  /// `NominalExpr`) — when a limit is driven by an expression (e.g.
  /// `Locals.Limits_DUT.__01_Power[1]`) rather than the literal [low]/[high]/
  /// [nominal] value. null when the limit is a plain constant or absent.
  String? get lowExpression => nonEmpty(raw?.prop('LowExpr')?.scalar);
  String? get highExpression => nonEmpty(raw?.prop('HighExpr')?.scalar);
  String? get nominalExpression => nonEmpty(raw?.prop('NominalExpr')?.scalar);

  /// Whether the low / high bound is taken from its expression form
  /// (`Limits.UseLowExpr` / `UseHighExpr`) instead of the literal value. null when
  /// unset.
  bool? get usesLowExpression => parseFlag(raw?.prop('UseLowExpr')?.scalar);
  bool? get usesHighExpression => parseFlag(raw?.prop('UseHighExpr')?.scalar);

  /// Whether the step carries any limit information.
  static StepLimits? fromStep(SeqProperty step) {
    final comp = nonEmpty(step.prop('Comp')?.scalar);
    final lim = step.prop('Limits');
    if (comp == null && lim == null) return null;
    return StepLimits(
      comparison: comp,
      comparisonExpression: nonEmpty(step.prop('CompExpr')?.scalar),
      low: nonEmpty(lim?.prop('Low')?.scalar),
      high: nonEmpty(lim?.prop('High')?.scalar),
      nominal: nonEmpty(lim?.prop('Nominal')?.scalar),
      thresholdType: nonEmpty(lim?.prop('ThresholdType')?.scalar),
      dataSource: nonEmpty(step.prop('DataSource')?.scalar),
      raw: lim,
    );
  }

  /// A short readable summary, e.g. `GELE [9, 11]`.
  String get summary => '${comparison ?? '?'} [${low ?? '?'}, ${high ?? '?'}]';

  @override
  String toString() => 'StepLimits($summary)';
}

/// The step settings the Sequence Editor surfaces — flow control and the
/// pre/post expressions — read from a step's `TS` sub-container. Every getter is
/// null when the underlying property is absent or empty (no fabricated default),
/// so "not set" is honestly distinguishable from a real value.
class StepSettings {
  StepSettings(this._ts);

  /// The `TS` property object, or null if the step has none.
  final SeqProperty? _ts;

  String? _scalar(String key) => nonEmpty(_ts?.prop(key)?.scalar);

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

  String? _flowTarget(String key) => nonEmpty(unwrapExprString(_scalar(key)));

  /// Parses a TS boolean step-setting: stored either as `true`/`false` or `1`/`0`.
  /// null when the key is absent or unrecognized.
  bool? _bool(String key) => parseFlagStrict(_scalar(key));

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
      final actionText = act ?? '?';
      return (actionText != 'Next' && target != null) ? '$actionText→$target' : actionText;
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
  bool? get canEditParameterAdditionalResults => _bool('CanEditParameterAdditionalResults');

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

  /// Whether the step is marked to produce no result entry (`NoResult`) — it is
  /// excluded from the result list / report. null when unset; the complement of
  /// [recordsResult] for step types that use this flag.
  bool? get producesNoResult => _bool('NoResult');

  /// The human-readable module adapter the step uses (`Adapter`, e.g.
  /// `Sequence Adapter`, `DLL Flexible Prototype Adapter`, `G Std Prototype
  /// Adapter`, `None Adapter`) — the editor's "Module Adapter" label. null when
  /// unset. The decoded binding is exposed via [Step.module]/[StepModule.adapter].
  String? get adapterName => _scalar('Adapter');

  /// Whether the step has a code module configured (`HasModule`). null when unset.
  bool? get hasModule => _bool('HasModule');

  /// The requirement-traceability links the step declares (`TS.Requirements.
  /// Links`). Empty when none.
  List<String> get requirementLinks => scalarValues(_ts?.prop('Requirements')?.prop('Links'));
}
