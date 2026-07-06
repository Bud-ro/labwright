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
import 'dart:collection';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:test_api/hooks_testing.dart';
import 'package:vm_service/vm_service.dart' as vm;
import 'package:vm_service/vm_service_io.dart' as vmio;

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

/// The seed currently driving order + [rand]. Starts at [seed] and is what the
/// viewer's "seed replay" swaps out (a `reseed` action) so an operator can
/// reproduce a specific fuzz order on demand without restarting the process.
int _activeSeed = seed;

Random? _rand;

/// The suite's deterministic random stream. It is reset to the active seed at
/// the START of every test, so a test draws the same sequence whether it runs
/// in a full pass or alone via the viewer's re-run button — per-test
/// reproducibility, not whole-run. `rand()` draws in `[0, 1)`; `rand(min, max)`
/// draws in `[min, max)`; within a test the stream advances on every draw.
double rand([num? min, num? max]) {
  final rng = _rand ??= _activeSeed != 0 ? Random(_activeSeed) : Random();
  final r = rng.nextDouble();
  if (min == null && max == null) return r;
  if (min != null && max != null) return min + r * (max - min);
  throw ArgumentError('rand() takes zero bounds or both');
}

/// Resets the [rand] stream so the next test starts from the active seed — the
/// hook that makes a single test's random draws reproducible on re-run.
void _resetRand() => _rand = _activeSeed != 0 ? Random(_activeSeed) : Random();

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

/// Cap on the viewer's in-memory execution history (Log view). A long soak
/// keeps the most recent [_historyCap] records; older ones drop off.
const int _historyCap = 2000;

/// Whether registrations capture their `file:line` call site: needed by the
/// viewer's jump-to-source AND by the report's test hashes, so it is on
/// whenever either can consume it. A bare `dart run` with neither pays no
/// per-registration stack-trace cost.
const bool _captureLocations = _linger || _reportPath != '';

/// Whether the run computes the suite's CONTENT identity (per-test hashes +
/// setupHash) for the report and hot reload's modified-test detection. On by
/// default; `-Dlabwright.identity=false` skips the hasher isolate (~3s, off
/// the bench path) when nothing consumes the hashes — hot reload then falls
/// back to re-running everything. The cheap contextHash is always reported.
const bool _identity = bool.fromEnvironment('labwright.identity', defaultValue: true);

/// The command the viewer's "open in editor" runs, as space-separated argv
/// with `{file}` / `{line}` placeholders substituted into single args (so
/// paths with spaces are safe — no shell). Defaults to the VS Code CLI; set
/// `-Dlabwright.editor` for another editor, e.g. `vim +{line} {file}`.
const String _editorCmd = String.fromEnvironment(
  'labwright.editor',
  defaultValue: 'code --goto {file}:{line}',
);

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

/// Registers a labelled control button for the interactive viewer — a bench
/// action the operator can fire on demand (e.g. `button('Reset unit', () async
/// { await dut.reset(); })`). Register buttons during setup, alongside [test];
/// the [action] runs serialized with test runs (the bench is singular) and its
/// [log] lines stream out like a test's. Narrow by design: a label and an
/// async action, nothing more. Buttons are viewer-only — they never run under
/// a plain `dart run`/CI pass.
///
/// Throws [StateError] if called after the run has started.
void button(String label, FutureOr<void> Function() action) {
  if (_runStarted) {
    throw StateError(
      '$_tag button "$label" registered after the run started. Register '
      'buttons during setup, before the first test() triggers the run.',
    );
  }
  _buttons.add(_Button(label, action));
}

/// Declares one key of the suite CONTEXT — the identity of what is on the
/// bench: DUT serial, firmware revision, fixture version, operator... Call it
/// during setup, alongside [test] registrations, with a JSON-encodable value
/// (typically read off the hardware):
///
/// ```dart
/// context('dut.serial', await dut.serialNumber());
/// context('dut.firmware', await dut.firmwareVersion());
/// ```
///
/// The report carries the map plus its SHA-1 (`contextHash`, canonical
/// sorted-key JSON), alongside each test's `hash` and the suite `setupHash` —
/// together the identity a skip-unmodified system needs: a test's outcome is
/// reusable only while all three match. Labwright cannot derive what is
/// physically on the bench, so the bench declares it here.
///
/// Throws [StateError] if called after the run has started, and
/// [JsonUnsupportedObjectError] immediately if [value] is not encodable.
void context(String key, Object? value) {
  if (_runStarted) {
    throw StateError(
      '$_tag context("$key") set after the run started. Declare the bench '
      'context during setup, before the first test() triggers the run.',
    );
  }
  jsonEncode(value); // fail fast: context values must be JSON-encodable
  _context[key] = value;
}

/// Wall-clock milliseconds since the epoch — the viewer stamps queue/run/log
/// events with these and formats them client-side in the operator's timezone.
int _now() => DateTime.now().millisecondsSinceEpoch;

/// Prints a log line, attributed to the currently running test (suite-level
/// when none is running) — shown in the viewer under its test with the time it
/// occurred, and carried in the report.
void log(String message) {
  stdout.writeln('  - $message');
  _running?.logs.add(_LogLine(_now(), message));
  _viewer?.update();
}

// ── registry and execution ───────────────────────────────────────────────────

/// One log line with the wall-clock time it was emitted.
class _LogLine {
  _LogLine(this.at, this.message);

  final int at;
  final String message;

  Map<String, Object?> toJson() => {'t': at, 'm': message};
}

class _TestEntry {
  _TestEntry(this.name, this.body, this.requirements, {required this.skip, this.file, this.line});

  final String name;
  final FutureOr<void> Function() body;
  final List<String> requirements;
  final bool skip;

  /// Where `test()` was called, captured at registration (interactive only) so
  /// the viewer can open the test's source. Null when not captured / unknown.
  final String? file;
  final int? line;

  String status = 'queued';
  String detail = '';
  int? ms;
  final List<_LogLine> logs = [];

  /// Wall-clock stamps (epoch ms) for the viewer's timeline: when this entry
  /// was queued for the current run, when it started, and when it finished.
  int? queuedAt;
  int? startedAt;
  int? finishedAt;

  /// Run-to-run diff, recomputed each pass: `newFail` / `newPass` / `changed`
  /// versus the prior run ('' when unchanged or never run before), and a flip
  /// count so the viewer can flag a test that keeps changing verdict (flaky).
  String change = '';
  int flips = 0;

  Map<String, Object?> toJson() => {
    'name': name,
    'status': status,
    if (requirements.isNotEmpty) 'requirements': requirements,
    if (file != null) 'file': file,
    if (line != null) 'line': line,
    if (change.isNotEmpty) 'change': change,
    if (flips >= 2) 'flaky': true,
    if (queuedAt != null) 'queuedAt': queuedAt,
    if (startedAt != null) 'startedAt': startedAt,
    if (finishedAt != null) 'finishedAt': finishedAt,
    if (detail.isNotEmpty) 'detail': detail,
    if (ms != null) 'ms': ms,
    if (logs.isNotEmpty) 'logs': [for (final l in logs) l.toJson()],
  };
}

bool _isFail(String s) => s == 'failed' || s == 'error';
bool _isTerminal(String s) => s == 'passed' || s == 'skipped' || _isFail(s);

/// One operator-registered control button (see [button]).
class _Button {
  _Button(this.label, this.action);

  final String label;
  final FutureOr<void> Function() action;
}

final List<_Button> _buttons = [];

/// The bench-declared suite context (see [context]) and, once computed, the
/// suite's content hashes. Hashes are computed lazily off the bench-critical
/// path — after a pass (when lingering or reporting) and after each hot
/// reload — and reflect the sources as LOADED, so a disk edit without a
/// reload correctly does not change what the report claims ran.
final Map<String, Object?> _context = {};
_SuiteHashes? _suiteHashes;

/// The suite's content identity as computed by the hasher isolate
/// (src/hash_main.dart): the shared [setupHash] plus a per-registration-site
/// test hash keyed `<abs path>:<line>`.
class _SuiteHashes {
  _SuiteHashes(this.setupHash, this.sites);

  final String setupHash;
  final Map<String, String> sites;

  /// The test hash for the registration at [file]:[line], or null when none
  /// could be attributed (tear-off/wrapper registrations) — callers must
  /// treat null as "assume modified".
  String? testHash(String? file, int? line) =>
      file == null || line == null ? null : sites['${File(file).absolute.uri.normalizePath().toFilePath()}:$line'];
}

/// SHA-1 of the canonical (sorted-key) JSON of [_context] — the "what was on
/// the bench" component of the skip-unmodified identity.
String _contextHash() => sha1.convert(utf8.encode(jsonEncode(SplayTreeMap<String, Object?>.from(_context)))).toString();

/// Computes the suite hashes in a spawned ISOLATE (src/hash_main.dart), or
/// returns null (with a warning) when hashing is unavailable — a hashing
/// failure must never fail a run. An isolate keeps the analyzer out of this
/// library's import graph (importing it costs ~3s of recompile on every
/// `dart run e2e/main.dart`) without nesting `dart run` under `dart run`,
/// which contends the dartdev compiler cache and sporadically exits 255 on
/// Windows. The compile happens lazily, off the bench-critical path.
Future<_SuiteHashes?> _tryComputeHashes() async {
  if (!_identity) return null; // opted out — callers fall back conservatively
  final result = ReceivePort();
  final errors = ReceivePort();
  try {
    await Isolate.spawnUri(
      Uri.parse('package:labwright/src/hash_main.dart'),
      [Platform.script.toFilePath()],
      result.sendPort,
      onError: errors.sendPort,
    );
    final raw = await Future.any([
      result.first,
      errors.first.then((e) => throw StateError('$e')),
    ]).timeout(const Duration(minutes: 2));
    final decoded = (jsonDecode(raw as String) as Map).cast<String, Object?>();
    return _SuiteHashes(decoded['setupHash'] as String, (decoded['sites'] as Map).cast<String, String>());
  } catch (e) {
    stderr.writeln('$_tag source hashing unavailable: $e');
    return null;
  } finally {
    result.close();
    errors.close();
  }
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

// Chronological record of every test execution (oldest first) for the viewer's
// Log view. Pushed to clients as deltas — not in the frequently-resent snapshot
// — and capped so a long soak stays bounded in memory.
final List<Map<String, Object?>> _history = [];
int _historyId = 0; // unique id per execution record
int _runSeq = 0; // increments each pass, so records group by run

/// Snapshots [entry]'s just-finished execution into the history feed and pushes
/// it to the viewer. Capped ([_historyCap]); the oldest record drops first.
void _record(_TestEntry entry) {
  final record = {
    'id': ++_historyId,
    'run': _runSeq,
    'name': entry.name,
    'status': entry.status,
    if (entry.ms != null) 'ms': entry.ms,
    if (entry.file != null) 'file': entry.file,
    if (entry.line != null) 'line': entry.line,
    if (entry.change.isNotEmpty) 'change': entry.change,
    if (entry.queuedAt != null) 'queuedAt': entry.queuedAt,
    if (entry.startedAt != null) 'startedAt': entry.startedAt,
    if (entry.finishedAt != null) 'finishedAt': entry.finishedAt,
    if (entry.detail.isNotEmpty) 'detail': entry.detail,
    if (entry.logs.isNotEmpty) 'logs': [for (final l in entry.logs) l.toJson()],
  };
  _history.add(record);
  if (_history.length > _historyCap) _history.removeAt(0);
  _viewer?.pushHistory(record);
}

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
  // Capture the call site only when something will consume it (the viewer's
  // jump-to-source or the report's test hashes) — a stack trace per test is
  // pure waste on a plain `dart run` pass.
  final (file, line) = _captureLocations ? _callerLocation() : (null, null);
  _registry.add(_TestEntry(name, body, requirements, skip: skip, file: file, line: line));
  if (!_runScheduled) {
    _runScheduled = true;
    // Fires once the current synchronous burst (typically the rest of main)
    // has finished — the registration phase is over.
    Timer.run(_runAll);
  }
}

/// The first stack frame outside this framework file — the user's `test()`
/// call site — as (file, line), or (null, null) if it can't be parsed. Lets
/// the viewer open a test's source at the right spot.
(String?, int?) _callerLocation() {
  // VM frames look like `#3  register (file:///abs/foo.dart:30:3)`.
  final re = RegExp(r'\(([^\s()]+):(\d+):\d+\)');
  for (final frame in StackTrace.current.toString().split('\n')) {
    final m = re.firstMatch(frame);
    if (m == null) continue;
    final uri = m.group(1)!;
    if (uri.endsWith('labwright.dart')) continue; // still inside the framework
    final path = uri.startsWith('file://') ? Uri.parse(uri).toFilePath() : uri;
    return (path, int.parse(m.group(2)!));
  }
  return (null, null);
}

/// The suite state the viewer and the report share.
Map<String, Object?> _state() => {
  'seed': _activeSeed,
  'done': _done,
  // Whether a run is executing (UI disables re-run controls) and whether
  // the viewer is lingering with the control plane live (UI shows them).
  'busy': _runInProgress,
  'interactive': _linger,
  if (_buttons.isNotEmpty) 'buttons': [for (final b in _buttons) b.label],
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

/// Shard over the one in-process registry (the whole suite), then let
/// [seedValue] shuffle only the ORDER of the selection — membership is stable
/// (index `% N == I`), so the seed never changes WHICH tests run, only when.
List<_TestEntry> _select(int seedValue) {
  final sel = [
    for (var i = 0; i < _registry.length; i++)
      if (i % totalShards == shardIndex) _registry[i],
  ];
  if (seedValue != 0) sel.shuffle(Random(seedValue));
  return sel;
}

Future<void> _runAll() async {
  _runStarted = true;
  if (totalShards < 1 || shardIndex < 0 || shardIndex >= totalShards) {
    stderr.writeln('$_tag invalid shard $shardIndex of $totalShards');
    exitCode = 64;
    return;
  }
  _selected = _select(_activeSeed);

  // The seed prints once, here at suite start (not per test).
  if (_activeSeed != 0) stdout.writeln('$_tag seed $_activeSeed');

  if (_viewerEnabled) {
    _viewer = await Viewer.start(_port, _state);
    if (_viewer != null) {
      // The control plane: the viewer POSTs actions back here. Only reachable
      // while we linger (an explicit flag), so CI never grows an action surface.
      _viewer!.onAction = _handleAction;
      _viewer!.report = _report; // GET /report.json for download
      _viewer!.history = () => _history; // Log view feed (batch on connect)

      stdout.writeln(
        '$_tag viewer on http://localhost:${_viewer!.port}'
        '${totalShards > 1 ? ' - shard $shardIndex of $totalShards '
                  '(${_selected.length} of ${_registry.length})' : ''}',
      );
    }
  }

  await _execute(_selected);

  if (_linger && _viewer != null) {
    // Baseline for hot reload's modified-test detection — computed here, off
    // the bench-critical path, once the first pass is done.
    _suiteHashes ??= await _tryComputeHashes();
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
  _runSeq++;
  // Remember each entry's prior verdict so we can diff it the moment it reruns.
  final prior = {for (final e in entries) e: e.status};
  // Queue them all up front (same instant) so the Queue pane shows the whole
  // pending set draining, and each carries the time it was queued.
  final queuedAt = _now();
  for (final e in entries) {
    e
      ..status = 'queued'
      ..detail = ''
      ..ms = null
      ..startedAt = null
      ..finishedAt = null
      ..queuedAt = queuedAt
      ..logs.clear();
  }
  _viewer?.update();
  for (final entry in entries) {
    if (_stopRequested) break;
    await _runOne(entry);
    // Diff against the prior run (independent per test), then snapshot the
    // finished execution into the Log feed — so it pops in as it completes.
    _diff(entry, prior[entry]!);
    _record(entry);
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
    // The report carries the content identity — make sure it exists (a child
    // spawn, once per process; a reload refreshes it separately).
    _suiteHashes ??= await _tryComputeHashes();
    File(_reportPath).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(_report()));
    stdout.writeln('$_tag report written to $_reportPath');
  }
}

/// Records how [entry]'s verdict moved from [priorStatus] to its current one:
/// `newFail` / `newPass` / `changed` (or clears the badge when unchanged or
/// there was no prior run), and bumps the flip counter when it crossed the
/// pass↔fail line — that feeds the viewer's flaky flag.
void _diff(_TestEntry entry, String priorStatus) {
  final now = entry.status;
  if (!_isTerminal(priorStatus) || priorStatus == now) {
    entry.change = '';
    return;
  }
  final wasFail = _isFail(priorStatus), nowFail = _isFail(now);
  entry.change = !wasFail && nowFail ? 'newFail' : (wasFail && !nowFail ? 'newPass' : 'changed');
  if (wasFail != nowFail) entry.flips++;
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
  if (type == 'open') {
    // Opening a source file is always allowed — it touches the editor, not the
    // bench, so it never waits on (or blocks) a run.
    final file = action['file'] as String?;
    if (file == null || file.isEmpty) {
      return const {'accepted': false, 'error': 'no file'};
    }
    unawaited(_openInEditor(file, (action['line'] as num?)?.toInt() ?? 1));
    return const {'accepted': true};
  }
  if (_runInProgress) {
    return const {'accepted': false, 'error': 'a run is already in progress'};
  }
  switch (type) {
    case 'hotReload':
      // Reload edited sources, then re-run only what changed (falling back to
      // the whole selection when hashes can't tell). Held busy across the
      // reload so no other action slips in; the gate is finally-protected so
      // no throw can leave the UI locked out.
      _runInProgress = true;
      _viewer?.update();
      String? err;
      List<_TestEntry> modified = const [];
      try {
        err = await _hotReload();
        if (err == null) modified = await _modifiedAfterReload();
      } catch (e) {
        err = 'hot reload failed: $e';
      } finally {
        if (err != null || modified.isEmpty) {
          _runInProgress = false;
          _viewer?.update();
        }
      }
      if (err != null) return {'accepted': false, 'error': err};
      if (modified.isEmpty) {
        stdout.writeln('$_tag hot reload - no modified tests');
        return const {'accepted': true, 'modified': 0};
      }
      stdout.writeln('$_tag hot reload - ${modified.length} modified test(s)');
      unawaited(_execute(modified));
      return {'accepted': true, 'modified': modified.length};
    case 'reseed':
      // Seed replay: re-shuffle the selection to a chosen seed and re-run, so
      // an operator reproduces a specific fuzz order without a restart.
      _activeSeed = (action['seed'] as num?)?.toInt() ?? 0;
      _selected = _select(_activeSeed);
      unawaited(_execute(_selected));
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
    case 'button':
      final i = (action['index'] as num?)?.toInt() ?? -1;
      if (i < 0 || i >= _buttons.length) {
        return {'accepted': false, 'error': 'no button #$i'};
      }
      unawaited(_runButton(_buttons[i]));
    default:
      return {'accepted': false, 'error': 'unknown action "$type"'};
  }
  return const {'accepted': true};
}

/// Recomputes the suite hashes after a reload and returns the selected tests
/// whose registration content changed since the previous baseline. Falls back
/// to the WHOLE selection (conservative) when there is no baseline, hashing is
/// unavailable, or the shared setup changed; a test with no attributable hash
/// (tear-off/wrapper registration) always counts as modified. The fresh hashes
/// become the new baseline, so the report reflects the reloaded sources.
Future<List<_TestEntry>> _modifiedAfterReload() async {
  final before = _suiteHashes;
  final fresh = await _tryComputeHashes();
  _suiteHashes = fresh;
  if (before == null || fresh == null || before.setupHash != fresh.setupHash) {
    return _selected;
  }
  return [
    for (final t in _selected)
      if (fresh.testHash(t.file, t.line) == null || fresh.testHash(t.file, t.line) != before.testHash(t.file, t.line))
        t,
  ];
}

/// Runs one operator [button]'s action, serialized with test runs via the same
/// `_runInProgress` gate (the bench is singular). A throwing action is caught
/// and surfaced — a button must never crash the lingering process. Does not
/// touch test state or the exit code (buttons are viewer-only).
Future<void> _runButton(_Button b) async {
  _runInProgress = true;
  _viewer?.update();
  stdout.writeln('$_tag button "${b.label}"');
  final watch = Stopwatch()..start();
  try {
    await b.action();
    watch.stop();
    stdout.writeln('$_tag button "${b.label}" done (${watch.elapsedMilliseconds} ms)');
  } catch (e) {
    watch.stop();
    stdout.writeln('$_tag button "${b.label}" failed (${watch.elapsedMilliseconds} ms): $e');
  }
  _runInProgress = false;
  _viewer?.update();
}

/// Self-triggers a Dart hot reload, then leaves the caller to re-run. Edited
/// test BODIES pick up their new code; ADDED or REMOVED tests still need a
/// restart (registration does not re-run). Requires the process to be started
/// with the VM service on (the `labwright` CLI adds `--enable-vm-service` in
/// interactive mode). Returns null on success, else a human-readable reason.
Future<String?> _hotReload() async {
  final serverUri = (await developer.Service.getInfo()).serverUri;
  if (serverUri == null) {
    return 'hot reload needs the VM service — start with --enable-vm-service '
        '(the labwright CLI adds it in --interactive mode)';
  }
  final wsUri = serverUri.replace(
    scheme: serverUri.scheme == 'https' ? 'wss' : 'ws',
    pathSegments: [...serverUri.pathSegments.where((s) => s.isNotEmpty), 'ws'],
  );
  vm.VmService? service;
  try {
    service = await vmio.vmServiceConnectUri(wsUri.toString());
    final isolateId = (await service.getVM()).isolates!.first.id!;
    final report = await service.reloadSources(isolateId);
    return report.success == true ? null : 'the VM rejected the reload';
  } catch (e) {
    return 'hot reload failed: $e';
  } finally {
    await service?.dispose();
  }
}

/// Opens [file] at [line] in the operator's editor via [_editorCmd]. Runs
/// detached with an argv list (no shell), so a path with spaces is one safe
/// argument; a missing editor is a warning, never a crash.
Future<void> _openInEditor(String file, int line) async {
  final argv = [
    for (final a in _editorCmd.split(' '))
      if (a.isNotEmpty) a.replaceAll('{file}', file).replaceAll('{line}', '$line'),
  ];
  if (argv.isEmpty) return;
  try {
    await Process.start(argv.first, argv.sublist(1), mode: ProcessStartMode.detached);
  } catch (e) {
    stderr.writeln('$_tag could not open editor (${argv.first}): $e');
  }
}

/// The report: the suite state plus the requirements trace
/// (requirement ID → every test that claims it, with status). Viewer-only
/// keys (the button labels) are dropped — the report is about run results.
Map<String, Object?> _report() {
  final requirements = <String, List<Map<String, Object?>>>{};
  for (final t in _selected) {
    for (final req in t.requirements) {
      requirements.putIfAbsent(req, () => []).add({'test': t.name, 'status': t.status});
    }
  }
  final state = _state()..remove('buttons');
  // Content identity, contained to the report: each test's hash, the shared
  // setupHash, and the bench-declared context + contextHash. A consumer may
  // reuse a prior verdict only while all three match (see [context]).
  // Reads the cached identity only — computed at pass end / reload time (a
  // sync report from the viewer before the first pass ends just omits it).
  final hashes = _suiteHashes;
  // The report keeps logs as plain strings (a stable machine format); the
  // viewer carries the timestamped {t, m} form.
  for (final t in (state['tests'] as List).cast<Map<String, Object?>>()) {
    final logs = t['logs'];
    if (logs is List) t['logs'] = [for (final l in logs) (l as Map)['m']];
    final hash = hashes?.testHash(t['file'] as String?, t['line'] as int?);
    if (hash != null) t['hash'] = hash;
  }
  return {
    ...state,
    if (hashes != null) 'setupHash': hashes.setupHash,
    if (_context.isNotEmpty) 'context': Map<String, Object?>.of(_context),
    'contextHash': _contextHash(),
    'requirements': requirements,
  };
}

Future<void> _runOne(_TestEntry entry) async {
  // Requirement IDs live in the report and the viewer, not the console.
  if (entry.skip) {
    entry
      ..status = 'skipped'
      ..finishedAt = _now();
    stdout.writeln('${_paint('SKIP', _yellow)} ${entry.name}');
    _viewer?.update();
    return;
  }
  stdout.writeln('${_paint('RUN ', _dim)} ${entry.name}');
  entry
    ..status = 'running'
    ..startedAt = _now();
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
  entry
    ..status = status.name
    ..finishedAt = _now();
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
