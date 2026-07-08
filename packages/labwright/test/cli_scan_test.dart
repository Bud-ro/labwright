// `labwright scan`: AST-driven plug-in lint for suite folders.
import 'dart:io';

import 'package:test/test.dart';

import 'harness.dart';

void main() {
  test('scan: names unplugged files and exits 1; clean suite exits 0', () {
    final dirty = cli(['scan', 'test/fixtures/scan_suite']);
    expect(dirty.exitCode, 1, reason: dirty.stdout.toString());
    expect(dirty.stdout.toString(), contains('unplugged.dart'), reason: 'the forgotten file is named');
    expect(
      dirty.stdout.toString(),
      isNot(contains('${Platform.pathSeparator}plugged.dart')),
      reason: 'path-anchored: imported modules are reachable, not flagged',
    );

    final clean = cli(['scan', 'test/fixtures/suite']);
    expect(clean.exitCode, 0, reason: clean.stdout.toString());
    expect(clean.stdout.toString(), contains('plugged into main.dart'));
  });

  test('scan is AST-driven: outside-folder plumbing, exports, renames, '
      'conditional imports, and comment/string decoys', () {
    final result = cli(['scan', 'test/fixtures/tricky_scan']);
    final out = result.stdout.toString();
    expect(result.exitCode, 1, reason: out);
    expect(out, contains('1 file(s) not reachable'), reason: out);
    expect(out, contains('ghost.dart'), reason: 'comment/string mentions are not directives');
    // (reachable file, why it must not be flagged)
    // dart format off
    const plugged = [
      ('via_outside.dart', 'plugged THROUGH a helper outside the scanned folder'),
      ('renamed_symbols.dart', 'reached via an export; renamed test symbols are irrelevant'),
      ('decoy_mentions.dart', 'directly imported by main.dart'),
      ('conditional_io.dart', 'the default branch of a conditional import is plugged'),
      ('conditional_js.dart', 'the non-default branch is part of the program too'),
    ];
    // dart format on
    for (final (file, why) in plugged) {
      expect(out, isNot(contains(file)), reason: why);
    }
  });

  test('the tricky fixture is a real suite: it runs green single-process', () {
    final (exit, out, err) = runSuite('test/fixtures/tricky_scan/main.dart');
    expect(exit, 0, reason: '$out\n$err');
    for (final line in [
      'PASS plugged via an outside helper',
      'PASS renamed test symbol', // lab.test registers like test — aliasing changes nothing
      'PASS tear-off registered test',
      'PASS conditional io branch', // the VM loads the default conditional branch
    ]) {
      expect(out, contains(line));
    }
    expect(
      out,
      contains('[Labwright]: 4 test(s) - 4 passed, 0 failed, 0 errors, 0 skipped'),
      reason: 'the ghost never registered — unplugged means not run',
    );
  });
}
