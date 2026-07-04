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
(int, List<String>) _run(String file, {bool jsonl = true}) {
  final result = Process.runSync(
    Platform.resolvedExecutable,
    ['run', file],
    environment: {if (jsonl) 'LABWRIGHT_REPORT': 'jsonl'},
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
  test('green fixture: real expect works, requirements bind, skip stays green',
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
        reason: 'package:test expect/expectLater/matchers work as-is');
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
    expect(ends[1]['status'], 'passed',
        reason: 'un-awaited registrations still run in order via the chain');
    expect(ends[2]['status'], 'error',
        reason: 'a non-TestFailure escape is an error, not a failure');
    expect('${ends[2]['detail']}', contains('relay stuck'));
  });

  test('human mode (no env): readable lines, same exit semantics', () {
    final (exit, lines) = _run('test/fixtures/green_e2e.dart', jsonl: false);
    expect(exit, 0);
    final text = lines.join('\n');
    expect(text, contains('▶ rail comes up [REQ-1]'));
    expect(text, contains('✓ rail comes up'));
    expect(text, contains('○ thermal camera sweep (skipped)'));
    expect(text, isNot(contains('{"e"')), reason: 'no JSON in human mode');
  });
}
