import 'package:labwright_core/labwright_core.dart';

/// A unit of work to distribute (a test or a requirement), tagged with the
/// hardware labels it needs (e.g. `{'labjack', 'dut-rev-c'}`).
class TestUnit {
  const TestUnit(this.id, {this.requires = const {}});

  /// Stable identifier for this unit of work.
  final String id;

  /// Hardware labels a worker must advertise to run this unit.
  final Set<String> requires;
}

/// A lab worker (a self-hosted runner) and the hardware labels it advertises.
class Worker {
  const Worker(this.id, {this.labels = const {}});

  /// The worker's identifier (e.g. the self-hosted runner name).
  final String id;

  /// Hardware labels this worker advertises.
  final Set<String> labels;

  /// True if this worker has every label the unit requires.
  bool canRun(TestUnit unit) => unit.requires.every(labels.contains);
}

/// A unit that couldn't be scheduled with the requested redundancy.
class UnschedulableTest {
  const UnschedulableTest({
    required this.testId,
    required this.capableWorkers,
    required this.requested,
    required this.reason,
  });
  /// The unit that couldn't be placed.
  final String testId;

  /// How many workers could actually run it.
  final int capableWorkers;

  /// The redundancy that was requested.
  final int requested;

  /// Human-readable explanation (no capable worker, or too few).
  final String reason;
}

/// The result of sharding: which units each worker runs, which workers run each
/// unit (one entry per redundant copy), and anything that couldn't be placed.
class ShardPlan {
  ShardPlan({required this.byWorker, required this.byTest, required this.unschedulable});
  /// Unit ids assigned to each worker id.
  final Map<String, List<String>> byWorker;

  /// Worker ids running each unit id (one entry per redundant copy).
  final Map<String, List<String>> byTest;

  /// Units that couldn't be placed with the requested redundancy.
  final List<UnschedulableTest> unschedulable;

  /// True when every unit was placed (nothing [unschedulable]).
  bool get fullyScheduled => unschedulable.isEmpty;

  Map<String, Object?> toJson() => {
        'byWorker': byWorker,
        'byTest': byTest,
        'unschedulable': [
          for (final u in unschedulable)
            {'testId': u.testId, 'capableWorkers': u.capableWorkers, 'requested': u.requested, 'reason': u.reason},
        ],
      };
}

/// Shards [tests] across [workers], placing each unit on [redundancy] distinct
/// capable workers, greedily balancing load. Deterministic (ties break by worker
/// id). Units without enough capable workers are reported in
/// [ShardPlan.unschedulable] and left unassigned.
ShardPlan shardTests(List<TestUnit> tests, List<Worker> workers, {int redundancy = 1}) {
  if (redundancy < 1) {
    throw ArgumentError.value(redundancy, 'redundancy', 'must be >= 1');
  }
  final load = {for (final w in workers) w.id: 0};
  final byWorker = {for (final w in workers) w.id: <String>[]};
  final byTest = <String, List<String>>{};
  final unschedulable = <UnschedulableTest>[];

  for (final t in tests) {
    final capable = [for (final w in workers) if (w.canRun(t)) w];
    if (capable.length < redundancy) {
      unschedulable.add(UnschedulableTest(
        testId: t.id,
        capableWorkers: capable.length,
        requested: redundancy,
        reason: capable.isEmpty
            ? 'no worker has the required labels ${t.requires}'
            : 'only ${capable.length} of $redundancy required capable workers',
      ));
      continue;
    }
    capable.sort((a, b) {
      final byLoad = load[a.id]!.compareTo(load[b.id]!);
      return byLoad != 0 ? byLoad : a.id.compareTo(b.id);
    });
    for (final w in capable.take(redundancy)) {
      byWorker[w.id]!.add(t.id);
      (byTest[t.id] ??= []).add(w.id);
      load[w.id] = load[w.id]! + 1;
    }
  }

  return ShardPlan(byWorker: byWorker, byTest: byTest, unschedulable: unschedulable);
}

/// How well redundant runs of a unit agreed.
enum Agreement { unanimous, majority, tie }

/// The merged verdict for one unit across its redundant runs.
class MergedResult {
  const MergedResult({
    required this.testId,
    required this.outcome,
    required this.agreement,
    required this.votes,
  });
  /// The unit these runs belong to.
  final String testId;

  /// The chosen (most-voted; ties → worst) outcome.
  final Outcome outcome;

  /// How well the redundant runs agreed.
  final Agreement agreement;

  /// Vote count per distinct outcome across the runs.
  final Map<Outcome, int> votes;

  /// True only when every redundant run agreed ([Agreement.unanimous]).
  bool get consistent => agreement == Agreement.unanimous;
}

/// Merges the outcomes of redundant runs of one unit. Picks the most-voted
/// outcome; ties break toward the **worst** outcome (conservative — a failure
/// seen by any redundant run is not hidden by a tie). `Outcome.index` is the
/// severity (the enum is declared in increasing-severity order).
MergedResult mergeRuns(String testId, List<Outcome> outcomes) {
  if (outcomes.isEmpty) {
    throw ArgumentError.value(outcomes, 'outcomes', 'must not be empty');
  }
  final votes = <Outcome, int>{};
  for (final o in outcomes) {
    votes[o] = (votes[o] ?? 0) + 1;
  }
  final ranked = votes.entries.toList()
    ..sort((a, b) {
      final byCount = b.value.compareTo(a.value);
      return byCount != 0 ? byCount : b.key.index.compareTo(a.key.index);
    });

  final Agreement agreement;
  if (votes.length == 1) {
    agreement = Agreement.unanimous;
  } else if (ranked.length > 1 && ranked[0].value == ranked[1].value) {
    agreement = Agreement.tie;
  } else {
    agreement = Agreement.majority;
  }

  return MergedResult(testId: testId, outcome: ranked.first.key, agreement: agreement, votes: votes);
}

/// Merges every unit's redundant runs.
List<MergedResult> mergeAll(Map<String, List<Outcome>> runsByTest) =>
    [for (final e in runsByTest.entries) mergeRuns(e.key, e.value)];

/// The merged results whose redundant runs disagreed (flaky / inconsistent).
List<MergedResult> inconsistentResults(Iterable<MergedResult> results) =>
    [for (final r in results) if (!r.consistent) r];
