import 'dart:io';

import 'package:test/test.dart';

import 'harness.dart';

const _allTests = {
  'rail comes up',
  'ripple in limits',
  'thermal camera sweep',
  'trip threshold',
  'still reachable after trip',
  'teardown throws',
};

(int, Map<String, Object?>) _runReport(String target, [List<String> extra = const []]) {
  final dir = Directory.systemTemp.createTempSync('lw_');
  try {
    final path = '${dir.path}/report.json';
    final result = cli(['run', target, '--no-viewer', '--no-identity', '--report', path, ...extra]);
    expect(result.exitCode, anyOf(0, 1), reason: 'crashed ($target $extra):\n${result.stdout}\n${result.stderr}');
    return (result.exitCode, jsonMap(File(path).readAsStringSync()));
  } finally {
    dir.deleteSync(recursive: true);
  }
}

void main() {
  test('run: a directory resolves to its main.dart; flags become defines;'
      ' the child exit code propagates', () {
    final (exit, report) = _runReport('test/fixtures/suite');
    expect(exit, 1, reason: 'the suite contains failures');
    expect(
      testsOf(report).map((t) => t['name']).toSet(),
      _allTests,
      reason: 'the plugged-in modules registered into ONE process',
    );
    final req9 = (report['requirements'] as Map<String, Object?>)['REQ-9'] as List;
    expect((req9.single as Map<String, Object?>)['status'], 'failed');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('run + shards + seed: the shards partition the suite, none missed', () {
    for (final seed in ['0', '7']) {
      final executed = <String>[];
      for (var index = 0; index < 2; index++) {
        final (_, report) = _runReport('test/fixtures/suite', [
          '--total-shards', '2', '--shard-index', '$index', '--seed', seed, //
        ]);
        expect(report['seed'], int.parse(seed));
        executed.addAll(testsOf(report).map((t) => t['name'] as String));
      }
      expect(executed, hasLength(_allTests.length), reason: 'seed $seed: every test exactly once across shards');
      expect(executed.toSet(), _allTests, reason: 'seed $seed: the union of shards is the whole suite');
    }
  }, timeout: const Timeout(Duration(minutes: 4)));
}
