import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// The labwright package root, whether the suite runs from the repo root or
/// the package dir (mirrors the corpus_dirs.dart convention).
final String pkgRoot = Directory('packages/labwright').existsSync()
    ? 'packages/labwright'
    : '.';

/// End-to-end tests of the `labwright` runner executable: sequential file
/// execution, aggregation, the JSON report with its requirements trace, CI
/// exit codes, and the live viewer endpoints.
void main() {
  test('runs a directory sequentially, aggregates, writes the report', () {
    final reportFile =
        File('${Directory.systemTemp.createTempSync('lw_').path}/report.json');
    final result = Process.runSync(
        Platform.resolvedExecutable,
        [
          'run',
          'bin/labwright.dart',
          'run',
          'test/fixtures',
          '--port',
          '0',
          '--report',
          reportFile.path,
        ],
        workingDirectory: pkgRoot);
    // red_e2e fails → runner exits non-zero.
    expect(result.exitCode, 1, reason: result.stdout.toString());
    final out = result.stdout.toString();
    expect(out, contains('viewer on http://localhost:'));
    expect(out, contains('green_e2e.dart'));
    expect(out, contains('red_e2e.dart'));
    expect(out,
        contains('6 test(s) — 3 passed, 1 failed, 1 errors, 1 skipped'));

    final report = (jsonDecode(reportFile.readAsStringSync()) as Map)
        .cast<String, Object?>();
    final summary = (report['summary'] as Map).cast<String, Object?>();
    expect(summary['failed'], 1);
    expect(summary['errors'], 1);
    expect(summary['skipped'], 1);
    // The requirements trace: every claimed ID maps to its tests + statuses.
    final requirements =
        (report['requirements'] as Map).cast<String, Object?>();
    expect(requirements.keys,
        containsAll(['REQ-1', 'REQ-2', 'REQ-3', 'REQ-9']));
    final req9 =
        (requirements['REQ-9'] as List).cast<Map<String, Object?>>();
    expect(req9.single['status'], 'failed');
    expect(req9.single['test'], 'trip threshold');
    reportFile.parent.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('viewer serves the page, state.json (with logs), --keep-open persists',
      () async {
    final process = await Process.start(
        Platform.resolvedExecutable,
        [
          'run',
          'bin/labwright.dart',
          'run',
          'test/fixtures/green_e2e.dart',
          '--port',
          '0',
          '--keep-open',
        ],
        workingDirectory: pkgRoot);
    try {
      final port = Completer<int>();
      final done = Completer<void>();
      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        final m = RegExp(r'viewer on http://localhost:(\d+)').firstMatch(line);
        if (m != null && !port.isCompleted) port.complete(int.parse(m[1]!));
        if (line.contains('--keep-open') && !done.isCompleted) {
          done.complete();
        }
      });
      final p = await port.future.timeout(const Duration(seconds: 30));
      await done.future.timeout(const Duration(seconds: 60));

      final client = HttpClient();
      final stateReq =
          await client.getUrl(Uri.parse('http://localhost:$p/state.json'));
      final stateRes = await stateReq.close();
      expect(stateRes.statusCode, 200);
      final state = (jsonDecode(await stateRes.transform(utf8.decoder).join())
              as Map)
          .cast<String, Object?>();
      expect(state['done'], true);
      final files = (state['files'] as List).cast<Map<String, Object?>>();
      final tests =
          (files.single['tests'] as List).cast<Map<String, Object?>>();
      expect(tests, hasLength(3));
      expect(tests.first['name'], 'rail comes up');
      expect(tests.first['status'], 'passed');
      expect(tests.first['logs'], ['applying power'],
          reason: 'logs attach to their test for the viewer');
      expect(tests.last['status'], 'skipped');

      final pageReq = await client.getUrl(Uri.parse('http://localhost:$p/'));
      final pageRes = await pageReq.close();
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
}
