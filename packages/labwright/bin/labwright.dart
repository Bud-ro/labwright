// The `labwright` runner: executes hardware E2E files sequentially and hosts
// the live execution viewer.
//
//   labwright run [paths...] [--port N] [--report out.json]
//                 [--total-shards N --shard-index I]
//                 [--fail-on-skipped] [--keep-open]
//
//   paths             E2E files or directories (default: ./e2e). Directories
//                     are walked recursively for *.dart, hidden dirs skipped.
//   --port N          Viewer HTTP port (default 8642; 0 picks a free port).
//                     The viewer is up from launch, streaming live results.
//   --report out.json Write the machine-readable run report (files, tests,
//                     and the requirements trace).
//   --total-shards N  With --shard-index I: run only tests whose
//   --shard-index I   registration index i satisfies i % N == I (dart
//                     test's sharding convention) — one bench per shard.
//   --fail-on-skipped Exit non-zero when any test is skipped (strict CI —
//                     generated boilerplate ships as skipTest until armed).
//   --keep-open       Keep the viewer serving after the run until Ctrl-C.
//
// Each file runs under `dart run` with LABWRIGHT_REPORT=jsonl; the runner
// renders its events, updates the viewer, and aggregates the exit code:
// non-zero iff any test failed/errored, a file crashed, or --fail-on-skipped
// saw a skip. Files run strictly one at a time — hardware E2E owns the
// bench; there is no parallelism tier.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  var port = 8642;
  String? reportPath;
  var failOnSkipped = false;
  var keepOpen = false;
  var totalShards = 1;
  var shardIndex = 0;
  final paths = <String>[];

  final rest = [...args];
  if (rest.isNotEmpty && rest.first == 'run') rest.removeAt(0);
  while (rest.isNotEmpty) {
    final arg = rest.removeAt(0);
    switch (arg) {
      case '--port':
        port = int.tryParse(rest.isEmpty ? '' : rest.removeAt(0)) ?? port;
      case '--report':
        reportPath = rest.isEmpty ? null : rest.removeAt(0);
      case '--total-shards':
        totalShards =
            int.tryParse(rest.isEmpty ? '' : rest.removeAt(0)) ?? totalShards;
      case '--shard-index':
        shardIndex =
            int.tryParse(rest.isEmpty ? '' : rest.removeAt(0)) ?? shardIndex;
      case '--fail-on-skipped':
        failOnSkipped = true;
      case '--keep-open':
        keepOpen = true;
      case '--help' || '-h':
        stdout.writeln(_usage);
        return;
      default:
        paths.add(arg);
    }
  }
  if (paths.isEmpty) paths.add('e2e');
  if (totalShards < 1 || shardIndex < 0 || shardIndex >= totalShards) {
    stderr.writeln(
        'labwright: invalid shard $shardIndex of $totalShards\n$_usage');
    exitCode = 64;
    return;
  }

  final files = _collectFiles(paths);
  if (files.isEmpty) {
    stderr
      ..writeln('no E2E .dart files found under: ${paths.join(', ')}')
      ..writeln(_usage);
    exitCode = 64;
    return;
  }

  final state = _RunState(files);
  final viewer = await _Viewer.start(port, state);
  stdout.writeln('labwright: viewer on http://localhost:${viewer.port} · '
      '${files.length} file(s)'
      '${totalShards > 1 ? ' · shard $shardIndex of $totalShards' : ''}');

  for (final file in files) {
    await _runFile(file, state, viewer,
        totalShards: totalShards, shardIndex: shardIndex);
  }
  state.done = true;
  viewer.broadcast({'e': 'done'});

  final summary = state.summary();
  stdout.writeln('labwright: ${summary.tests} test(s) — '
      '${summary.passed} passed, ${summary.failed} failed, '
      '${summary.errors} errors, ${summary.skipped} skipped');
  if (reportPath != null) {
    File(reportPath).writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(state.toJson()));
    stdout.writeln('labwright: report written to $reportPath');
  }
  if (summary.failed > 0 || summary.errors > 0 || state.crashedFiles > 0) {
    exitCode = 1;
  }
  if (failOnSkipped && summary.skipped > 0) exitCode = 1;

  if (keepOpen) {
    stdout.writeln('labwright: --keep-open — viewer stays on '
        'http://localhost:${viewer.port} (Ctrl-C to exit)');
  } else {
    await viewer.close();
  }
}

const _usage = '''
usage: labwright run [paths...] [--port N] [--report out.json]
                     [--total-shards N --shard-index I]
                     [--fail-on-skipped] [--keep-open]
Runs hardware E2E files (plain Dart programs using package:labwright)
sequentially via `dart run`, with a live viewer and CI exit codes.''';

/// E2E files: explicit .dart paths as-is; directories walked recursively,
/// hidden directories skipped, sorted for a deterministic run order.
List<File> _collectFiles(List<String> paths) {
  final out = <File>[];
  for (final path in paths) {
    if (FileSystemEntity.isDirectorySync(path)) {
      final files = Directory(path)
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .where((f) => !f.path
              .split(Platform.pathSeparator)
              .any((seg) => seg.startsWith('.')))
          .toList();
      out.addAll(files);
    } else if (FileSystemEntity.isFileSync(path)) {
      out.add(File(path));
    } else {
      stderr.writeln('labwright: skipping missing path: $path');
    }
  }
  out.sort((a, b) => a.path.compareTo(b.path));
  return out;
}

Future<void> _runFile(File file, _RunState state, _Viewer viewer,
    {required int totalShards, required int shardIndex}) async {
  stdout.writeln('── ${file.path}');
  final fileState = state.file(file.path)..status = 'running';
  viewer.broadcast({'e': 'file-start', 'file': file.path});

  final process = await Process.start(
    Platform.resolvedExecutable,
    ['run', file.path],
    environment: {
      'LABWRIGHT_REPORT': 'jsonl',
      if (totalShards > 1) ...{
        'LABWRIGHT_TOTAL_SHARDS': '$totalShards',
        'LABWRIGHT_SHARD_INDEX': '$shardIndex',
      },
    },
  );
  // Hardware E2E: strictly sequential; stderr passes straight through.
  final stderrDone = process.stderr.pipe(stderr.nonBlocking);
  await for (final line in process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final event = _tryDecode(line);
    if (event == null) {
      stdout.writeln('  | $line'); // non-event output, passed through
      continue;
    }
    fileState.apply(event);
    _renderEvent(event);
    viewer.broadcast({...event, 'file': file.path});
  }
  final exit = await process.exitCode;
  await stderrDone;
  fileState.status = exit == 0 ? 'done' : 'crashed($exit)';
  if (exit != 0) {
    state.crashedFiles++;
    stdout.writeln('  ‼ ${file.path} exited $exit');
  }
  viewer.broadcast({'e': 'file-end', 'file': file.path, 'exit': exit});
}

Map<String, Object?>? _tryDecode(String line) {
  if (!line.startsWith('{')) return null;
  try {
    final decoded = jsonDecode(line);
    return decoded is Map<String, Object?> && decoded['e'] is String
        ? decoded
        : null;
  } on FormatException {
    return null;
  }
}

void _renderEvent(Map<String, Object?> event) {
  switch (event['e']) {
    case 'test-start':
      final reqs = event['requirements'] is List
          ? ' [${(event['requirements'] as List).join(', ')}]'
          : '';
      stdout.writeln('▶ ${event['test']}$reqs');
    case 'test-end':
      final mark = switch (event['status']) {
        'passed' => '✓',
        'failed' => '✗',
        'skipped' => '○',
        _ => '‼',
      };
      final detail = event['detail'] != null
          ? '\n    ${'${event['detail']}'.replaceAll('\n', '\n    ')}'
          : '';
      stdout.writeln('  $mark ${event['test']}: ${event['status']}$detail');
    case 'log':
      stdout.writeln('  · ${event['message']}');
    case 'shard':
      stdout.writeln('  shard ${event['index']} of ${event['total']}: '
          '${event['selected']} of ${event['registered']} test(s)');
  }
}

// ── run state ────────────────────────────────────────────────────────────────

class _FileState {
  _FileState(this.path);
  final String path;
  String status = 'queued';

  /// Tests in registration order (name → entry; names are unique per run in
  /// practice — a duplicate name folds into its first entry's slot).
  final Map<String, Map<String, Object?>> tests = {};

  Map<String, Object?> _test(String name) => tests.putIfAbsent(
      name,
      () => {
            'name': name,
            'status': 'running',
            'requirements': const <Object?>[],
            'detail': '',
            'logs': <Object?>[],
          });

  void apply(Map<String, Object?> event) {
    switch (event['e']) {
      case 'test-start':
        _test(event['test'] as String)['requirements'] =
            event['requirements'] ?? const <Object?>[];
      case 'test-end':
        final entry = _test(event['test'] as String);
        entry['status'] = event['status'];
        entry['detail'] = event['detail'] ?? '';
        entry['ms'] = event['ms'];
        entry['requirements'] =
            event['requirements'] ?? entry['requirements']!;
      case 'log':
        // Attributed to its test when one is running; suite-level otherwise.
        final name = event['test'];
        if (name is String) {
          (_test(name)['logs'] as List).add(event['message']);
        }
    }
  }
}

class _RunState {
  _RunState(List<File> files) {
    for (final f in files) {
      _files[f.path] = _FileState(f.path);
    }
  }

  final Map<String, _FileState> _files = {};
  var crashedFiles = 0;
  var done = false;

  _FileState file(String path) => _files[path]!;

  ({int tests, int passed, int failed, int errors, int skipped}) summary() {
    var tests = 0, passed = 0, failed = 0, errors = 0, skipped = 0;
    for (final f in _files.values) {
      for (final t in f.tests.values) {
        tests++;
        switch (t['status']) {
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
    }
    return (
      tests: tests,
      passed: passed,
      failed: failed,
      errors: errors,
      skipped: skipped
    );
  }

  /// The full report: per-file tests plus the requirements trace
  /// (requirement ID → every test that claims it, with status).
  Map<String, Object?> toJson() {
    final requirements = <String, List<Map<String, Object?>>>{};
    for (final f in _files.values) {
      for (final t in f.tests.values) {
        for (final req in (t['requirements'] as List).cast<Object?>()) {
          requirements.putIfAbsent('$req', () => []).add({
            'file': f.path,
            'test': t['name'],
            'status': t['status'],
          });
        }
      }
    }
    final s = summary();
    return {
      'files': [
        for (final f in _files.values)
          {
            'path': f.path,
            'status': f.status,
            'tests': f.tests.values.toList(),
          },
      ],
      'requirements': requirements,
      'summary': {
        'tests': s.tests,
        'passed': s.passed,
        'failed': s.failed,
        'errors': s.errors,
        'skipped': s.skipped,
        'crashedFiles': crashedFiles,
      },
      'done': done,
    };
  }
}

// ── live viewer ──────────────────────────────────────────────────────────────

class _Viewer {
  _Viewer._(this._server, this._state);

  final HttpServer _server;
  final _RunState _state;
  final List<HttpResponse> _sseClients = [];

  int get port => _server.port;

  static Future<_Viewer> start(int port, _RunState state) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    final viewer = _Viewer._(server, state);
    server.listen(viewer._handle);
    return viewer;
  }

  void _handle(HttpRequest request) {
    switch (request.uri.path) {
      case '/':
        request.response
          ..headers.contentType = ContentType.html
          ..write(_viewerHtml)
          ..close();
      case '/state.json':
        request.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(_state.toJson()))
          ..close();
      case '/events':
        final response = request.response;
        response.headers
          ..contentType = ContentType('text', 'event-stream')
          ..set('Cache-Control', 'no-cache')
          ..set('Connection', 'keep-alive');
        response.bufferOutput = false;
        // New client: full state snapshot first, then the live stream.
        response.write('data: ${jsonEncode({
              'e': 'state',
              'state': _state.toJson(),
            })}\n\n');
        _sseClients.add(response);
        response.done.whenComplete(() => _sseClients.remove(response));
      default:
        request.response
          ..statusCode = HttpStatus.notFound
          ..close();
    }
  }

  void broadcast(Map<String, Object?> event) {
    final frame = 'data: ${jsonEncode(event)}\n\n';
    for (final client in [..._sseClients]) {
      try {
        client.write(frame);
      } catch (_) {
        _sseClients.remove(client);
      }
    }
  }

  Future<void> close() async {
    for (final client in [..._sseClients]) {
      try {
        await client.close();
      } catch (_) {}
    }
    await _server.close();
  }
}

/// The self-contained live viewer page: SSE-fed, no external assets. Logs
/// stream in under their owning test — the bench view during a run.
const _viewerHtml = '''
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<title>labwright run</title>
<style>
  :root { color-scheme: light dark; }
  body { font: 14px/1.5 system-ui, sans-serif; margin: 1.5rem auto;
         max-width: 60rem; padding: 0 1rem; }
  h1 { font-size: 1.1rem; } h2 { font-size: .95rem; margin: 1.2rem 0 .3rem;
       font-family: ui-monospace, monospace; opacity: .8; }
  .test { margin: .4rem 0; border-left: 3px solid #8884; padding-left: .8rem; }
  .head { display: flex; gap: .5rem; align-items: baseline; }
  .name { font-weight: 600; }
  .req { font-family: ui-monospace, monospace; font-size: .8em;
         border: 1px solid #8886; border-radius: .6em; padding: 0 .5em; }
  .detail { white-space: pre-wrap; font-family: ui-monospace, monospace;
            font-size: .85em; opacity: .85; margin: .2rem 0 0 1.2rem; }
  .logs { font-family: ui-monospace, monospace; font-size: .8em; opacity: .7;
          margin: .2rem 0 0 1.2rem; white-space: pre-wrap; }
  .passed { color: #2e7d32; } .failed { color: #c62828; }
  .skipped { color: #b28900; } .error { color: #c62828; }
  .running { opacity: .75; } #status { opacity: .7; }
</style>
</head>
<body>
<h1>labwright run <span id="status">connecting…</span></h1>
<div id="files"></div>
<script>
const filesEl = document.getElementById('files');
const statusEl = document.getElementById('status');
const state = { files: {} };
const mark = { passed: '✓', failed: '✗', skipped: '○', error: '‼',
               running: '…' };

function render() {
  filesEl.replaceChildren();
  for (const [path, file] of Object.entries(state.files)) {
    const h = document.createElement('h2');
    h.textContent = path + '  (' + file.status + ')';
    filesEl.appendChild(h);
    for (const t of Object.values(file.tests)) {
      const div = document.createElement('div');
      div.className = 'test';
      const head = document.createElement('div');
      head.className = 'head';
      const m = document.createElement('span');
      m.className = t.status;
      m.textContent = mark[t.status] || '•';
      head.appendChild(m);
      const n = document.createElement('span');
      n.className = 'name ' + t.status;
      n.textContent = t.name;
      head.appendChild(n);
      for (const r of t.requirements || []) {
        const chip = document.createElement('span');
        chip.className = 'req';
        chip.textContent = r;
        head.appendChild(chip);
      }
      div.appendChild(head);
      if (t.detail) {
        const d = document.createElement('div');
        d.className = 'detail failed';
        d.textContent = t.detail;
        div.appendChild(d);
      }
      if ((t.logs || []).length) {
        const l = document.createElement('div');
        l.className = 'logs';
        l.textContent = t.logs.join('\\n');
        div.appendChild(l);
      }
      filesEl.appendChild(div);
    }
  }
}

function fileState(path) {
  return state.files[path] ??= { status: 'running', tests: {} };
}

function testState(file, name) {
  return file.tests[name] ??=
      { name, status: 'running', requirements: [], detail: '', logs: [] };
}

function apply(ev) {
  if (ev.e === 'state') {
    state.files = {};
    for (const f of ev.state.files) {
      const tests = {};
      for (const t of f.tests) tests[t.name] = t;
      state.files[f.path] = { status: f.status, tests };
    }
    statusEl.textContent = ev.state.done ? 'finished' : 'live';
    return;
  }
  if (ev.e === 'done') { statusEl.textContent = 'finished'; return; }
  const file = fileState(ev.file || '');
  if (ev.e === 'file-end') { file.status = ev.exit === 0 ? 'done' : 'crashed'; }
  if (ev.e === 'test-start') {
    const t = testState(file, ev.test);
    t.requirements = ev.requirements || [];
  }
  if (ev.e === 'test-end') {
    const t = testState(file, ev.test);
    t.status = ev.status;
    t.detail = ev.detail || '';
    t.requirements = ev.requirements || t.requirements;
  }
  if (ev.e === 'log' && ev.test) testState(file, ev.test).logs.push(ev.message);
}

const source = new EventSource('/events');
source.onopen = () => { statusEl.textContent = 'live'; };
source.onerror = () => { statusEl.textContent = 'disconnected'; };
source.onmessage = (m) => { apply(JSON.parse(m.data)); render(); };
</script>
</body>
</html>
''';
