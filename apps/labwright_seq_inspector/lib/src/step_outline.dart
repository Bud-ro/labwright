/// Per-step view models for the sequence outline: the step row itself plus its
/// call arguments, connector-pane parameters, measurement parameters, limits,
/// and variables.
library;

import 'package:labwright_seq/labwright_seq.dart';

import 'sequence_outline.dart';

/// One step, with its fields pulled apart for layout.
class StepOutline {
  StepOutline({
    required this.name,
    required this.type,
    this.adapter,
    this.target,
    this.callTargetIndex,
    this.externalCall,
    this.limits,
    this.limitsDetail,
    this.units,
    this.dataSource,
    this.runMode,
    this.comment,
    this.expressions = const [],
    this.callArgs = const [],
    this.measurementParams = const [],
    this.connectorParams = const [],
    this.flowHeader,
    this.flowDepth = 0,
    required this.notes,
  });

  final String name;
  final String type;

  /// For an `NI_Flow_*` step, the construct's readable header — `if (cond)`,
  /// `for each (x in xs)`, `while (cond)`, `else`, `end`, `break`, … — recovered
  /// via [Step.flowControl]. `null` for ordinary (non-flow) steps. Lets the UI
  /// render the control-flow construct instead of a bare step name.
  final String? flowHeader;

  /// The step's control-flow nesting depth (0 at a group's top level), computed
  /// by balancing the `NI_Flow_*` openers/ends across the group. Drives the
  /// indentation of the structured view so the nested logic reads like code.
  final int flowDepth;

  /// The step's free-text comment — the editor's per-step note — or `null` when
  /// the step has none. Recovered from `%COMMENT`.
  final String? comment;

  /// The step's run mode when it is *not* the normal `Normal` (e.g. `Skip`,
  /// `Pass`, `Fail`) — a forced override that changes execution, so it gets its
  /// own prominent badge. `null` when the step runs normally (the common case;
  /// not noteworthy). The default itself is recovered via type inheritance.
  final String? runMode;

  /// Module adapter name (e.g. `labView`, `sequenceCall`), or `null` for none.
  final String? adapter;

  /// What the adapter targets (VI path, DLL function, called sequence, …).
  final String? target;

  /// For an in-file SequenceCall, the [SeqOutline.sequences] index to jump to.
  /// `null` when the step is not an in-file call.
  final int? callTargetIndex;

  /// For an external SequenceCall, the file it lives in (or `''` if unknown);
  /// `null` when the step is not an external call.
  final String? externalCall;

  /// Limits summary (e.g. `GELE [9, 11]`), or `null` if the step has none.
  /// Kept for the one-line label and search; [limitsDetail] holds the fields.
  final String? limits;

  /// The individual limit fields for a richer display, or `null` if the step has
  /// no limits.
  final LimitsOutline? limitsDetail;

  /// The measurement units the step's result records in (`Result.Units`, e.g.
  /// `V`, `mA`), or `null` when the step records none. Pairs with [limitsDetail]
  /// for a numeric limit test; shown as a "Units" row there, or its own chip.
  final String? units;

  /// The step's data-source expression (`DataSource`) — the pass/fail criterion
  /// for a `PassFailTest` (e.g. `Step.Result.PassFail`) or the measured value
  /// otherwise — or `null` when the step has none. For a limit test this is
  /// already shown in [limitsDetail]'s "Data source" row, so the UI only renders
  /// it standalone when [limitsDetail] is null.
  final String? dataSource;

  /// The step's TestStand expressions that are set (label → expression), in
  /// editor order: precondition, pre/post/status expressions, loop-while. Empty
  /// when the step uses none. These are the custom logic the editor surfaces but
  /// are too long for a chip, so the UI shows them as their own rows.
  final List<(String, String)> expressions;

  /// The arguments the step's code-module call binds (name, direction, bound
  /// expression, type) — the editor's "Module > Parameters" rows. Empty when the
  /// call passes none. Shown as their own mini-table, like [limitsDetail].
  final List<CallArgOutline> callArgs;

  /// The typed formal parameters of a measurement step (`Measurement.Parameters`)
  /// — name, data type, direction, bound value. Empty for non-measurement steps.
  /// Shown as their own mini-table, distinct from [callArgs].
  final List<MeasurementParamOutline> measurementParams;

  /// The LabVIEW VI-call connector-pane parameters (`ViCall.Parms`) — connector
  /// terminal, label, display type, bound expression. Empty for non-LabVIEW
  /// steps. Shown as their own mini-table; the VI library/project ride in
  /// [notes] (parity with the dump's `{vi:}`/`{conn:}` chips).
  final List<ConnectorParamOutline> connectorParams;

  /// Mode / flow / loop notes (only non-default ones).
  final List<String> notes;

  bool get isInFileCall => callTargetIndex != null;

  /// How to display the module target: the basename as a prominent [label] when
  /// the target looks like a file path (contains `/` or `\`), otherwise the
  /// target verbatim; [tooltip] is always the full target. Returns null when the
  /// step has no module target. Pure.
  ({String label, String tooltip})? get targetDisplay {
    final targetText = target;
    if (targetText == null) return null;
    final label = pathBasename(targetText);
    return (label: label.isEmpty ? targetText : label, tooltip: targetText);
  }

  factory StepOutline.of(Step step, SeqFile file, {int flowDepth = 0}) {
    final module = step.module;
    String? adapter;
    String? target;
    int? callTargetIndex;
    String? externalCall;
    if (module.adapter != SeqAdapter.none) {
      adapter = module.adapter.name;
      target = switch (module.adapter) {
        SeqAdapter.python => module.target ?? '(target not yet recovered)',
        _ => module.target ?? '(none)',
      };
      if (module.adapter == SeqAdapter.sequenceCall) {
        final resolved = file.resolveCall(step);
        if (resolved != null) {
          callTargetIndex = file.sequences.indexOf(resolved);
        } else {
          externalCall = module.sequenceFile ?? '';
        }
      }
    }

    final settings = step.settings;
    final runMode = settings.isNormalMode ? null : settings.mode;
    final notes = <String>[];
    if (settings.flowSummary != null) notes.add('flow ${settings.flowSummary}');
    String resolveTarget(String target) => target.startsWith('ID#:')
        ? (file.stepNameForId(target) ?? target)
        : target;
    if (settings.customTrueTarget != null) {
      notes.add('cust-true→${resolveTarget(settings.customTrueTarget!)}');
    }
    if (settings.customFalseTarget != null) {
      notes.add('cust-false→${resolveTarget(settings.customFalseTarget!)}');
    }
    if (module.adapter == SeqAdapter.labView) {
      final lv = <String>[];
      if (module.viNamespace != null) lv.add('lib ${module.viNamespace}');
      if (module.viProjectPath != null) lv.add('proj ${module.viProjectPath}');
      if (lv.isNotEmpty) notes.add('vi: ${lv.join(', ')}');
    }
    if (module.adapter == SeqAdapter.python) {
      final py = <String>[];
      if (module.pythonModulePath != null)
        py.add('mod ${module.pythonModulePath}');
      if (module.pythonClassName != null)
        py.add('class ${module.pythonClassName}');
      if (module.pythonVersion != null) py.add('py ${module.pythonVersion}');
      if (py.isNotEmpty) notes.add('python: ${py.join(', ')}');
    }
    if (settings.loadOption != null &&
        settings.loadOption != 'PreloadWhenExecuted') {
      notes.add('load ${settings.loadOption}');
    }
    if (settings.unloadOption != null &&
        settings.unloadOption != 'UnloadWithFile') {
      notes.add('unload ${settings.unloadOption}');
    }
    if (settings.isLooping) notes.add('loop ${settings.loopType}');
    if (settings.ignoresRunTimeErrors == true) notes.add('ignore-RTE');
    if (settings.failureCausesSequenceFailure == false)
      notes.add('no-seq-fail');
    if (settings.recordsResult == false) notes.add('no-record');
    final addl = step.additionalResults;
    if (addl.isNotEmpty) {
      String fmt(AdditionalResult a) =>
          a.condition != null ? '${a.name} if ${a.condition}' : a.name;
      notes.add('+results: ${addl.map(fmt).join(', ')}');
    }
    if (settings.usesMutex == true) {
      notes.add(
        'mutex${settings.mutexName != null ? ' ${settings.mutexName}' : ''}',
      );
    }
    final res = step.result;
    if (res != null && res.hasRecordedOutcome) {
      final resultBits = <String>[];
      if (res.status != null) resultBits.add('status ${res.status}');
      if (res.errorOccurred == true) {
        final code = res.errorCode;
        resultBits.add('error${code != null ? ' $code' : ''}');
      }
      if (res.reportText != null) resultBits.add('report "${res.reportText}"');
      if (resultBits.isNotEmpty) notes.add('result ${resultBits.join('; ')}');
    }

    final expressions = <(String, String)>[
      if (settings.precondition != null)
        ('Precondition', settings.precondition!),
      if (settings.customExpression != null)
        ('Custom condition', settings.customExpression!),
      if (settings.preExpression != null)
        ('Pre-expression', settings.preExpression!),
      if (settings.postExpression != null)
        ('Post-expression', settings.postExpression!),
      if (settings.statusExpression != null)
        ('Status', settings.statusExpression!),
      if (settings.loopInitialize != null)
        ('Loop init', settings.loopInitialize!),
      if (settings.loopWhile != null) ('Loop while', settings.loopWhile!),
      if (settings.loopIncrement != null)
        ('Loop increment', settings.loopIncrement!),
      if (settings.loopStatus != null) ('Loop status', settings.loopStatus!),
    ];

    return StepOutline(
      name: step.name,
      type: step.type ?? '?',
      adapter: adapter,
      target: target,
      callTargetIndex: callTargetIndex,
      externalCall: externalCall,
      limits: step.limits?.summary,
      limitsDetail: step.limits != null ? LimitsOutline.of(step.limits!) : null,
      units: step.resultUnits,
      dataSource: step.dataSource,
      runMode: runMode,
      comment: step.comment,
      expressions: expressions,
      callArgs: [
        for (final param in module.callParameters) CallArgOutline.of(param),
      ],
      measurementParams: [
        for (final param in step.measurementParameters)
          MeasurementParamOutline.of(param),
      ],
      connectorParams: [
        for (final param in module.viParameters)
          ConnectorParamOutline.of(param),
      ],
      flowHeader: step.flowControl?.header,
      flowDepth: flowDepth,
      notes: notes,
    );
  }

  /// A one-line label, equivalent to the dump view's per-step line (minus the
  /// in-file/external tag, which the UI renders as a tappable chip).
  String get summary {
    final out = StringBuffer('$name [$type]');
    if (flowHeader != null) out.write('  {flow: $flowHeader}');
    if (adapter != null) out.write(' -> $adapter: $target');
    if (limits != null) {
      out.write('  {limits $limits${units != null ? ' $units' : ''}}');
    } else if (units != null) {
      out.write('  {units $units}');
    }
    // Data source standalone only for non-limit steps (limit steps carry it in
    // limitsDetail), matching the dump.
    if (limitsDetail == null && dataSource != null) {
      out.write('  {data-source $dataSource}');
    }
    if (runMode != null) out.write('  {mode $runMode}');
    if (comment != null) out.write('  // $comment');
    if (notes.isNotEmpty) out.write('  (${notes.join('; ')})');
    for (final (label, value) in expressions) {
      out.write('  {$label: $value}');
    }
    if (callArgs.isNotEmpty) {
      out.write('  {args: ${callArgs.map((a) => a.line).join('; ')}}');
    }
    if (measurementParams.isNotEmpty) {
      out.write(
        '  {params: ${measurementParams.map((p) => p.line).join('; ')}}',
      );
    }
    if (connectorParams.isNotEmpty) {
      out.write('  {conn: ${connectorParams.map((p) => p.line).join('; ')}}');
    }
    return out.toString();
  }
}

/// One LabVIEW VI-call connector parameter for display — mirrors the package's
/// [CallParameter] read from `ViCall.Parms`, and the dump's `_dumpViParam`: a
/// connector-pane terminal [connectorNumber], the param [name] (its `Label`),
/// the human-readable [displayType], and the [boundExpression] wired to it. Each
/// field is omitted (left null) when absent — never invented. Distinct from
/// [CallArgOutline] (which carries a direction, not a connector index).
class ConnectorParamOutline {
  ConnectorParamOutline({
    required this.name,
    this.connectorNumber,
    this.displayType,
    this.boundExpression,
  });

  final String name;
  final int? connectorNumber;
  final String? displayType;
  final String? boundExpression;

  factory ConnectorParamOutline.of(CallParameter p) => ConnectorParamOutline(
    name: p.name,
    connectorNumber: p.connectorNumber,
    displayType: p.displayType,
    boundExpression: p.boundExpression,
  );

  /// Left-column label: the connector terminal index (when known) and the param
  /// name, e.g. `#11 sequence context`.
  String get label =>
      connectorNumber != null ? '#$connectorNumber $name' : name;

  /// Right-column value: the display type then the wired expression, e.g.
  /// `Object Reference ←ThisContext`; `(unwired)` when neither is present.
  String get cell {
    final out = StringBuffer();
    if (displayType != null) out.write(displayType);
    if (boundExpression != null)
      out.write('${out.isEmpty ? '' : ' '}←$boundExpression');
    return out.isEmpty ? '(unwired)' : out.toString();
  }

  /// Compact one-line form for the text summary / search, mirroring the dump's
  /// `_dumpViParam`: `#11 sequence context (Object Reference)←ThisContext`.
  String get line {
    final out = StringBuffer();
    if (connectorNumber != null) out.write('#$connectorNumber ');
    out.write(name);
    if (displayType != null) out.write(' ($displayType)');
    if (boundExpression != null) out.write('←$boundExpression');
    return out.toString();
  }
}

/// One module-call argument for display — mirrors the package's [CallParameter]:
/// a parameter [name], the [boundExpression] that supplies its value, its
/// [direction] (`in`/`out`/`in/out`, null when the code is absent/unrecognized),
/// and its [displayType]. Each field is omitted (left null) when absent — never
/// invented.
class CallArgOutline {
  CallArgOutline({
    required this.name,
    this.direction,
    this.boundExpression,
    this.displayType,
  });

  final String name;
  final String? direction;
  final String? boundExpression;
  final String? displayType;

  factory CallArgOutline.of(CallParameter p) => CallArgOutline(
    name: p.name,
    direction: p.direction,
    boundExpression: p.boundExpression,
    displayType: p.displayType,
  );

  /// Left-column label: the parameter name, tagged with its direction when known
  /// (e.g. `LoginName (in)`).
  String get label => direction != null ? '$name ($direction)' : name;

  /// Right-column value: the bound expression, falling back to the declared type
  /// when the call leaves the parameter unbound, else `(unbound)`.
  String get value => boundExpression ?? displayType ?? '(unbound)';

  /// Compact one-line form for the text summary / search, e.g.
  /// `LoginName in←FileGlobals.UserToAutoLogin`.
  String get line {
    final out = StringBuffer(name);
    if (direction != null) out.write(' $direction');
    if (boundExpression != null) out.write('←$boundExpression');
    return out.toString();
  }
}

/// One measurement-step formal parameter for display — mirrors the package's
/// [MeasurementParameter]: a parameter [name], its [dataType] (`TypeDouble`,
/// `TypeString`, …), [direction] (`In`/`Out`), bound [value] expression, and
/// whether it [isArray]. Each field is omitted (left null) when absent — never
/// invented. Distinct from [CallArgOutline] (the ActiveX/C + Python adapter
/// argument list); a measurement step uses these instead.
class MeasurementParamOutline {
  MeasurementParamOutline({
    required this.name,
    this.dataType,
    this.direction,
    this.value,
    this.isArray = false,
    this.typeSpecialization,
    this.logged,
    this.enumValues = const [],
  });

  final String name;
  final String? dataType;
  final String? direction;
  final String? value;
  final bool isArray;

  /// A refinement of [dataType] (`IOResource`/`Path`/`Pin`/`Enum`), or null for
  /// an unspecialized parameter.
  final String? typeSpecialization;

  /// Whether the parameter is recorded to the report; null when unknown. Only a
  /// `false` is noteworthy (logging is the default).
  final bool? logged;

  /// For a `TypeEnum` parameter, the enum's allowed values as `name=value`
  /// strings (e.g. `NONE=0`); empty for non-enum parameters.
  final List<String> enumValues;

  factory MeasurementParamOutline.of(MeasurementParameter p) =>
      MeasurementParamOutline(
        name: p.name,
        dataType: p.dataType,
        direction: p.direction,
        value: p.value,
        isArray: p.isArray,
        typeSpecialization: p.typeSpecialization,
        logged: p.logged,
        enumValues: [
          for (final item in p.enumValues) '${item.name}=${item.value ?? '?'}',
        ],
      );

  /// The enum value list capped for compact display, e.g. `NONE=0, DC_VOLTS=1,
  /// …(16)`; empty string when the parameter is not an enum.
  String get _enumChip {
    if (enumValues.isEmpty) return '';
    final shown = enumValues.take(6).join(', ');
    final more = enumValues.length > 6 ? ', …(${enumValues.length})' : '';
    return '{$shown$more}';
  }

  /// Left-column label: the parameter name, tagged with its direction when known
  /// (e.g. `voltage_level (in)`).
  String get label =>
      direction != null ? '$name (${direction!.toLowerCase()})' : name;

  /// Right-column value: the data type (with its `(specialization)` and `[]` for
  /// an array), the bound expression when set, then a `not logged` marker;
  /// `(unbound)` when nothing is present.
  String get cell {
    final out = StringBuffer();
    if (dataType != null) {
      out.write(dataType);
      if (typeSpecialization != null) out.write(' ($typeSpecialization)');
      if (isArray) out.write('[]');
    }
    if (value != null) out.write('${out.isEmpty ? '' : ' '}= $value');
    if (enumValues.isNotEmpty) out.write('${out.isEmpty ? '' : ' '}$_enumChip');
    if (logged == false) out.write('${out.isEmpty ? '' : ' '}· not logged');
    return out.isEmpty ? '(unbound)' : out.toString();
  }

  /// Compact one-line form for the text summary / search, e.g.
  /// `voltage_level in TypeDouble = 6`.
  String get line {
    final out = StringBuffer(name);
    if (direction != null) out.write(' ${direction!.toLowerCase()}');
    if (dataType != null) {
      out.write(' $dataType');
      if (typeSpecialization != null) out.write(' ($typeSpecialization)');
      if (isArray) out.write('[]');
    }
    if (value != null) out.write(' = $value');
    // All enum values in the search/summary line (not capped, so every constant
    // is searchable).
    if (enumValues.isNotEmpty) out.write(' {${enumValues.join(', ')}}');
    if (logged == false) out.write(' [not logged]');
    return out.toString();
  }
}

/// `n label` with the label pluralized (`label + 's'`) unless `n == 1`.
String _count(int count, String label) =>
    '$count $label${count == 1 ? '' : 's'}';

/// A one-line summary of an outline, e.g. `3 sequences · 42 steps`; when
/// [typeCount] is given (from the file's type list), appends `· K types`. Pure.
String outlineSummary(SeqOutline outline, {int? typeCount}) {
  final parts = [
    _count(outline.sequences.length, 'sequence'),
    _count(outline.totalSteps, 'step'),
    if (typeCount != null) _count(typeCount, 'type'),
  ];
  return parts.join(' · ');
}

/// A step's limits broken into individual fields for a richer display. Mirrors
/// the package's [StepLimits]; every field is optional and is omitted (left
/// null) when the step doesn't carry it — never invented.
class LimitsOutline {
  LimitsOutline({
    this.comparison,
    this.low,
    this.high,
    this.nominal,
    this.thresholdType,
    this.dataSource,
  });

  final String? comparison;
  final String? low;
  final String? high;
  final String? nominal;
  final String? thresholdType;
  final String? dataSource;

  factory LimitsOutline.of(StepLimits l) => LimitsOutline(
    comparison: l.comparison,
    low: l.low,
    high: l.high,
    nominal: l.nominal,
    thresholdType: l.thresholdType,
    dataSource: l.dataSource,
  );

  /// Present fields as label→value rows, in display order, omitting nulls.
  List<(String, String)> get rows => [
    if (comparison != null) ('Comparison', comparison!),
    if (low != null) ('Low', low!),
    if (high != null) ('High', high!),
    if (nominal != null) ('Nominal', nominal!),
    if (thresholdType != null) ('Threshold', thresholdType!),
    if (dataSource != null) ('Data source', dataSource!),
  ];
}

/// True if [s] matches [query] (case-insensitive, query already lower-cased) by
/// name, type, adapter, target, limits summary, run mode, free-text comment, or
/// any note/expression.
bool stepMatches(StepOutline s, String query) {
  if (query.isEmpty) return true;
  bool hit(String? x) => x != null && x.toLowerCase().contains(query);
  if (hit(s.name) ||
      hit(s.type) ||
      hit(s.adapter) ||
      hit(s.target) ||
      hit(s.limits) ||
      hit(s.units) ||
      hit(s.dataSource) ||
      hit(s.runMode) ||
      hit(s.flowHeader) ||
      hit(s.comment)) {
    return true;
  }
  for (final note in s.notes) {
    if (note.toLowerCase().contains(query)) return true;
  }
  for (final (label, value) in s.expressions) {
    if (label.toLowerCase().contains(query) ||
        value.toLowerCase().contains(query)) {
      return true;
    }
  }
  for (final arg in s.callArgs) {
    if (arg.name.toLowerCase().contains(query) ||
        (arg.boundExpression?.toLowerCase().contains(query) ?? false) ||
        (arg.displayType?.toLowerCase().contains(query) ?? false)) {
      return true;
    }
  }
  for (final param in s.measurementParams) {
    if (param.line.toLowerCase().contains(query)) return true;
  }
  for (final param in s.connectorParams) {
    if (param.line.toLowerCase().contains(query)) return true;
  }
  return false;
}

bool _varMatches(VarOutline v, String query) =>
    v.name.toLowerCase().contains(query) ||
    (v.type?.toLowerCase().contains(query) ?? false) ||
    (v.value?.toLowerCase().contains(query) ?? false) ||
    (v.comment?.toLowerCase().contains(query) ?? false);

/// Returns a display-filtered copy of [outline]: keeps a sequence if its name
/// matches, any variable matches, or any step matches; within a kept sequence,
/// keeps only matching steps — UNLESS the sequence name itself matches, in which
/// case the whole sequence is kept. An empty/blank query returns [outline]
/// unchanged (same instance). Pure.
///
/// Step objects are reused as-is, so each [StepOutline.callTargetIndex] still
/// refers to the ORIGINAL `outline.sequences` — callers that resolve jumps must
/// keep the full outline, not this filtered view.
SeqOutline filterSequences(SeqOutline outline, String query) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return outline;
  final kept = <SequenceOutline>[];
  for (final seq in outline.sequences) {
    if (seq.name.toLowerCase().contains(needle) ||
        (seq.comment?.toLowerCase().contains(needle) ?? false)) {
      kept.add(seq); // whole-sequence match → keep everything
      continue;
    }
    final varHit =
        seq.parameters.any((v) => _varMatches(v, needle)) ||
        seq.locals.any((v) => _varMatches(v, needle));
    final groups = <StepGroupOutline>[];
    for (final group in seq.groups) {
      final steps = group.steps.where((s) => stepMatches(s, needle)).toList();
      if (steps.isNotEmpty) groups.add(StepGroupOutline(group.name, steps));
    }
    if (groups.isNotEmpty || varHit) {
      kept.add(
        SequenceOutline(
          name: seq.name,
          parameters: varHit ? seq.parameters : const [],
          locals: varHit ? seq.locals : const [],
          groups: groups,
          comment: seq.comment,
        ),
      );
    }
  }
  return SeqOutline(kept);
}

/// A parameter or local variable row.
class VarOutline {
  VarOutline({
    required this.name,
    this.type,
    this.value,
    this.isArray = false,
    this.containerCount,
    this.comment,
  });
  final String name;
  final String? type;
  final String? value;

  /// Whether the variable is an array container (vs. an object/cluster). Only
  /// meaningful when [containerCount] is non-null.
  final bool isArray;

  /// Array element count / object field count, or `null` for a scalar variable.
  final int? containerCount;

  /// The variable's free-text comment (editor note), or `null` when it has none.
  final String? comment;

  factory VarOutline.of(SeqVariable v) => VarOutline(
    name: v.name,
    type: v.type,
    value: v.value,
    isArray: v.isArray,
    containerCount: v.containerCount,
    comment: v.comment,
  );

  /// `name : type`, then either ` = value` for a scalar or a container-size
  /// suffix (` [N]` for an array, ` {N fields}` for an object/cluster), and a
  /// trailing ` // comment` when the variable carries one.
  String get label {
    final out = StringBuffer('$name : ${type ?? '(untyped)'}');
    if (value != null) {
      out.write(' = $value');
    } else if (containerCount != null) {
      out.write(
        isArray
            ? ' [$containerCount]'
            : ' {$containerCount ${containerCount == 1 ? 'field' : 'fields'}}',
      );
    }
    if (comment != null) out.write('  // $comment');
    return out.toString();
  }
}
