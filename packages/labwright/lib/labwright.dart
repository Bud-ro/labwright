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

import 'src/restart_code.dart';
import 'src/viewer.dart';

export 'package:matcher/expect.dart';

const int totalShards = int.fromEnvironment('labwright.totalShards', defaultValue: 1);
const int shardIndex = int.fromEnvironment('labwright.shardIndex');

const int _seedUnset = -1;
const int _seedDefine = int.fromEnvironment('labwright.seed', defaultValue: _seedUnset);

const int _shardSeed = 0x5EED;

final int seed = _seedDefine != _seedUnset ? _seedDefine : (totalShards > 1 ? _shardSeed : Random().nextInt(1 << 31));

int _activeSeed = seed;

Random? _rand;

double rand([num? min, num? max]) {
  final rng = _rand ??= _activeSeed != 0 ? Random(_activeSeed) : Random();
  final r = rng.nextDouble();
  if (min == null && max == null) return r;
  if (min != null && max != null) return min + r * (max - min);
  throw ArgumentError('rand() takes zero bounds or both');
}

void _resetRand() => _rand = _activeSeed != 0 ? Random(_activeSeed) : Random();

const int _port = int.fromEnvironment('labwright.port', defaultValue: 1212);
const bool _viewerEnabled = bool.fromEnvironment('labwright.viewer', defaultValue: true);
const bool _keepOpen = bool.fromEnvironment('labwright.keepOpen');
const bool _interactive = bool.fromEnvironment('labwright.interactive');

const bool _supervised = bool.fromEnvironment('labwright.supervised');

const bool _linger = _keepOpen || _interactive;
const String _reportPath = String.fromEnvironment('labwright.report');

const int _historyCap = 2000;

const bool _captureLocations = _linger || _reportPath != '';

const bool _identity = bool.fromEnvironment('labwright.identity', defaultValue: true);

final String _editorLink = editorLinkTemplate(
  isWindows: Platform.isWindows,
  wslDistro: Platform.isLinux ? Platform.environment['WSL_DISTRO_NAME'] : null,
);

const String _tag = '[Labwright]:';

final bool _ansi = stdout.supportsAnsiEscapes;
String _paint(String text, String code) => _ansi ? '$code$text\x1b[0m' : text;
const String _green = '\x1b[32m';
const String _red = '\x1b[31m';
const String _yellow = '\x1b[33m';
const String _dim = '\x1b[2m';

enum TestStatus {
  queued('QUEUE', _dim),

  running('RUN ', _dim),

  passed('PASS', _green),

  failed('FAIL', _red),

  error('ERR ', _red),

  skipped('SKIP', _yellow)
  ;

  const TestStatus(this._label, this._color);

  final String _label;
  final String _color;

  String get _console => _paint(_label, _color);

  bool get isFail => this == failed || this == error;

  bool get isTerminal => this == passed || this == skipped || isFail;
}

enum _TestChange {
  newFail,

  newPass,

  changed,
}

void test(
  String name,
  FutureOr<void> Function() body, {
  String? requirement,
  List<String> requirements = const [],
}) => _register(name, body, skip: false, requirements: [if (requirement != null) requirement, ...requirements]);

void skipTest(
  String name,
  FutureOr<void> Function() body, {
  String? requirement,
  List<String> requirements = const [],
}) => _register(name, body, skip: true, requirements: [if (requirement != null) requirement, ...requirements]);

void button(String label, FutureOr<void> Function() action) {
  if (_runStarted) {
    throw StateError(
      '$_tag button "$label" registered after the run started. Register '
      'buttons during setup, before the first test() triggers the run.',
    );
  }
  _buttons.add(_Button(label, action));
}

void context(String key, Object? value) {
  if (_runStarted) {
    throw StateError(
      '$_tag context("$key") set after the run started. Declare the bench '
      'context during setup, before the first test() triggers the run.',
    );
  }
  jsonEncode(value);
  _context[key] = value;
}

int _now() => DateTime.now().millisecondsSinceEpoch;

void log(String message) {
  stdout.writeln('  - $message');
  final line = _LogLine(_now(), message);
  (_running?.logs ?? _actionLogs)?.add(line);
  final owner = _running?.name ?? _actionName;
  if (owner != null) _viewer?.pushLog(owner, line.at, line.message);
}

List<_LogLine>? _actionLogs;
String? _actionName;

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

  final String? file;
  final int? line;

  TestStatus status = TestStatus.queued;
  String detail = '';
  int? ms;
  final List<_LogLine> logs = [];

  int? queuedAt;
  int? startedAt;
  int? finishedAt;

  _TestChange? change;
  int flips = 0;

  Map<String, Object?> toJson() => {
    'name': name,
    'status': status.name,
    if (requirements.isNotEmpty) 'requirements': requirements,
    if (file != null) 'file': file,
    if (line != null) 'line': line,
    if (change case final change?) 'change': change.name,
    if (flips >= _flakyFlips) 'flaky': true,
    if (queuedAt != null) 'queuedAt': queuedAt,
    if (startedAt != null) 'startedAt': startedAt,
    if (finishedAt != null) 'finishedAt': finishedAt,
    if (detail.isNotEmpty) 'detail': detail,
    if (ms != null) 'ms': ms,
    if (logs.isNotEmpty) 'logs': [for (final l in logs) l.toJson()],
  };
}

class _Button {
  _Button(this.label, this.action);

  final String label;
  final FutureOr<void> Function() action;
}

final List<_Button> _buttons = [];

final Map<String, Object?> _context = {};
_SuiteHashes? _suiteHashes;

class _SuiteHashes {
  _SuiteHashes(this.setupHash, this.sites);

  final String setupHash;
  final Map<String, String> sites;

  String? testHash(String? file, int? line) =>
      file == null || line == null ? null : sites['${File(file).absolute.uri.normalizePath().toFilePath()}:$line'];
}

String _contextHash() => sha1.convert(utf8.encode(jsonEncode(SplayTreeMap<String, Object?>.from(_context)))).toString();

Future<_SuiteHashes?> _tryComputeHashes() async {
  if (!_identity) return null;
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
    final decoded = jsonDecode(raw as String) as Map<String, Object?>;
    final sites = decoded['sites'] as Map<String, Object?>;
    return _SuiteHashes(decoded['setupHash'] as String, {
      for (final MapEntry(:key, :value) in sites.entries) key: value as String,
    });
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
bool _runInProgress = false;
bool _stopRequested = false;
_TestEntry? _running;
Viewer? _viewer;

final List<Map<String, Object?>> _history = [];
int _historyId = 0;
int _runSeq = 0;

void _record(_TestEntry entry) => _pushRecord(entry.toJson());

void _pushRecord(Map<String, Object?> fields) {
  final record = {...fields, 'id': ++_historyId, 'run': _runSeq};
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
  final (file, line) = _captureLocations ? _callerLocation() : (null, null);
  _registry.add(_TestEntry(name, body, requirements, skip: skip, file: file, line: line));
  if (!_runScheduled) {
    _runScheduled = true;
    Timer.run(_runAll);
  }
}

(String?, int?) _callerLocation() {
  final re = RegExp(r'\(([^\s()]+):(\d+):\d+\)');
  for (final frame in StackTrace.current.toString().split('\n')) {
    final m = re.firstMatch(frame);
    if (m == null) continue;
    final uri = m.group(1)!;
    if (uri.endsWith('labwright.dart')) continue;
    final String? path;
    if (uri.startsWith('file://')) {
      path = Uri.parse(uri).toFilePath();
    } else if (uri.startsWith('package:')) {
      path = Isolate.resolvePackageUriSync(Uri.parse(uri))?.toFilePath();
    } else if (uri.startsWith('dart:')) {
      path = null;
    } else {
      path = uri;
    }
    if (path == null) continue;
    return (File(path).absolute.path, int.parse(m.group(2)!));
  }
  return (null, null);
}

Map<String, Object?> _state() => {
  'seed': _activeSeed,
  'done': _done,
  'busy': _runInProgress,
  'interactive': _linger,
  'supervised': _supervised,
  if (_linger) 'editorLink': _editorLink,
  if (_buttons.isNotEmpty) 'buttons': [for (final b in _buttons) b.label],
  'queue': [for (final t in _queue) t.name],
  'tests': [for (final t in _selected) t.toJson()],
  'summary': _summary(),
};

Map<String, Object?> _summary() {
  var passed = 0, failed = 0, errors = 0, skipped = 0;
  for (final t in _selected) {
    switch (t.status) {
      case TestStatus.passed:
        passed++;
      case TestStatus.failed:
        failed++;
      case TestStatus.error:
        errors++;
      case TestStatus.skipped:
        skipped++;
      case TestStatus.queued || TestStatus.running:
        break;
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

  if (_activeSeed != 0) stdout.writeln('$_tag seed $_activeSeed');

  if (_viewerEnabled) {
    final viewer = _viewer = await Viewer.start(_port, _state);
    if (viewer != null) {
      if (_linger) viewer.actions = _actions;
      viewer.report = _report;
      viewer.history = () => _history;

      stdout.writeln(
        '$_tag viewer on http://localhost:${viewer.port}'
        '${totalShards > 1 ? ' - shard $shardIndex of $totalShards '
                  '(${_selected.length} of ${_registry.length})' : ''}',
      );
    }
  }

  await _execute(_selected);

  final viewer = _viewer;
  if (_linger && viewer != null) {
    _suiteHashes ??= await _tryComputeHashes();
    stdout.writeln(
      '$_tag View results and re-run tests at '
      'http://localhost:${viewer.port}. Ctrl + C to exit --interactive '
      'mode.',
    );
  } else {
    await viewer?.close();
  }
}

final List<_TestEntry> _queue = [];

Future<void> _execute(List<_TestEntry> entries) async {
  _runInProgress = true;
  _done = false;
  _runSeq++;
  final queuedAt = _now();
  _queue
    ..clear()
    ..addAll(entries);
  for (final e in entries) {
    e.queuedAt = queuedAt;
  }
  _viewer?.update();
  while (_queue.isNotEmpty) {
    if (_stopRequested) {
      _queue.clear();
      break;
    }
    final entry = _queue.removeAt(0);
    final prior = entry.status;
    entry
      ..detail = ''
      ..ms = null
      ..startedAt = null
      ..finishedAt = null
      ..logs.clear();
    await _runOne(entry);
    _diff(entry, prior);
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
    _suiteHashes ??= await _tryComputeHashes();
    File(_reportPath).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(_report()));
    stdout.writeln('$_tag report written to $_reportPath');
  }
}

void _diff(_TestEntry entry, TestStatus priorStatus) {
  final now = entry.status;
  if (!priorStatus.isTerminal || priorStatus == now) {
    entry.change = null;
    return;
  }
  if (priorStatus == TestStatus.skipped || now == TestStatus.skipped) {
    entry.change = _TestChange.changed;
    return;
  }
  final wasFail = priorStatus.isFail, nowFail = now.isFail;
  entry.change = nowFail && !wasFail
      ? _TestChange.newFail
      : (wasFail && !nowFail ? _TestChange.newPass : _TestChange.changed);
  if (wasFail != nowFail) entry.flips++;
}

const int _flakyFlips = 2;

final Map<String, Future<Map<String, Object?>> Function(Map<String, Object?>)> _actions = {
  'run': _runAction,
  'run-failed': _runFailedAction,
  'run-one': _runOneAction,
  'stop': _stopAction,
  'reload': _reloadAction,
  'restart': _restartAction,
  'reseed': _reseedAction,
  'button': _buttonAction,
};

Map<String, Object?>? _rejectUnlessIdle() {
  if (_runInProgress) {
    return const {'accepted': false, 'error': 'a run is already in progress'};
  }
  _stopRequested = false;
  return null;
}

Future<Map<String, Object?>> _stopAction(Map<String, Object?> body) async {
  _stopRequested = true;
  return const {'accepted': true};
}

Future<Map<String, Object?>> _runAction(Map<String, Object?> body) async {
  final rejected = _rejectUnlessIdle();
  if (rejected != null) return rejected;
  unawaited(_execute(_selected));
  return const {'accepted': true};
}

Future<Map<String, Object?>> _runFailedAction(Map<String, Object?> body) async {
  final rejected = _rejectUnlessIdle();
  if (rejected != null) return rejected;
  final failed = [
    for (final t in _selected)
      if (t.status.isFail) t,
  ];
  if (failed.isEmpty) {
    return const {'accepted': false, 'error': 'nothing to re-run'};
  }
  unawaited(_execute(failed));
  return const {'accepted': true};
}

Future<Map<String, Object?>> _runOneAction(Map<String, Object?> body) async {
  final rejected = _rejectUnlessIdle();
  if (rejected != null) return rejected;
  for (final t in _selected) {
    if (t.name == body['test']) {
      unawaited(_execute([t]));
      return const {'accepted': true};
    }
  }
  return {'accepted': false, 'error': 'no test named "${body['test']}"'};
}

Future<Map<String, Object?>> _restartAction(Map<String, Object?> body) async {
  final rejected = _rejectUnlessIdle();
  if (rejected != null) return rejected;
  if (!_supervised) {
    return const {
      'accepted': false,
      'error': 'hot restart needs the labwright run supervisor (bare dart run cannot respawn itself)',
    };
  }
  stdout.writeln('$_tag hot restart - exiting for a fresh suite process');
  unawaited(Future<void>.delayed(const Duration(milliseconds: 50)).then((_) => exit(restartExitCode)));
  return const {'accepted': true};
}

Future<Map<String, Object?>> _reloadAction(Map<String, Object?> body) async {
  final rejected = _rejectUnlessIdle();
  if (rejected != null) return rejected;
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
}

Future<Map<String, Object?>> _reseedAction(Map<String, Object?> body) async {
  final rejected = _rejectUnlessIdle();
  if (rejected != null) return rejected;
  final requested = body['seed'];
  if (requested is! num) {
    return const {'accepted': false, 'error': 'reseed needs an integer seed (0 = registration order)'};
  }
  _activeSeed = requested.toInt();
  _selected = _select(_activeSeed);
  unawaited(_execute(_selected));
  return const {'accepted': true};
}

Future<Map<String, Object?>> _buttonAction(Map<String, Object?> body) async {
  final rejected = _rejectUnlessIdle();
  if (rejected != null) return rejected;
  final i = (body['index'] as num?)?.toInt() ?? -1;
  if (i < 0 || i >= _buttons.length) {
    return {'accepted': false, 'error': 'no button #$i'};
  }
  unawaited(_runButton(_buttons[i]));
  return const {'accepted': true};
}

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

Future<void> _runButton(_Button b) async {
  _runInProgress = true;
  _viewer?.update();
  stdout.writeln('$_tag button "${b.label}"');
  final logs = _actionLogs = <_LogLine>[];
  _actionName = 'button: ${b.label}';
  final startedAt = _now();
  final watch = Stopwatch()..start();
  var detail = '';
  try {
    await b.action();
  } catch (e) {
    detail = '$e';
  }
  watch.stop();
  _actionLogs = null;
  _actionName = null;
  final ms = watch.elapsedMilliseconds;
  stdout.writeln('$_tag button "${b.label}" ${detail.isEmpty ? 'done ($ms ms)' : 'failed ($ms ms): $detail'}');
  _pushRecord({
    'name': 'button: ${b.label}',
    'status': detail.isEmpty ? 'passed' : 'error',
    'ms': ms,
    'startedAt': startedAt,
    'finishedAt': _now(),
    if (detail.isNotEmpty) 'detail': detail,
    if (logs.isNotEmpty) 'logs': [for (final l in logs) l.toJson()],
  });
  _runInProgress = false;
  _viewer?.update();
}

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

Map<String, Object?> _report() {
  final requirements = <String, List<Map<String, Object?>>>{};
  for (final t in _selected) {
    for (final req in t.requirements) {
      requirements.putIfAbsent(req, () => []).add({'test': t.name, 'status': t.status.name});
    }
  }
  final hashes = _suiteHashes;
  final tests = <Map<String, Object?>>[];
  for (final t in _selected) {
    final json = t.toJson();
    if (t.logs.isNotEmpty) json['logs'] = [for (final l in t.logs) l.message];
    final hash = hashes?.testHash(t.file, t.line);
    if (hash != null) json['hash'] = hash;
    tests.add(json);
  }
  final state = _state()
    ..remove('buttons')
    ..remove('editorLink')
    ..['tests'] = tests;
  return {
    ...state,
    if (hashes != null) 'setupHash': hashes.setupHash,
    if (_context.isNotEmpty) 'context': Map<String, Object?>.of(_context),
    'contextHash': _contextHash(),
    'requirements': requirements,
  };
}

Future<void> _runOne(_TestEntry entry) async {
  if (entry.skip) {
    entry
      ..status = TestStatus.skipped
      ..finishedAt = _now();
    stdout.writeln('${TestStatus.skipped._console} ${entry.name}');
    _viewer?.update();
    return;
  }
  stdout.writeln('${TestStatus.running._console} ${entry.name}');
  entry
    ..status = TestStatus.running
    ..startedAt = _now();
  _running = entry;
  _viewer?.update();
  _resetRand();
  final watch = Stopwatch()..start();
  final monitor = await TestCaseMonitor.run(entry.body);
  watch.stop();
  _running = null;
  entry.ms = watch.elapsedMilliseconds;
  final TestStatus status;
  switch (monitor.state) {
    case State.passed:
      status = TestStatus.passed;
    case State.skipped:
      status = TestStatus.skipped;
    case State.pending || State.running:
      status = TestStatus.error;
      entry.detail = 'internal: test case still ${monitor.state.name} after run';
    case State.failed:
      final errors = monitor.errors.toList();
      status = errors.every((e) => e.error is TestFailure) ? TestStatus.failed : TestStatus.error;
      entry.detail = errors.map((e) => e.error.toString().trimRight()).join('\n').trim();
  }
  entry
    ..status = status
    ..finishedAt = _now();
  if (status.isFail) exitCode = 1;
  final note = entry.detail.isEmpty ? '' : '\n  ${entry.detail.replaceAll('\n', '\n  ')}';
  stdout.writeln('${status._console} ${entry.name} (${entry.ms} ms)$note');
  _viewer?.update();
}
