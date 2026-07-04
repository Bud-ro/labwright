import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// The labwright package root, whether the suite runs from the repo root or
/// the package dir (mirrors the corpus_dirs.dart convention).
final String pkgRoot = Directory('packages/labwright').existsSync()
    ? 'packages/labwright'
    : '.';

/// End-to-end tests of the `labwright` runner executable: sequential file
/// execution, aggregation, the JSON report with its requirements trace, CI
/// exit codes, and the live viewer endpoints.
void main() {
  test('runs a directory sequentially, aggregates, writes the report', () {
    final reportFile =
        File('${Directory.systemTemp.createTempSync('lw_').path}/report.json');
    final result = Process.runSync(
        Platform.resolvedExecutable,
        [
          'run',
          'bin/labwright.dart',
          'run',
          'test/fixtures',
          '--port',
          '0',
          '--report',
          reportFile.path,
        ],
        workingDirectory: pkgRoot);
    // red_e2e fails → runner exits non-zero.
    expect(result.exitCode, 1, reason: result.stdout.toString());
    final out = result.stdout.toString();
    expect(out, contains('viewer on http://localhost:'));
    expect(out, contains('collected 6 test(s)'),
        reason: 'the collect pass gathered the whole suite up front');
    expect(out, contains('green_e2e.dart'));
    expect(out, contains('red_e2e.dart'));
    expect(out,
        contains('6 test(s) — 3 passed, 1 failed, 1 errors, 1 skipped'));

    final report = (jsonDecode(reportFile.readAsStringSync()) as Map)
        .cast<String, Object?>();
    final summary = (report['summary'] as Map).cast<String, Object?>();
    expect(summary['failed'], 1);
    expect(summary['errors'], 1);
    expect(summary['skipped'], 1);
    // The requirements trace: every claimed ID maps to its tests + statuses.
    final requirements =
        (report['requirements'] as Map).cast<String, Object?>();
    expect(requirements.keys,
        containsAll(['REQ-1', 'REQ-2', 'REQ-3', 'REQ-9']));
    final req9 =
        (requirements['REQ-9'] as List).cast<Map<String, Object?>>();
    expect(req9.single['status'], 'failed');
    expect(req9.single['test'], 'trip threshold');
    reportFile.parent.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('sharding is GLOBAL: the modulo runs across files via the offset',
      () {
    String runShard(int index) {
      final result = Process.runSync(
          Platform.resolvedExecutable,
          [
            'run',
            'bin/labwright.dart',
            'run',
            'test/fixtures',
            '--port',
            '0',
            '--total-shards',
            '2',
            '--shard-index',
            '$index',
          ],
          workingDirectory: pkgRoot);
      // Global indices over the collected suite: green 0,1,2 then red
      // 3,4,5. Shard 0 = {0,2,4} = rail, thermal(skip), still-reachable —
      // all green. Shard 1 = {1,3,5} = ripple, trip(FAIL), teardown(ERROR).
      // A per-file modulo would have put a failure in BOTH shards — this
      // split is the proof the modulo ran over the whole collected list.
      expect(result.exitCode, index == 0 ? 0 : 1,
          reason: 'shard $index:\n${result.stdout}');
      return result.stdout.toString();
    }

    final shard0 = runShard(0);
    expect(shard0, contains('shard 0 of 2 (3 selected)'));
    expect(shard0, contains('still reachable after trip'),
        reason: 'red\'s middle test crossed into the green shard');
    expect(shard0,
        contains('3 test(s) — 2 passed, 0 failed, 0 errors, 1 skipped'));
    final shard1 = runShard(1);
    expect(shard1,
        contains('3 test(s) — 1 passed, 1 failed, 1 errors, 0 skipped'));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('no test is ever missed: shards partition the suite for any seed × N',
      () {
    const allTests = {
      'rail comes up',
      'ripple in limits',
      'thermal camera sweep',
      'trip threshold',
      'still reachable after trip',
      'teardown throws',
    };
    for (final totalShards in [2, 3]) {
      for (final seed in [0, 12345]) {
        final executed = <String>[];
        for (var index = 0; index < totalShards; index++) {
          final reportFile = File(
              '${Directory.systemTemp.createTempSync('lw_').path}/r.json');
          final result = Process.runSync(
              Platform.resolvedExecutable,
              [
                'run',
                'bin/labwright.dart',
                'run',
                'test/fixtures',
                '--port',
                '0',
                '--total-shards',
                '$totalShards',
                '--shard-index',
                '$index',
                '--seed',
                '$seed',
                '--report',
                reportFile.path,
              ],
              workingDirectory: pkgRoot);
          expect(result.exitCode, anyOf(0, 1),
              reason: 'shard $index/$totalShards seed $seed crashed:\n'
                  '${result.stdout}\n${result.stderr}');
          final report = (jsonDecode(reportFile.readAsStringSync()) as Map)
              .cast<String, Object?>();
          expect(report['seed'], seed, reason: 'the report carries the seed');
          for (final f
              in (report['files'] as List).cast<Map<String, Object?>>()) {
            for (final t
                in (f['tests'] as List).cast<Map<String, Object?>>()) {
              executed.add(t['name'] as String);
            }
          }
          reportFile.parent.deleteSync(recursive: true);
        }
        expect(executed, hasLength(allTests.length),
            reason: 'seed $seed, $totalShards shards: every test exactly '
                'once — none missed, none duplicated');
        expect(executed.toSet(), allTests,
            reason: 'seed $seed, $totalShards shards: union of shards is '
                'the whole suite');
      }
    }
  }, timeout: const Timeout(Duration(minutes: 4)));

  test('viewer serves the page, state.json (with logs), --keep-open persists',
      () async {
    final process = await Process.start(
        Platform.resolvedExecutable,
        [
          'run',
          'bin/labwright.dart',
          'run',
          'test/fixtures/green_e2e.dart',
          '--port',
          '0',
          '--keep-open',
        ],
        workingDirectory: pkgRoot);
    try {
      final port = Completer<int>();
      final done = Completer<void>();
      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        final m = RegExp(r'viewer on http://localhost:(\d+)').firstMatch(line);
        if (m != null && !port.isCompleted) port.complete(int.parse(m[1]!));
        if (line.contains('--keep-open') && !done.isCompleted) {
          done.complete();
        }
      });
      final p = await port.future.timeout(const Duration(seconds: 30));
      await done.future.timeout(const Duration(seconds: 60));

      final client = HttpClient();
      final stateReq =
          await client.getUrl(Uri.parse('http://localhost:$p/state.json'));
      final stateRes = await stateReq.close();
      expect(stateRes.statusCode, 200);
      final state = (jsonDecode(await stateRes.transform(utf8.decoder).join())
              as Map)
          .cast<String, Object?>();
      expect(state['done'], true);
      final files = (state['files'] as List).cast<Map<String, Object?>>();
      final tests =
          (files.single['tests'] as List).cast<Map<String, Object?>>();
      expect(tests, hasLength(3));
      expect(tests.first['name'], 'rail comes up');
      expect(tests.first['status'], 'passed');
      expect(tests.first['logs'], ['applying power'],
          reason: 'logs attach to their test for the viewer');
      expect(tests.last['status'], 'skipped');

      final pageReq = await client.getUrl(Uri.parse('http://localhost:$p/'));
      final pageRes = await pageReq.close();
      expect(pageRes.statusCode, 200);
      final page = await pageRes.transform(utf8.decoder).join();
      expect(page, contains('labwright run'));
      expect(page, contains('EventSource'), reason: 'live SSE viewer');
      client.close(force: true);
    } finally {
      process.kill();
      await process.exitCode;
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
