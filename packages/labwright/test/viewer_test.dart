// The in-process viewer and its interactive control plane, driven over HTTP
// against real suite child processes (see harness.dart).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'harness.dart';

const _t2 = Timeout(Duration(minutes: 2));
const _green = ['-Dlabwright.identity=false', '-Dlabwright.seed=0'];
const _interactive = '-Dlabwright.interactive=true';

void main() {
  test('keepOpen viewer serves the page and state after the run', () async {
    final v = await Viewer.start('test/fixtures/green_e2e.dart', defines: ['-Dlabwright.keepOpen=true', ..._green]);
    try {
      final (stateCode, stateBody) = await v.get('/state.json');
      expect(stateCode, 200);
      final state = (jsonDecode(stateBody) as Map).cast<String, Object?>();
      expect(state['done'], true);
      final tests = testsOf(state);
      expect(tests, hasLength(3));
      expect(
        (tests.first['logs'] as List).map((l) => (l as Map)['m']),
        ['applying power'],
        reason: 'logs (timestamped {t,m}) attach to their test for the viewer',
      );
      final (pageCode, page) = await v.get('/');
      expect(pageCode, 200);
      expect(page, contains('labwright'));
      expect(page, contains('id="logList"'), reason: 'the multi-pane app (Tests/Log/Queue)');
      expect(page, contains('src="app.js"'), reason: 'the app ships as real site files (see site_test.dart)');
    } finally {
      await v.close();
    }
  }, timeout: _t2);

  test('interactive control plane: routes re-run, reject when idle/unknown', () async {
    final v = await Viewer.start('test/fixtures/green_e2e.dart', defines: [_interactive, '-Dlabwright.identity=false']);
    try {
      final (failedCode, _) = await v.post('/run-failed');
      expect(failedCode, 409, reason: 'nothing failed in the green fixture — rejected, not a crash');

      final (restartCode, restartBody) = await v.post('/restart');
      expect(restartCode, 409, reason: 'unsupervised (bare dart run): exiting would kill the viewer');
      expect(restartBody!['error'], contains('supervisor'));

      final (bogusCode, bogusBody) = await v.post('/nonsense');
      expect(bogusCode, 404, reason: 'a verb outside the route table is a clean 404, not a 500');
      expect(bogusBody!['error'], contains('unknown route'));

      final (runCode, _) = await v.post('/run-one', {'test': 'rail comes up'});
      expect(runCode, 202);
      final state = await v.settle((s) => s['busy'] == false && s['done'] == true);
      expect(state['interactive'], true);
    } finally {
      await v.close();
    }
  }, timeout: _t2);

  test('custom buttons: exposed in state, run their action, log to the feed', () async {
    final v = await Viewer.start('test/fixtures/green_e2e.dart', defines: [_interactive, '-Dlabwright.identity=false']);
    try {
      expect((await v.state())['buttons'], ['reset rig'], reason: 'registered buttons surface in the viewer state');

      final (code, _) = await v.post('/button', {'index': 0});
      expect(code, 202);
      await v.line('button "reset rig" done').timeout(const Duration(seconds: 30));

      final (badCode, _) = await v.post('/button', {'index': 9});
      expect(badCode, 409, reason: 'an out-of-range index is a clean rejection');

      // The action's execution — including its log() lines — landed in the Log
      // feed; a fresh SSE client replays the history in a `hist` reset frame.
      final got = Completer<List<Map<String, Object?>>>();
      final sub = await v.events((event, data) {
        if (event == 'hist' && data['reset'] == true && !got.isCompleted) {
          got.complete((data['entries'] as List).cast<Map<String, Object?>>());
        }
      });
      final entries = await got.future.timeout(const Duration(seconds: 30));
      final record = entries.firstWhere((e) => e['name'] == 'button: reset rig');
      expect(record['status'], 'passed');
      expect((record['logs'] as List).map((l) => (l as Map)['m']), ['rig reset']);
      await sub.cancel();
    } finally {
      await v.close();
    }
  }, timeout: _t2);

  test('goto link + seed replay: absolute source locations, editorLink template, reseed', () async {
    final v = await Viewer.start('test/fixtures/green_e2e.dart', defines: [_interactive, ..._green]);
    try {
      // Registration file:line is ABSOLUTE — the page concatenates it straight
      // into the client-side vscode:// goto link (no server route involved).
      final state = await v.state();
      final rail = testIn(state, 'rail comes up');
      expect('${rail['file']}', endsWith('green_e2e.dart'));
      expect('${rail['file']}', anyOf(startsWith('/'), matches(RegExp(r'^[A-Za-z]:'))));
      expect(rail['line'], isA<int>().having((n) => n > 0, 'positive', isTrue));
      expect('${state['editorLink']}', startsWith('vscode://'));
      expect('${state['editorLink']}', endsWith('{file}:{line}'));

      final (code, _) = await v.post('/reseed', {'seed': 7});
      expect(code, 202);
      final after = await v.settle((s) => s['busy'] == false && s['seed'] == 7);
      expect(after['seed'], 7, reason: 'reseed swapped the active seed');
    } finally {
      await v.close();
    }
  }, timeout: _t2);

  test('run-to-run diff + report download: newFail/newPass/flaky, /report.json', () async {
    final v = await Viewer.start('test/fixtures/flaky_e2e.dart', defines: [_interactive, ..._green]);
    try {
      Future<Map<String, Object?>> settleAt(String status) => v.settle(
        (s) => s['busy'] == false && testsOf(s).single['status'] == status,
      );

      final first = await settleAt('passed');
      expect(testsOf(first).single['change'], isNull, reason: 'no prior run to diff against');

      await v.post('/button', {'index': 0}); // break the bench
      await v.post('/run');
      expect(testsOf(await settleAt('failed')).single['change'], 'newFail');

      await v.post('/button', {'index': 1}); // fix the bench
      await v.post('/run');
      final fixed = testsOf(await settleAt('passed')).single;
      expect(fixed['change'], 'newPass');
      expect(fixed['flaky'], true, reason: 'a pass-fail-pass test is flaky');

      final rep = await v.getRes('/report.json');
      expect(rep.headers.value('content-disposition'), contains('labwright-report.json'));
      final report = (jsonDecode(await utf8.decodeStream(rep)) as Map).cast<String, Object?>();
      expect(report.containsKey('requirements'), isTrue, reason: 'the report carries the requirements trace');
      expect(report.containsKey('buttons'), isFalse, reason: 'buttons are viewer-only');
    } finally {
      await v.close();
    }
  }, timeout: _t2);

  test('log feed: history replays to a new client as a hist event; runs stream log deltas', () async {
    final v = await Viewer.start('test/fixtures/green_e2e.dart', defines: [_interactive, ..._green]);
    try {
      final hist = Completer<Map<String, Object?>>();
      final logDelta = Completer<Map<String, Object?>>();
      final sub = await v.events((event, data) {
        if (event == 'hist' && data['reset'] == true && !hist.isCompleted) hist.complete(data);
        if (event == 'log' && !logDelta.isCompleted) logDelta.complete(data);
      });

      final entries = ((await hist.future.timeout(const Duration(seconds: 30)))['entries'] as List)
          .cast<Map<String, Object?>>();
      expect(entries.map((e) => e['name']).toSet(), {
        'rail comes up',
        'ripple in limits',
        'thermal camera sweep',
      }, reason: 'the first run recorded one execution per test');
      expect(entries.every((e) => e['run'] == 1), isTrue, reason: 'all from the first pass');
      final rail = entries.firstWhere((e) => e['name'] == 'rail comes up');
      expect((rail['logs'] as List).map((l) => (l as Map)['m']), ['applying power']);
      final queued = rail['queuedAt'] as int, started = rail['startedAt'] as int, finished = rail['finishedAt'] as int;
      expect(queued, lessThanOrEqualTo(started), reason: 'wall-clock stamps flow through in order');
      expect(started, lessThanOrEqualTo(finished));
      expect((rail['logs'] as List).first, containsPair('t', isA<int>()));

      // A log line during a run arrives as a small `log` DELTA ({name, t, m}),
      // not a full-state rebroadcast per line.
      await v.post('/run');
      final delta = await logDelta.future.timeout(const Duration(seconds: 30));
      expect(delta['name'], 'rail comes up');
      expect(delta['m'], 'applying power');
      expect(delta['t'], isA<int>());
      await sub.cancel();
    } finally {
      await v.close();
    }
  }, timeout: _t2);

  test('stop preserves unreached tests; control posts are origin/type guarded', () async {
    final v = await Viewer.start('test/fixtures/slow_e2e.dart', defines: [_interactive, ..._green]);
    try {
      final before = await v.state();
      expect(testIn(before, 'fast follower')['status'], 'passed');

      // Re-run, then Stop while the 800ms 'slow gate' is in flight: the slow
      // test must finish, and 'fast follower' must never be touched.
      expect((await v.post('/run')).$1, 202);
      expect((await v.post('/stop')).$1, 202);
      final after = await v.settle((s) => s['busy'] == false && s['done'] == true);
      expect(after['queue'] as List, isEmpty, reason: 'stop drains the queue — no phantom entries');
      final slow = testIn(after, 'slow gate');
      expect(slow['status'], 'passed', reason: 'the in-flight test always finishes');
      expect(slow['finishedAt'], isNot(testIn(before, 'slow gate')['finishedAt']), reason: 'it really re-ran');
      final fast = testIn(after, 'fast follower');
      expect(fast['status'], 'passed', reason: 'the unreached test keeps its prior verdict, not phantom queued');
      expect(fast['finishedAt'], testIn(before, 'fast follower')['finishedAt'], reason: 'never touched');
      expect((after['summary'] as Map)['passed'], 2, reason: 'the summary still counts the preserved verdict');

      expect((await v.post('/reseed')).$1, 409, reason: 'reseed without a seed is rejected, not silently seed 0');

      // Requests that don't look like the page's own are 403 before any route
      // logic: a cross-site Origin, or a no-preflight non-JSON content type.
      expect((await v.post('/stop', const {}, 'https://evil.example')).$1, 403);
      expect((await v.post('/stop', const {}, null, ContentType.text)).$1, 403);
      expect((await v.post('/stop', const {}, 'http://localhost:${v.port}')).$1, 202, reason: 'same-host is welcome');
    } finally {
      await v.close();
    }
  }, timeout: _t2);

  test('a non-interactive viewer is read-only: a control POST answers 503', () async {
    // slow fixture: the viewer is up while it runs; no linger banner to await.
    final v = await Viewer.start('test/fixtures/slow_e2e.dart', defines: _green, awaitReady: false);
    try {
      expect((await v.post('/stop')).$1, 503, reason: 'without interactive/keepOpen no route is wired at all');
    } finally {
      await v.close();
    }
  }, timeout: _t2);
}
