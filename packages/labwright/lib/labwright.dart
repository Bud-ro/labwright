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
///   await pinMap.load('OutputVoltage.pinmap'); // setup: just code, runs first
///
///   await test('output voltage in range', requirements: ['REQ-101'], () async {
///     await psu.setVoltage(2.0);
///     final v = await dmm.readVoltage();
///     expect(v, inInclusiveRange(1.9, 2.1));
///   });
/// }
/// ```
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
///  * **Tests run strictly in registration order, never interleaved.** Each
///    [test] call chains behind the previous one, so bodies are serialized
///    even if a caller forgets to await — the bench is singular. Register
///    from `main` or from any function `main` reaches.
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

/// Runs [body] as one named test, strictly after every previously registered
/// test. Returns when this test (and everything queued before it) has
/// finished, so `await test(...)` in an async `main` reads sequentially; an
/// un-awaited call is still safe — bodies never interleave.
///
/// [requirement]/[requirements] bind requirement tracing IDs (they merge).
Future<TestStatus> test(
  String name,
  FutureOr<void> Function() body, {
  String? requirement,
  List<String> requirements = const [],
}) =>
    _enqueue(name, body, skip: false,
        requirements: [if (requirement != null) requirement, ...requirements]);

/// [test] with the body disarmed: reported as skipped, in order, without
/// running. Rename `skipTest` → `test` to arm (and back to disarm) — the
/// signature is identical by design.
Future<TestStatus> skipTest(
  String name,
  FutureOr<void> Function() body, {
  String? requirement,
  List<String> requirements = const [],
}) =>
    _enqueue(name, body, skip: true,
        requirements: [if (requirement != null) requirement, ...requirements]);

/// Emits a log line, attributed to the currently running test (suite-level
/// when none is running). Streams to the runner/viewer live.
void log(String message) => _sink.log(_currentTest, message);

// ── execution ────────────────────────────────────────────────────────────────

/// The FIFO chain: every registration queues behind the previous one. This is
/// what makes un-awaited `test(...)` calls safe on hardware — there is never
/// a second body in flight.
Future<void> _chain = Future.value();

String? _currentTest;

Future<TestStatus> _enqueue(
  String name,
  FutureOr<void> Function() body, {
  required bool skip,
  required List<String> requirements,
}) {
  final previous = _chain;
  final done = Future(() async {
    await previous;
    return _runOne(name, body, skip: skip, requirements: requirements);
  });
  // The chain must survive a failed test: errors are consumed by _runOne and
  // reported as results, so `done` only errors on labwright's own bugs.
  _chain = done.then((_) {}, onError: (_) {});
  return done;
}

Future<TestStatus> _runOne(
  String name,
  FutureOr<void> Function() body, {
  required bool skip,
  required List<String> requirements,
}) async {
  _sink.testStart(name, requirements, skip: skip);
  if (skip) {
    const status = TestStatus.skipped;
    _sink.testEnd(name, status, requirements, '', Duration.zero);
    return status;
  }
  _currentTest = name;
  final watch = Stopwatch()..start();
  // Host the body in a real test_api case: package:test's expect/expectLater/
  // matchers work as-is, and late async errors surface like under dart test.
  final monitor = await TestCaseMonitor.run(body);
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
  _sink.testEnd(name, status, requirements, detail, watch.elapsed);
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
