import 'package:labwright_teststand/labwright_teststand.dart';

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
  SeqOutline(this.sequences);

  final List<SequenceOutline> sequences;

  /// Builds the outline for [file]. Pure.
  factory SeqOutline.of(SeqFile file) => SeqOutline([
    for (final seq in file.sequences) SequenceOutline.of(seq, file),
  ]);

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
        StepGroupOutline(group.key, [
          for (final s in steps) StepOutline.of(s, file),
        ]),
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
    this.runMode,
    this.comment,
    this.expressions = const [],
    required this.notes,
  });

  final String name;
  final String type;

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

  /// The step's TestStand expressions that are set (label → expression), in
  /// editor order: precondition, pre/post/status expressions, loop-while. Empty
  /// when the step uses none. These are the custom logic the editor surfaces but
  /// are too long for a chip, so the UI shows them as their own rows.
  final List<(String, String)> expressions;

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

  factory StepOutline.of(Step step, SeqFile file) {
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
    if (s.isLooping) notes.add('loop ${s.loopType}');

    // The step's set expressions, in editor order. Shown as their own rows (they
    // can be long); precondition lives here too (was a note before).
    final expressions = <(String, String)>[
      if (s.precondition != null) ('Precondition', s.precondition!),
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
      runMode: runMode,
      comment: step.comment,
      expressions: expressions,
      notes: notes,
    );
  }

  /// A one-line label, equivalent to the dump view's per-step line (minus the
  /// in-file/external tag, which the UI renders as a tappable chip).
  String get summary {
    final b = StringBuffer('$name [$type]');
    if (adapter != null) b.write(' -> $adapter: $target');
    if (limits != null) b.write('  {limits $limits}');
    if (runMode != null) b.write('  {mode $runMode}');
    if (comment != null) b.write('  // $comment');
    if (notes.isNotEmpty) b.write('  (${notes.join('; ')})');
    for (final (label, value) in expressions) {
      b.write('  {$label: $value}');
    }
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
/// name, type, adapter, target, limits summary, or any note.
bool stepMatches(StepOutline s, String query) {
  if (query.isEmpty) return true;
  bool hit(String? x) => x != null && x.toLowerCase().contains(query);
  if (hit(s.name) ||
      hit(s.type) ||
      hit(s.adapter) ||
      hit(s.target) ||
      hit(s.limits) ||
      hit(s.runMode)) {
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
  return false;
}

bool _varMatches(VarOutline v, String query) =>
    v.name.toLowerCase().contains(query) ||
    (v.type?.toLowerCase().contains(query) ?? false) ||
    (v.value?.toLowerCase().contains(query) ?? false);

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
