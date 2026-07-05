@Tags(['corpus'])
library;

import 'dart:io';

import 'package:labwright_seq/labwright_seq.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

/// Validates the TestStand → labwright E2E exporter
/// ([exportSeqFileToLabwright]) over the real corpus:
///  * every parseable corpus `.seq` exports a balanced program with exactly
///    one `main()`, the prefixed labwright import, and one `lw.test`/
///    `lw.skipTest` per ROOT sequence (called sequences are plain functions
///    — some corpus files must exercise that);
///  * stub FUNCTIONS are generated for VI calls only — every other unported
///    surface is an inline `throw UnimplementedError` line;
///  * the flagship guarantee: the oracle's generated program actually RUNS
///    under `dart run` (the E2E execution surface — not `dart test`), ships
///    disarmed as `lw.skipTest` (its module calls are unported), and exits 0.
///
/// Generated files use no `_test.dart` suffix so a stray file can never join
/// unit-suite discovery; E2E programs are run by explicit path.
void main() {
  if (!corpusSeqDir.existsSync()) {
    test('labwright export (skipped: corpus not fetched)', () {}, skip: true);
    return;
  }

  final seqs = corpusSeqDir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.seq'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  test('every parseable corpus .seq exports a balanced labwright program',
      () {
    var exported = 0, withViStub = 0, withInlineThrow = 0, withHelpers = 0;
    final stubAdapter = RegExp(r'/// Stub for the (\w+) module call');
    for (final f in seqs) {
      final SeqFile file;
      try {
        file = parseSeqFile(f.readAsBytesSync());
      } catch (_) {
        continue; // unparseable files are covered by corpus_seq_test
      }
      final source = exportSeqFileToLabwright(file, sourceName: f.path);
      exported++;
      expect('{'.allMatches(source).length, '}'.allMatches(source).length,
          reason: '${f.path}: unbalanced braces');
      expect('void main() {'.allMatches(source).length, 1,
          reason: '${f.path}: exactly one generated main');
      expect(
          "import 'package:labwright/labwright.dart' as lw;"
              .allMatches(source)
              .length,
          1,
          reason: '${f.path}: prefixed labwright import');
      final tests = 'lw.test('.allMatches(source).length +
          'lw.skipTest('.allMatches(source).length;
      if (file.sequences.isNotEmpty) {
        expect(tests, inInclusiveRange(1, file.sequences.length),
            reason: '${f.path}: one test per ROOT sequence');
        if (tests < file.sequences.length) withHelpers++;
      } else {
        expect(tests, 0, reason: '${f.path}: no sequences, no tests');
      }
      // Stub policy: stub FUNCTIONS for VI calls (the port targets) and
      // external sequence calls (plain `await fn();` against a stub the
      // porter implements). DLL/Python/typed-step surfaces stay inline
      // throws, not stubs.
      for (final m in stubAdapter.allMatches(source)) {
        expect(m.group(1), 'labView',
            reason: '${f.path}: non-VI adapter got a module-call stub');
      }
      if (stubAdapter.hasMatch(source)) withViStub++;
      if (source.contains("throw UnimplementedError('")) withInlineThrow++;
    }
    expect(exported, greaterThan(300),
        reason: 'XML+INI+binary corpus should all export');
    expect(withViStub, greaterThanOrEqualTo(5),
        reason: 'the corpus has VI-call files; their stubs must be generated');
    expect(withInlineThrow, greaterThan(50),
        reason: 'non-VI unported surfaces must be inline throws');
    expect(withHelpers, greaterThan(10),
        reason: 'files with called sequences must export them as plain '
            'functions, not tests');
    // ignore: avoid_print
    print('labwright export: $exported programs · $withViStub with VI stubs '
        '· $withInlineThrow with inline throws · $withHelpers with helper '
        'sequences');
  });

  test('the oracle program runs under dart run: disarmed skipTest, exit 0',
      () {
    final oracle = File('${corpusSeqDir.path}/rosetta/OutputVoltage_XML.seq');
    expect(oracle.existsSync(), isTrue,
        reason: 'the Rosetta oracle must be fetched with the corpus');
    final source = exportSeqFileToLabwright(
        parseSeqFile(oracle.readAsBytesSync()),
        sourceName: 'OutputVoltage_XML.seq');
    // Disarmed: the oracle's steps are python/typed — all unported, so the
    // harness ships it as skipTest with the targets in the TODO.
    expect(source, contains('lw.skipTest('));
    expect(source, contains('rename lw.skipTest -> lw.test'));
    expect(source, contains('python call: teststand_nidcpower.py'));
    // Run from the package root so package:labwright resolves (dev_dep).
    final pkgRoot = corpusSeqDir.parent.parent;
    final genDir = Directory('${pkgRoot.path}/test/.export_gen')
      ..createSync(recursive: true);
    try {
      final genPath = '${genDir.path}/oracle_gen.dart';
      File(genPath).writeAsStringSync(source);
      final result = Process.runSync(
          'dart',
          [
            'run',
            '-Dlabwright.viewer=false',
            'test/.export_gen/oracle_gen.dart',
          ],
          workingDirectory: pkgRoot.path);
      expect(result.exitCode, 0,
          reason: 'disarmed boilerplate must exit green:\n'
              '${result.stdout}\n${result.stderr}');
      final out = result.stdout.toString();
      expect(out, contains('○ MainSequence (skipped)'),
          reason: 'unported boilerplate reports skipped, not passed');
      expect(out, contains('1 test(s) — 0 passed, 0 failed, 0 errors, '
          '1 skipped'));
    } finally {
      genDir.deleteSync(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
