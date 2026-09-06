import 'dart:convert';
import 'dart:io';

import 'package:labwright/src/viewer.dart' show editorLinkTemplate;
import 'package:test/test.dart';

import 'harness.dart';

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
    final used = RegExp(r"byId\('([^']+)'\)").allMatches(_site('app.js')).map((m) => m.group(1)!).toSet();
    expect(used, isNotEmpty, reason: 'the JS drives the page through byId lookups');
    for (final id in used) {
      expect(html, contains('id="$id"'), reason: 'app.js uses #$id, so index.html must declare it');
    }
  });

  test('the JS and CSS agree on the status/badge class vocabulary', () {
    final js = _site('app.js');
    final css = _site('style.css');
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
    expect(_site('app.js'), contains('source.onopen'), reason: 'the dot turns green when the stream opens');
    expect(_site('app.js'), contains('setConn(false)'), reason: 'and red the moment it drops');
  });

  test('editor link template per platform (the page substitutes {file}/{line})', () {
    // dart format off
    final rows = <(String, String, String)>[
      ('native (path supplies the slash)', editorLinkTemplate(isWindows: false), 'vscode://file{file}:{line}'),
      ('Windows (explicit slash before the drive letter)', editorLinkTemplate(isWindows: true), 'vscode://file/{file}:{line}'),
      ('WSL (vscode-remote authority names the distro)',
          editorLinkTemplate(isWindows: false, wslDistro: 'Ubuntu-24.04'), 'vscode://vscode-remote/wsl+Ubuntu-24.04{file}:{line}'),
    ];
    // dart format on
    for (final (name, got, want) in rows) {
      expect(got, want, reason: name);
    }
  });

  test(
    'the viewer serves the site: right content types, disk-identical bytes, whitelist-only',
    () async {
      final v = await Viewer.start(
        'test/fixtures/slow_e2e.dart',
        defines: ['-Dlabwright.identity=false', '-Dlabwright.seed=0'],
        awaitReady: false,
      );
      try {
        for (final (path, type, file) in const [
          ('/', 'text/html', 'index.html'),
          ('/style.css', 'text/css', 'style.css'),
          ('/app.js', 'text/javascript', 'app.js'),
        ]) {
          final res = await v.getRes(path);
          expect(res.statusCode, 200);
          expect(res.headers.contentType?.toString(), contains(type));
          expect(await utf8.decodeStream(res), _site(file), reason: '$path serves $file byte-for-byte');
        }
        for (final path in const [
          '/nope.js',
          '/site/index.html',
          '/%2e%2e/labwright.dart',
          '/pubspec.yaml',
          '/..%2fpubspec.yaml',
        ]) {
          expect((await v.get(path)).$1, 404, reason: path);
        }
      } finally {
        await v.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
