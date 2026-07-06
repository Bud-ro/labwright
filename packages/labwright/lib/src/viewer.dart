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

  /// The execution history (oldest first) for the Log view, replayed to each
  /// new client on connect; live additions arrive via [pushHistory]. Null until
  /// the run wires it.
  List<Map<String, Object?>> Function()? history;

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
        // New client: the live snapshot (default event, re-sent whole on every
        // change — suites are small) plus a one-shot replay of the history feed
        // (a named `hist` event; live additions come as deltas via pushHistory).
        response.write('data: ${jsonEncode(_state())}\n\n');
        final past = history?.call();
        if (past != null) {
          response.write('event: hist\ndata: ${jsonEncode({'reset': true, 'entries': past})}\n\n');
        }
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

  /// Pushes the current live snapshot to every connected page.
  void update() => _broadcast('data: ${jsonEncode(_state())}\n\n');

  /// Pushes one new history record to every page as a `hist` delta (the Log
  /// view prepends it and animates it in).
  void pushHistory(Map<String, Object?> record) =>
      _broadcast('event: hist\ndata: ${jsonEncode({'entry': record})}\n\n');

  void _broadcast(String frame) {
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

/// The page: a full-height, self-contained app showing three filterable panes
/// at once — Tests (compact latest-run status + jump-to-source + queue button)
/// and Queue (what is waiting) stacked at left, and Log (an animated, scrollable
/// history of every execution with its logs) filling the right. Interactive
/// controls (re-run, hot reload, stop, buttons, open-in-editor) appear only when
/// the viewer is lingering. No external assets; each pane scrolls internally so
/// the page itself never grows.
const _viewerHtml = '''
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>labwright</title>
<style>
  :root { color-scheme: light dark; --line: #8883; --hl: #8ab4f8; }
  * { box-sizing: border-box; }
  html, body { height: 100%; margin: 0; }
  body { font: 13px/1.5 system-ui, sans-serif; height: 100vh; display: flex;
         flex-direction: column; overflow: hidden; }
  header { padding: .5rem .8rem; border-bottom: 1px solid var(--line);
           display: flex; flex-direction: column; gap: .4rem; flex: none; }
  header h1 { font-size: 1rem; margin: 0; font-weight: 600; }
  #meta { opacity: .7; font-size: .85em; font-weight: 400; margin-left: .4rem; }
  #controls { display: flex; gap: .4rem; align-items: center; flex-wrap: wrap; }
  #controls[hidden] { display: none; }
  button { font: inherit; padding: .12rem .55rem; border: 1px solid var(--line);
           border-radius: .5em; background: #8881; cursor: pointer; color: inherit; }
  button:disabled { opacity: .4; cursor: default; }
  .mini { font-size: .85em; padding: 0 .45em; }
  a#dl { color: inherit; text-decoration: underline dotted; font-size: .9em; }
  .count { font-size: .8em; opacity: .55; margin-left: .15rem; }
  /* Every view is on screen at once: Tests + Queue stacked at left, Log large
     at right. Each pane scrolls internally so the page itself never grows. */
  main { flex: 1; overflow: hidden; display: grid;
         grid-template-columns: minmax(230px, 32%) 1fr; }
  #left { display: flex; flex-direction: column; min-height: 0; overflow: hidden;
          border-right: 1px solid var(--line); }
  #tests { flex: 1; border-bottom: 1px solid var(--line); }
  #queue { flex: 1; }
  .pane { display: flex; flex-direction: column; min-height: 0; overflow: hidden; }
  .paneHead { padding: .3rem .8rem; font-weight: 600; font-size: .82em; opacity: .75;
              border-bottom: 1px solid var(--line); flex: none; }
  .filter { margin: .4rem .8rem .1rem; padding: .2rem .5rem; font: inherit; flex: none;
            border: 1px solid var(--line); border-radius: .4em; background: #8881;
            color: inherit; }
  .scroll { flex: 1; overflow-y: auto; min-height: 0; padding: .15rem .8rem .6rem; }
  @media (max-width: 680px) {
    main { grid-template-columns: 1fr; grid-template-rows: 1fr 1fr 1.5fr; }
    #left { display: contents; }
    #tests, #queue, #log { border-right: none; border-bottom: 1px solid var(--line); }
  }
  .row { display: flex; gap: .5rem; align-items: baseline; padding: .15rem 0;
         flex-wrap: wrap; }
  .name { font-weight: 600; }
  .name.link { cursor: pointer; text-decoration: underline dotted; }
  .spacer { flex: 1; }
  .req, .idx { font-family: ui-monospace, monospace; font-size: .78em; opacity: .85;
               border: 1px solid var(--line); border-radius: .6em; padding: 0 .5em; }
  .time { font-family: ui-monospace, monospace; font-size: .74em; opacity: .5; }
  .chg { font-size: .72em; border-radius: .6em; padding: 0 .5em;
         border: 1px solid var(--line); }
  .chg.newFail { color: #e2574c; } .chg.newPass { color: #4caf6a; }
  .chg.flaky { color: #d0a000; }
  .passed { color: #4caf6a; } .failed, .error { color: #e2574c; }
  .skipped { color: #d0a000; } .running { opacity: .9; } .queued { opacity: .55; }
  .logentry { border-left: 3px solid var(--line); padding: .25rem .6rem;
              margin: .35rem 0; border-radius: .2em; }
  .logentry.passed { border-left-color: #4caf6a66; }
  .logentry.failed, .logentry.error { border-left-color: #e2574c88; }
  .logentry.skipped { border-left-color: #d0a00066; }
  .logentry.running { border-left-color: var(--hl); }
  .logentry.hl { background: #8ab4f822; outline: 1px solid #8ab4f855; }
  .detail { white-space: pre-wrap; font-family: ui-monospace, monospace;
            font-size: .82em; opacity: .85; margin: .2rem 0 0 .2rem; }
  .logs { white-space: pre-wrap; font-family: ui-monospace, monospace;
          font-size: .8em; opacity: .7; margin: .2rem 0 0 .2rem; }
  .empty { opacity: .5; padding: 1rem .2rem; }
  @keyframes pop { from { opacity: 0; transform: translateY(-8px); }
                  to { opacity: 1; transform: none; } }
  .pop { animation: pop .2s ease; }
</style>
</head>
<body>
<header>
  <h1>labwright<span id="meta">connecting…</span></h1>
  <div id="controls" hidden>
    <button id="rerun">Re-run all</button>
    <button id="rerunFailed">Re-run failed</button>
    <button id="hotReload" title="reload edited sources and re-run the modified tests">Hot reload</button>
    <button id="stop">Stop</button>
    <span id="userButtons"></span>
    <a id="dl" href="/report.json" download="labwright-report.json">download report</a>
    <button id="copyFails" class="mini">copy failures</button>
  </div>
</header>
<main>
  <div id="left">
    <section class="pane" id="tests">
      <div class="paneHead">Tests <span class="count" id="cTests"></span></div>
      <input class="filter" id="filterTests" placeholder="filter tests by name / status / requirement…">
      <div class="scroll" id="testsList"></div>
    </section>
    <section class="pane" id="queue">
      <div class="paneHead">Queue <span class="count" id="cQueue"></span></div>
      <input class="filter" id="filterQueue" placeholder="filter queue…">
      <div class="scroll" id="queueList"></div>
    </section>
  </div>
  <section class="pane" id="log">
    <div class="paneHead">Log <span class="count" id="cLog"></span></div>
    <input class="filter" id="filterLog" placeholder="filter log by name / status…">
    <div class="scroll" id="logList"></div>
  </section>
</main>
<script>
const byId = (id) => document.getElementById(id);
let snap = { tests: [], buttons: [] };
let history = [];              // newest first
const filters = { tests: '', log: '', queue: '' };
let highlight = null;          // {name, run} — the show-log target to spotlight

const mark = { passed: '✓', failed: '✗', error: '‼', skipped: '○', running: '…', queued: '·' };
const changeLabel = { newFail: '▲ new fail', newPass: '▼ now passing', changed: 'changed' };
const isFail = (s) => s === 'failed' || s === 'error';
// Wall-clock ms → the operator's local HH:MM:SS.
const clock = (ms) => ms == null ? '' : new Date(ms).toLocaleTimeString([], { hour12: false });

async function post(action) {
  try {
    const res = await fetch('/action', { method: 'POST',
        headers: { 'content-type': 'application/json' }, body: JSON.stringify(action) });
    if (!res.ok) { const r = await res.json().catch(() => ({}));
      byId('meta').textContent = ' · rejected: ' + (r.error || res.status); }
  } catch (e) { byId('meta').textContent = ' · action failed: ' + e; }
}

function badge(cls, text) { const b = document.createElement('span'); b.className = cls; b.textContent = text; return b; }
function nameEl(t) {
  const n = document.createElement('span');
  n.className = 'name ' + (t.status || '');
  n.textContent = t.name;
  if (snap.interactive && t.file) {
    n.classList.add('link');
    n.title = 'open ' + t.file + ':' + (t.line || 1);
    n.onclick = () => post({ type: 'open', file: t.file, line: t.line || 1 });
  }
  return n;
}
function has(text, q) { return !q || text.toLowerCase().includes(q.toLowerCase()); }
function testMatch(t, q) { return has([t.name, t.status, t.change, (t.requirements || []).join(' ')].join(' '), q); }
function logMatch(e, q) { return has(e.name + ' ' + e.status, q); }

// ── Tests view: compact latest-run status, no logs ───────────────────────────
function renderTests() {
  const list = byId('testsList'); list.replaceChildren();
  for (const t of snap.tests || []) {
    if (!testMatch(t, filters.tests)) continue;
    const row = document.createElement('div'); row.className = 'row';
    row.appendChild(badge(t.status, mark[t.status] || '•'));
    row.appendChild(nameEl(t));
    for (const r of t.requirements || []) row.appendChild(badge('req', r));
    if (t.ms != null) row.appendChild(badge('req', t.ms + ' ms'));
    if (t.change) row.appendChild(badge('chg ' + t.change, changeLabel[t.change] || t.change));
    if (t.flaky) row.appendChild(badge('chg flaky', 'flaky'));
    const at = t.status === 'running' ? t.startedAt : t.finishedAt;
    if (at != null) row.appendChild(badge('time', clock(at)));
    row.appendChild(badge('spacer', ''));
    const lg = document.createElement('button'); lg.className = 'mini'; lg.textContent = 'log';
    lg.title = 'show this test in the Log view'; lg.onclick = () => showLog(t.name);
    row.appendChild(lg);
    if (snap.interactive) {
      const q = document.createElement('button'); q.className = 'mini'; q.textContent = '▶';
      q.title = 'queue this test'; q.disabled = !!snap.busy;
      q.onclick = () => post({ type: 'runOne', test: t.name });
      row.appendChild(q);
    }
    list.appendChild(row);
  }
}

// ── Queue view: tests waiting in the active run ──────────────────────────────
// The queue is first-class server state (snap.queue, ordered names), NOT
// derived from statuses — a waiting test keeps showing its previous verdict
// in the Tests pane until it actually runs.
function renderQueue() {
  const list = byId('queueList'); list.replaceChildren();
  const byName = new Map((snap.tests || []).map((t) => [t.name, t]));
  const queued = (snap.queue || []).map((n) => byName.get(n)).filter(Boolean);
  const shown = queued.filter((t) => testMatch(t, filters.queue));
  if (!shown.length) {
    list.appendChild(badge('empty', snap.busy ? 'running — nothing else queued' : 'nothing queued'));
    return;
  }
  shown.forEach((t, i) => {
    const row = document.createElement('div'); row.className = 'row';
    row.appendChild(badge('idx', '' + (i + 1)));
    row.appendChild(nameEl(t));
    for (const r of t.requirements || []) row.appendChild(badge('req', r));
    if (t.queuedAt != null) row.appendChild(badge('time', 'queued ' + clock(t.queuedAt)));
    list.appendChild(row);
  });
}

// ── Log view: animated history feed, newest at top ───────────────────────────
function logEntryEl(e, live) {
  const div = document.createElement('div'); div.className = 'logentry ' + (e.status || '');
  if (live) div.classList.add('live');
  if (highlight && e.name === highlight.name && e.run === highlight.run) div.classList.add('hl');
  const head = document.createElement('div'); head.className = 'row';
  head.appendChild(badge(e.status, live ? '…' : (mark[e.status] || '•')));
  head.appendChild(nameEl(e));
  if (e.run != null) head.appendChild(badge('idx', 'run ' + e.run));
  if (e.ms != null) head.appendChild(badge('req', e.ms + ' ms'));
  if (e.change) head.appendChild(badge('chg ' + e.change, changeLabel[e.change] || e.change));
  const when = live ? e.startedAt : e.finishedAt;
  if (when != null) head.appendChild(badge('time', (live ? 'started ' : '') + clock(when)));
  div.appendChild(head);
  if (e.detail) { const d = document.createElement('div'); d.className = 'detail'; d.textContent = e.detail; div.appendChild(d); }
  if ((e.logs || []).length) {
    const l = document.createElement('div'); l.className = 'logs';
    // Each line carries the wall-clock time it was logged.
    l.textContent = e.logs.map((x) => clock(x.t) + '  ' + x.m).join('\\n');
    div.appendChild(l);
  }
  return div;
}
function renderLog() {
  const list = byId('logList'); list.replaceChildren();
  const running = (snap.tests || []).find((t) => t.status === 'running');
  if (running && logMatch(running, filters.log)) list.appendChild(logEntryEl(running, true));
  for (const e of history) if (logMatch(e, filters.log)) list.appendChild(logEntryEl(e, false));
  const hl = list.querySelector('.hl'); if (hl) hl.scrollIntoView({ block: 'center' });
}
// Prepend one freshly-finished entry (below the live row) and animate it in.
function prependLog(e) {
  if (!logMatch(e, filters.log)) return;
  const node = logEntryEl(e, false); node.classList.add('pop');
  const list = byId('logList'); const live = list.querySelector('.live');
  if (live) list.insertBefore(node, live.nextSibling); else list.insertBefore(node, list.firstChild);
}
// Refresh only the live (currently-running) row on a snapshot — cheap.
function refreshLive() {
  const list = byId('logList'); const live = list.querySelector('.live');
  const running = (snap.tests || []).find((t) => t.status === 'running');
  if (!running || !logMatch(running, filters.log)) { if (live) live.remove(); return; }
  const fresh = logEntryEl(running, true);
  if (live) list.replaceChild(fresh, live); else list.insertBefore(fresh, list.firstChild);
}

// The Log pane is always visible, so show-log just filters + spotlights it.
function showLog(name) {
  let run = null;
  for (const e of history) if (e.name === name) run = run == null ? e.run : Math.max(run, e.run);
  highlight = { name: name, run: run };
  filters.log = name; byId('filterLog').value = name;
  renderLog();
}

function counts() {
  byId('cTests').textContent = (snap.tests || []).length || '';
  byId('cLog').textContent = history.length || '';
  byId('cQueue').textContent = (snap.queue || []).length || '';
}
function controls() {
  byId('controls').hidden = !snap.interactive;
  const busy = !!snap.busy;
  const anyFail = (snap.tests || []).some((t) => isFail(t.status));
  byId('rerun').disabled = busy;
  byId('rerunFailed').disabled = busy || !anyFail;
  byId('hotReload').disabled = busy;
  byId('stop').disabled = !busy;
  const ub = byId('userButtons'); ub.replaceChildren();
  (snap.buttons || []).forEach((label, i) => {
    const b = document.createElement('button'); b.textContent = label; b.disabled = busy;
    b.onclick = () => post({ type: 'button', index: i }); ub.appendChild(b);
  });
}
function onSnapshot() {
  const busy = !!snap.busy;
  byId('meta').textContent = ' · seed ' + snap.seed + (busy ? ' · running…' : snap.done ? ' · idle' : ' · live');
  controls(); renderTests(); renderQueue(); refreshLive(); counts();
}

byId('rerun').onclick = () => post({ type: 'rerun' });
byId('rerunFailed').onclick = () => post({ type: 'rerunFailed' });
byId('hotReload').onclick = () => post({ type: 'hotReload' });
byId('stop').onclick = () => post({ type: 'stop' });
byId('copyFails').onclick = () => {
  const text = (snap.tests || []).filter((t) => isFail(t.status))
      .map((t) => t.name + (t.detail ? '\\n  ' + t.detail.replace(/\\n/g, '\\n  ') : '')).join('\\n\\n');
  navigator.clipboard.writeText(text || 'no failures').then(
      () => { byId('meta').textContent = ' · copied ' + (text ? 'failures' : '(none)'); },
      () => { byId('meta').textContent = ' · clipboard blocked'; });
};
byId('filterTests').oninput = (e) => { filters.tests = e.target.value; renderTests(); };
byId('filterQueue').oninput = (e) => { filters.queue = e.target.value; renderQueue(); };
byId('filterLog').oninput = (e) => { filters.log = e.target.value; highlight = null; renderLog(); };

const source = new EventSource('/events');
source.onerror = () => { byId('meta').textContent = ' · disconnected'; };
source.onmessage = (m) => { snap = JSON.parse(m.data); onSnapshot(); };
source.addEventListener('hist', (m) => {
  const d = JSON.parse(m.data);
  if (d.reset) { history = (d.entries || []).slice().reverse(); renderLog(); }
  else if (d.entry) { history.unshift(d.entry); prependLog(d.entry); }
  counts();
});
</script>
</body>
</html>
''';
