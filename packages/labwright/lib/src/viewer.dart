/// The in-process live execution viewer: an SSE-fed page served by the test
/// process itself — no separate monitoring process, no IPC. The page's HTML,
/// CSS and JS live as real files under `lib/src/site/` (see [_siteTypes]).
/// Binding failures are tolerated (a busy port must never fail a hardware
/// run).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

/// The running viewer server. [update] pushes the current suite state to
/// every connected page; [close] shuts the server down (the run keeps the
/// process alive otherwise).
class Viewer {
  Viewer._(this._server);

  final HttpServer _server;
  final List<HttpResponse> _sseClients = [];
  Map<String, Object?> Function() _state = () => const {};

  /// The control-plane route table: one named handler per `POST /<verb>`
  /// (JSON body in, result map `{accepted: bool, error?: String}` echoed to
  /// the caller). Null until the run wires it — an un-wired viewer is
  /// read-only.
  Map<String, Future<Map<String, Object?>> Function(Map<String, Object?> body)>? actions;

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
    if (request.method == 'POST') {
      unawaited(_handlePost(request));
      return;
    }
    switch (request.uri.path) {
      case '/' || '/index.html':
        _serveSite(request, 'index.html');
      case '/style.css':
        _serveSite(request, 'style.css');
      case '/app.js':
        _serveSite(request, 'app.js');
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

  /// Serves one whitelisted site file with its content type; 404 when the
  /// asset cannot be loaded (warned once by [_siteFile], never a crash).
  void _serveSite(HttpRequest request, String name) {
    final content = _siteFile(name);
    if (content == null) {
      request.response
        ..statusCode = HttpStatus.notFound
        ..close();
      return;
    }
    request.response
      ..headers.contentType = ContentType.parse(_siteTypes[name]!)
      ..write(content)
      ..close();
  }

  /// The control plane: `POST /<verb>` looks the verb up in [actions] and
  /// invokes its one handler with the JSON body (`{}` when empty). Status:
  /// 202 accepted, 409 rejected (e.g. a run is in progress), 400 on a
  /// malformed body, 404 unknown verb, 403 cross-origin/non-JSON, 503 when
  /// the viewer is read-only (no routes wired).
  Future<void> _handlePost(HttpRequest request) async {
    final response = request.response..headers.contentType = ContentType.json;
    // The CSRF defense. Loopback binding does not protect against the
    // operator's own BROWSER: any webpage can fire a no-preflight POST at
    // localhost, and these routes actuate bench hardware. So a POST must look
    // like it came from this page: a JSON content type (a cross-site fetch
    // with that type triggers a CORS preflight, which this server never
    // approves) and, when the browser attached an Origin header, a localhost
    // one (a cross-site text/plain form post always carries the attacker's
    // origin; curl sends none and stays welcome).
    final origin = request.headers.value('origin');
    final originHost = origin == null ? null : Uri.tryParse(origin)?.host;
    final sameHost = originHost == null || originHost == 'localhost' || originHost == '127.0.0.1';
    if (!sameHost || request.headers.contentType?.mimeType != 'application/json') {
      response.statusCode = HttpStatus.forbidden;
      response.write('{"accepted":false,"error":"cross-origin or non-JSON request rejected"}');
      await response.close();
      return;
    }
    final routes = actions;
    if (routes == null) {
      response.statusCode = HttpStatus.serviceUnavailable;
      response.write('{"accepted":false,"error":"viewer is read-only"}');
      await response.close();
      return;
    }
    final handler = routes[request.uri.path.length > 1 ? request.uri.path.substring(1) : ''];
    if (handler == null) {
      response.statusCode = HttpStatus.notFound;
      response.write(jsonEncode({'accepted': false, 'error': 'unknown route ${request.uri.path}'}));
      await response.close();
      return;
    }
    Map<String, Object?> result;
    int status;
    try {
      final raw = await utf8.decoder.bind(request).join();
      final body = (jsonDecode(raw.isEmpty ? '{}' : raw) as Map).cast<String, Object?>();
      result = await handler(body);
      status = result['accepted'] == true ? HttpStatus.accepted : HttpStatus.conflict;
    } catch (e) {
      result = {'accepted': false, 'error': 'bad request: $e'};
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

  /// Pushes one log line as a small `log` delta — `{name, t, m}` — so a
  /// chatty test streams lines without full-state rebroadcasts per line.
  void pushLog(String name, int at, String message) =>
      _broadcast('event: log\ndata: ${jsonEncode({'name': name, 't': at, 'm': message})}\n\n');

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

/// The `vscode://` deep-link template for jump-to-source, computed once at
/// startup and shipped in the viewer state (`editorLink`). The page
/// substitutes `{file}` (absolute path) and `{line}` and renders a plain
/// `<a href>` — opening the editor never touches this server.
///
///  * WSL (`WSL_DISTRO_NAME` set): `vscode://vscode-remote/wsl+<distro>` —
///    the Windows browser hands `vscode://` to Windows VS Code, which owns
///    the WSL remote, so the link works whatever this process is doing.
///  * Windows: `vscode://file/` (the page normalizes `\` to `/`).
///  * Linux/macOS: `vscode://file` (the absolute path supplies the slash).
String editorLinkTemplate({required bool isWindows, String? wslDistro}) {
  if (wslDistro != null) return 'vscode://vscode-remote/wsl+$wslDistro{file}:{line}';
  return isWindows ? 'vscode://file/{file}:{line}' : 'vscode://file{file}:{line}';
}

/// The page: a full-height app showing three filterable panes at once — Tests
/// (compact latest-run status + jump-to-source + queue button) and Queue (what
/// is waiting) stacked at left, and Log (an animated, scrollable history of
/// every execution with its logs) filling the right. Interactive controls
/// appear only when the viewer is lingering.
///
/// The site lives as REAL files — `lib/src/site/{index.html,style.css,app.js}`
/// — resolved through the package config and cached per process. Only names in
/// [_siteTypes] are ever served (the request never contributes a path), and
/// everything is same-origin: no external assets.
const Map<String, String> _siteTypes = {
  'index.html': 'text/html; charset=utf-8',
  'style.css': 'text/css; charset=utf-8',
  'app.js': 'text/javascript; charset=utf-8',
};

final Map<String, String> _siteCache = {};

/// The content of one whitelisted site file, or null (with a warning) when it
/// cannot be resolved/read — a missing asset must never fail a hardware run.
String? _siteFile(String name) {
  final cached = _siteCache[name];
  if (cached != null) return cached;
  try {
    final uri = Isolate.resolvePackageUriSync(Uri.parse('package:labwright/src/site/$name'));
    if (uri == null) throw StateError('package config cannot resolve labwright');
    return _siteCache[name] = File.fromUri(uri).readAsStringSync();
  } catch (e) {
    stderr.writeln('[Labwright]: viewer asset $name unavailable: $e');
    return null;
  }
}
