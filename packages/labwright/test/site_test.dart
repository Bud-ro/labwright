// The viewer site ships as real files under lib/src/site/ — one page, one
// stylesheet, one script — served by the in-process viewer. These tests pin
// the folder's integrity (files reference each other; the JS only touches
// element ids the HTML declares) and the serving contract (content types,
// whitelist-only routing, bytes identical to disk).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// The labwright package root, whether the suite runs from the repo root or
/// the package dir (mirrors the corpus_dirs.dart convention).
final String pkgRoot = Directory('packages/labwright').existsSync() ? 'packages/labwright' : '.';

String _site(String name) => File('$pkgRoot/lib/src/site/$name').readAsStringSync();

void main() {
  test('the site folder holds the three properly-extensioned files, wired together', () {
    final html = _site('index.html');
    expect(html, startsWith('<!doctype html>'));
    expect(html, contains('<link rel="stylesheet" href="style.css">'));
    expect(html, contains('<script src="app.js" defer></script>'));
    expect(html, isNot(contains('<style>')), reason: 'no inline CSS — it lives in style.css');
    expect(html, isNot(contains('<script>')), reason: 'no inline JS — it lives in app.js');

    final js = _site('app.js');
    expect(js, contains("new EventSource('/events')"), reason: 'the live feed drives the page');
    expect(js, isNot(contains(r'\\n')), reason: 'no leftover Dart-string escaping from the extraction');

    final css = _site('style.css');
    expect(css, contains('.logentry'), reason: 'the Log pane styling came along');
    expect(css, contains('@keyframes pop'), reason: 'the pop-in animation came along');
  });

  test('every element id the JS touches exists in the HTML', () {
    final html = _site('index.html');
    final js = _site('app.js');
    final used = RegExp(r"byId\('([^']+)'\)").allMatches(js).map((m) => m.group(1)!).toSet();
    expect(used, isNotEmpty, reason: 'the JS drives the page through byId lookups');
    for (final id in used) {
      expect(html, contains('id="$id"'), reason: 'app.js uses #$id, so index.html must declare it');
    }
  });

  test('the JS and CSS agree on the status/badge class vocabulary', () {
    final js = _site('app.js');
    final css = _site('style.css');
    // Every status the JS can stamp on a row/entry has a style.
    for (final status in ['passed', 'failed', 'error', 'skipped', 'running', 'queued']) {
      expect(js, contains(status), reason: 'the JS knows the $status status');
      expect(css, contains('.$status'), reason: 'style.css styles .$status');
    }
    for (final badge in ['newFail', 'newPass', 'flaky']) {
      expect(css, contains('.chg.$badge'), reason: 'style.css styles the $badge change badge');
    }
  });

  test('the connection dot exists and follows the SSE stream state', () {
    expect(_site('index.html'), contains('id="conn"'), reason: 'the dot sits top-left in the header');
    expect(_site('style.css'), contains('.conn.ok'), reason: 'green when connected, red base otherwise');
    final js = _site('app.js');
    expect(js, contains('source.onopen'), reason: 'the dot turns green when the stream opens');
    expect(js, contains('setConn(false)'), reason: 'and red the moment it drops');
  });

  test(
    'the viewer serves the site: right content types, disk-identical bytes, whitelist-only',
    () async {
      final process = await Process.start(Platform.resolvedExecutable, [
        'run',
        '-Dlabwright.port=0',
        '-Dlabwright.identity=false',
        '-Dlabwright.seed=0',
        'test/fixtures/slow_e2e.dart', // slow: the viewer is up while it runs
      ], workingDirectory: pkgRoot);
      try {
        final port = Completer<int>();
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
          final m = RegExp(r'viewer on http://localhost:(\d+)').firstMatch(line);
          if (m != null && !port.isCompleted) port.complete(int.parse(m[1]!));
        });
        final p = await port.future.timeout(const Duration(seconds: 30));
        final client = HttpClient();

        Future<(int, String?, String)> fetch(String path) async {
          final res = await (await client.getUrl(Uri.parse('http://localhost:$p$path'))).close();
          return (res.statusCode, res.headers.contentType?.toString(), await res.transform(utf8.decoder).join());
        }

        final (rootCode, rootType, rootBody) = await fetch('/');
        expect(rootCode, 200);
        expect(rootType, contains('text/html'));
        expect(rootBody, _site('index.html'), reason: '/ serves index.html byte-for-byte');

        final (cssCode, cssType, cssBody) = await fetch('/style.css');
        expect(cssCode, 200);
        expect(cssType, contains('text/css'));
        expect(cssBody, _site('style.css'));

        final (jsCode, jsType, jsBody) = await fetch('/app.js');
        expect(jsCode, 200);
        expect(jsType, contains('text/javascript'));
        expect(jsBody, _site('app.js'));

        // Whitelist-only: nothing outside the three site files is reachable —
        // not other assets, and never anything via a traversal-shaped path.
        expect((await fetch('/nope.js')).$1, 404);
        expect((await fetch('/site/index.html')).$1, 404);
        expect((await fetch('/%2e%2e/labwright.dart')).$1, 404);
        client.close(force: true);
      } finally {
        process.kill();
        await process.exitCode;
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
