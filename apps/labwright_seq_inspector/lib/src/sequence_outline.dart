import 'package:labwright_seq/labwright_seq.dart';

export 'step_outline.dart';

import 'step_outline.dart';

/// The last path segment of [path], handling both `/` and `\` separators. The
/// single source of truth for basename extraction across the app (file labels in
/// `main.dart`, module-target display in [StepOutline.targetDisplay]). Returns
/// the empty string when [path] ends in a separator; callers that need a
/// non-empty fallback handle that themselves.
String pathBasename(String path) {
  final sepIndex = path.lastIndexOf(RegExp(r'[/\\]'));
  return sepIndex >= 0 ? path.substring(sepIndex + 1) : path;
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
    if (specifications.isNotEmpty)
      ('Specifications', specifications.join(', ')),
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
      groups.add(StepGroupOutline(group.key, _withFlowDepth(steps, file)));
    }
    return SequenceOutline(
      name: seq.name,
      parameters: [
        for (final variable in seq.parameters) VarOutline.of(variable),
      ],
      locals: [for (final variable in seq.locals) VarOutline.of(variable)],
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
