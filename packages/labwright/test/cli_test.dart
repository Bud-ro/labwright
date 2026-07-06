import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// The labwright package root, whether the suite runs from the repo root or
/// the package dir (mirrors the corpus_dirs.dart convention).
final String pkgRoot = Directory('packages/labwright').existsSync() ? 'packages/labwright' : '.';

/// Invokes the `labwright` CLI (bin/labwright.dart) with [args].
ProcessResult _cli(List<String> args) => Process.runSync(
  Platform.resolvedExecutable,
  ['run', 'bin/labwright.dart', ...args],
  workingDirectory: pkgRoot,
);

const _allTests = {
  'rail comes up',
  'ripple in limits',
  'thermal camera sweep',
  'trip threshold',
  'still reachable after trip',
  'teardown throws',
};

void main() {
  test('run: a directory resolves to its main.dart; flags become defines;'
      ' the child exit code propagates', () {
    final dir = Directory.systemTemp.createTempSync('lw_');
    try {
      final reportPath = '${dir.path}/report.json';
      final result = _cli([
        'run',
        'test/fixtures/suite',
        '--no-viewer',
        '--report',
        reportPath,
      ]);
      expect(result.exitCode, 1, reason: 'the suite contains failures:\n${result.stdout}');
      final report = (jsonDecode(File(reportPath).readAsStringSync()) as Map).cast<String, Object?>();
      final tests = (report['tests'] as List).cast<Map<String, Object?>>();
      expect(
        tests.map((t) => t['name']).toSet(),
        _allTests,
        reason: 'the plugged-in modules registered into ONE process',
      );
      final req9 = ((report['requirements'] as Map)['REQ-9'] as List).cast<Map<String, Object?>>();
      expect(req9.single['status'], 'failed');
    } finally {
      dir.deleteSync(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('run + shards + seed: the shards partition the suite, none missed', () {
    for (final seedArg in ['0', '7']) {
      final executed = <String>[];
      for (var index = 0; index < 2; index++) {
        final dir = Directory.systemTemp.createTempSync('lw_');
        try {
          final reportPath = '${dir.path}/report.json';
          final result = _cli([
            'run',
            'test/fixtures/suite',
            '--no-viewer',
            '--total-shards',
            '2',
            '--shard-index',
            '$index',
            '--seed',
            seedArg,
            '--report',
            reportPath,
          ]);
          expect(
            result.exitCode,
            anyOf(0, 1),
            reason:
                'shard $index seed $seedArg crashed:\n'
                '${result.stdout}\n${result.stderr}',
          );
          final report = (jsonDecode(File(reportPath).readAsStringSync()) as Map).cast<String, Object?>();
          expect(report['seed'], int.parse(seedArg));
          for (final t in (report['tests'] as List).cast<Map<String, Object?>>()) {
            executed.add(t['name'] as String);
          }
        } finally {
          dir.deleteSync(recursive: true);
        }
      }
      expect(executed, hasLength(_allTests.length), reason: 'seed $seedArg: every test exactly once across shards');
      expect(executed.toSet(), _allTests, reason: 'seed $seedArg: union of shards is the whole suite');
    }
  }, timeout: const Timeout(Duration(minutes: 4)));

  test('scan: names unplugged files and exits 1; clean suite exits 0', () {
    final dirty = _cli(['scan', 'test/fixtures/scan_suite']);
    expect(dirty.exitCode, 1, reason: dirty.stdout.toString());
    expect(dirty.stdout.toString(), contains('unplugged.dart'), reason: 'the forgotten file is named');
    // Path-anchored: "unplugged.dart" itself contains "plugged.dart".
    expect(
      dirty.stdout.toString(),
      isNot(contains('${Platform.pathSeparator}plugged.dart')),
      reason: 'imported modules are reachable, not flagged',
    );

    final clean = _cli(['scan', 'test/fixtures/suite']);
    expect(clean.exitCode, 0, reason: clean.stdout.toString());
    expect(clean.stdout.toString(), contains('plugged into main.dart'));
  });

  test('scan is AST-driven: outside-folder plumbing, exports, renames, '
      'conditional imports, and comment/string decoys', () {
    final result = _cli(['scan', 'test/fixtures/tricky_scan']);
    final out = result.stdout.toString();
    // The ONE genuinely unplugged file is flagged...
    expect(result.exitCode, 1, reason: out);
    expect(out, contains('1 file(s) not reachable'), reason: out);
    expect(
      out,
      contains('ghost.dart'),
      reason:
          'mentions of ghost.dart in comments and string literals are '
          'not directives — a text-match walk would have missed it',
    );
    // ...and none of the tricky-but-plugged ones are:
    expect(out, isNot(contains('via_outside.dart')), reason: 'plugged THROUGH a helper outside the scanned folder');
    expect(
      out,
      isNot(contains('renamed_symbols.dart')),
      reason: 'reached via an export; renamed test symbols are irrelevant',
    );
    expect(out, isNot(contains('decoy_mentions.dart')), reason: 'directly imported by main.dart');
    expect(
      out,
      isNot(contains('conditional_io.dart')),
      reason: 'the default branch of a conditional import is plugged',
    );
    expect(out, isNot(contains('conditional_js.dart')), reason: 'the non-default branch is part of the program too');
  });

  test('the tricky fixture is a real suite: it runs green single-process', () {
    final result = Process.runSync(
      Platform.resolvedExecutable,
      ['run', '-Dlabwright.viewer=false', 'test/fixtures/tricky_scan/main.dart'],
      workingDirectory: pkgRoot,
    );
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    final out = result.stdout.toString();
    expect(out, contains('PASS plugged via an outside helper'));
    expect(
      out,
      contains('PASS renamed test symbol'),
      reason: 'lab.test registers like test — aliasing changes nothing',
    );
    expect(out, contains('PASS tear-off registered test'));
    expect(out, contains('PASS conditional io branch'), reason: 'the VM loads the default conditional branch');
    expect(
      out,
      contains(
        '[Labwright]: 4 test(s) - 4 passed, 0 failed, 0 errors, '
        '0 skipped',
      ),
      reason: 'the ghost never registered — unplugged means not run',
    );
  });

  test('init: generates the example suite; it runs green; refuses overwrite', () {
    const dir = '.init_tmp/e2e';
    final abs = Directory('$pkgRoot/.init_tmp');
    try {
      final created = _cli(['init', dir]);
      expect(created.exitCode, 0, reason: created.stderr.toString());
      expect(File('$pkgRoot/$dir/main.dart').existsSync(), isTrue);
      expect(File('$pkgRoot/$dir/power_rail_test.dart').existsSync(), isTrue);

      // The generated example is a real green suite in this package context.
      final run = Process.runSync(
        Platform.resolvedExecutable,
        ['run', '-Dlabwright.viewer=false', '$dir/main.dart'],
        workingDirectory: pkgRoot,
      );
      expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
      expect(run.stdout.toString(), contains('PASS rail comes up'));

      // And the generated suite passes its own plug-in lint.
      expect(_cli(['scan', dir]).exitCode, 0);

      final again = _cli(['init', dir]);
      expect(again.exitCode, 64, reason: 'must refuse to overwrite');
      expect(again.stderr.toString(), contains('already exists'));
    } finally {
      if (abs.existsSync()) abs.deleteSync(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
