import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// The labwright package root, whether the suite runs from the repo root or
/// the package dir (mirrors the corpus_dirs.dart convention).
final String pkgRoot = Directory('packages/labwright').existsSync() ? 'packages/labwright' : '.';

const _noViewer = '-Dlabwright.viewer=false';

/// Runs a suite the only way suites run — ONE process, `dart run`, all
/// configuration as Dart defines — and returns (exitCode, stdout, stderr).
/// Content-identity hashing is off by default here (the hasher isolate costs
/// ~3s per child process); the tests that assert on hashes opt back in.
(int, String, String) _run(String file, {List<String> defines = const [], bool identity = false}) {
  final result = Process.runSync(
    Platform.resolvedExecutable,
    ['run', _noViewer, if (!identity) '-Dlabwright.identity=false', ...defines, file],
    workingDirectory: pkgRoot,
  );
  return (result.exitCode, result.stdout.toString(), result.stderr.toString());
}

/// Runs [file] with a report define and returns (exitCode, stdout, report).
(int, String, Map<String, Object?>) _runWithReport(
  String file, {
  List<String> defines = const [],
  bool identity = false,
}) {
  final dir = Directory.systemTemp.createTempSync('lw_');
  try {
    final path = '${dir.path}/report.json';
    final (exit, out, _) = _run(file, defines: ['-Dlabwright.report=$path', ...defines], identity: identity);
    final report = (jsonDecode(File(path).readAsStringSync()) as Map).cast<String, Object?>();
    return (exit, out, report);
  } finally {
    dir.deleteSync(recursive: true);
  }
}

List<Map<String, Object?>> _tests(Map<String, Object?> report) =>
    (report['tests'] as List).cast<Map<String, Object?>>();

void main() {
  test('green fixture: registration then execution, real expect, skip green', () {
    final (exit, out, report) = _runWithReport('test/fixtures/green_e2e.dart', defines: ['-Dlabwright.seed=0']);
    expect(exit, 0, reason: 'skipped alone must stay green:\n$out');
    final tests = _tests(report);
    expect(tests.map((t) => t['name']), [
      'rail comes up',
      'ripple in limits',
      'thermal camera sweep',
    ], reason: 'seed 0 keeps registration order as execution order');
    expect(
      tests[0]['status'],
      'passed',
      reason:
          'async setup at the top of main completed before any body; '
          'package:test expect/expectLater/matchers work as-is',
    );
    expect(tests[0]['requirements'], ['REQ-1']);
    expect(tests[0]['logs'], ['applying power'], reason: 'log lines attach to their test in the report');
    expect(tests[1]['requirements'], ['REQ-2', 'REQ-3']);
    expect(tests[2]['status'], 'skipped', reason: 'skipTest reports without running the body');
    expect((report['summary'] as Map)['skipped'], 1);
  });

  test('red fixture: TestFailure=failed, other throw=error, exits non-zero', () {
    final (exit, out, report) = _runWithReport('test/fixtures/red_e2e.dart', defines: ['-Dlabwright.seed=0']);
    expect(exit, isNot(0), reason: 'failures must fail CI');
    final tests = _tests(report);
    expect(tests, hasLength(3), reason: 'a failed test does not stop later tests');
    expect(tests[0]['status'], 'failed');
    expect('${tests[0]['detail']}', contains('trip current'), reason: 'the matcher mismatch description is carried');
    expect(tests[1]['status'], 'passed');
    expect(tests[2]['status'], 'error', reason: 'a non-TestFailure escape is an error, not a failure');
    expect('${tests[2]['detail']}', contains('relay stuck'));
    // The requirements trace maps each ID to its tests and statuses.
    final req9 = ((report['requirements'] as Map)['REQ-9'] as List).cast<Map<String, Object?>>();
    expect(req9.single['status'], 'failed');
    expect(out, contains('RUN  trip threshold'), reason: 'the start line names the test; no requirement/seed noise');
  });

  test('sharding: plain index % N over the one in-process registry', () {
    final byShard = <int, List<Object?>>{};
    for (var i = 0; i < 2; i++) {
      final (exit, out, report) = _runWithReport(
        'test/fixtures/green_e2e.dart',
        defines: [
          '-Dlabwright.totalShards=2',
          '-Dlabwright.shardIndex=$i',
        ],
      );
      expect(exit, 0, reason: 'shard $i:\n$out');
      expect(
        report['seed'],
        0x5EED,
        reason:
            'a sharded run with no explicit seed uses the fixed shard '
            'seed so every runner shuffles alike',
      );
      byShard[i] = _tests(report).map((t) => t['name']).toList();
    }
    expect(byShard[0]!.toSet(), {
      'rail comes up',
      'thermal camera sweep',
    }, reason: 'indices 0,2 land in shard 0 (order shuffled by shard seed)');
    expect(byShard[1], ['ripple in limits'], reason: 'index 1 lands in shard 1');
  });

  test('seed: an explicit seed shuffles order deterministically, never the set', () {
    List<Object?> orderFor(int s) {
      final (exit, out, report) = _runWithReport('test/fixtures/green_e2e.dart', defines: ['-Dlabwright.seed=$s']);
      expect(exit, 0, reason: out);
      expect(report['seed'], s, reason: 'the report carries the seed');
      if (s != 0) {
        expect(out, contains('[Labwright]: seed $s'), reason: 'a non-zero seed prints once, at suite start');
      }
      return _tests(report).map((t) => t['name']).toList();
    }

    final registration = orderFor(0); // an explicit 0 keeps registration order
    final seeded = orderFor(1);
    expect(seeded.toSet(), registration.toSet(), reason: 'a seed permutes the run order, never the set of tests');
    expect(seeded, isNot(equals(registration)), reason: 'seed 1 reorders this fixture (verified permutation)');
    expect(orderFor(1), seeded, reason: 'the same seed reproduces the order');
  });

  test('unseeded, unsharded run mints and announces a random seed', () {
    final (exit, out, report) = _runWithReport('test/fixtures/green_e2e.dart');
    expect(exit, 0);
    final s = report['seed'] as int;
    expect(s, isNot(0), reason: 'no seed + no sharding randomizes each run (not seed 0)');
    expect(out, contains('[Labwright]: seed $s'), reason: 'the minted seed prints once, at suite start, to reproduce');
  });

  test('late registration (after the run starts) dies loudly, not silently', () {
    final (exit, out, errText) = _run('test/bad_fixtures/late_registration_e2e.dart');
    expect(exit, isNot(0));
    expect(errText, contains('registered after the run started'), reason: 'the contract violation names itself');
    expect(out, contains('PASS registered in time'), reason: 'the in-time test still ran; the late one never joined');
  });

  test('human output: readable ASCII lines and a definite end-of-run summary', () {
    // Seed 0 keeps registration order so the lines are predictable here.
    final (exit, out, _) = _run('test/fixtures/green_e2e.dart', defines: ['-Dlabwright.seed=0']);
    expect(exit, 0);
    expect(out, contains('RUN  rail comes up'), reason: 'the start line is plain ASCII, no requirement/seed');
    expect(out, contains('PASS rail comes up'));
    expect(out, contains('SKIP thermal camera sweep'));
    expect(out, isNot(contains('seed')), reason: 'seed 0 is registration order — nothing to announce');
    expect(
      out,
      contains(
        '[Labwright]: 3 test(s) - 2 passed, 0 failed, 0 errors, '
        '1 skipped',
      ),
    );
  });

  test('the in-process viewer serves the page and state; busy port tolerated', () async {
    // keepOpen holds the (single) process alive serving results.
    final process = await Process.start(
      Platform.resolvedExecutable,
      [
        'run',
        '-Dlabwright.port=0',
        '-Dlabwright.keepOpen=true',
        '-Dlabwright.identity=false', // hashes not asserted here — skip the hasher isolate
        '-Dlabwright.seed=0', // registration order → tests.first is stable
        'test/fixtures/green_e2e.dart',
      ],
      workingDirectory: pkgRoot,
    );
    try {
      final port = Completer<int>();
      final done = Completer<void>();
      process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
        final m = RegExp(r'viewer on http://localhost:(\d+)').firstMatch(line);
        if (m != null && !port.isCompleted) port.complete(int.parse(m[1]!));
        if (line.contains('View results and re-run tests at') && !done.isCompleted) {
          done.complete();
        }
      });
      final p = await port.future.timeout(const Duration(seconds: 30));
      await done.future.timeout(const Duration(seconds: 60));

      final client = HttpClient();
      final stateRes = await (await client.getUrl(Uri.parse('http://localhost:$p/state.json'))).close();
      expect(stateRes.statusCode, 200);
      final state = (jsonDecode(await stateRes.transform(utf8.decoder).join()) as Map).cast<String, Object?>();
      expect(state['done'], true);
      final tests = (state['tests'] as List).cast<Map<String, Object?>>();
      expect(tests, hasLength(3));
      expect(
        (tests.first['logs'] as List).map((l) => (l as Map)['m']),
        ['applying power'],
        reason: 'logs (timestamped {t,m}) attach to their test for the viewer',
      );

      final pageRes = await (await client.getUrl(Uri.parse('http://localhost:$p/'))).close();
      expect(pageRes.statusCode, 200);
      final page = await pageRes.transform(utf8.decoder).join();
      expect(page, contains('labwright'));
      expect(page, contains('id="logList"'), reason: 'the multi-pane app (Tests/Log/Queue)');
      expect(page, contains('EventSource'), reason: 'live SSE viewer');
      client.close(force: true);
    } finally {
      process.kill();
      await process.exitCode;
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('interactive control plane: actions re-run, reject when idle/unknown', () async {
    // --interactive lingers AND wires the POST /action control plane.
    final process = await Process.start(
      Platform.resolvedExecutable,
      [
        'run',
        '-Dlabwright.port=0',
        '-Dlabwright.interactive=true',
        '-Dlabwright.identity=false', // hashes not asserted here — skip the hasher isolate
        'test/fixtures/green_e2e.dart',
      ],
      workingDirectory: pkgRoot,
    );
    try {
      final port = Completer<int>();
      final ready = Completer<void>();
      process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
        final m = RegExp(r'viewer on http://localhost:(\d+)').firstMatch(line);
        if (m != null && !port.isCompleted) port.complete(int.parse(m[1]!));
        // The interactive linger banner prints once the first run finishes.
        if (line.contains('View results and re-run tests at') && !ready.isCompleted) {
          ready.complete();
        }
      });
      final p = await port.future.timeout(const Duration(seconds: 30));
      await ready.future.timeout(const Duration(seconds: 60));

      final client = HttpClient();
      Future<HttpClientResponse> action(Object body) async {
        final req = await client.postUrl(Uri.parse('http://localhost:$p/action'));
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(body));
        return req.close();
      }

      // Green fixture has nothing failed → rejected (409), not a crash.
      final failedRes = await action({'type': 'rerunFailed'});
      expect(failedRes.statusCode, 409);
      await failedRes.drain<void>();

      // An unknown action is a clean 409 with an error, not a 500.
      final bogusRes = await action({'type': 'nonsense'});
      expect(bogusRes.statusCode, 409);
      expect((jsonDecode(await bogusRes.transform(utf8.decoder).join()) as Map)['error'], contains('unknown action'));

      // Re-run one test: accepted (202), and the suite runs again to done.
      final runRes = await action({'type': 'runOne', 'test': 'rail comes up'});
      expect(runRes.statusCode, 202);
      await runRes.drain<void>();

      // Poll state until the re-run settles (busy false, done true again).
      Map<String, Object?> state = const {};
      for (var i = 0; i < 100; i++) {
        final res = await (await client.getUrl(Uri.parse('http://localhost:$p/state.json'))).close();
        state = (jsonDecode(await res.transform(utf8.decoder).join()) as Map).cast<String, Object?>();
        if (state['busy'] == false && state['done'] == true) break;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(state['interactive'], true);
      expect(state['busy'], false, reason: 'the re-run settled');
      client.close(force: true);
    } finally {
      process.kill();
      await process.exitCode;
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('custom buttons: exposed in state and run their action on demand', () async {
    final process = await Process.start(
      Platform.resolvedExecutable,
      [
        'run',
        '-Dlabwright.port=0',
        '-Dlabwright.interactive=true',
        '-Dlabwright.identity=false',
        'test/fixtures/green_e2e.dart',
      ],
      workingDirectory: pkgRoot,
    );
    try {
      final port = Completer<int>();
      final ready = Completer<void>();
      final ranButton = Completer<void>();
      process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
        final m = RegExp(r'viewer on http://localhost:(\d+)').firstMatch(line);
        if (m != null && !port.isCompleted) port.complete(int.parse(m[1]!));
        if (line.contains('View results and re-run tests at') && !ready.isCompleted) {
          ready.complete();
        }
        if (line.contains('button "reset rig" done') && !ranButton.isCompleted) {
          ranButton.complete();
        }
      });
      final p = await port.future.timeout(const Duration(seconds: 30));
      await ready.future.timeout(const Duration(seconds: 60));

      final client = HttpClient();
      final stateRes = await (await client.getUrl(Uri.parse('http://localhost:$p/state.json'))).close();
      final state = (jsonDecode(await stateRes.transform(utf8.decoder).join()) as Map).cast<String, Object?>();
      expect(state['buttons'], ['reset rig'], reason: 'registered buttons surface in the viewer state');

      Future<HttpClientResponse> action(Object body) async {
        final req = await client.postUrl(Uri.parse('http://localhost:$p/action'));
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(body));
        return req.close();
      }

      // Firing the button runs its async action (which logs 'rig reset').
      final runRes = await action({'type': 'button', 'index': 0});
      expect(runRes.statusCode, 202);
      await runRes.drain<void>();
      await ranButton.future.timeout(const Duration(seconds: 30), onTimeout: () => fail('the button action never ran'));

      // An out-of-range button index is a clean rejection, not a crash.
      final badRes = await action({'type': 'button', 'index': 9});
      expect(badRes.statusCode, 409);
      await badRes.drain<void>();

      // The action's execution — including its log() lines — landed in the
      // Log feed, as the button() docs promise. A fresh SSE client replays
      // the history, so read its `hist` reset frame.
      final events = await (await client.getUrl(Uri.parse('http://localhost:$p/events'))).close();
      final got = Completer<List<Map<String, Object?>>>();
      final buf = StringBuffer();
      final sub = events.transform(utf8.decoder).listen((chunk) {
        buf.write(chunk);
        for (final frame in buf.toString().split('\n\n')) {
          if (!frame.startsWith('event: hist')) continue;
          final dataLine = frame.split('\n').firstWhere((l) => l.startsWith('data: '), orElse: () => '');
          if (dataLine.isEmpty) continue;
          try {
            final data = (jsonDecode(dataLine.substring(6)) as Map).cast<String, Object?>();
            if (data['reset'] == true && !got.isCompleted) {
              got.complete((data['entries'] as List).cast<Map<String, Object?>>());
            }
          } catch (_) {
            /* partial frame — wait for more */
          }
        }
      });
      final entries = await got.future.timeout(const Duration(seconds: 30));
      final record = entries.firstWhere((e) => e['name'] == 'button: reset rig');
      expect(record['status'], 'passed');
      expect(
        (record['logs'] as List).map((l) => (l as Map)['m']),
        ['rig reset'],
        reason: 'a button action streams its log() lines to the Log feed',
      );
      await sub.cancel();
      client.close(force: true);
    } finally {
      process.kill();
      await process.exitCode;
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('open-in-editor + seed replay: source locations, reseed, editor launch', () async {
    final tmp = Directory.systemTemp.createTempSync('lw_');
    // A recorder standing in for the editor (POSIX only — bash script), in a
    // directory WITH A SPACE: the editor template must express it via quotes.
    final opened = File('${tmp.path}/opened.txt');
    final rec = File('${tmp.path}/editor dir/rec.sh')
      ..createSync(recursive: true)
      ..writeAsStringSync('#!/usr/bin/env bash\nprintf "%s" "\$*" > "${opened.path}"\n');
    final posix = !Platform.isWindows;
    if (posix) Process.runSync('chmod', ['+x', rec.path]);
    try {
      final process = await Process.start(Platform.resolvedExecutable, [
        'run',
        '-Dlabwright.port=0',
        '-Dlabwright.interactive=true',
        '-Dlabwright.identity=false', // hashes not asserted here — skip the hasher isolate
        '-Dlabwright.seed=0',
        if (posix) '-Dlabwright.editor="${rec.path}" {file} {line}',
        'test/fixtures/green_e2e.dart',
      ], workingDirectory: pkgRoot);
      try {
        final port = Completer<int>();
        final ready = Completer<void>();
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
          final m = RegExp(r'viewer on http://localhost:(\d+)').firstMatch(line);
          if (m != null && !port.isCompleted) port.complete(int.parse(m[1]!));
          if (line.contains('View results and re-run tests at') && !ready.isCompleted) {
            ready.complete();
          }
        });
        final p = await port.future.timeout(const Duration(seconds: 30));
        await ready.future.timeout(const Duration(seconds: 60));
        final client = HttpClient();

        Future<Map<String, Object?>> getState() async {
          final res = await (await client.getUrl(Uri.parse('http://localhost:$p/state.json'))).close();
          return (jsonDecode(await res.transform(utf8.decoder).join()) as Map).cast<String, Object?>();
        }

        Future<HttpClientResponse> action(Object body) async {
          final req = await client.postUrl(Uri.parse('http://localhost:$p/action'));
          req.headers.contentType = ContentType.json;
          req.write(jsonEncode(body));
          return req.close();
        }

        // Each test carries its registration file:line (captured in interactive).
        final state = await getState();
        final rail = (state['tests'] as List).cast<Map<String, Object?>>().firstWhere(
          (t) => t['name'] == 'rail comes up',
        );
        expect('${rail['file']}', endsWith('green_e2e.dart'));
        expect(rail['line'], isA<int>().having((n) => n > 0, 'positive', isTrue));

        // Open the test's source: accepted, and (POSIX) the editor really runs.
        final openRes = await action({'type': 'open', 'file': rail['file'], 'line': rail['line']});
        expect(openRes.statusCode, 202);
        await openRes.drain<void>();
        if (posix) {
          for (var i = 0; i < 60 && !opened.existsSync(); i++) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
          expect(
            opened.readAsStringSync(),
            contains('green_e2e.dart'),
            reason: 'the editor command ran with the file:line',
          );
        }

        // Seed replay: re-run in a chosen seed's order; state carries the seed.
        final reseedRes = await action({'type': 'reseed', 'seed': 7});
        expect(reseedRes.statusCode, 202);
        await reseedRes.drain<void>();
        Map<String, Object?> after = const {};
        for (var i = 0; i < 100; i++) {
          after = await getState();
          if (after['busy'] == false && after['seed'] == 7) break;
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(after['seed'], 7, reason: 'reseed swapped the active seed');
        client.close(force: true);
      } finally {
        process.kill();
        await process.exitCode;
      }
    } finally {
      tmp.deleteSync(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('run-to-run diff + report download: newFail/newPass/flaky, /report.json', () async {
    final process = await Process.start(
      Platform.resolvedExecutable,
      [
        'run',
        '-Dlabwright.port=0',
        '-Dlabwright.interactive=true',
        '-Dlabwright.identity=false', // hashes not asserted here — skip the hasher isolate
        '-Dlabwright.seed=0',
        'test/fixtures/flaky_e2e.dart',
      ],
      workingDirectory: pkgRoot,
    );
    try {
      final port = Completer<int>();
      final ready = Completer<void>();
      process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
        final m = RegExp(r'viewer on http://localhost:(\d+)').firstMatch(line);
        if (m != null && !port.isCompleted) port.complete(int.parse(m[1]!));
        if (line.contains('View results and re-run tests at') && !ready.isCompleted) ready.complete();
      });
      final p = await port.future.timeout(const Duration(seconds: 30));
      await ready.future.timeout(const Duration(seconds: 60));
      final client = HttpClient();

      Future<Map<String, Object?>> getState() async {
        final res = await (await client.getUrl(Uri.parse('http://localhost:$p/state.json'))).close();
        return (jsonDecode(await res.transform(utf8.decoder).join()) as Map).cast<String, Object?>();
      }

      Map<String, Object?> theTest(Map<String, Object?> s) => (s['tests'] as List).cast<Map<String, Object?>>().single;

      Future<void> action(Object body) async {
        final req = await client.postUrl(Uri.parse('http://localhost:$p/action'));
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(body));
        await (await req.close()).drain<void>();
      }

      // Waits until the single test reaches [status] and the run has settled.
      Future<Map<String, Object?>> settleAt(String status) async {
        for (var i = 0; i < 200; i++) {
          final s = await getState();
          if (s['busy'] == false && theTest(s)['status'] == status) return s;
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        fail('test never settled at $status');
      }

      // First run: green, no change badge yet.
      final first = await settleAt('passed');
      expect(theTest(first)['change'], isNull, reason: 'no prior run to diff against');

      // break the bench, re-run → newFail.
      await action({'type': 'button', 'index': 0});
      await action({'type': 'rerun'});
      expect(theTest(await settleAt('failed'))['change'], 'newFail');

      // fix the bench, re-run → newPass, and now flaky (flipped twice).
      await action({'type': 'button', 'index': 1});
      await action({'type': 'rerun'});
      final fixed = await settleAt('passed');
      expect(theTest(fixed)['change'], 'newPass');
      expect(theTest(fixed)['flaky'], true, reason: 'a pass↔fail↔pass test is flaky');

      // The report endpoint serves the machine report, without viewer-only keys.
      final rep = await (await client.getUrl(Uri.parse('http://localhost:$p/report.json'))).close();
      expect(rep.headers.value('content-disposition'), contains('labwright-report.json'));
      final report = (jsonDecode(await rep.transform(utf8.decoder).join()) as Map).cast<String, Object?>();
      expect(report.containsKey('requirements'), isTrue, reason: 'report carries the requirements trace');
      expect(report.containsKey('buttons'), isFalse, reason: 'buttons are viewer-only');
      client.close(force: true);
    } finally {
      process.kill();
      await process.exitCode;
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('log feed: the run history replays to a new client as a hist event', () async {
    final process = await Process.start(
      Platform.resolvedExecutable,
      [
        'run',
        '-Dlabwright.port=0',
        '-Dlabwright.interactive=true',
        '-Dlabwright.identity=false', // hashes not asserted here — skip the hasher isolate
        '-Dlabwright.seed=0',
        'test/fixtures/green_e2e.dart',
      ],
      workingDirectory: pkgRoot,
    );
    try {
      final port = Completer<int>();
      final ready = Completer<void>();
      process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
        final m = RegExp(r'viewer on http://localhost:(\d+)').firstMatch(line);
        if (m != null && !port.isCompleted) port.complete(int.parse(m[1]!));
        if (line.contains('View results and re-run tests at') && !ready.isCompleted) ready.complete();
      });
      final p = await port.future.timeout(const Duration(seconds: 30));
      await ready.future.timeout(const Duration(seconds: 60));

      // Consume the SSE stream and pull the one-shot `hist` reset frame,
      // plus any per-line `log` deltas that flow during a re-run.
      final client = HttpClient();
      final res = await (await client.getUrl(Uri.parse('http://localhost:$p/events'))).close();
      final got = Completer<Map<String, Object?>>();
      final logDelta = Completer<Map<String, Object?>>();
      final buf = StringBuffer();
      final sub = res.transform(utf8.decoder).listen((chunk) {
        buf.write(chunk);
        for (final frame in buf.toString().split('\n\n')) {
          final dataLine = frame.split('\n').firstWhere((l) => l.startsWith('data: '), orElse: () => '');
          if (dataLine.isEmpty) continue;
          try {
            final data = (jsonDecode(dataLine.substring(6)) as Map).cast<String, Object?>();
            if (frame.startsWith('event: hist') && data['reset'] == true && !got.isCompleted) got.complete(data);
            if (frame.startsWith('event: log') && !logDelta.isCompleted) logDelta.complete(data);
          } catch (_) {
            /* partial frame — wait for more */
          }
        }
      });
      final hist = await got.future.timeout(const Duration(seconds: 30));
      final entries = (hist['entries'] as List).cast<Map<String, Object?>>();
      expect(entries.map((e) => e['name']).toSet(), {
        'rail comes up',
        'ripple in limits',
        'thermal camera sweep',
      }, reason: 'the first run recorded one execution per test');
      expect(entries.every((e) => e['run'] == 1), isTrue, reason: 'all from the first pass');
      final rail = entries.firstWhere((e) => e['name'] == 'rail comes up');
      expect(
        (rail['logs'] as List).map((l) => (l as Map)['m']),
        ['applying power'],
        reason: 'history carries each execution\'s timestamped logs for the Log view',
      );
      // Wall-clock stamps flow through: queued ≤ started ≤ finished, and each
      // log line is timestamped.
      final queued = rail['queuedAt'] as int, started = rail['startedAt'] as int, finished = rail['finishedAt'] as int;
      expect(queued, lessThanOrEqualTo(started));
      expect(started, lessThanOrEqualTo(finished));
      expect((rail['logs'] as List).first, containsPair('t', isA<int>()));

      // A log line during a run arrives as a small `log` DELTA ({name, t, m})
      // rather than a full-state rebroadcast per line.
      final req = await client.postUrl(Uri.parse('http://localhost:$p/action'));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({'type': 'rerun'}));
      await (await req.close()).drain<void>();
      final delta = await logDelta.future.timeout(const Duration(seconds: 30));
      expect(delta['name'], 'rail comes up');
      expect(delta['m'], 'applying power');
      expect(delta['t'], isA<int>());
      await sub.cancel();
      client.close(force: true);
    } finally {
      process.kill();
      await process.exitCode;
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('hot reload: reloads edited sources and re-runs in place', () async {
    // A throwaway suite inside the package (so package: resolves) whose body
    // logs a value returned by a top-level function we then edit + reload.
    final dir = Directory('$pkgRoot/.hot_tmp')..createSync(recursive: true);
    final suite = File('${dir.path}/suite.dart');
    String src(String marker) =>
        "import 'package:labwright/labwright.dart';\n"
        "String marker() => '$marker';\n"
        "void main() {\n  test('marker', () async { log(marker()); });\n}\n";
    suite.writeAsStringSync(src('MARKER_A'));
    Process? process;
    try {
      process = await Process.start(Platform.resolvedExecutable, [
        'run',
        '--enable-vm-service=0',
        '-Dlabwright.port=0',
        '-Dlabwright.interactive=true',
        '-Dlabwright.identity=false', // hashes not asserted here — skip the hasher isolate
        '.hot_tmp/suite.dart',
      ], workingDirectory: pkgRoot);
      final port = Completer<int>();
      final ready = Completer<void>();
      process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
        final m = RegExp(r'viewer on http://localhost:(\d+)').firstMatch(line);
        if (m != null && !port.isCompleted) port.complete(int.parse(m[1]!));
        if (line.contains('View results and re-run tests at') && !ready.isCompleted) ready.complete();
      });
      final p = await port.future.timeout(const Duration(seconds: 30));
      await ready.future.timeout(const Duration(seconds: 60));
      final client = HttpClient();

      // The marker messages (state logs are timestamped {t, m}).
      Future<List<Object?>?> logsNow() async {
        final res = await (await client.getUrl(Uri.parse('http://localhost:$p/state.json'))).close();
        final s = (jsonDecode(await res.transform(utf8.decoder).join()) as Map).cast<String, Object?>();
        if (s['busy'] == true) return null;
        final logs = (s['tests'] as List).cast<Map<String, Object?>>().single['logs'] as List?;
        return logs?.map((l) => (l as Map)['m']).toList();
      }

      expect(await logsNow(), ['MARKER_A']);

      // Edit the source and hot-reload: the re-run must pick up the new code.
      suite.writeAsStringSync(src('MARKER_B'));
      final req = await client.postUrl(Uri.parse('http://localhost:$p/action'));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({'type': 'hotReload'}));
      final res = await req.close();
      expect(res.statusCode, 202, reason: 'reload accepted (VM service is on)');
      await res.drain<void>();

      List<Object?>? after;
      for (var i = 0; i < 200; i++) {
        after = await logsNow();
        if (after != null && after.contains('MARKER_B')) break;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(after, ['MARKER_B'], reason: 'the reloaded code ran on re-run');
      client.close(force: true);
    } finally {
      process?.kill();
      await process?.exitCode;
      dir.deleteSync(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test(
    'stop preserves unreached tests: verdicts, logs and diff survive a halted run',
    () async {
      final process = await Process.start(Platform.resolvedExecutable, [
        'run',
        '-Dlabwright.port=0',
        '-Dlabwright.interactive=true',
        '-Dlabwright.identity=false', // hashes not asserted here — skip the hasher isolate
        '-Dlabwright.seed=0',
        'test/fixtures/slow_e2e.dart',
      ], workingDirectory: pkgRoot);
      try {
        final port = Completer<int>();
        final ready = Completer<void>();
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
          final m = RegExp(r'viewer on http://localhost:(\d+)').firstMatch(line);
          if (m != null && !port.isCompleted) port.complete(int.parse(m[1]!));
          if (line.contains('View results and re-run tests at') && !ready.isCompleted) ready.complete();
        });
        final p = await port.future.timeout(const Duration(seconds: 30));
        await ready.future.timeout(const Duration(seconds: 60));
        final client = HttpClient();

        Future<Map<String, Object?>> getState() async {
          final res = await (await client.getUrl(Uri.parse('http://localhost:$p/state.json'))).close();
          return (jsonDecode(await res.transform(utf8.decoder).join()) as Map).cast<String, Object?>();
        }

        Future<int> action(Object body) async {
          final req = await client.postUrl(Uri.parse('http://localhost:$p/action'));
          req.headers.contentType = ContentType.json;
          req.write(jsonEncode(body));
          final res = await req.close();
          await res.drain<void>();
          return res.statusCode;
        }

        Map<String, Object?> testIn(Map<String, Object?> s, String name) =>
            (s['tests'] as List).cast<Map<String, Object?>>().firstWhere((t) => t['name'] == name);

        final before = await getState();
        expect(testIn(before, 'fast follower')['status'], 'passed');

        // Re-run, then Stop while the 800ms 'slow gate' is in flight: the slow
        // test must finish, and 'fast follower' must never be touched.
        expect(await action({'type': 'rerun'}), 202);
        expect(await action({'type': 'stop'}), 202);
        Map<String, Object?> after = const {};
        for (var i = 0; i < 200; i++) {
          after = await getState();
          if (after['busy'] == false && after['done'] == true) break;
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(after['busy'], false, reason: 'the stopped run settled');
        expect(after['queue'] as List, isEmpty, reason: 'stop drains the queue — no phantom entries');
        final slow = testIn(after, 'slow gate');
        expect(slow['status'], 'passed', reason: 'the in-flight test always finishes');
        expect(slow['finishedAt'], isNot(testIn(before, 'slow gate')['finishedAt']), reason: 'it really re-ran');
        final fast = testIn(after, 'fast follower');
        expect(fast['status'], 'passed', reason: 'the unreached test keeps its prior verdict, not phantom queued');
        expect(
          fast['finishedAt'],
          testIn(before, 'fast follower')['finishedAt'],
          reason: 'the unreached test was never touched',
        );
        expect((after['summary'] as Map)['passed'], 2, reason: 'the summary still counts the preserved verdict');

        // A reseed without an explicit seed is rejected, not silently seed 0.
        expect(await action({'type': 'reseed'}), 409);

        // The action surface refuses requests that don't look like this
        // page's own: a cross-site Origin (a drive-by form/fetch always
        // carries one) or a non-JSON content type is 403, before any action
        // logic runs. curl-style requests (no Origin, JSON type) stay welcome.
        Future<int> post({String? origin, ContentType? type}) async {
          final req = await client.postUrl(Uri.parse('http://localhost:$p/action'));
          if (type != null) req.headers.contentType = type;
          if (origin != null) req.headers.set('Origin', origin);
          req.write(jsonEncode({'type': 'stop'}));
          final res = await req.close();
          await res.drain<void>();
          return res.statusCode;
        }

        expect(
          await post(origin: 'https://evil.example', type: ContentType.json),
          403,
          reason: 'a cross-origin browser request must never actuate the bench',
        );
        expect(await post(type: ContentType.text), 403, reason: 'a no-preflight text/plain post is rejected');
        expect(
          await post(origin: 'http://localhost:$p', type: ContentType.json),
          202,
          reason: 'the page itself (same-host origin) stays welcome',
        );
        client.close(force: true);
      } finally {
        process.kill();
        await process.exitCode;
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('a non-interactive viewer is read-only: POST /action answers 503', () async {
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
      final req = await client.postUrl(Uri.parse('http://localhost:$p/action'));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({'type': 'stop'}));
      final res = await req.close();
      expect(res.statusCode, 503, reason: 'without --interactive/--keep-open no action is wired at all');
      await res.drain<void>();
      client.close(force: true);
    } finally {
      process.kill();
      await process.exitCode;
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('report identity: per-test hash, setupHash, context + contextHash, all deterministic', () {
    final hex40 = matches(RegExp(r'^[0-9a-f]{40}$'));
    final (exit1, _, r1) = _runWithReport(
      'test/fixtures/green_e2e.dart',
      defines: ['-Dlabwright.seed=0'],
      identity: true,
    );
    final (exit2, _, r2) = _runWithReport(
      'test/fixtures/green_e2e.dart',
      defines: ['-Dlabwright.seed=0'],
      identity: true,
    );
    expect(exit1, 0);
    expect(exit2, 0);
    expect(r1['setupHash'], hex40);
    expect(r1['context'], {'dut.serial': 'SIM-001'}, reason: 'the bench-declared context lands in the report');
    expect(r1['contextHash'], hex40);
    final hashes1 = {for (final t in _tests(r1)) t['name']: t['hash']};
    expect(hashes1.values, everyElement(hex40), reason: 'every test carries a content hash');
    expect(hashes1.values.toSet(), hasLength(3), reason: 'distinct tests hash distinctly');
    // Identity is deterministic: unchanged sources produce identical hashes.
    expect(r2['setupHash'], r1['setupHash']);
    expect(r2['contextHash'], r1['contextHash']);
    expect({for (final t in _tests(r2)) t['name']: t['hash']}, hashes1);
  });

  test(
    'hot reload re-runs only modified tests; hashes factor test bodies out of setup',
    () async {
      final dir = Directory('$pkgRoot/.hot_tmp')..createSync(recursive: true);
      final suite = File('${dir.path}/suite.dart');
      String src({required String alpha, required String helper}) =>
          "import 'package:labwright/labwright.dart';\n"
          "String helper() => '$helper';\n"
          'void main() {\n'
          "  test('alpha', () async { log('$alpha'); });\n"
          "  test('beta', () async { log(helper()); });\n"
          '}\n';
      suite.writeAsStringSync(src(alpha: 'A1', helper: 'H1'));
      Process? process;
      try {
        process = await Process.start(Platform.resolvedExecutable, [
          'run',
          '--enable-vm-service=0',
          '-Dlabwright.port=0',
          '-Dlabwright.interactive=true',
          '-Dlabwright.seed=0',
          '.hot_tmp/suite.dart',
        ], workingDirectory: pkgRoot);
        final port = Completer<int>();
        final ready = Completer<void>();
        final consoleLines = <String>[];
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
          consoleLines.add(line);
          final m = RegExp(r'viewer on http://localhost:(\d+)').firstMatch(line);
          if (m != null && !port.isCompleted) port.complete(int.parse(m[1]!));
          if (line.contains('View results and re-run tests at') && !ready.isCompleted) ready.complete();
        });
        final p = await port.future.timeout(const Duration(seconds: 30));
        await ready.future.timeout(const Duration(seconds: 60));
        final client = HttpClient();

        Future<Map<String, Object?>> getJson(String path) async {
          final res = await (await client.getUrl(Uri.parse('http://localhost:$p$path'))).close();
          return (jsonDecode(await res.transform(utf8.decoder).join()) as Map).cast<String, Object?>();
        }

        Future<int> reload() async {
          final req = await client.postUrl(Uri.parse('http://localhost:$p/action'));
          req.headers.contentType = ContentType.json;
          req.write(jsonEncode({'type': 'hotReload'}));
          final res = await req.close();
          expect(res.statusCode, 202);
          final body = (jsonDecode(await res.transform(utf8.decoder).join()) as Map).cast<String, Object?>();
          // Wait for any triggered re-run to settle.
          for (var i = 0; i < 200; i++) {
            if ((await getJson('/state.json'))['busy'] == false) break;
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
          return (body['modified'] as num).toInt();
        }

        Map<String, Object?> testIn(Map<String, Object?> report, String name) =>
            (report['tests'] as List).cast<Map<String, Object?>>().firstWhere((t) => t['name'] == name);

        final r1 = await getJson('/report.json');

        // Edit ONLY alpha's body: alpha is modified, beta and the SETUP are not.
        suite.writeAsStringSync(src(alpha: 'A2', helper: 'H1'));
        expect(await reload(), 1, reason: 'exactly the edited test counts as modified');
        expect(consoleLines, contains('[Labwright]: hot reload - 1 modified test(s)'));
        final r2 = await getJson('/report.json');
        expect(testIn(r2, 'alpha')['hash'], isNot(testIn(r1, 'alpha')['hash']));
        expect(testIn(r2, 'beta')['hash'], testIn(r1, 'beta')['hash']);
        expect(r2['setupHash'], r1['setupHash'], reason: 'test bodies are factored OUT of the setup hash');
        expect(
          testIn(r2, 'beta')['finishedAt'],
          testIn(r1, 'beta')['finishedAt'],
          reason: 'the unmodified test did not re-run',
        );
        expect(
          testIn(r2, 'alpha')['finishedAt'],
          isNot(testIn(r1, 'alpha')['finishedAt']),
          reason: 'the modified test re-ran',
        );

        // Edit the shared helper (outside any test body): setup changed → all.
        suite.writeAsStringSync(src(alpha: 'A2', helper: 'H2'));
        expect(await reload(), 2, reason: 'a setup change conservatively marks every test modified');
        final r3 = await getJson('/report.json');
        expect(r3['setupHash'], isNot(r2['setupHash']));

        // No edit at all: nothing to re-run.
        expect(await reload(), 0, reason: 'an unchanged suite re-runs nothing');
        client.close(force: true);
      } finally {
        process?.kill();
        await process?.exitCode;
        dir.deleteSync(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
