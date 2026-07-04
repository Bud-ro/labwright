/// Labwright's hardware end-to-end test API — the TestStand-replacement
/// runner surface. **Everything runs in one process.**
///
/// The convention (like `integration_test`, minus the machinery): an `e2e/`
/// folder with a top-level `main.dart` that every test module is plugged
/// into by hand. The suite IS `dart run e2e/main.dart` — no scanning, no
/// IPC, no child processes. Setup is ordinary code at the top of `main()`;
/// a test is a named body of ordinary code registered from `main` or any
/// function it reaches:
///
/// ```dart
/// // e2e/main.dart
/// import 'power_rail_test.dart' as power_rail;
///
/// Future<void> main() async {
///   await pinMap.load('OutputVoltage.pinmap'); // setup — before any test()
///   power_rail.register();
/// }
///
/// // e2e/power_rail_test.dart
/// import 'package:labwright/labwright.dart';
///
/// void register() {
///   test('output voltage in range', requirements: ['REQ-101'], () async {
///     await psu.setVoltage(2.0);
///     expect(await dmm.readVoltage(), inInclusiveRange(1.9, 2.1));
///   });
/// }
/// ```
///
/// **Registration, then execution.** [test] only *registers*; bodies run
/// after every test is registered (when `main` finishes), one at a time —
/// the bench is singular. A registration arriving after the run has started
/// throws a [StateError] rather than silently joining; async setup goes
/// BEFORE the first [test] call.
///
/// **Sharding and the seed.** The single in-process registry is the whole
/// suite, so sharding is a plain `index % N == I` over it
/// (`-Dlabwright.totalShards`/`-Dlabwright.shardIndex`, `dart test`'s
/// convention) and the [seed] (`-Dlabwright.seed`) deterministically
/// shuffles the selected run order. The seed is printed at the start of
/// every test and available to bodies — the hook fuzz testing will grow
/// from. Configuration travels as Dart defines (`-D`), never environment
/// variables; the `labwright` CLI is optional sugar that maps flags to the
/// same defines.
///
/// **The live viewer runs in-process** (default `http://localhost:8642`,
/// `-Dlabwright.port`, disable with `-Dlabwright.viewer=false`): SSE-fed,
/// self-contained, showing the planned suite up front and each test's log
/// lines as it runs. A busy port warns and continues — a viewer must never
/// fail a hardware run. `-Dlabwright.keepOpen=true` keeps serving after the
/// run until the process is killed.
///
/// The `package:test` assertion surface works **as-is**: [expect],
/// [expectLater], [fail], [TestFailure], and every matcher are re-exported,
/// and each body runs inside a real `test_api` case (via its
/// third-party-runner hooks), so failure descriptions and late async errors
/// behave exactly as they do under `dart test`.
///
/// Semantics:
///  * **Exceptions are how tests fail.** A [TestFailure] (what [expect]
///    throws) reports as *failed*; any other escape reports as *error*; both
///    make the process exit non-zero. There is no soft-fail tier.
///  * [skipTest] has the identical signature and skips the body (reported,
///    not run) — rename `test` ⇄ `skipTest` to disarm/arm. To-do notes are
///    just comments; there is no metadata for them.
///  * Requirement tracing IDs attach to tests via `requirement:` /
///    `requirements:` and land in the report's requirements trace.
///  * [log] lines print, attach to the running test, and stream to the
///    viewer.
///  * `-Dlabwright.report=path.json` writes the machine-readable run report
///    (tests, statuses, logs, the requirements trace, seed, summary) for CI.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:test_api/hooks_testing.dart';

import 'src/viewer.dart';

export 'package:matcher/expect.dart';

/// The run's seed (define `labwright.seed`; the CLI's `--seed`): `0` =
/// registration order. Printed at the start of every test, and available
/// here to test bodies — the hook fuzz testing will grow from.
const int seed = int.fromEnvironment('labwright.seed');

/// Sharding, `dart test`'s convention (`labwright.totalShards` /
/// `labwright.shardIndex`): a test runs in this shard iff its registration
/// index is `≡ shardIndex (mod totalShards)`. The in-process registry is
/// the whole suite, so the modulo is global by construction.
const int totalShards = int.fromEnvironment('labwright.totalShards', defaultValue: 1);
const int shardIndex = int.fromEnvironment('labwright.shardIndex');

const int _port = int.fromEnvironment('labwright.port', defaultValue: 8642);
const bool _viewerEnabled =
    bool.fromEnvironment('labwright.viewer', defaultValue: true);
const bool _keepOpen = bool.fromEnvironment('labwright.keepOpen');
const String _reportPath = String.fromEnvironment('labwright.report');

/// Terminal status of one test.
enum TestStatus {
  /// Body ran to completion with no escape.
  passed,

  /// The body threw a [TestFailure] — an assertion did not hold.
  failed,

  /// The body escaped with something other than a [TestFailure].
  error,

  /// A [skipTest] body — reported in order, never run.
  skipped,
}

/// Registers one named test. Bodies run later — after every test is
/// registered — one at a time.
///
/// [requirement]/[requirements] bind requirement tracing IDs (they merge).
///
/// Throws [StateError] if called after the run has started: all tests must
/// register before anything runs (see the library doc).
void test(
  String name,
  FutureOr<void> Function() body, {
  String? requirement,
  List<String> requirements = const [],
}) =>
    _register(name, body, skip: false,
        requirements: [if (requirement != null) requirement, ...requirements]);

/// [test] with the body disarmed: reported as skipped, in order, without
/// running. Rename `skipTest` → `test` to arm (and back to disarm) — the
/// signature is identical by design.
void skipTest(
  String name,
  FutureOr<void> Function() body, {
  String? requirement,
  List<String> requirements = const [],
}) =>
    _register(name, body, skip: true,
        requirements: [if (requirement != null) requirement, ...requirements]);

/// Prints a log line, attributed to the currently running test (suite-level
/// when none is running) — shown in the viewer under its test and carried
/// in the report.
void log(String message) {
  stdout.writeln('  · $message');
  _running?.logs.add(message);
  _viewer?.update();
}

// ── registry and execution ───────────────────────────────────────────────────

class _TestEntry {
  _TestEntry(this.name, this.body, this.requirements, {required this.skip});

  final String name;
  final FutureOr<void> Function() body;
  final List<String> requirements;
  final bool skip;

  String status = 'queued';
  String detail = '';
  int? ms;
  final List<String> logs = [];

  Map<String, Object?> toJson() => {
        'name': name,
        'status': status,
        if (requirements.isNotEmpty) 'requirements': requirements,
        if (detail.isNotEmpty) 'detail': detail,
        if (ms != null) 'ms': ms,
        if (logs.isNotEmpty) 'logs': logs,
      };
}

final List<_TestEntry> _registry = [];
List<_TestEntry> _selected = const [];
bool _runScheduled = false;
bool _runStarted = false;
bool _done = false;
_TestEntry? _running;
Viewer? _viewer;

void _register(
  String name,
  FutureOr<void> Function() body, {
  required bool skip,
  required List<String> requirements,
}) {
  if (_runStarted) {
    throw StateError(
        'labwright: test "$name" registered after the run started. All tests '
        'must register before anything runs — do async setup BEFORE the '
        'first test() call and register in one synchronous burst.');
  }
  _registry.add(_TestEntry(name, body, requirements, skip: skip));
  if (!_runScheduled) {
    _runScheduled = true;
    // Fires once the current synchronous burst (typically the rest of main)
    // has finished — the registration phase is over.
    Timer.run(_runAll);
  }
}

/// The suite state the viewer and the report share.
Map<String, Object?> _state() => {
      'seed': seed,
      'done': _done,
      'tests': [for (final t in _selected) t.toJson()],
      'summary': _summary(),
    };

Map<String, Object?> _summary() {
  var passed = 0, failed = 0, errors = 0, skipped = 0;
  for (final t in _selected) {
    switch (t.status) {
      case 'passed':
        passed++;
      case 'failed':
        failed++;
      case 'error':
        errors++;
      case 'skipped':
        skipped++;
    }
  }
  return {
    'tests': _selected.length,
    'passed': passed,
    'failed': failed,
    'errors': errors,
    'skipped': skipped,
  };
}

Future<void> _runAll() async {
  _runStarted = true;
  if (totalShards < 1 || shardIndex < 0 || shardIndex >= totalShards) {
    stderr.writeln('labwright: invalid shard $shardIndex of $totalShards');
    exitCode = 64;
    return;
  }
  // Shard over the one in-process registry (the whole suite), then let the
  // seed shuffle only the ORDER of the selection — membership is stable.
  _selected = [
    for (var i = 0; i < _registry.length; i++)
      if (i % totalShards == shardIndex) _registry[i],
  ];
  if (seed != 0) _selected.shuffle(Random(seed));

  if (_viewerEnabled) {
    _viewer = await Viewer.start(_port, _state);
    if (_viewer != null) {
      stdout.writeln('labwright: viewer on http://localhost:${_viewer!.port}'
          '${totalShards > 1 ? ' · shard $shardIndex of $totalShards '
              '(${_selected.length} of ${_registry.length})' : ''}');
    }
  }

  for (final entry in _selected) {
    await _runOne(entry);
  }
  _done = true;
  _viewer?.update();

  final s = _summary();
  stdout.writeln('labwright: ${s['tests']} test(s) — ${s['passed']} passed, '
      '${s['failed']} failed, ${s['errors']} errors, ${s['skipped']} skipped'
      '${seed != 0 ? ' (seed $seed)' : ''}');
  if (_reportPath.isNotEmpty) {
    File(_reportPath).writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(_report()));
    stdout.writeln('labwright: report written to $_reportPath');
  }
  if (_keepOpen && _viewer != null) {
    stdout.writeln('labwright: keepOpen — viewer stays on '
        'http://localhost:${_viewer!.port} until the process is killed');
  } else {
    // The server subscription would otherwise keep the process alive.
    await _viewer?.close();
  }
}

/// The report: the suite state plus the requirements trace
/// (requirement ID → every test that claims it, with status).
Map<String, Object?> _report() {
  final requirements = <String, List<Map<String, Object?>>>{};
  for (final t in _selected) {
    for (final req in t.requirements) {
      requirements
          .putIfAbsent(req, () => [])
          .add({'test': t.name, 'status': t.status});
    }
  }
  return {..._state(), 'requirements': requirements};
}

Future<void> _runOne(_TestEntry entry) async {
  final reqs = entry.requirements.isEmpty
      ? ''
      : ' [${entry.requirements.join(', ')}]';
  if (entry.skip) {
    entry.status = 'skipped';
    stdout.writeln('○ ${entry.name}$reqs (skipped)');
    _viewer?.update();
    return;
  }
  stdout.writeln('▶ ${entry.name}$reqs (seed $seed)');
  entry.status = 'running';
  _running = entry;
  _viewer?.update();
  final watch = Stopwatch()..start();
  // Host the body in a real test_api case: package:test's expect/expectLater/
  // matchers work as-is, and late async errors surface like under dart test.
  final monitor = await TestCaseMonitor.run(entry.body);
  watch.stop();
  _running = null;
  entry.ms = watch.elapsedMilliseconds;
  final TestStatus status;
  switch (monitor.state) {
    case State.passed:
      status = TestStatus.passed;
    case State.skipped:
      // A body used test_api's own skip surface; honor it.
      status = TestStatus.skipped;
    case State.pending || State.running:
      // Unreachable: TestCaseMonitor.run returns only after the case is
      // done. Classified as error rather than silently passed if it ever
      // changes under us.
      status = TestStatus.error;
      entry.detail = 'internal: test case still ${monitor.state.name} after run';
    case State.failed:
      final errors = monitor.errors.toList();
      status = errors.every((e) => e.error is TestFailure)
          ? TestStatus.failed
          : TestStatus.error;
      entry.detail = errors
          .map((e) => e.error.toString().trimRight())
          .join('\n')
          .trim();
  }
  entry.status = status.name;
  if (status == TestStatus.failed || status == TestStatus.error) exitCode = 1;
  final mark = switch (status) {
    TestStatus.passed => '✓',
    TestStatus.failed => '✗',
    TestStatus.error => '‼',
    TestStatus.skipped => '○',
  };
  final note = entry.detail.isEmpty
      ? ''
      : '\n  ${entry.detail.replaceAll('\n', '\n  ')}';
  stdout.writeln('$mark ${entry.name}$reqs (${entry.ms} ms)$note');
  _viewer?.update();
}
