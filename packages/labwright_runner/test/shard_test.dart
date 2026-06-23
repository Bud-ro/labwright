import 'package:labwright_core/labwright_core.dart';
import 'package:labwright_runner/labwright_runner.dart';
import 'package:test/test.dart';

void main() {
  group('shardTests', () {
    final workers = [
      const Worker('w1', labels: {'labjack'}),
      const Worker('w2', labels: {'labjack', 'ni'}),
      const Worker('w3', labels: {'ni'}),
    ];

    test('places each unit on `redundancy` capable workers; flags the rest', () {
      final tests = [
        const TestUnit('t1', requires: {'labjack'}),
        const TestUnit('t2', requires: {'ni'}),
        const TestUnit('t3', requires: {'bluetooth'}),
      ];
      final plan = shardTests(tests, workers, redundancy: 2);

      expect(plan.byTest['t1']!.toSet(), {'w1', 'w2'});
      expect(plan.byTest['t2']!.toSet(), {'w2', 'w3'});
      expect(plan.byTest.containsKey('t3'), isFalse);
      expect(plan.unschedulable.single.testId, 't3');
      expect(plan.unschedulable.single.capableWorkers, 0);
      expect(plan.fullyScheduled, isFalse);
    });

    test('balances load and is deterministic', () {
      final ws = [const Worker('a', labels: {'x'}), const Worker('b', labels: {'x'})];
      final ts = [for (var i = 0; i < 4; i++) TestUnit('t$i', requires: const {'x'})];
      final p1 = shardTests(ts, ws);
      final p2 = shardTests(ts, ws);
      expect(p1.byWorker, p2.byWorker); // deterministic (deep equality)
      expect(p1.byWorker['a']!.length, 2);
      expect(p1.byWorker['b']!.length, 2);
    });

    test('rejects redundancy < 1', () {
      expect(() => shardTests(const [], const [], redundancy: 0), throwsArgumentError);
    });

    test('some-but-not-enough capable workers: unit is left unassigned, not partial', () {
      final ws = [const Worker('w1', labels: {'ni'}), const Worker('w2', labels: {'ni'})];
      final plan = shardTests([const TestUnit('t', requires: {'ni'})], ws, redundancy: 3);
      final u = plan.unschedulable.single;
      expect(u.testId, 't');
      expect(u.capableWorkers, 2);
      expect(u.requested, 3);
      expect(u.reason, contains('only 2 of 3'));
      expect(plan.byTest.containsKey('t'), isFalse); // not partially placed
      expect(plan.byWorker.values.every((l) => l.isEmpty), isTrue);
      expect(plan.fullyScheduled, isFalse);
    });

    test('default redundancy is 1: one capable worker per unit', () {
      final plan = shardTests([const TestUnit('t1', requires: {'labjack'})], workers);
      expect(plan.byTest['t1']!.length, 1);
      expect(plan.fullyScheduled, isTrue);
    });

    test('toJson surfaces the unschedulable detail', () {
      final plan = shardTests([const TestUnit('t', requires: {'none'})], workers);
      final json = plan.toJson();
      final unsched = (json['unschedulable']! as List).single as Map<String, Object?>;
      expect(unsched['testId'], 't');
      expect(unsched['capableWorkers'], 0);
      expect(unsched['requested'], 1);
    });
  });

  group('mergeRuns', () {
    test('unanimous', () {
      final m = mergeRuns('t', [Outcome.pass, Outcome.pass]);
      expect(m.outcome, Outcome.pass);
      expect(m.agreement, Agreement.unanimous);
      expect(m.consistent, isTrue);
    });

    test('majority wins but is flagged inconsistent', () {
      final m = mergeRuns('t', [Outcome.pass, Outcome.pass, Outcome.fail]);
      expect(m.outcome, Outcome.pass);
      expect(m.agreement, Agreement.majority);
      expect(m.consistent, isFalse);
    });

    test('ties break toward the worst outcome', () {
      final m = mergeRuns('t', [Outcome.pass, Outcome.fail]);
      expect(m.outcome, Outcome.fail);
      expect(m.agreement, Agreement.tie);
    });

    test('empty outcomes is an error', () {
      expect(() => mergeRuns('t', const []), throwsArgumentError);
    });

    test('a single run is unanimous', () {
      final m = mergeRuns('t', [Outcome.error]);
      expect(m.outcome, Outcome.error);
      expect(m.agreement, Agreement.unanimous);
      expect(m.votes, {Outcome.error: 1});
    });

    test('three runs: clear majority picks the consensus and tallies votes', () {
      final m = mergeRuns('t', [Outcome.fail, Outcome.pass, Outcome.fail]);
      expect(m.outcome, Outcome.fail);
      expect(m.agreement, Agreement.majority);
      expect(m.votes[Outcome.fail], 2);
      expect(m.votes[Outcome.pass], 1);
      expect(m.consistent, isFalse);
    });

    test('three-way 1-1-1 split is a tie that resolves to the worst outcome', () {
      final m = mergeRuns('t', [Outcome.pass, Outcome.error, Outcome.fail]);
      expect(m.outcome, Outcome.error); // highest severity
      expect(m.agreement, Agreement.tie);
    });
  });

  test('mergeAll + inconsistentResults surface flaky units', () {
    final merged = mergeAll({
      'a': [Outcome.pass, Outcome.pass],
      'b': [Outcome.pass, Outcome.fail],
    });
    expect(inconsistentResults(merged).map((r) => r.testId), ['b']);
  });
}
