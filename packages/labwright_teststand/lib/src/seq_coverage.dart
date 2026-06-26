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
/// their jump targets, and the step icon). Each is a direct `TS` child.
const _settingKeys = [
  'Id', 'Mode', 'LoadOpt', 'UnloadOpt', 'PreCond', 'Icon',
  'LoopType', 'LoopWhile', 'LoopInitialize', 'LoopIncrement', 'LoopStatus',
  'PreExpr', 'PostExpr', 'StatusExpr',
  'PassAct', 'FailAct',
  'PassActTarget', 'FailActTarget', 'CustTrueActTarget', 'CustFalseActTarget',
];

/// Measures [SeqCoverage] for [f] (the `Data` tree only; the type list is
/// excluded as a separate concern).
SeqCoverage measureCoverage(SeqFile f) {
  // Identity set — SeqProperty has no custom ==, so this dedupes by object.
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
      // The adapter records and the specific fields the lens extracts.
      for (final rec in ['ViCall', 'Call', 'PythonCall']) {
        mark(sdata?.prop(rec));
      }
      mark(sdata?.prop('ViCall')?.prop('VIPath'));
      mark(sdata?.prop('Call')?.prop('LibPath'));
      mark(sdata?.prop('Call')?.prop('Func'));
      mark(sdata?.prop('SeqName'));
      mark(sdata?.prop('SFPath'));
      // Module call arguments: the `Call.Parameters` container and the fields
      // each `CallParameter` surfaces.
      mark(sdata?.prop('Call')?.prop('Parameters'));
      for (final p in step.module.callParameters) {
        mark(p.raw);
        for (final k in ['Name', 'ArgVal', 'DisplayType', 'Direction']) {
          mark(p.raw.prop(k));
        }
      }
      // Limit-test criteria.
      mark(step.raw.prop('Comp'));
      mark(step.raw.prop('DataSource'));
      final lim = step.raw.prop('Limits');
      mark(lim);
      for (final k in ['Low', 'High', 'Nominal', 'ThresholdType']) {
        mark(lim?.prop(k));
      }
      // Recorded result: the `Result` sub-object the lens navigates and the
      // `Units` leaf it reads (Step.resultUnits).
      final result = step.raw.prop('Result');
      mark(result);
      mark(result?.prop('Units'));
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
