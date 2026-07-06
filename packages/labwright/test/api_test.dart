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
(int, String, String) _run(String file, {List<String> defines = const []}) {
  final result = Process.runSync(
    Platform.resolvedExecutable,
    ['run', _noViewer, ...defines, file],
    workingDirectory: pkgRoot,
  );
  return (result.exitCode, result.stdout.toString(), result.stderr.toString());
}

/// Runs [file] with a report define and returns (exitCode, stdout, report).
(int, String, Map<String, Object?>) _runWithReport(String file, {List<String> defines = const []}) {
  final dir = Directory.systemTemp.createTempSync('lw_');
  try {
    final path = '${dir.path}/report.json';
    final (exit, out, _) = _run(file, defines: ['-Dlabwright.report=$path', ...defines]);
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
      expect(tests.first['logs'], ['applying power'], reason: 'logs attach to their test for the viewer');

      final pageRes = await (await client.getUrl(Uri.parse('http://localhost:$p/'))).close();
      expect(pageRes.statusCode, 200);
      final page = await pageRes.transform(utf8.decoder).join();
      expect(page, contains('labwright run'));
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
      ['run', '-Dlabwright.port=0', '-Dlabwright.interactive=true', 'test/fixtures/green_e2e.dart'],
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
      client.close(force: true);
    } finally {
      process.kill();
      await process.exitCode;
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('open-in-editor + seed replay: source locations, reseed, editor launch', () async {
    final tmp = Directory.systemTemp.createTempSync('lw_');
    // A recorder standing in for the editor (POSIX only — bash script).
    final opened = File('${tmp.path}/opened.txt');
    final rec = File('${tmp.path}/rec.sh')
      ..writeAsStringSync('#!/usr/bin/env bash\nprintf "%s" "\$*" > "${opened.path}"\n');
    final posix = !Platform.isWindows;
    if (posix) Process.runSync('chmod', ['+x', rec.path]);
    try {
      final process = await Process.start(Platform.resolvedExecutable, [
        'run',
        '-Dlabwright.port=0',
        '-Dlabwright.interactive=true',
        '-Dlabwright.seed=0',
        if (posix) '-Dlabwright.editor=${rec.path} {file} {line}',
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
}
