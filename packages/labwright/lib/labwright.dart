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
/// shuffles the selected run order. Left unset, each run mints a fresh random
/// seed (a sharded run instead uses a fixed one so every runner agrees); an
/// explicit `0` keeps registration order. The effective seed is printed once
/// at suite start and available to bodies — the hook fuzz testing will grow
/// from. Configuration travels as Dart defines (`-D`), never environment
/// variables; the `labwright` CLI is optional sugar that maps flags to the
/// same defines.
///
/// **The live viewer runs in-process** (default `http://localhost:1212`,
/// `-Dlabwright.port`, disable with `-Dlabwright.viewer=false`): SSE-fed,
/// self-contained, showing the planned suite up front and each test's log
/// lines as it runs. A busy port warns and continues — a viewer must never
/// fail a hardware run. `-Dlabwright.keepOpen=true` keeps serving after the
/// run until the process is killed; `-Dlabwright.interactive=true` goes
/// further and makes the page a control plane — re-run all/failed, run or loop
/// a single test, and stop after the current test (it implies keepOpen). Both
/// are opt-in, so bare `dart run`/CI still runs once and exits.
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

/// Sharding, `dart test`'s convention (`labwright.totalShards` /
/// `labwright.shardIndex`): a test runs in this shard iff its registration
/// index is `≡ shardIndex (mod totalShards)`. The in-process registry is
/// the whole suite, so the modulo is global by construction.
const int totalShards = int.fromEnvironment('labwright.totalShards', defaultValue: 1);
const int shardIndex = int.fromEnvironment('labwright.shardIndex');

/// The seed define, or [_seedUnset] when the user passed none. Real seeds are
/// `>= 0`, so a negative sentinel keeps an explicit `--seed 0` (registration
/// order) distinct from "unset".
const int _seedUnset = -1;
const int _seedDefine = int.fromEnvironment('labwright.seed', defaultValue: _seedUnset);

/// The fixed seed a SHARDED run falls back to when the user gave none: every
/// shard runner then shuffles identically (so the partition is stable across
/// machines) and each shard is mixed enough that it rarely runs several
/// registration-order neighbours back to back. `0x5EED` spells SEED.
const int _shardSeed = 0x5EED;

/// The run's effective seed (define `labwright.seed`; the CLI's `--seed`),
/// resolved once — first read wins, so the shuffle, the report, [rand], and
/// every test body see one stable value:
///  * an explicit `-Dlabwright.seed=N` always wins, including `0` which keeps
///    registration order (no shuffle);
///  * otherwise a sharded run uses the fixed [_shardSeed] so every shard
///    runner agrees on the permutation;
///  * otherwise each run mints a fresh RANDOM seed (printed at suite start),
///    so repeated local runs surface order-dependent flakiness.
final int seed = _seedDefine != _seedUnset ? _seedDefine : (totalShards > 1 ? _shardSeed : Random().nextInt(1 << 31));

Random? _rand;

/// The suite's deterministic random stream. It is reset to [seed] at the
/// START of every test (when a seed is set), so a test draws the same
/// sequence whether it runs in a full pass or alone via the viewer's re-run
/// button — per-test reproducibility, not whole-run. `rand()` draws in
/// `[0, 1)`; `rand(min, max)` draws in `[min, max)`; within a test the stream
/// advances on every draw.
double rand([num? min, num? max]) {
  final rng = _rand ??= seed != 0 ? Random(seed) : Random();
  final r = rng.nextDouble();
  if (min == null && max == null) return r;
  if (min != null && max != null) return min + r * (max - min);
  throw ArgumentError('rand() takes zero bounds or both');
}

/// Resets the [rand] stream so the next test starts from the seed — the hook
/// that makes a single test's random draws reproducible on re-run.
void _resetRand() => _rand = seed != 0 ? Random(seed) : Random();

const int _port = int.fromEnvironment('labwright.port', defaultValue: 1212);
const bool _viewerEnabled = bool.fromEnvironment('labwright.viewer', defaultValue: true);
const bool _keepOpen = bool.fromEnvironment('labwright.keepOpen');
const bool _interactive = bool.fromEnvironment('labwright.interactive');

/// The viewer lingers after the run — serving results and accepting control
/// actions (re-run, run-one, stop) — only when explicitly asked
/// (`--interactive` / `--keep-open`). Bare `dart run` and CI keep exiting with
/// the run's code, so a pipeline never hangs.
const bool _linger = _keepOpen || _interactive;
const String _reportPath = String.fromEnvironment('labwright.report');

// ── console styling ───────────────────────────────────────────────────────────

/// The log/message prefix for anything labwright prints itself.
const String _tag = '[Labwright]:';

/// ANSI color is used only on a real terminal — piped/CI output (and the
/// captured stdout the tests assert on) stays plain ASCII with no escapes.
final bool _ansi = stdout.supportsAnsiEscapes;
String _paint(String text, String code) => _ansi ? '$code$text\x1b[0m' : text;
const String _green = '\x1b[32m';
const String _red = '\x1b[31m';
const String _yellow = '\x1b[33m';
const String _dim = '\x1b[2m';

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
}) => _register(name, body, skip: false, requirements: [if (requirement != null) requirement, ...requirements]);

/// [test] with the body disarmed: reported as skipped, in order, without
/// running. Rename `skipTest` → `test` to arm (and back to disarm) — the
/// signature is identical by design.
void skipTest(
  String name,
  FutureOr<void> Function() body, {
  String? requirement,
  List<String> requirements = const [],
}) => _register(name, body, skip: true, requirements: [if (requirement != null) requirement, ...requirements]);

/// Prints a log line, attributed to the currently running test (suite-level
/// when none is running) — shown in the viewer under its test and carried
/// in the report.
void log(String message) {
  stdout.writeln('  - $message');
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
// A run (initial or re-run) is currently executing; guards against overlapping
// runs — the bench is singular.
bool _runInProgress = false;
// Set by a `stop` action; the loop halts before the NEXT test. The in-flight
// test always finishes (never leave the bench torn mid-test).
bool _stopRequested = false;
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
      '$_tag test "$name" registered after the run started. All tests '
      'must register before anything runs — do async setup BEFORE the '
      'first test() call and register in one synchronous burst.',
    );
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
  // Whether a run is executing (UI disables re-run controls) and whether
  // the viewer is lingering with the control plane live (UI shows them).
  'busy': _runInProgress,
  'interactive': _linger,
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
    stderr.writeln('$_tag invalid shard $shardIndex of $totalShards');
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

  // The seed prints once, here at suite start (not per test).
  if (seed != 0) stdout.writeln('$_tag seed $seed');

  if (_viewerEnabled) {
    _viewer = await Viewer.start(_port, _state);
    if (_viewer != null) {
      // The control plane: the viewer POSTs actions back here. Only reachable
      // while we linger (an explicit flag), so CI never grows an action surface.
      _viewer!.onAction = _handleAction;
      stdout.writeln(
        '$_tag viewer on http://localhost:${_viewer!.port}'
        '${totalShards > 1 ? ' - shard $shardIndex of $totalShards '
                  '(${_selected.length} of ${_registry.length})' : ''}',
      );
    }
  }

  await _execute(_selected);

  if (_linger && _viewer != null) {
    stdout.writeln(
      '$_tag View results and re-run tests at '
      'http://localhost:${_viewer!.port}. Ctrl + C to exit --interactive '
      'mode.',
    );
    // The server subscription keeps the process alive; control actions drive
    // further runs until the user kills it.
  } else {
    // The server subscription would otherwise keep the process alive.
    await _viewer?.close();
  }
}

/// Runs [entries] as one pass — resetting each first so a re-run starts clean.
/// Between tests it honors a `stop` request; the in-flight test always
/// finishes (Stop halts the queue, never a running body). Pushes state to the
/// viewer throughout, prints the summary, and rewrites the report when
/// configured. Re-entrancy is the caller's concern (see [_handleAction]).
Future<void> _execute(List<_TestEntry> entries) async {
  _runInProgress = true;
  _stopRequested = false;
  _done = false;
  _viewer?.update();
  for (final entry in entries) {
    if (_stopRequested) break;
    entry
      ..status = 'queued'
      ..detail = ''
      ..ms = null
      ..logs.clear();
    _viewer?.update();
    await _runOne(entry);
  }
  _runInProgress = false;
  _done = true;
  _viewer?.update();

  final s = _summary();
  stdout.writeln(
    '$_tag ${s['tests']} test(s) - ${s['passed']} passed, '
    '${s['failed']} failed, ${s['errors']} errors, ${s['skipped']} skipped',
  );
  if (_reportPath.isNotEmpty) {
    File(_reportPath).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(_report()));
    stdout.writeln('$_tag report written to $_reportPath');
  }
}

/// Dispatches a viewer control action. `stop` is always accepted (it just
/// flips the flag the run loop watches); the re-run family is rejected with
/// `accepted: false` while a run is already in progress (the bench is
/// singular). The actual run is fired-and-forgotten — its progress streams
/// back over SSE.
Future<Map<String, Object?>> _handleAction(Map<String, Object?> action) async {
  final type = action['type'];
  if (type == 'stop') {
    _stopRequested = true;
    return const {'accepted': true};
  }
  if (_runInProgress) {
    return const {'accepted': false, 'error': 'a run is already in progress'};
  }
  switch (type) {
    case 'rerun':
      unawaited(_execute(_selected));
    case 'rerunFailed':
      final failed = [
        for (final t in _selected)
          if (t.status == 'failed' || t.status == 'error') t,
      ];
      if (failed.isEmpty) {
        return const {'accepted': false, 'error': 'nothing to re-run'};
      }
      unawaited(_execute(failed));
    case 'runOne':
      _TestEntry? entry;
      for (final t in _selected) {
        if (t.name == action['test']) {
          entry = t;
          break;
        }
      }
      if (entry == null) {
        return {'accepted': false, 'error': 'no test named "${action['test']}"'};
      }
      unawaited(_execute([entry]));
    default:
      return {'accepted': false, 'error': 'unknown action "$type"'};
  }
  return const {'accepted': true};
}

/// The report: the suite state plus the requirements trace
/// (requirement ID → every test that claims it, with status).
Map<String, Object?> _report() {
  final requirements = <String, List<Map<String, Object?>>>{};
  for (final t in _selected) {
    for (final req in t.requirements) {
      requirements.putIfAbsent(req, () => []).add({'test': t.name, 'status': t.status});
    }
  }
  return {..._state(), 'requirements': requirements};
}

Future<void> _runOne(_TestEntry entry) async {
  // Requirement IDs live in the report and the viewer, not the console.
  if (entry.skip) {
    entry.status = 'skipped';
    stdout.writeln('${_paint('SKIP', _yellow)} ${entry.name}');
    _viewer?.update();
    return;
  }
  stdout.writeln('${_paint('RUN ', _dim)} ${entry.name}');
  entry.status = 'running';
  _running = entry;
  _viewer?.update();
  // Reset the random stream so this test draws the same sequence every time it
  // runs — reproducibility per test, whether in a full pass or a lone re-run.
  _resetRand();
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
      status = errors.every((e) => e.error is TestFailure) ? TestStatus.failed : TestStatus.error;
      entry.detail = errors.map((e) => e.error.toString().trimRight()).join('\n').trim();
  }
  entry.status = status.name;
  if (status == TestStatus.failed || status == TestStatus.error) exitCode = 1;
  final (label, color) = switch (status) {
    TestStatus.passed => ('PASS', _green),
    TestStatus.failed => ('FAIL', _red),
    TestStatus.error => ('ERR ', _red),
    TestStatus.skipped => ('SKIP', _yellow),
  };
  final note = entry.detail.isEmpty ? '' : '\n  ${entry.detail.replaceAll('\n', '\n  ')}';
  stdout.writeln('${_paint(label, color)} ${entry.name} (${entry.ms} ms)$note');
  _viewer?.update();
}
