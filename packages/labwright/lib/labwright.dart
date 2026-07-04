/// Labwright's hardware end-to-end test API — the TestStand-replacement
/// runner surface.
///
/// An E2E file is a **plain Dart program**: `main()` awaits [sequence] calls,
/// and the file runs under `dart run` (never `dart test` — hardware tests own
/// their process, run strictly in order, and cannot be sharded or isolated by
/// a unit-test runner). The `labwright` executable (see `bin/labwright.dart`)
/// runs a set of E2E files sequentially, renders live progress, serves the
/// execution viewer over HTTP, and produces CI exit codes and JSON reports.
///
/// ```dart
/// import 'package:labwright/labwright.dart';
///
/// Future<void> main() async {
///   await sequence('MainSequence', (s) async {
///     await s.step('Update pin map', requirement: 'REQ-101', (ctx) async {
///       await pinMap.load('OutputVoltage.pinmap');
///     });
///     await s.step('Output voltage test', (ctx) async {
///       final v = await dmm.read();
///       ctx.check(v >= 1.9 && v <= 2.1, 'voltage $v within [1.9, 2.1]');
///     });
///   });
/// }
/// ```
///
/// Step status contract (shared with the TestStand exporter's boilerplate):
///  * a false [StepContext.check] marks the step **failed** and execution
///    continues (TestStand's continue-on-fail);
///  * [StepContext.pending] or an [UnimplementedError] escaping the body
///    marks the step **pending** — an unimplemented surface (a VI-call stub,
///    an untranslated engine expression), never a failure;
///  * any other escape is an **error**;
///  * the process [exitCode] goes non-zero iff a sequence failed or errored —
///    pending alone stays green (CI can tighten with `--fail-on-pending`).
///
/// Reporting: human-readable lines by default; when the runner sets
/// `LABWRIGHT_REPORT=jsonl` the file emits one JSON event per line on stdout
/// instead, which the runner renders, serves to the viewer, and aggregates.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// The environment variable the `labwright` runner sets to switch a file's
/// output from human lines to machine JSON-lines events.
const String reportEnv = 'LABWRIGHT_REPORT';

/// The [reportEnv] value selecting JSON-lines event output.
const String reportJsonl = 'jsonl';

/// Terminal status of one step.
enum StepStatus {
  /// Ran to completion with every check true.
  passed,

  /// A check was false or [StepContext.fail] was called.
  failed,

  /// The step reached an unimplemented surface ([StepContext.pending] or an
  /// escaped [UnimplementedError]) — boilerplate awaiting an implementation.
  pending,

  /// The body escaped with an unexpected error.
  error,
}

/// Terminal status of one sequence: the worst of its steps ([StepStatus.error]
/// and [StepStatus.failed] both fail the sequence).
enum SequenceStatus { passed, failed, pending }

/// One executed step, as recorded by [SequenceContext.step].
class StepResult {
  StepResult({
    required this.name,
    required this.status,
    required this.requirements,
    required this.detail,
    required this.elapsed,
  });

  /// The step's display name.
  final String name;

  /// Terminal status (see the class contract on the library doc).
  final StepStatus status;

  /// Requirement tracing IDs this step covers (may be empty).
  final List<String> requirements;

  /// Failure messages / pending reason / error text — empty when passed.
  final String detail;

  /// Wall-clock duration of the step body.
  final Duration elapsed;

  Map<String, Object?> toJson(String sequenceName) => {
        'e': 'step',
        'seq': sequenceName,
        'step': name,
        'status': status.name,
        if (requirements.isNotEmpty) 'requirements': requirements,
        if (detail.isNotEmpty) 'detail': detail,
        'ms': elapsed.inMilliseconds,
      };
}

/// Handed to each step body: checks, explicit outcomes, and logging.
class StepContext {
  StepContext._(this._sink);

  final _EventSink _sink;
  final List<String> _failures = [];

  /// Records a pass/fail check. A false [condition] marks the step failed
  /// and keeps executing — TestStand's continue-on-fail semantics.
  void check(bool condition, String message) {
    if (!condition) _failures.add(message);
  }

  /// Marks the step **pending** (an unimplemented surface) and stops its
  /// body. This is what generated boilerplate calls for a not-yet-ported
  /// module target; implementing the target and removing the call arms the
  /// step.
  Never pending(String reason) => throw _Pending(reason);

  /// Fails the step with [message] and stops its body.
  Never fail(String message) => throw _Failed(message);

  /// Emits a free-form log line attributed to the running step.
  void log(String message) => _sink.log(message);
}

/// Handed to a [sequence] body: registers and runs steps **in order**.
class SequenceContext {
  SequenceContext._(this._name, this._sink);

  final String _name;
  final _EventSink _sink;
  final List<StepResult> results = [];

  /// Runs one step. [requirement]/[requirements] bind requirement tracing
  /// IDs to the step (both accepted; they merge).
  Future<void> step(
    String name,
    FutureOr<void> Function(StepContext ctx) body, {
    String? requirement,
    List<String> requirements = const [],
  }) async {
    final reqs = [if (requirement != null) requirement, ...requirements];
    final ctx = StepContext._(_sink);
    final watch = Stopwatch()..start();
    StepStatus status;
    var detail = '';
    try {
      await body(ctx);
      status = ctx._failures.isEmpty ? StepStatus.passed : StepStatus.failed;
      detail = ctx._failures.join('; ');
    } on _Pending catch (e) {
      status = StepStatus.pending;
      detail = e.reason;
    } on _Failed catch (e) {
      status = StepStatus.failed;
      detail = [...ctx._failures, e.message].join('; ');
    } on UnimplementedError catch (e) {
      status = StepStatus.pending;
      detail = e.message ?? 'UnimplementedError';
    } catch (e) {
      status = StepStatus.error;
      detail = e.toString();
    }
    watch.stop();
    final result = StepResult(
      name: name,
      status: status,
      requirements: reqs,
      detail: detail,
      elapsed: watch.elapsed,
    );
    results.add(result);
    _sink.step(_name, result);
  }
}

/// Runs one named sequence of steps, reporting as it goes. Returns the
/// sequence's terminal status; also accumulates it into the process
/// [exitCode] (failed → non-zero) so a bare `dart run file.dart` is already
/// CI-meaningful.
Future<SequenceStatus> sequence(
  String name,
  FutureOr<void> Function(SequenceContext s) body, {
  List<String> requirements = const [],
}) async {
  final sink = _EventSink._instance;
  sink.sequenceStart(name, requirements);
  final s = SequenceContext._(name, sink);
  final watch = Stopwatch()..start();
  var bodyError = '';
  var bodyPending = '';
  try {
    await body(s);
  } on UnimplementedError catch (e) {
    // An unimplemented surface OUTSIDE any step (e.g. an untranslated
    // expression in generated flow control) is boilerplate, not a failure —
    // the sequence is pending; note that execution stopped there.
    bodyPending = e.message ?? 'UnimplementedError';
  } catch (e) {
    // Any other escape OUTSIDE a step is a sequence-level error.
    bodyError = e.toString();
  }
  watch.stop();
  final failed = bodyError.isNotEmpty ||
      s.results.any((r) =>
          r.status == StepStatus.failed || r.status == StepStatus.error);
  final pending = bodyPending.isNotEmpty ||
      s.results.any((r) => r.status == StepStatus.pending);
  final status = failed
      ? SequenceStatus.failed
      : pending
          ? SequenceStatus.pending
          : SequenceStatus.passed;
  if (status == SequenceStatus.failed) exitCode = 1;
  sink.sequenceEnd(name, status, s.results, watch.elapsed,
      bodyError.isNotEmpty ? bodyError : bodyPending);
  return status;
}

/// Explicit pending/failed step escapes (private control-flow signals — a
/// generic catch in the step body would defeat them, so bodies should not
/// blanket-catch).
class _Pending implements Exception {
  _Pending(this.reason);
  final String reason;
}

class _Failed implements Exception {
  _Failed(this.message);
  final String message;
}

/// Where events go: JSON lines on stdout under the runner, human lines
/// otherwise.
class _EventSink {
  _EventSink._() : jsonl = Platform.environment[reportEnv] == reportJsonl;

  static final _EventSink _instance = _EventSink._();

  /// Whether the runner asked for machine output.
  final bool jsonl;

  void _emit(Map<String, Object?> event) => stdout.writeln(jsonEncode(event));

  void sequenceStart(String name, List<String> requirements) {
    if (jsonl) {
      _emit({
        'e': 'seq-start',
        'seq': name,
        if (requirements.isNotEmpty) 'requirements': requirements,
      });
    } else {
      final reqs = requirements.isEmpty ? '' : ' ${requirements.join(', ')}';
      stdout.writeln('▶ $name$reqs');
    }
  }

  void step(String sequenceName, StepResult result) {
    if (jsonl) {
      _emit(result.toJson(sequenceName));
      return;
    }
    final mark = switch (result.status) {
      StepStatus.passed => '✓',
      StepStatus.failed => '✗',
      StepStatus.pending => '○',
      StepStatus.error => '‼',
    };
    final reqs = result.requirements.isEmpty
        ? ''
        : ' [${result.requirements.join(', ')}]';
    final detail = result.detail.isEmpty ? '' : ' — ${result.detail}';
    stdout.writeln('  $mark ${result.name}$reqs$detail '
        '(${result.elapsed.inMilliseconds} ms)');
  }

  void log(String message) {
    if (jsonl) {
      _emit({'e': 'log', 'message': message});
    } else {
      stdout.writeln('    · $message');
    }
  }

  void sequenceEnd(String name, SequenceStatus status,
      List<StepResult> results, Duration elapsed, String detail) {
    if (jsonl) {
      _emit({
        'e': 'seq-end',
        'seq': name,
        'status': status.name,
        if (detail.isNotEmpty) 'detail': detail,
        'ms': elapsed.inMilliseconds,
      });
      return;
    }
    var passed = 0, failed = 0, pending = 0, errors = 0;
    for (final r in results) {
      switch (r.status) {
        case StepStatus.passed:
          passed++;
        case StepStatus.failed:
          failed++;
        case StepStatus.pending:
          pending++;
        case StepStatus.error:
          errors++;
      }
    }
    final note = detail.isEmpty ? '' : ' — $detail';
    stdout.writeln('$name: ${status.name.toUpperCase()} '
        '($passed passed, $failed failed, $errors errors, $pending pending, '
        '${elapsed.inMilliseconds} ms)$note');
  }
}
