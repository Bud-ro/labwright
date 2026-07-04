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

  int get port => _server.port;

  /// Binds on localhost:[port] (0 = ephemeral). Returns null — with a
  /// warning, not an error — when the port cannot be bound.
  static Future<Viewer?> start(
      int port, Map<String, Object?> Function() state) async {
    final HttpServer server;
    try {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    } on SocketException catch (e) {
      stderr.writeln(
          'labwright: viewer disabled — cannot bind port $port (${e.message})');
      return null;
    }
    final viewer = Viewer._(server).._state = state;
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
          ..write(jsonEncode(_state()))
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
/// requirement chips, per-test logs. No external assets.
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
  .running { opacity: .9; } .queued { opacity: .55; }
</style>
</head>
<body>
<h1>labwright run <span id="meta">connecting…</span></h1>
<div id="tests"></div>
<script>
const testsEl = document.getElementById('tests');
const metaEl = document.getElementById('meta');
const mark = { passed: '✓', failed: '✗', skipped: '○', error: '‼',
               running: '…', queued: '·' };

function render(state) {
  metaEl.textContent = 'seed ' + state.seed +
      (state.done ? ' · finished' : ' · live');
  testsEl.replaceChildren();
  for (const t of state.tests || []) {
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
