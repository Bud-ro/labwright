import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// The labwright package root, whether the suite runs from the repo root or
/// the package dir (mirrors the corpus_dirs.dart convention).
final String pkgRoot = Directory('packages/labwright').existsSync()
    ? 'packages/labwright'
    : '.';

/// Runs [file] under `dart run` the way the labwright runner does — all
/// configuration as Dart defines, never environment variables — and returns
/// (exitCode, stdout lines, stderr).
(int, List<String>, String) _run(String file,
    {List<String> defines = const []}) {
  final result = Process.runSync(
    Platform.resolvedExecutable,
    ['run', ...defines, file],
    workingDirectory: pkgRoot,
  );
  return (
    result.exitCode,
    const LineSplitter().convert(result.stdout.toString()),
    result.stderr.toString(),
  );
}

const _jsonl = '-Dlabwright.report=jsonl';

List<Map<String, Object?>> _events(List<String> lines) => [
      for (final line in lines)
        if (line.startsWith('{'))
          (jsonDecode(line) as Map).cast<String, Object?>(),
    ];

void main() {
  test('green fixture: registration then execution, real expect, skip green',
      () {
    final (exit, lines, _) =
        _run('test/fixtures/green_e2e.dart', defines: [_jsonl]);
    expect(exit, 0, reason: 'skipped alone must stay green:\n$lines');
    final events = _events(lines);
    final ends = events.where((e) => e['e'] == 'test-end').toList();
    expect(ends.map((e) => e['test']), [
      'rail comes up',
      'ripple in limits',
      'thermal camera sweep',
    ], reason: 'registration order is execution order');
    expect(ends[0]['status'], 'passed',
        reason: 'async setup at the top of main completed before any body; '
            'package:test expect/expectLater/matchers work as-is');
    expect(ends[0]['requirements'], ['REQ-1']);
    expect(ends[1]['requirements'], ['REQ-2', 'REQ-3']);
    expect(ends[2]['status'], 'skipped',
        reason: 'skipTest reports without running the body');
    final logs = events.where((e) => e['e'] == 'log').toList();
    expect(logs.single['test'], 'rail comes up',
        reason: 'log lines attribute to the running test');
  });

  test('red fixture: TestFailure=failed, other throw=error, exits non-zero',
      () {
    final (exit, lines, _) =
        _run('test/fixtures/red_e2e.dart', defines: [_jsonl]);
    expect(exit, isNot(0), reason: 'failures must fail CI');
    final events = _events(lines);
    final ends = events.where((e) => e['e'] == 'test-end').toList();
    expect(ends, hasLength(3),
        reason: 'a failed test does not stop later tests');
    expect(ends[0]['status'], 'failed');
    expect('${ends[0]['detail']}', contains('trip current'),
        reason: 'the matcher mismatch description is carried');
    expect(ends[1]['status'], 'passed');
    expect(ends[2]['status'], 'error',
        reason: 'a non-TestFailure escape is an error, not a failure');
    expect('${ends[2]['detail']}', contains('relay stuck'));
  });

  test('collect mode: full registry with metadata, no body runs', () {
    final (exit, lines, _) = _run('test/fixtures/red_e2e.dart',
        defines: ['-Dlabwright.mode=collect']);
    expect(exit, 0,
        reason: 'collect must be green even for a failing file — nothing '
            'executes:\n$lines');
    final events = _events(lines);
    expect(events.where((e) => e['e'] == 'test-end'), isEmpty,
        reason: 'no body runs during collection');
    final registry = events.singleWhere((e) => e['e'] == 'registry');
    final tests = (registry['tests'] as List).cast<Map<String, Object?>>();
    expect(tests.map((t) => t['name']), [
      'trip threshold',
      'still reachable after trip',
      'teardown throws',
    ]);
    expect(tests[0]['requirements'], ['REQ-9'],
        reason: 'metadata travels with the collected registry');

    final (_, greenLines, _) = _run('test/fixtures/green_e2e.dart',
        defines: ['-Dlabwright.mode=collect']);
    final greenTests = (_events(greenLines)
            .singleWhere((e) => e['e'] == 'registry')['tests'] as List)
        .cast<Map<String, Object?>>();
    expect(greenTests[2]['skip'], true,
        reason: 'skipTest is visible in the collected metadata');
  });

  test('run mode executes exactly the chosen tests in the chosen order', () {
    final (exit, lines, _) = _run('test/fixtures/green_e2e.dart',
        defines: [_jsonl, '-Dlabwright.tests=2,0']);
    expect(exit, 0, reason: '$lines');
    expect(
        [
          for (final e in _events(lines))
            if (e['e'] == 'test-end') e['test'],
        ],
        ['thermal camera sweep', 'rail comes up'],
        reason: 'the runner owns selection AND order; the file just obeys');
  });

  test('seed: printed on every test start, shuffles order, never the set',
      () {
    final (exit0, lines0, _) =
        _run('test/fixtures/green_e2e.dart', defines: [_jsonl]);
    final order0 = [
      for (final e in _events(lines0))
        if (e['e'] == 'test-end') e['test'],
    ];
    expect(exit0, 0);
    for (final e in _events(lines0).where((e) => e['e'] == 'test-start')) {
      expect(e['seed'], 0, reason: 'no seed -> seed 0, still printed');
    }

    List<Object?> runSeeded() {
      final (exit, lines, _) = _run('test/fixtures/green_e2e.dart',
          defines: [_jsonl, '-Dlabwright.seed=1']);
      expect(exit, 0, reason: '$lines');
      final events = _events(lines);
      for (final e in events.where((e) => e['e'] == 'test-start')) {
        expect(e['seed'], 1,
            reason: 'the seed is printed at the start of each test');
      }
      return [
        for (final e in events)
          if (e['e'] == 'test-end') e['test'],
      ];
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
    final (exit, lines, errText) = _run(
        'test/bad_fixtures/late_registration_e2e.dart',
        defines: [_jsonl]);
    expect(exit, isNot(0));
    expect(errText, contains('registered after the run started'),
        reason: 'the contract violation names itself');
    expect(
        _events(lines)
            .where((e) => e['e'] == 'test-end')
            .map((e) => e['test']),
        ['registered in time'],
        reason: 'the in-time test still ran; the late one never joined');
  });

  test('human mode (no defines): readable lines, summary, same semantics',
      () {
    final (exit, lines, _) = _run('test/fixtures/green_e2e.dart');
    expect(exit, 0);
    final text = lines.join('\n');
    expect(text, contains('▶ rail comes up [REQ-1] (seed 0)'),
        reason: 'the seed is printed at the start of each test');
    expect(text, contains('✓ rail comes up'));
    expect(text, contains('○ thermal camera sweep (skipped)'));
    expect(text,
        contains('labwright: 3 test(s) — 2 passed, 0 failed, 0 errors, '
            '1 skipped'),
        reason: 'deferred registration gives a definite end-of-run summary');
    expect(text, isNot(contains('{"e"')), reason: 'no JSON in human mode');
  });
}
