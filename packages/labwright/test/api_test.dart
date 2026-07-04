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
  test('green fixture: passes, streams events, binds requirements, exits 0',
      () {
    final (exit, lines) = _run('test/fixtures/green_e2e.dart');
    expect(exit, 0, reason: 'pending alone must stay green:\n$lines');
    final events = _events(lines);
    expect(events.map((e) => e['e']),
        containsAllInOrder(['seq-start', 'step', 'step', 'step', 'seq-end']));

    final seqStart = events.firstWhere((e) => e['e'] == 'seq-start');
    expect(seqStart['requirements'], ['REQ-SEQ-1'],
        reason: 'sequence-level requirement binding');

    final steps = events.where((e) => e['e'] == 'step').toList();
    expect(steps[0]['status'], 'passed');
    expect(steps[0]['requirements'], ['REQ-1']);
    expect(steps[1]['requirements'], ['REQ-2', 'REQ-3']);
    expect(steps[2]['status'], 'pending',
        reason: 'ctx.pending marks the step pending');
    expect(steps[2]['detail'], contains('ThermalSweep.vi'),
        reason: 'the pending target is named');

    final seqEnd = events.firstWhere((e) => e['e'] == 'seq-end');
    expect(seqEnd['status'], 'pending',
        reason: 'no failures + a pending step → sequence pending');
    expect(events.any((e) => e['e'] == 'log'), isTrue);
  });

  test('red fixture: false check fails step, run continues, exits non-zero',
      () {
    final (exit, lines) = _run('test/fixtures/red_e2e.dart');
    expect(exit, isNot(0), reason: 'a failed sequence must fail CI');
    final events = _events(lines);
    final steps = events.where((e) => e['e'] == 'step').toList();
    expect(steps[0]['status'], 'failed');
    expect(steps[0]['detail'], contains('trip current'),
        reason: 'the failing check message is carried');
    expect(steps, hasLength(2),
        reason: 'continue-on-fail: the next step still runs');
    expect(steps[1]['status'], 'passed');
    expect(events.firstWhere((e) => e['e'] == 'seq-end')['status'], 'failed');
  });

  test('human mode (no env): readable lines, same exit semantics', () {
    final (exit, lines) = _run('test/fixtures/green_e2e.dart', jsonl: false);
    expect(exit, 0);
    final text = lines.join('\n');
    expect(text, contains('▶ PowerRail'));
    expect(text, contains('✓ Rail comes up [REQ-1]'));
    expect(text, contains('○ Thermal camera sweep'));
    expect(text, isNot(contains('{"e"')), reason: 'no JSON in human mode');
  });
}
