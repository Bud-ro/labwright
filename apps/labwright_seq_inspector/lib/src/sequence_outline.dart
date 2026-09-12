import 'package:labwright_seq/labwright_seq.dart';

export 'step_outline.dart';

import 'step_outline.dart';

String pathBasename(String path) {
  final sepIndex = path.lastIndexOf(RegExp(r'[/\\]'));
  return sepIndex >= 0 ? path.substring(sepIndex + 1) : path;
}

class SeqOutline {
  SeqOutline(this.sequences, {this.plugins});

  final List<SequenceOutline> sequences;

  final MeasurementPluginsOutline? plugins;

  factory SeqOutline.of(SeqFile file) {
    final mp = file.measurementPlugIns;
    return SeqOutline(
      [for (final seq in file.sequences) SequenceOutline.of(seq, file)],
      plugins: mp != null && mp.isNotEmpty
          ? MeasurementPluginsOutline.of(mp)
          : null,
    );
  }

  int get totalSteps => sequences.fold(0, (n, s) => n + s.stepCount);

  int? indexOf(String name) {
    for (var i = 0; i < sequences.length; i++) {
      if (sequences[i].name == name) return i;
    }
    return null;
  }
}

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

  List<(String, String)> get rows => [
    if (pinMap case final path?) ('Pin map', path),
    if (specifications.isNotEmpty)
      ('Specifications', specifications.join(', ')),
    if (levels.isNotEmpty) ('Levels', levels.join(', ')),
    if (timing.isNotEmpty) ('Timing', timing.join(', ')),
    if (patterns.isNotEmpty) ('Patterns', patterns.join(', ')),
  ];
}

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

  final String? comment;

  final List<StepGroupOutline> groups;

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

class StepGroupOutline {
  StepGroupOutline(this.name, this.steps);
  final String name;
  final List<StepOutline> steps;
}
