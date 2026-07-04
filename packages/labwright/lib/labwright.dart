/// Labwright's hardware end-to-end test API — the TestStand-replacement
/// runner surface.
///
/// An E2E file is a **plain Dart program**: setup is ordinary code at the top
/// of `main()`, a test is a named body of ordinary code, and the file runs
/// under `dart run` (never `dart test` — hardware tests own their process and
/// run strictly in order). The `labwright` executable runs a set of E2E files
/// sequentially, renders live progress, serves the execution viewer over
/// HTTP, and produces CI exit codes and JSON reports.
///
/// ```dart
/// import 'package:labwright/labwright.dart';
///
/// Future<void> main() async {
///   await pinMap.load('OutputVoltage.pinmap'); // setup — before any test()
///
///   test('output voltage in range', requirements: ['REQ-101'], () async {
///     await psu.setVoltage(2.0);
///     final v = await dmm.readVoltage();
///     expect(v, inInclusiveRange(1.9, 2.1));
///   });
/// }
/// ```
///
/// **Registration, then execution.** [test] only *registers*; nothing runs
/// until every test is registered (the run starts once registration goes
/// quiet — in practice, when `main` finishes). Register from `main` or any
/// function it reaches, but do it in one synchronous burst: async setup goes
/// BEFORE the first [test] call, and a registration arriving after the run
/// has started throws a [StateError] rather than silently joining. The full
/// ordered list is what makes sharding deterministic.
///
/// **Sharding.** With `LABWRIGHT_TOTAL_SHARDS`/`LABWRIGHT_SHARD_INDEX` set
/// (the runner's `--total-shards N --shard-index i`, same convention as
/// `dart test`), registration index `i % N` selects each test's shard;
/// unselected tests are not run and not reported.
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
///    make the process exit non-zero. There is no soft-fail tier — if a
///    non-immediately-failing check is ever needed, it will be carved out
///    explicitly.
///  * Tests execute strictly in registration order, one at a time — the
///    bench is singular.
///  * [skipTest] has the identical signature and skips the body (reported,
///    not run) — rename `test` ⇄ `skipTest` to disarm/arm. To-do notes are
///    just comments; there is no metadata for them.
///  * Requirement tracing IDs attach to tests via `requirement:` /
///    `requirements:` and flow into the runner's report and viewer.
///  * [log] lines are attributed to the running test and stream to the
///    viewer.
///
/// Reporting: human-readable lines by default; under the runner
/// (`LABWRIGHT_REPORT=jsonl`) one JSON event per line on stdout.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test_api/hooks_testing.dart';

export 'package:matcher/expect.dart';

/// The environment variable the `labwright` runner sets to switch a file's
/// output from human lines to machine JSON-lines events.
const String reportEnv = 'LABWRIGHT_REPORT';

/// The [reportEnv] value selecting JSON-lines event output.
const String reportJsonl = 'jsonl';

/// Sharding environment variables — `dart test`'s `--total-shards` /
/// `--shard-index` convention, delivered by the runner (or set by hand).
const String totalShardsEnv = 'LABWRIGHT_TOTAL_SHARDS';
const String shardIndexEnv = 'LABWRIGHT_SHARD_INDEX';

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
/// registered — strictly in registration order, one at a time.
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

/// Emits a log line, attributed to the currently running test (suite-level
/// when none is running). Streams to the runner/viewer live.
void log(String message) => _sink.log(_currentTest, message);

// ── registry and execution ───────────────────────────────────────────────────

typedef _Registered = ({
  String name,
  FutureOr<void> Function() body,
  bool skip,
  List<String> requirements,
});

final List<_Registered> _registry = [];
bool _runScheduled = false;
bool _runStarted = false;
String? _currentTest;

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
  _registry.add(
      (name: name, body: body, skip: skip, requirements: requirements));
  if (!_runScheduled) {
    _runScheduled = true;
    // Fires once the current synchronous burst (typically the rest of main)
    // has finished — the registration phase is over.
    Timer.run(_runAll);
  }
}

Future<void> _runAll() async {
  _runStarted = true;
  final env = Platform.environment;
  final total = int.tryParse(env[totalShardsEnv] ?? '') ?? 1;
  final index = int.tryParse(env[shardIndexEnv] ?? '') ?? 0;
  if (total < 1 || index < 0 || index >= total) {
    stderr.writeln('labwright: invalid shard $index of $total');
    exitCode = 64;
    return;
  }
  // Deterministic shard selection by registration index — the reason the
  // registry must be complete before anything runs.
  final selected = [
    for (var i = 0; i < _registry.length; i++)
      if (i % total == index) _registry[i],
  ];
  if (total > 1) {
    _sink.shard(index, total, selected.length, _registry.length);
  }
  final counts = <TestStatus, int>{};
  for (final entry in selected) {
    final status = await _runOne(entry);
    counts[status] = (counts[status] ?? 0) + 1;
  }
  _sink.suiteEnd(selected.length, counts);
}

Future<TestStatus> _runOne(_Registered entry) async {
  _sink.testStart(entry.name, entry.requirements, skip: entry.skip);
  if (entry.skip) {
    const status = TestStatus.skipped;
    _sink.testEnd(
        entry.name, status, entry.requirements, '', Duration.zero);
    return status;
  }
  _currentTest = entry.name;
  final watch = Stopwatch()..start();
  // Host the body in a real test_api case: package:test's expect/expectLater/
  // matchers work as-is, and late async errors surface like under dart test.
  final monitor = await TestCaseMonitor.run(entry.body);
  watch.stop();
  _currentTest = null;
  final TestStatus status;
  var detail = '';
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
      detail = 'internal: test case still ${monitor.state.name} after run';
    case State.failed:
      final errors = monitor.errors.toList();
      status = errors.every((e) => e.error is TestFailure)
          ? TestStatus.failed
          : TestStatus.error;
      detail = errors
          .map((e) => e.error.toString().trimRight())
          .join('\n')
          .trim();
  }
  if (status == TestStatus.failed || status == TestStatus.error) exitCode = 1;
  _sink.testEnd(entry.name, status, entry.requirements, detail, watch.elapsed);
  return status;
}

// ── reporting ────────────────────────────────────────────────────────────────

final _EventSink _sink = _EventSink._();

/// Where events go: JSON lines on stdout under the runner, human lines
/// otherwise.
class _EventSink {
  _EventSink._() : jsonl = Platform.environment[reportEnv] == reportJsonl;

  /// Whether the runner asked for machine output.
  final bool jsonl;

  void _emit(Map<String, Object?> event) => stdout.writeln(jsonEncode(event));

  void shard(int index, int total, int selected, int registered) {
    if (jsonl) {
      _emit({
        'e': 'shard',
        'index': index,
        'total': total,
        'selected': selected,
        'registered': registered,
      });
    } else {
      stdout.writeln('shard $index of $total: running $selected of '
          '$registered test(s)');
    }
  }

  void testStart(String name, List<String> requirements,
      {required bool skip}) {
    if (jsonl) {
      _emit({
        'e': 'test-start',
        'test': name,
        if (requirements.isNotEmpty) 'requirements': requirements,
      });
    } else if (!skip) {
      final reqs =
          requirements.isEmpty ? '' : ' [${requirements.join(', ')}]';
      stdout.writeln('▶ $name$reqs');
    }
  }

  void testEnd(String name, TestStatus status, List<String> requirements,
      String detail, Duration elapsed) {
    if (jsonl) {
      _emit({
        'e': 'test-end',
        'test': name,
        'status': status.name,
        if (requirements.isNotEmpty) 'requirements': requirements,
        if (detail.isNotEmpty) 'detail': detail,
        'ms': elapsed.inMilliseconds,
      });
      return;
    }
    final mark = switch (status) {
      TestStatus.passed => '✓',
      TestStatus.failed => '✗',
      TestStatus.error => '‼',
      TestStatus.skipped => '○',
    };
    final reqs = requirements.isEmpty ? '' : ' [${requirements.join(', ')}]';
    final note = detail.isEmpty ? '' : '\n  ${detail.replaceAll('\n', '\n  ')}';
    stdout.writeln(status == TestStatus.skipped
        ? '$mark $name$reqs (skipped)'
        : '$mark $name$reqs (${elapsed.inMilliseconds} ms)$note');
  }

  void suiteEnd(int ran, Map<TestStatus, int> counts) {
    if (jsonl) return; // the runner aggregates from test-end events
    stdout.writeln('labwright: $ran test(s) — '
        '${counts[TestStatus.passed] ?? 0} passed, '
        '${counts[TestStatus.failed] ?? 0} failed, '
        '${counts[TestStatus.error] ?? 0} errors, '
        '${counts[TestStatus.skipped] ?? 0} skipped');
  }

  void log(String? testName, String message) {
    if (jsonl) {
      _emit({
        'e': 'log',
        if (testName != null) 'test': testName,
        'message': message,
      });
    } else {
      stdout.writeln('  · $message');
    }
  }
}
