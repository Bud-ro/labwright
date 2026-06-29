import 'package:labwright_seq/labwright_seq.dart';

/// The last path segment of [path], handling both `/` and `\` separators. The
/// single source of truth for basename extraction across the app (file labels in
/// `main.dart`, module-target display in [StepOutline.targetDisplay]). Returns
/// the empty string when [path] ends in a separator; callers that need a
/// non-empty fallback handle that themselves.
String pathBasename(String path) {
  final i = path.lastIndexOf(RegExp(r'[/\\]'));
  return i >= 0 ? path.substring(i + 1) : path;
}

/// A Flutter-free structured outline of a [SeqFile] — the data behind the
/// Sequences tab's tree. Kept widget-free so the shaping logic (which fields to
/// surface, how to label a step, what a SequenceCall resolves to) is
/// unit-testable without a Flutter binding.
///
/// Mirrors the field selection of `dumpSeqFile`'s `_dumpStep`, but exposes the
/// pieces individually so the UI can lay them out and make in-file calls
/// tappable, rather than rendering one flat line.

/// The whole outline: the sequences in a file, in document order.
class SeqOutline {
  SeqOutline(this.sequences, {this.plugins});

  final List<SequenceOutline> sequences;

  /// The file's Semiconductor-Test-System resource set (pin map + spec/levels/
  /// timing/pattern files), or `null` when the file declares none. File-level —
  /// not part of any sequence; shown as a header card.
  final MeasurementPluginsOutline? plugins;

  /// Builds the outline for [file]. Pure.
  factory SeqOutline.of(SeqFile file) {
    final mp = file.measurementPlugIns;
    return SeqOutline(
      [for (final seq in file.sequences) SequenceOutline.of(seq, file)],
      plugins: mp != null && mp.isNotEmpty
          ? MeasurementPluginsOutline.of(mp)
          : null,
    );
  }

  /// Total steps across all sequences and groups.
  int get totalSteps => sequences.fold(0, (n, s) => n + s.stepCount);

  /// Index of the sequence named [name], or `null` if absent — used to jump to
  /// the target of an in-file SequenceCall.
  int? indexOf(String name) {
    for (var i = 0; i < sequences.length; i++) {
      if (sequences[i].name == name) return i;
    }
    return null;
  }
}

/// The file's Semiconductor-Test-System resource set for display — mirrors the
/// package's [MeasurementPlugIns]: the pin map and the specifications/levels/
/// timing/pattern file lists the test program depends on. Each field is omitted
/// (empty/null) when absent — never invented.
class MeasurementPluginsOutline {
  MeasurementPluginsOutline({
    this.pinMap,
    this.specifications = const [],
    this.levels = const [],
    this.timing = const [],
    this.patterns = const [],
    this.monitoringEnabled = false,
  });

  final String? pinMap;
  final List<String> specifications;
  final List<String> levels;
  final List<String> timing;
  final List<String> patterns;
  final bool monitoringEnabled;

  factory MeasurementPluginsOutline.of(MeasurementPlugIns mp) =>
      MeasurementPluginsOutline(
        pinMap: mp.pinMapPath,
        specifications: mp.specificationFiles,
        levels: mp.levelsFiles,
        timing: mp.timingFiles,
        patterns: mp.patternFiles,
        monitoringEnabled: mp.monitoringEnabled,
      );

  /// Present resources as label→value rows, in display order, omitting empties.
  List<(String, String)> get rows => [
        if (pinMap != null) ('Pin map', pinMap!),
        if (specifications.isNotEmpty) ('Specifications', specifications.join(', ')),
        if (levels.isNotEmpty) ('Levels', levels.join(', ')),
        if (timing.isNotEmpty) ('Timing', timing.join(', ')),
        if (patterns.isNotEmpty) ('Patterns', patterns.join(', ')),
      ];
}

/// One sequence: its name, variables, and non-empty step groups.
class SequenceOutline {
  SequenceOutline({
    required this.name,
    required this.parameters,
    required this.locals,
    required this.groups,
    this.comment,
  });

  final String name;
  final List<VarOutline> parameters;
  final List<VarOutline> locals;

  /// The sequence's free-text comment (the editor's per-sequence note), or
  /// `null` when it has none. Recovered from `%COMMENT`.
  final String? comment;

  /// Setup/Main/Cleanup, omitting empty groups (matches the dump view).
  final List<StepGroupOutline> groups;

  /// Total steps across all groups.
  int get stepCount => groups.fold(0, (n, g) => n + g.steps.length);

  factory SequenceOutline.of(Sequence seq, SeqFile file) {
    final groups = <StepGroupOutline>[];
    for (final group in StepGroup.values) {
      final steps = seq.stepsIn(group);
      if (steps.isEmpty) continue;
      groups.add(
        StepGroupOutline(group.key, _withFlowDepth(steps, file)),
      );
    }
    return SequenceOutline(
      name: seq.name,
      parameters: [for (final v in seq.parameters) VarOutline.of(v)],
      locals: [for (final v in seq.locals) VarOutline.of(v)],
      groups: groups,
      comment: seq.comment,
    );
  }
}

/// Builds [StepOutline]s for [steps], assigning each its control-flow nesting
/// [StepOutline.flowDepth] by balancing the `NI_Flow_*` openers/ends — the same
/// model the package's `exportSequenceLogic` uses: an opener (if/while/for/…)
/// indents its body; a matching `NI_Flow_End` dedents; else/else-if render at the
/// opener's level. Depth never drops below 0, so an unbalanced block can't
/// underflow. Pure.
List<StepOutline> _withFlowDepth(List<Step> steps, SeqFile file) {
  final out = <StepOutline>[];
  var depth = 0;
  for (final step in steps) {
    final fc = step.flowControl;
    if (fc != null && fc.kind.closesBlock) {
      if (depth > 0) depth--;
      out.add(StepOutline.of(step, file, flowDepth: depth));
    } else if (fc != null && fc.kind.isContinuation) {
      out.add(StepOutline.of(step, file, flowDepth: depth > 0 ? depth - 1 : 0));
    } else if (fc != null && fc.kind.opensBlock) {
      out.add(StepOutline.of(step, file, flowDepth: depth));
      depth++;
    } else {
      out.add(StepOutline.of(step, file, flowDepth: depth));
    }
  }
  return out;
}

/// A named group of steps (Setup / Main / Cleanup).
class StepGroupOutline {
  StepGroupOutline(this.name, this.steps);
  final String name;
  final List<StepOutline> steps;
}

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
    final t = target;
    if (t == null) return null;
    final label = pathBasename(t);
    return (label: label.isEmpty ? t : label, tooltip: t);
  }

  factory StepOutline.of(Step step, SeqFile file, {int flowDepth = 0}) {
    final m = step.module;
    String? adapter;
    String? target;
    int? callTargetIndex;
    String? externalCall;
    if (m.adapter != SeqAdapter.none) {
      adapter = m.adapter.name;
      target = switch (m.adapter) {
        SeqAdapter.python => m.target ?? '(target not yet recovered)',
        _ => m.target ?? '(none)',
      };
      if (m.adapter == SeqAdapter.sequenceCall) {
        final resolved = file.resolveCall(step);
        if (resolved != null) {
          callTargetIndex = file.sequences.indexOf(resolved);
        } else {
          externalCall = m.sequenceFile ?? '';
        }
      }
    }

    final s = step.settings;
    final runMode = s.isNormalMode ? null : s.mode;
    final notes = <String>[];
    if (s.flowSummary != null) notes.add('flow ${s.flowSummary}');
    // Custom-condition jump targets, with `ID#:` step references resolved to the
    // destination step's name (bookmarks like <Cleanup> shown verbatim).
    String resolveTarget(String t) =>
        t.startsWith('ID#:') ? (file.stepNameForId(t) ?? t) : t;
    if (s.customTrueTarget != null) {
      notes.add('cust-true→${resolveTarget(s.customTrueTarget!)}');
    }
    if (s.customFalseTarget != null) {
      notes.add('cust-false→${resolveTarget(s.customFalseTarget!)}');
    }
    // LabVIEW VI-call library/project (parity with the dump's {vi:} chip); the
    // connector pane rides in [connectorParams] below.
    if (m.adapter == SeqAdapter.labView) {
      final lv = <String>[];
      if (m.viNamespace != null) lv.add('lib ${m.viNamespace}');
      if (m.viProjectPath != null) lv.add('proj ${m.viProjectPath}');
      if (lv.isNotEmpty) notes.add('vi: ${lv.join(', ')}');
    }
    // Python call module/class/interpreter (parity with the dump's {python:}
    // chip); the called function is already the module target.
    if (m.adapter == SeqAdapter.python) {
      final py = <String>[];
      if (m.pythonModulePath != null) py.add('mod ${m.pythonModulePath}');
      if (m.pythonClassName != null) py.add('class ${m.pythonClassName}');
      if (m.pythonVersion != null) py.add('py ${m.pythonVersion}');
      if (py.isNotEmpty) notes.add('python: ${py.join(', ')}');
    }
    // Module load/unload timing, only when non-default.
    if (s.loadOption != null && s.loadOption != 'PreloadWhenExecuted') {
      notes.add('load ${s.loadOption}');
    }
    if (s.unloadOption != null && s.unloadOption != 'UnloadWithFile') {
      notes.add('unload ${s.unloadOption}');
    }
    if (s.isLooping) notes.add('loop ${s.loopType}');
    // Notable non-default execution flags (same set the text dump surfaces).
    if (s.ignoresRunTimeErrors == true) notes.add('ignore-RTE');
    if (s.failureCausesSequenceFailure == false) notes.add('no-seq-fail');
    if (s.recordsResult == false) notes.add('no-record');
    // "Additional Results" recording spec: the extra values the step logs to the
    // report, each with its gating condition when set (parity with the dump's
    // {+results} chip). Flags/CheckedState are not yet decoded, so omitted.
    final addl = step.additionalResults;
    if (addl.isNotEmpty) {
      String fmt(AdditionalResult a) =>
          a.condition != null ? '${a.name} if ${a.condition}' : a.name;
      notes.add('+results: ${addl.map(fmt).join(', ')}');
    }
    // Step mutex synchronization, only when the step actually locks one (parity
    // with the dump's `mutex` note; default-off in the corpus).
    if (s.usesMutex == true) {
      notes.add('mutex${s.mutexName != null ? ' ${s.mutexName}' : ''}');
    }
    // A recorded run outcome (Result), shown only when non-default (a sequence
    // file's un-run steps hold only defaults → nothing shown). Parity with the
    // dump's {result:…} chip.
    final res = step.result;
    if (res != null && res.hasRecordedOutcome) {
      final r = <String>[];
      if (res.status != null) r.add('status ${res.status}');
      if (res.errorOccurred == true) {
        final code = res.errorCode;
        r.add('error${code != null ? ' $code' : ''}');
      }
      if (res.reportText != null) r.add('report "${res.reportText}"');
      if (r.isNotEmpty) notes.add('result ${r.join('; ')}');
    }

    // The step's set expressions, in editor order. Shown as their own rows (they
    // can be long); precondition lives here too (was a note before).
    final expressions = <(String, String)>[
      if (s.precondition != null) ('Precondition', s.precondition!),
      // The custom-condition expression (the step's own true/false branch test).
      if (s.customExpression != null) ('Custom condition', s.customExpression!),
      if (s.preExpression != null) ('Pre-expression', s.preExpression!),
      if (s.postExpression != null) ('Post-expression', s.postExpression!),
      if (s.statusExpression != null) ('Status', s.statusExpression!),
      // The loop block (init → while → increment → status) for a looping step.
      if (s.loopInitialize != null) ('Loop init', s.loopInitialize!),
      if (s.loopWhile != null) ('Loop while', s.loopWhile!),
      if (s.loopIncrement != null) ('Loop increment', s.loopIncrement!),
      if (s.loopStatus != null) ('Loop status', s.loopStatus!),
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
      callArgs: [for (final p in m.callParameters) CallArgOutline.of(p)],
      measurementParams: [
        for (final p in step.measurementParameters)
          MeasurementParamOutline.of(p),
      ],
      connectorParams: [
        for (final p in m.viParameters) ConnectorParamOutline.of(p),
      ],
      flowHeader: step.flowControl?.header,
      flowDepth: flowDepth,
      notes: notes,
    );
  }

  /// A one-line label, equivalent to the dump view's per-step line (minus the
  /// in-file/external tag, which the UI renders as a tappable chip).
  String get summary {
    final b = StringBuffer('$name [$type]');
    if (flowHeader != null) b.write('  {flow: $flowHeader}');
    if (adapter != null) b.write(' -> $adapter: $target');
    if (limits != null) {
      b.write('  {limits $limits${units != null ? ' $units' : ''}}');
    } else if (units != null) {
      b.write('  {units $units}');
    }
    // Data source standalone only for non-limit steps (limit steps carry it in
    // limitsDetail), matching the dump.
    if (limitsDetail == null && dataSource != null) {
      b.write('  {data-source $dataSource}');
    }
    if (runMode != null) b.write('  {mode $runMode}');
    if (comment != null) b.write('  // $comment');
    if (notes.isNotEmpty) b.write('  (${notes.join('; ')})');
    for (final (label, value) in expressions) {
      b.write('  {$label: $value}');
    }
    if (callArgs.isNotEmpty) {
      b.write('  {args: ${callArgs.map((a) => a.line).join('; ')}}');
    }
    if (measurementParams.isNotEmpty) {
      b.write('  {params: ${measurementParams.map((p) => p.line).join('; ')}}');
    }
    if (connectorParams.isNotEmpty) {
      b.write('  {conn: ${connectorParams.map((p) => p.line).join('; ')}}');
    }
    return b.toString();
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
    final b = StringBuffer();
    if (displayType != null) b.write(displayType);
    if (boundExpression != null) b.write('${b.isEmpty ? '' : ' '}←$boundExpression');
    return b.isEmpty ? '(unwired)' : b.toString();
  }

  /// Compact one-line form for the text summary / search, mirroring the dump's
  /// `_dumpViParam`: `#11 sequence context (Object Reference)←ThisContext`.
  String get line {
    final b = StringBuffer();
    if (connectorNumber != null) b.write('#$connectorNumber ');
    b.write(name);
    if (displayType != null) b.write(' ($displayType)');
    if (boundExpression != null) b.write('←$boundExpression');
    return b.toString();
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
    final b = StringBuffer(name);
    if (direction != null) b.write(' $direction');
    if (boundExpression != null) b.write('←$boundExpression');
    return b.toString();
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
        enumValues: [for (final e in p.enumValues) '${e.name}=${e.value ?? '?'}'],
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
    final b = StringBuffer();
    if (dataType != null) {
      b.write(dataType);
      if (typeSpecialization != null) b.write(' ($typeSpecialization)');
      if (isArray) b.write('[]');
    }
    if (value != null) b.write('${b.isEmpty ? '' : ' '}= $value');
    if (enumValues.isNotEmpty) b.write('${b.isEmpty ? '' : ' '}$_enumChip');
    if (logged == false) b.write('${b.isEmpty ? '' : ' '}· not logged');
    return b.isEmpty ? '(unbound)' : b.toString();
  }

  /// Compact one-line form for the text summary / search, e.g.
  /// `voltage_level in TypeDouble = 6`.
  String get line {
    final b = StringBuffer(name);
    if (direction != null) b.write(' ${direction!.toLowerCase()}');
    if (dataType != null) {
      b.write(' $dataType');
      if (typeSpecialization != null) b.write(' ($typeSpecialization)');
      if (isArray) b.write('[]');
    }
    if (value != null) b.write(' = $value');
    // All enum values in the search/summary line (not capped, so every constant
    // is searchable).
    if (enumValues.isNotEmpty) b.write(' {${enumValues.join(', ')}}');
    if (logged == false) b.write(' [not logged]');
    return b.toString();
  }
}

/// `n label` with the label pluralized (`label + 's'`) unless `n == 1`.
String _count(int n, String label) => '$n $label${n == 1 ? '' : 's'}';

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
  for (final n in s.notes) {
    if (n.toLowerCase().contains(query)) return true;
  }
  for (final (label, value) in s.expressions) {
    if (label.toLowerCase().contains(query) ||
        value.toLowerCase().contains(query)) {
      return true;
    }
  }
  for (final a in s.callArgs) {
    if (a.name.toLowerCase().contains(query) ||
        (a.boundExpression?.toLowerCase().contains(query) ?? false) ||
        (a.displayType?.toLowerCase().contains(query) ?? false)) {
      return true;
    }
  }
  for (final p in s.measurementParams) {
    if (p.line.toLowerCase().contains(query)) return true;
  }
  for (final p in s.connectorParams) {
    if (p.line.toLowerCase().contains(query)) return true;
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
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return outline;
  final kept = <SequenceOutline>[];
  for (final seq in outline.sequences) {
    if (seq.name.toLowerCase().contains(q) ||
        (seq.comment?.toLowerCase().contains(q) ?? false)) {
      kept.add(seq); // whole-sequence match → keep everything
      continue;
    }
    final varHit =
        seq.parameters.any((v) => _varMatches(v, q)) ||
        seq.locals.any((v) => _varMatches(v, q));
    final groups = <StepGroupOutline>[];
    for (final g in seq.groups) {
      final steps = g.steps.where((s) => stepMatches(s, q)).toList();
      if (steps.isNotEmpty) groups.add(StepGroupOutline(g.name, steps));
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
    final b = StringBuffer('$name : ${type ?? '(untyped)'}');
    if (value != null) {
      b.write(' = $value');
    } else if (containerCount != null) {
      b.write(isArray
          ? ' [$containerCount]'
          : ' {$containerCount ${containerCount == 1 ? 'field' : 'fields'}}');
    }
    if (comment != null) b.write('  // $comment');
    return b.toString();
  }
}
