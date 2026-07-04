import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// The labwright package root, whether the suite runs from the repo root or
/// the package dir (mirrors the corpus_dirs.dart convention).
final String pkgRoot = Directory('packages/labwright').existsSync()
    ? 'packages/labwright'
    : '.';

/// Runs [file] under `dart run` the way the labwright runner does and returns
/// (exitCode, stdout lines). E2E files are plain programs — this is their
/// real execution surface, so the API tests exercise exactly that.
(int, List<String>) _run(String file,
    {bool jsonl = true, Map<String, String> env = const {}}) {
  final result = Process.runSync(
    Platform.resolvedExecutable,
    ['run', file],
    environment: {if (jsonl) 'LABWRIGHT_REPORT': 'jsonl', ...env},
    workingDirectory: pkgRoot,
  );
  return (
    result.exitCode,
    const LineSplitter().convert(result.stdout.toString()),
  );
}

List<Map<String, Object?>> _events(List<String> lines) => [
      for (final line in lines)
        if (line.startsWith('{'))
          (jsonDecode(line) as Map).cast<String, Object?>(),
    ];

void main() {
  test('green fixture: registration then execution, real expect, skip green',
      () {
    final (exit, lines) = _run('test/fixtures/green_e2e.dart');
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
    final (exit, lines) = _run('test/fixtures/red_e2e.dart');
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

  test('sharding: registration index i % N == I, shards partition the tests',
      () {
    final byShard = <int, List<Object?>>{};
    for (var i = 0; i < 2; i++) {
      final (exit, lines) = _run('test/fixtures/green_e2e.dart', env: {
        'LABWRIGHT_TOTAL_SHARDS': '2',
        'LABWRIGHT_SHARD_INDEX': '$i',
      });
      expect(exit, 0, reason: 'shard $i:\n$lines');
      final events = _events(lines);
      final shard = events.singleWhere((e) => e['e'] == 'shard');
      expect(shard['total'], 2);
      expect(shard['registered'], 3,
          reason: 'the full registry is known before the run — that is what '
              'deferred registration buys');
      byShard[i] = [
        for (final e in events)
          if (e['e'] == 'test-end') e['test'],
      ];
    }
    expect(byShard[0], ['rail comes up', 'thermal camera sweep'],
        reason: 'indices 0,2 land in shard 0');
    expect(byShard[1], ['ripple in limits'],
        reason: 'index 1 lands in shard 1');
  });

  test('late registration (after the run starts) dies loudly, not silently',
      () {
    final result = Process.runSync(
      Platform.resolvedExecutable,
      ['run', 'test/bad_fixtures/late_registration_e2e.dart'],
      environment: {'LABWRIGHT_REPORT': 'jsonl'},
      workingDirectory: pkgRoot,
    );
    expect(result.exitCode, isNot(0));
    expect(result.stderr.toString(),
        contains('registered after the run started'),
        reason: 'the contract violation names itself');
    final events =
        _events(const LineSplitter().convert(result.stdout.toString()));
    expect(
        events
            .where((e) => e['e'] == 'test-end')
            .map((e) => e['test']),
        ['registered in time'],
        reason: 'the in-time test still ran; the late one never joined');
  });

  test('human mode (no env): readable lines, summary, same exit semantics',
      () {
    final (exit, lines) = _run('test/fixtures/green_e2e.dart', jsonl: false);
    expect(exit, 0);
    final text = lines.join('\n');
    expect(text, contains('▶ rail comes up [REQ-1]'));
    expect(text, contains('✓ rail comes up'));
    expect(text, contains('○ thermal camera sweep (skipped)'));
    expect(text,
        contains('labwright: 3 test(s) — 2 passed, 0 failed, 0 errors, '
            '1 skipped'),
        reason: 'deferred registration gives a definite end-of-run summary');
    expect(text, isNot(contains('{"e"')), reason: 'no JSON in human mode');
  });
}
