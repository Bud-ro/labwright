import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

final String pkgRoot = Directory('packages/labwright').existsSync() ? 'packages/labwright' : '.';

(int, String, String) runSuite(String file, {List<String> defines = const [], bool identity = false}) {
  final result = Process.runSync(Platform.resolvedExecutable, [
    'run',
    '-Dlabwright.viewer=false',
    if (!identity) '-Dlabwright.identity=false',
    ...defines,
    file,
  ], workingDirectory: pkgRoot);
  return (result.exitCode, result.stdout.toString(), result.stderr.toString());
}

(int, String, Map<String, Object?>) runWithReport(
  String file, {
  List<String> defines = const [],
  bool identity = false,
}) {
  final dir = Directory.systemTemp.createTempSync('lw_');
  try {
    final path = '${dir.path}/report.json';
    final (exit, out, _) = runSuite(file, defines: ['-Dlabwright.report=$path', ...defines], identity: identity);
    return (exit, out, jsonMap(File(path).readAsStringSync()));
  } finally {
    dir.deleteSync(recursive: true);
  }
}

ProcessResult cli(List<String> args) =>
    Process.runSync(Platform.resolvedExecutable, ['run', 'bin/labwright.dart', ...args], workingDirectory: pkgRoot);

Map<String, Object?> jsonMap(String text) => jsonDecode(text) as Map<String, Object?>;

List<Map<String, Object?>> testsOf(Map<String, Object?> reportOrState) => [
  for (final test in reportOrState['tests'] as List) test as Map<String, Object?>,
];

List<Object?>? logsOf(Map<String, Object?> record) {
  final logs = record['logs'];
  return logs == null ? null : [for (final line in logs as List) (line as Map<String, Object?>)['m']];
}

Map<String, Object?> testIn(Map<String, Object?> reportOrState, String name) =>
    testsOf(reportOrState).firstWhere((t) => t['name'] == name);

class Viewer {
  Viewer._(this.process) {
    process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(_onLine);
  }

  final Process process;
  late final int port;
  final HttpClient client = HttpClient();

  final lines = <String>[];
  final _waiters = <(bool Function(String), Completer<String>)>[];

  static Future<Viewer> start(
    String file, {
    List<String> defines = const [],
    bool vmService = false,
    bool awaitReady = true,
  }) async {
    final v = Viewer._(
      await Process.start(Platform.resolvedExecutable, [
        'run',
        if (vmService) '--enable-vm-service=0',
        '-Dlabwright.port=0',
        ...defines,
        file,
      ], workingDirectory: pkgRoot),
    );
    final m = RegExp(r'viewer on http://localhost:(\d+)').firstMatch(await v.line(RegExp(r'viewer on http')))!;
    v.port = int.parse(m[1]!);
    if (awaitReady) await v.ready();
    return v;
  }

  static Viewer attach(Process process, {required int fixedPort}) => Viewer._(process)..port = fixedPort;

  void _onLine(String l) {
    lines.add(l);
    _waiters.removeWhere((w) {
      if (!w.$1(l)) return false;
      w.$2.complete(l);
      return true;
    });
  }

  Future<String> line(Pattern p, {int nth = 1, Duration timeout = const Duration(seconds: 60)}) {
    bool match(String l) => p is RegExp ? p.hasMatch(l) : l.contains(p as String);
    var seen = 0;
    for (final l in lines) {
      if (match(l) && ++seen == nth) return Future.value(l);
    }
    final c = Completer<String>();
    _waiters.add(((l) => match(l) && ++seen == nth, c));
    return c.future.timeout(timeout);
  }

  Future<void> ready() => line('View results and re-run tests at');

  Uri _uri(String path) => Uri.parse('http://localhost:$port$path');

  Future<HttpClientResponse> getRes(String path) async => (await client.getUrl(_uri(path))).close();

  Future<(int, String)> get(String path) async {
    final res = await getRes(path);
    return (res.statusCode, await utf8.decodeStream(res));
  }

  Future<Map<String, Object?>> getJson(String path) async => jsonMap((await get(path)).$2);

  Future<Map<String, Object?>> state() => getJson('/state.json');

  Future<(int, Map<String, Object?>?)> post(
    String path, [
    Object body = const <String, Object?>{},
    String? origin,
    ContentType? type,
  ]) async {
    final req = await client.postUrl(_uri(path));
    req.headers.contentType = type ?? ContentType.json;
    if (origin != null) req.headers.set('Origin', origin);
    req.write(jsonEncode(body));
    final res = await req.close();
    final text = await utf8.decodeStream(res);
    Map<String, Object?>? decoded;
    try {
      decoded = jsonMap(text);
    } catch (_) {
      decoded = null;
    }
    return (res.statusCode, decoded);
  }

  Future<Map<String, Object?>> settle(
    bool Function(Map<String, Object?>) done, {
    int tries = 200,
    bool tolerateErrors = false,
  }) async {
    Map<String, Object?> s = const {};
    for (var i = 0; i < tries; i++) {
      try {
        s = await state();
        if (done(s)) return s;
      } catch (_) {
        if (!tolerateErrors) rethrow;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    fail('state never settled: $s');
  }

  Future<StreamSubscription<String>> events(void Function(String event, Map<String, Object?> data) onFrame) async {
    final res = await (await client.getUrl(_uri('/events'))).close();
    final buf = StringBuffer();
    return res.transform(utf8.decoder).listen((chunk) {
      buf.write(chunk);
      for (final frame in buf.toString().split('\n\n')) {
        final event = RegExp(r'event: (\S+)').firstMatch(frame)?[1];
        final dataLine = frame.split('\n').firstWhere((l) => l.startsWith('data: '), orElse: () => '');
        if (event == null || dataLine.isEmpty) continue;
        try {
          onFrame(event, jsonMap(dataLine.substring(6)));
        } catch (_) {}
      }
    });
  }

  Future<void> close() async {
    client.close(force: true);
    process.kill();
    await process.exitCode;
  }
}
