import 'seq_file.dart';
import 'seq_property.dart';

/// How much of a sequence file's property tree the typed lens actually surfaces.
///
/// The analog of the VI reader's coverage metric: a `.seq` decodes into a large
/// PropertyObject tree, but only some nodes are given *typed meaning* by
/// `SeqFile`/`Sequence`/`Step`/`StepSettings`/`StepModule`/`SeqVariable`. This
/// counts every node in the `Data` tree (`total`) and how many the lens
/// explains (`modeled`) — honest about how much is still raw.
class SeqCoverage {
  const SeqCoverage({required this.total, required this.modeled});

  /// Total property nodes in the file's `Data` tree.
  final int total;

  /// Nodes the typed lens surfaces with meaning.
  final int modeled;

  double get ratio => total == 0 ? 0 : modeled / total;

  SeqCoverage operator +(SeqCoverage o) =>
      SeqCoverage(total: total + o.total, modeled: modeled + o.modeled);
}

/// The `TS` step-setting keys the lens surfaces (kept in sync with [StepSettings]
/// and [Step] — the step's unique id, run mode, module load/unload, precondition,
/// the four loop expressions, pre/post/status expressions, pass/fail actions and
/// their jump targets, the custom-condition expression + its true/false actions,
/// the step icon, and the boolean flags step-fail-causes-sequence-fail /
/// ignore-run-time-errors / record-result). Each is a `TS` child.
const _settingKeys = [
  'Id', 'Mode', 'LoadOpt', 'UnloadOpt', 'PreCond', 'Icon',
  'LoopType', 'LoopWhile', 'LoopInitialize', 'LoopIncrement', 'LoopStatus',
  'PreExpr', 'PostExpr', 'StatusExpr',
  'PassAct', 'FailAct',
  'PassActTarget', 'FailActTarget', 'CustTrueActTarget', 'CustFalseActTarget',
  'CustExpr', 'CustTrueAct', 'CustFalseAct',
  'StepFCSeqF', 'IgnoreRTE', 'ResultOption',
  'UseMutex', 'MutexNameOrRef',
];

/// Measures [SeqCoverage] for [f] (the `Data` tree only; the type list is
/// excluded as a separate concern). Modeled nodes are collected in a set that
/// dedupes by object identity ([SeqProperty] declares no custom `==`).
SeqCoverage measureCoverage(SeqFile f) {
  final modeled = <SeqProperty>{};
  void mark(SeqProperty? p) {
    if (p != null) modeled.add(p);
  }

  mark(f.data);
  mark(f.data.prop('Seq'));
  for (final seq in f.sequences) {
    mark(seq.raw);
    for (final g in ['Setup', 'Main', 'Cleanup']) {
      mark(seq.raw.prop(g));
    }
    mark(seq.raw.prop('Locals'));
    mark(seq.raw.prop('Parameters'));
    for (final v in [...seq.locals, ...seq.parameters]) {
      mark(v.raw);
    }
    for (final step in seq.steps) {
      mark(step.raw);
      final ts = step.raw.prop('TS');
      mark(ts);
      for (final k in _settingKeys) {
        mark(ts?.prop(k));
      }
      final sdata = step.module.raw;
      mark(sdata);
      for (final rec in ['ViCall', 'Call', 'PythonCall']) {
        mark(sdata?.prop(rec));
      }
      final viCall = sdata?.prop('ViCall');
      mark(viCall?.prop('VIPath'));
      for (final k in [
        'Namespace', 'ProjectPath', 'CallName', 'VIDescription', 'ShowFrnPnl',
      ]) {
        mark(viCall?.prop(k));
      }
      mark(viCall?.prop('Parms'));
      for (final p in step.module.viParameters) {
        mark(p.raw);
        for (final k in ['Label', 'DisplayType', 'ArgVal', 'Direction', 'ConnectorNumber']) {
          mark(p.raw.prop(k));
        }
      }
      mark(sdata?.prop('Call')?.prop('LibPath'));
      mark(sdata?.prop('Call')?.prop('Func'));
      mark(sdata?.prop('SeqName'));
      mark(sdata?.prop('SFPath'));
      final pyCall = sdata?.prop('PythonCall');
      for (final k in [
        'FunctionOrAttributeName', 'ModulePath', 'ClassName',
        'PythonVersion', 'PythonVirtualEnvironmentPath',
      ]) {
        mark(pyCall?.prop(k));
      }
      mark(sdata?.prop('Call')?.prop('Parameters'));
      mark(sdata?.prop('PythonCall')?.prop('Parameters'));
      for (final p in step.module.callParameters) {
        mark(p.raw);
        for (final k in ['Name', 'ArgVal', 'ArgumentValue', 'DisplayType', 'Direction']) {
          mark(p.raw.prop(k));
        }
      }
      if (step.flowControl != null) {
        for (final k in [
          'ConditionExpr', 'InitializationExpr', 'IncrementExpr',
          'ArrayExpr', 'ArrayElementExpr', 'OffsetExpr',
        ]) {
          mark(step.raw.prop(k));
        }
      }
      mark(step.raw.prop('Comp'));
      mark(step.raw.prop('DataSource'));
      final lim = step.raw.prop('Limits');
      mark(lim);
      for (final k in ['Low', 'High', 'Nominal', 'ThresholdType']) {
        mark(lim?.prop(k));
      }
      final result = step.raw.prop('Result');
      mark(result);
      mark(result?.prop('Units'));
      mark(result?.prop('Status'));
      mark(result?.prop('ReportText'));
      mark(result?.prop('Common'));
      final error = result?.prop('Error');
      mark(error);
      for (final k in ['Code', 'Msg', 'Occurred']) {
        mark(error?.prop(k));
      }
      void markAddl(SeqProperty p) {
        if (p.name == 'AdditionalResults') {
          mark(p);
          for (final e in [...p.subProps, ...?p.array]) {
            mark(e);
            mark(e.prop('Condition'));
          }
          return;
        }
        for (final c in [...p.subProps, ...?p.array]) {
          markAddl(c);
        }
      }

      markAddl(step.raw);
      final meas = step.raw.prop('Measurement');
      mark(meas);
      final mparams = meas?.prop('Parameters');
      mark(mparams);
      for (final p in step.measurementParameters) {
        mark(p.raw);
        for (final k in [
          'Name', 'Type', 'Direction', 'Dimension', 'ArgumentValue',
          'TypeSpecialization', 'Log', 'ID',
        ]) {
          mark(p.raw.prop(k));
        }
        final ed = p.raw.prop('EnumDefinition');
        mark(ed);
        for (final e in ed?.array ?? const <SeqProperty>[]) {
          mark(e);
        }
      }
    }
  }

  final mp = f.measurementPlugIns;
  if (mp != null) {
    mark(mp.raw);
    for (final k in [
      'PinMapPath', 'EnableMonitoring', 'SpecificationsFilePaths',
      'LevelsFilePaths', 'TimingFilePaths', 'PatternFilePaths',
    ]) {
      final node = mp.raw.prop(k);
      mark(node);
      for (final e in node?.array ?? const <SeqProperty>[]) {
        mark(e);
      }
    }
  }

  var total = 0;
  void count(SeqProperty p) {
    total++;
    for (final c in p.subProps) {
      count(c);
    }
    if (p.array != null) {
      for (final c in p.array!) {
        count(c);
      }
    }
  }

  count(f.data);
  return SeqCoverage(total: total, modeled: modeled.length);
}
