/// The in-process live execution viewer: a self-contained SSE-fed page
/// served by the test process itself — no separate monitoring process, no
/// IPC. Binding failures are tolerated (a busy port must never fail a
/// hardware run).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// The running viewer server. [update] pushes the current suite state to
/// every connected page; [close] shuts the server down (the run keeps the
/// process alive otherwise).
class Viewer {
  Viewer._(this._server);

  final HttpServer _server;
  final List<HttpResponse> _sseClients = [];
  Map<String, Object?> Function() _state = () => const {};

  /// Invoked for a control action POSTed to `/action` (`{type, ...}`); returns
  /// a small result map (`{accepted: bool, error?: String}`) echoed to the
  /// caller. Null until the run wires it — an un-wired viewer is read-only.
  Future<Map<String, Object?>> Function(Map<String, Object?>)? onAction;

  /// Produces the full machine report for `GET /report.json` (the viewer's
  /// download button). Null until the run wires it.
  Map<String, Object?> Function()? report;

  int get port => _server.port;

  /// Binds on localhost:[port] (0 = ephemeral). Returns null — with a
  /// warning, not an error — when the port cannot be bound.
  static Future<Viewer?> start(int port, Map<String, Object?> Function() state) async {
    final HttpServer server;
    try {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    } on SocketException catch (e) {
      stderr.writeln('[Labwright]: viewer disabled - cannot bind port $port (${e.message})');
      return null;
    }
    final viewer = Viewer._(server).._state = state;
    server.listen(viewer._handle);
    return viewer;
  }

  void _handle(HttpRequest request) {
    if (request.method == 'POST' && request.uri.path == '/action') {
      unawaited(_handleAction(request));
      return;
    }
    switch (request.uri.path) {
      case '/':
        request.response
          ..headers.contentType = ContentType.html
          ..write(_viewerHtml)
          ..close();
      case '/state.json':
        request.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(_state()))
          ..close();
      case '/report.json':
        request.response
          ..headers.contentType = ContentType.json
          ..headers.set('Content-Disposition', 'attachment; filename="labwright-report.json"')
          ..write(const JsonEncoder.withIndent('  ').convert(report?.call() ?? _state()))
          ..close();
      case '/events':
        final response = request.response;
        response.headers
          ..contentType = ContentType('text', 'event-stream')
          ..set('Cache-Control', 'no-cache')
          ..set('Connection', 'keep-alive');
        response.bufferOutput = false;
        // New client: full state snapshot; updates re-send the whole state
        // (suites are small — simplicity beats a delta protocol here).
        response.write('data: ${jsonEncode(_state())}\n\n');
        _sseClients.add(response);
        response.done.whenComplete(() => _sseClients.remove(response));
      default:
        request.response
          ..statusCode = HttpStatus.notFound
          ..close();
    }
  }

  /// Reads a JSON action body, dispatches it to [onAction], and echoes the
  /// result. Status: 202 accepted, 409 rejected (e.g. a run is in progress),
  /// 400 on a malformed body, 503 when the viewer is read-only (no handler).
  Future<void> _handleAction(HttpRequest request) async {
    final response = request.response..headers.contentType = ContentType.json;
    final handler = onAction;
    if (handler == null) {
      response.statusCode = HttpStatus.serviceUnavailable;
      response.write('{"accepted":false,"error":"viewer is read-only"}');
      await response.close();
      return;
    }
    Map<String, Object?> result;
    int status;
    try {
      final body = await utf8.decoder.bind(request).join();
      final action = (jsonDecode(body.isEmpty ? '{}' : body) as Map).cast<String, Object?>();
      result = await handler(action);
      status = result['accepted'] == true ? HttpStatus.accepted : HttpStatus.conflict;
    } catch (e) {
      result = {'accepted': false, 'error': 'bad action: $e'};
      status = HttpStatus.badRequest;
    }
    response.statusCode = status;
    response.write(jsonEncode(result));
    await response.close();
  }

  /// Pushes the current state to every connected page.
  void update() {
    final frame = 'data: ${jsonEncode(_state())}\n\n';
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

/// The page: one flat suite (single process, single registry), statuses,
/// requirement chips, per-test logs. When the viewer is interactive (an
/// explicit `--interactive`/`--keep-open`) it also renders the control plane —
/// re-run all/failed, stop, and a per-test run button that POST `/action`.
/// No external assets.
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
  h1 { font-size: 1.1rem; }
  #meta { opacity: .7; font-size: .9em; }
  #controls { display: flex; gap: .5rem; align-items: center; margin: .6rem 0;
              flex-wrap: wrap; }
  #controls[hidden] { display: none; }
  button { font: inherit; padding: .1rem .6rem; border: 1px solid #8886;
           border-radius: .5em; background: #8881; cursor: pointer; }
  button:disabled { opacity: .4; cursor: default; }
  .test { margin: .4rem 0; border-left: 3px solid #8884; padding-left: .8rem; }
  .head { display: flex; gap: .5rem; align-items: baseline; }
  .name { font-weight: 600; }
  .name.link { cursor: pointer; text-decoration: underline dotted; }
  .req { font-family: ui-monospace, monospace; font-size: .8em;
         border: 1px solid #8886; border-radius: .6em; padding: 0 .5em; }
  .run { font-size: .8em; padding: 0 .45em; }
  #seedBox { font-size: .85em; opacity: .8; }
  #seedInput { width: 7em; font: inherit; }
  #viewbar { display: flex; gap: .6rem; align-items: center; margin: .4rem 0;
             flex-wrap: wrap; font-size: .85em; }
  #filter { flex: 1; min-width: 8rem; font: inherit; padding: .1rem .4rem; }
  .chg { font-size: .75em; border-radius: .6em; padding: 0 .5em;
         border: 1px solid #8886; }
  .chg.newFail { color: #c62828; border-color: #c6282866; }
  .chg.newPass { color: #2e7d32; border-color: #2e7d3266; }
  .chg.flaky { color: #b28900; border-color: #b2890066; }
  .detail { white-space: pre-wrap; font-family: ui-monospace, monospace;
            font-size: .85em; opacity: .85; margin: .2rem 0 0 1.2rem; }
  .logs { font-family: ui-monospace, monospace; font-size: .8em; opacity: .7;
          margin: .2rem 0 0 1.2rem; white-space: pre-wrap; }
  .passed { color: #2e7d32; } .failed { color: #c62828; }
  .skipped { color: #b28900; } .error { color: #c62828; }
  .running { opacity: .9; } .queued { opacity: .55; }
</style>
</head>
<body>
<h1>labwright run <span id="meta">connecting…</span></h1>
<div id="controls" hidden>
  <button id="rerun">Re-run all</button>
  <button id="rerunFailed">Re-run failed</button>
  <button id="hotReload" title="reload edited sources and re-run">Hot reload</button>
  <button id="stop">Stop</button>
  <span id="userButtons"></span>
  <span id="seedBox">seed <input id="seedInput" type="number" size="10"><button id="reseed">replay</button></span>
</div>
<div id="viewbar">
  <input id="filter" placeholder="filter tests…">
  <a id="dl" href="/report.json" download="labwright-report.json">download report</a>
  <button id="copyFails">copy failures</button>
</div>
<div id="tests"></div>
<script>
const testsEl = document.getElementById('tests');
const metaEl = document.getElementById('meta');
const controlsEl = document.getElementById('controls');
const btn = { rerun: document.getElementById('rerun'),
              rerunFailed: document.getElementById('rerunFailed'),
              hotReload: document.getElementById('hotReload'),
              stop: document.getElementById('stop') };
const userButtonsEl = document.getElementById('userButtons');
const seedInput = document.getElementById('seedInput');
const reseedBtn = document.getElementById('reseed');
const filterEl = document.getElementById('filter');
const copyFailsEl = document.getElementById('copyFails');
const mark = { passed: '✓', failed: '✗', skipped: '○', error: '‼',
               running: '…', queued: '·' };
const changeLabel = { newFail: '▲ new fail', newPass: '▼ now passing', changed: 'changed' };
const isFail = (s) => s === 'failed' || s === 'error';
let seedEdited = false;
seedInput.oninput = () => { seedEdited = true; };
let lastState = {};
filterEl.oninput = () => render(lastState);

// Copy every failing test (name + detail) to the clipboard for a bug report.
copyFailsEl.onclick = () => {
  const text = (lastState.tests || []).filter((t) => isFail(t.status))
      .map((t) => t.name + (t.detail ? '\\n  ' + t.detail.replace(/\\n/g, '\\n  ') : ''))
      .join('\\n\\n');
  navigator.clipboard.writeText(text || 'no failures').then(
      () => { metaEl.textContent = 'copied ' + (text ? '' : '(none) '); },
      () => { metaEl.textContent = 'clipboard blocked'; });
};

// POST a control action; surface a rejection in the meta line.
async function post(action) {
  try {
    const res = await fetch('/action', { method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(action) });
    if (!res.ok) {
      const r = await res.json().catch(() => ({}));
      metaEl.textContent = 'rejected: ' + (r.error || res.status);
    }
  } catch (e) { metaEl.textContent = 'action failed: ' + e; }
}
btn.rerun.onclick = () => post({ type: 'rerun' });
btn.rerunFailed.onclick = () => post({ type: 'rerunFailed' });
btn.hotReload.onclick = () => post({ type: 'hotReload' });
btn.stop.onclick = () => post({ type: 'stop' });
// Seed replay: re-run in the order a given seed produces (0 = registration).
reseedBtn.onclick = () => {
  seedEdited = false;
  post({ type: 'reseed', seed: parseInt(seedInput.value, 10) || 0 });
};

// A test matches the filter if the query is empty or occurs in its name,
// status, requirements, or change badge (case-insensitive).
function matches(t, q) {
  if (!q) return true;
  const hay = [t.name, t.status, t.change, (t.requirements || []).join(' ')].join(' ').toLowerCase();
  return hay.includes(q);
}

function render(state) {
  lastState = state;
  const busy = !!state.busy;
  const interactive = !!state.interactive;
  const q = filterEl.value.trim().toLowerCase();
  metaEl.textContent = 'seed ' + state.seed +
      (busy ? ' · running…' : state.done ? ' · finished' : ' · live');
  controlsEl.hidden = !interactive;
  const anyFail = (state.tests || []).some((t) => isFail(t.status));
  btn.rerun.disabled = busy;
  btn.rerunFailed.disabled = busy || !anyFail;
  btn.hotReload.disabled = busy;
  btn.stop.disabled = !busy;
  // Track the active seed unless the operator is mid-edit; disable while busy.
  if (!seedEdited && document.activeElement !== seedInput) seedInput.value = state.seed;
  seedInput.disabled = busy;
  reseedBtn.disabled = busy;
  // Operator-registered bench buttons (labels chosen in the suite).
  userButtonsEl.replaceChildren();
  (state.buttons || []).forEach((label, i) => {
    const b = document.createElement('button');
    b.textContent = label;
    b.disabled = busy;
    b.onclick = () => post({ type: 'button', index: i });
    userButtonsEl.appendChild(b);
  });
  testsEl.replaceChildren();
  for (const t of state.tests || []) {
    if (!matches(t, q)) continue;
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
    // Click a located test to open its source in the operator's editor.
    if (t.file) {
      n.classList.add('link');
      n.title = 'open ' + t.file + ':' + (t.line || 1);
      n.onclick = () => post({ type: 'open', file: t.file, line: t.line || 1 });
    }
    head.appendChild(n);
    // Run-to-run diff badges: what changed since the previous run, and flaky.
    if (t.change) {
      const c = document.createElement('span');
      c.className = 'chg ' + t.change;
      c.textContent = changeLabel[t.change] || t.change;
      head.appendChild(c);
    }
    if (t.flaky) {
      const f = document.createElement('span');
      f.className = 'chg flaky';
      f.textContent = 'flaky';
      head.appendChild(f);
    }
    for (const r of t.requirements || []) {
      const chip = document.createElement('span');
      chip.className = 'req';
      chip.textContent = r;
      head.appendChild(chip);
    }
    if (t.ms != null) {
      const ms = document.createElement('span');
      ms.className = 'req';
      ms.textContent = t.ms + ' ms';
      head.appendChild(ms);
    }
    if (interactive) {
      const run = document.createElement('button');
      run.className = 'run';
      run.textContent = '▶';
      run.title = 'run this test';
      run.disabled = busy;
      run.onclick = () => post({ type: 'runOne', test: t.name });
      head.appendChild(run);
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
    testsEl.appendChild(div);
  }
}

const source = new EventSource('/events');
source.onerror = () => { metaEl.textContent = 'disconnected'; };
source.onmessage = (m) => render(JSON.parse(m.data));
</script>
</body>
</html>
''';
