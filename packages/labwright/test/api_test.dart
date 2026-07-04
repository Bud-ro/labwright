import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// The labwright package root, whether the suite runs from the repo root or
/// the package dir (mirrors the corpus_dirs.dart convention).
final String pkgRoot = Directory('packages/labwright').existsSync()
    ? 'packages/labwright'
    : '.';

const _noViewer = '-Dlabwright.viewer=false';

/// Runs a suite the only way suites run — ONE process, `dart run`, all
/// configuration as Dart defines — and returns (exitCode, stdout, stderr).
(int, String, String) _run(String file, {List<String> defines = const []}) {
  final result = Process.runSync(
    Platform.resolvedExecutable,
    ['run', _noViewer, ...defines, file],
    workingDirectory: pkgRoot,
  );
  return (result.exitCode, result.stdout.toString(), result.stderr.toString());
}

/// Runs [file] with a report define and returns (exitCode, stdout, report).
(int, String, Map<String, Object?>) _runWithReport(String file,
    {List<String> defines = const []}) {
  final dir = Directory.systemTemp.createTempSync('lw_');
  try {
    final path = '${dir.path}/report.json';
    final (exit, out, _) =
        _run(file, defines: ['-Dlabwright.report=$path', ...defines]);
    final report =
        (jsonDecode(File(path).readAsStringSync()) as Map)
            .cast<String, Object?>();
    return (exit, out, report);
  } finally {
    dir.deleteSync(recursive: true);
  }
}

List<Map<String, Object?>> _tests(Map<String, Object?> report) =>
    (report['tests'] as List).cast<Map<String, Object?>>();

void main() {
  test('green fixture: registration then execution, real expect, skip green',
      () {
    final (exit, out, report) =
        _runWithReport('test/fixtures/green_e2e.dart');
    expect(exit, 0, reason: 'skipped alone must stay green:\n$out');
    final tests = _tests(report);
    expect(tests.map((t) => t['name']), [
      'rail comes up',
      'ripple in limits',
      'thermal camera sweep',
    ], reason: 'registration order is execution order');
    expect(tests[0]['status'], 'passed',
        reason: 'async setup at the top of main completed before any body; '
            'package:test expect/expectLater/matchers work as-is');
    expect(tests[0]['requirements'], ['REQ-1']);
    expect(tests[0]['logs'], ['applying power'],
        reason: 'log lines attach to their test in the report');
    expect(tests[1]['requirements'], ['REQ-2', 'REQ-3']);
    expect(tests[2]['status'], 'skipped',
        reason: 'skipTest reports without running the body');
    expect((report['summary'] as Map)['skipped'], 1);
  });

  test('red fixture: TestFailure=failed, other throw=error, exits non-zero',
      () {
    final (exit, out, report) = _runWithReport('test/fixtures/red_e2e.dart');
    expect(exit, isNot(0), reason: 'failures must fail CI');
    final tests = _tests(report);
    expect(tests, hasLength(3),
        reason: 'a failed test does not stop later tests');
    expect(tests[0]['status'], 'failed');
    expect('${tests[0]['detail']}', contains('trip current'),
        reason: 'the matcher mismatch description is carried');
    expect(tests[1]['status'], 'passed');
    expect(tests[2]['status'], 'error',
        reason: 'a non-TestFailure escape is an error, not a failure');
    expect('${tests[2]['detail']}', contains('relay stuck'));
    // The requirements trace maps each ID to its tests and statuses.
    final req9 = ((report['requirements'] as Map)['REQ-9'] as List)
        .cast<Map<String, Object?>>();
    expect(req9.single['status'], 'failed');
    expect(out, contains('▶ trip threshold [REQ-9] (seed 0)'));
  });

  test('sharding: plain index % N over the one in-process registry', () {
    final byShard = <int, List<Object?>>{};
    for (var i = 0; i < 2; i++) {
      final (exit, out, report) = _runWithReport(
          'test/fixtures/green_e2e.dart',
          defines: [
            '-Dlabwright.totalShards=2',
            '-Dlabwright.shardIndex=$i',
          ]);
      expect(exit, 0, reason: 'shard $i:\n$out');
      byShard[i] = _tests(report).map((t) => t['name']).toList();
    }
    expect(byShard[0], ['rail comes up', 'thermal camera sweep'],
        reason: 'indices 0,2 land in shard 0');
    expect(byShard[1], ['ripple in limits'],
        reason: 'index 1 lands in shard 1');
  });

  test('seed: printed on every test start, shuffles order, never the set',
      () {
    final (exit0, _, report0) =
        _runWithReport('test/fixtures/green_e2e.dart');
    expect(exit0, 0);
    final order0 = _tests(report0).map((t) => t['name']).toList();

    List<Object?> runSeeded() {
      final (exit, out, report) = _runWithReport(
          'test/fixtures/green_e2e.dart',
          defines: ['-Dlabwright.seed=1']);
      expect(exit, 0, reason: out);
      expect(out, contains('(seed 1)'),
          reason: 'the seed is printed at the start of each test');
      expect(report['seed'], 1, reason: 'the report carries the seed');
      return _tests(report).map((t) => t['name']).toList();
    }

    final order1 = runSeeded();
    expect(order1.toSet(), order0.toSet(),
        reason: 'a seed permutes the run order, never the set of tests');
    expect(order1, isNot(equals(order0)),
        reason: 'seed 1 reorders this fixture (verified permutation)');
    expect(runSeeded(), order1, reason: 'the same seed reproduces the order');
  });

  test('late registration (after the run starts) dies loudly, not silently',
      () {
    final (exit, out, errText) =
        _run('test/bad_fixtures/late_registration_e2e.dart');
    expect(exit, isNot(0));
    expect(errText, contains('registered after the run started'),
        reason: 'the contract violation names itself');
    expect(out, contains('✓ registered in time'),
        reason: 'the in-time test still ran; the late one never joined');
  });

  test('human output: readable lines and a definite end-of-run summary', () {
    final (exit, out, _) = _run('test/fixtures/green_e2e.dart');
    expect(exit, 0);
    expect(out, contains('▶ rail comes up [REQ-1] (seed 0)'),
        reason: 'the seed is printed at the start of each test');
    expect(out, contains('✓ rail comes up'));
    expect(out, contains('○ thermal camera sweep (skipped)'));
    expect(out,
        contains('labwright: 3 test(s) — 2 passed, 0 failed, 0 errors, '
            '1 skipped'));
  });

  test('the in-process viewer serves the page and state; busy port tolerated',
      () async {
    // keepOpen holds the (single) process alive serving results.
    final process = await Process.start(
      Platform.resolvedExecutable,
      [
        'run',
        '-Dlabwright.port=0',
        '-Dlabwright.keepOpen=true',
        'test/fixtures/green_e2e.dart',
      ],
      workingDirectory: pkgRoot,
    );
    try {
      final port = Completer<int>();
      final done = Completer<void>();
      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        final m = RegExp(r'viewer on http://localhost:(\d+)').firstMatch(line);
        if (m != null && !port.isCompleted) port.complete(int.parse(m[1]!));
        if (line.contains('keepOpen') && !done.isCompleted) done.complete();
      });
      final p = await port.future.timeout(const Duration(seconds: 30));
      await done.future.timeout(const Duration(seconds: 60));

      final client = HttpClient();
      final stateRes = await (await client
              .getUrl(Uri.parse('http://localhost:$p/state.json')))
          .close();
      expect(stateRes.statusCode, 200);
      final state = (jsonDecode(await stateRes.transform(utf8.decoder).join())
              as Map)
          .cast<String, Object?>();
      expect(state['done'], true);
      final tests = (state['tests'] as List).cast<Map<String, Object?>>();
      expect(tests, hasLength(3));
      expect(tests.first['logs'], ['applying power'],
          reason: 'logs attach to their test for the viewer');

      final pageRes = await (await client
              .getUrl(Uri.parse('http://localhost:$p/')))
          .close();
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
