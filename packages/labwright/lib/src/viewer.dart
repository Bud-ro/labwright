import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

class Viewer {
  Viewer._(this._server);

  final HttpServer _server;
  final List<HttpResponse> _sseClients = [];
  Map<String, Object?> Function() _state = () => const {};

  Map<String, Future<Map<String, Object?>> Function(Map<String, Object?> body)>? actions;

  Map<String, Object?> Function()? report;

  List<Map<String, Object?>> Function()? history;

  int get port => _server.port;

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
        _serveSite(request, SiteAsset.html);
      case '/style.css':
        _serveSite(request, SiteAsset.css);
      case '/app.js':
        _serveSite(request, SiteAsset.js);
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

  void _serveSite(HttpRequest request, SiteAsset asset) {
    request.response
      ..headers.contentType = ContentType.parse(asset.contentType)
      ..write(_siteFile(asset))
      ..close();
  }

  Future<void> _handlePost(HttpRequest request) async {
    final response = request.response..headers.contentType = ContentType.json;
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
      final body = jsonDecode(raw.isEmpty ? '{}' : raw) as Map<String, Object?>;
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

  void update() => _broadcast('data: ${jsonEncode(_state())}\n\n');

  void pushHistory(Map<String, Object?> record) =>
      _broadcast('event: hist\ndata: ${jsonEncode({'entry': record})}\n\n');

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

String editorLinkTemplate({required bool isWindows, String? wslDistro}) {
  if (wslDistro != null) return 'vscode://vscode-remote/wsl+$wslDistro{file}:{line}';
  return isWindows ? 'vscode://file/{file}:{line}' : 'vscode://file{file}:{line}';
}

enum SiteAsset {
  html('index.html', 'text/html; charset=utf-8'),
  css('style.css', 'text/css; charset=utf-8'),
  js('app.js', 'text/javascript; charset=utf-8')
  ;

  const SiteAsset(this.fileName, this.contentType);

  final String fileName;
  final String contentType;
}

final Map<SiteAsset, String> _siteCache = {};

String _siteFile(SiteAsset asset) {
  final packageUri = Uri.parse('package:labwright/src/site/${asset.fileName}');
  return _siteCache[asset] ??= File.fromUri(
    Isolate.resolvePackageUriSync(packageUri) ?? (throw StateError('package config cannot resolve $packageUri')),
  ).readAsStringSync();
}
