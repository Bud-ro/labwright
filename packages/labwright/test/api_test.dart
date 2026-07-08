// Batch (non-interactive) runner contract: verdicts, report, ordering,
// sharding, seeds, identity hashes. Viewer/interactive HTTP behavior lives in
// viewer_test.dart; hot reload in hot_reload_test.dart.
import 'package:test/test.dart';

import 'harness.dart';

void main() {
  test('green fixture: registration then execution, real expect, skip green', () {
    final (exit, out, report) = runWithReport('test/fixtures/green_e2e.dart', defines: ['-Dlabwright.seed=0']);
    expect(exit, 0, reason: 'skipped alone must stay green:\n$out');
    final tests = testsOf(report);
    expect(tests.map((t) => t['name']), [
      'rail comes up',
      'ripple in limits',
      'thermal camera sweep',
    ], reason: 'seed 0 keeps registration order as execution order');
    expect(tests[0]['status'], 'passed', reason: 'async setup in main completed before any body');
    expect(tests[0]['requirements'], ['REQ-1']);
    expect(tests[0]['logs'], ['applying power'], reason: 'log lines attach to their test');
    expect(tests[1]['requirements'], ['REQ-2', 'REQ-3']);
    expect(tests[2]['status'], 'skipped', reason: 'skipTest reports without running the body');
    expect((report['summary'] as Map)['skipped'], 1);
  });

  test('red fixture: TestFailure=failed, other throw=error, exits non-zero', () {
    final (exit, out, report) = runWithReport('test/fixtures/red_e2e.dart', defines: ['-Dlabwright.seed=0']);
    expect(exit, isNot(0), reason: 'failures must fail CI');
    final tests = testsOf(report);
    expect(tests, hasLength(3), reason: 'a failed test does not stop later tests');
    expect(tests[0]['status'], 'failed');
    expect('${tests[0]['detail']}', contains('trip current'), reason: 'the matcher mismatch description is carried');
    expect(tests[1]['status'], 'passed');
    expect(tests[2]['status'], 'error', reason: 'a non-TestFailure escape is an error, not a failure');
    expect('${tests[2]['detail']}', contains('relay stuck'));
    final req9 = ((report['requirements'] as Map)['REQ-9'] as List).cast<Map<String, Object?>>();
    expect(req9.single['status'], 'failed', reason: 'the requirements trace maps IDs to test statuses');
    expect(out, contains('RUN  trip threshold'), reason: 'the start line names the test, nothing else');
  });

  test('sharding: plain index % N over the one in-process registry', () {
    final byShard = <int, List<Object?>>{};
    for (var i = 0; i < 2; i++) {
      final (exit, out, report) = runWithReport(
        'test/fixtures/green_e2e.dart',
        defines: ['-Dlabwright.totalShards=2', '-Dlabwright.shardIndex=$i'],
      );
      expect(exit, 0, reason: 'shard $i:\n$out');
      expect(report['seed'], 0x5EED, reason: 'no explicit seed + sharding = fixed shard seed for every runner');
      byShard[i] = testsOf(report).map((t) => t['name']).toList();
    }
    expect(byShard[0]!.toSet(), {'rail comes up', 'thermal camera sweep'}, reason: 'indices 0,2 land in shard 0');
    expect(byShard[1], ['ripple in limits'], reason: 'index 1 lands in shard 1');
  });

  test('seed: an explicit seed shuffles order deterministically, never the set', () {
    List<Object?> orderFor(int s) {
      final (exit, out, report) = runWithReport('test/fixtures/green_e2e.dart', defines: ['-Dlabwright.seed=$s']);
      expect(exit, 0, reason: out);
      expect(report['seed'], s, reason: 'the report carries the seed');
      if (s != 0) {
        expect(out, contains('[Labwright]: seed $s'), reason: 'a non-zero seed prints once, at suite start');
      }
      return testsOf(report).map((t) => t['name']).toList();
    }

    final registration = orderFor(0); // an explicit 0 keeps registration order
    final seeded = orderFor(1);
    expect(seeded.toSet(), registration.toSet(), reason: 'a seed permutes the order, never the set');
    expect(seeded, isNot(equals(registration)), reason: 'seed 1 reorders this fixture (verified permutation)');
    expect(orderFor(1), seeded, reason: 'the same seed reproduces the order');
  });

  test('unseeded, unsharded run mints and announces a random seed', () {
    final (exit, out, report) = runWithReport('test/fixtures/green_e2e.dart');
    expect(exit, 0);
    final s = report['seed'] as int;
    expect(s, isNot(0), reason: 'no seed + no sharding randomizes each run');
    expect(out, contains('[Labwright]: seed $s'), reason: 'the minted seed prints once, to reproduce');
  });

  test('late registration (after the run starts) dies loudly, not silently', () {
    final (exit, out, errText) = runSuite('test/bad_fixtures/late_registration_e2e.dart');
    expect(exit, isNot(0));
    expect(errText, contains('registered after the run started'), reason: 'the contract violation names itself');
    expect(out, contains('PASS registered in time'), reason: 'the in-time test still ran; the late one never joined');
  });

  test('human output: readable ASCII lines and a definite end-of-run summary', () {
    final (exit, out, _) = runSuite('test/fixtures/green_e2e.dart', defines: ['-Dlabwright.seed=0']);
    expect(exit, 0);
    expect(out, contains('RUN  rail comes up'), reason: 'plain ASCII, no requirement/seed noise');
    expect(out, contains('PASS rail comes up'));
    expect(out, contains('SKIP thermal camera sweep'));
    expect(out, isNot(contains('seed')), reason: 'seed 0 is registration order — nothing to announce');
    expect(out, contains('[Labwright]: 3 test(s) - 2 passed, 0 failed, 0 errors, 1 skipped'));
  });

  test('report identity: per-test hash, setupHash, context + contextHash, all deterministic', () {
    final hex40 = matches(RegExp(r'^[0-9a-f]{40}$'));
    (Map<String, Object?>, Map<Object?, Object?>) run() {
      final (exit, _, r) = runWithReport(
        'test/fixtures/green_e2e.dart',
        defines: ['-Dlabwright.seed=0'],
        identity: true,
      );
      expect(exit, 0);
      return (r, {for (final t in testsOf(r)) t['name']: t['hash']});
    }

    final (r1, hashes1) = run();
    expect(r1['setupHash'], hex40);
    expect(r1['context'], {'dut.serial': 'SIM-001'}, reason: 'the bench-declared context lands in the report');
    expect(r1['contextHash'], hex40);
    expect(hashes1.values, everyElement(hex40), reason: 'every test carries a content hash');
    expect(hashes1.values.toSet(), hasLength(3), reason: 'distinct tests hash distinctly');

    final (r2, hashes2) = run();
    expect(r2['setupHash'], r1['setupHash'], reason: 'unchanged sources produce identical hashes');
    expect(r2['contextHash'], r1['contextHash']);
    expect(hashes2, hashes1);
  });
}
