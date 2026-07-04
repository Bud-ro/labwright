@Tags(['corpus'])
library;

import 'dart:io';

import 'package:labwright_seq/labwright_seq.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

/// Validates the TestStand → Dart **test** exporter ([exportSeqFileToDartTest])
/// over the real corpus:
///  * every parseable corpus `.seq` exports a balanced suite with exactly one
///    generated `main()` and one `t.test` per sequence;
///  * the flagship guarantee: the oracle's generated suite actually RUNS under
///    `dart test` and lands green-with-skips — the boilerplate contract is
///    that unimplemented surfaces (module stubs, engine-only expressions)
///    skip with the pending target named, never fail.
///
/// Generated files use no `_test.dart` suffix so a stray file can never join
/// suite discovery; they are run by explicit path only.
void main() {
  if (!corpusSeqDir.existsSync()) {
    test('dart test export (skipped: corpus not fetched)', () {}, skip: true);
    return;
  }

  final seqs = corpusSeqDir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.seq'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  test('every parseable corpus .seq exports a balanced one-main test suite',
      () {
    var exported = 0;
    for (final f in seqs) {
      final SeqFile file;
      try {
        file = parseSeqFile(f.readAsBytesSync());
      } catch (_) {
        continue; // unparseable files are covered by corpus_seq_test
      }
      final source = exportSeqFileToDartTest(file, sourceName: f.path);
      exported++;
      expect('{'.allMatches(source).length, '}'.allMatches(source).length,
          reason: '${f.path}: unbalanced braces');
      expect('void main() {'.allMatches(source).length, 1,
          reason: '${f.path}: exactly one generated main');
      expect("import 'package:test/test.dart' as t;".allMatches(source).length,
          1,
          reason: '${f.path}: prefixed package:test import');
      expect('t.test('.allMatches(source).length, file.sequences.length,
          reason: '${f.path}: one test per sequence');
    }
    expect(exported, greaterThan(300),
        reason: 'XML+INI+binary corpus should all export');
  });

  test('the oracle suite runs under dart test: green with named-stub skips',
      () {
    final oracle = File('${corpusSeqDir.path}/rosetta/OutputVoltage_XML.seq');
    expect(oracle.existsSync(), isTrue,
        reason: 'the Rosetta oracle must be fetched with the corpus');
    final source = exportSeqFileToDartTest(
        parseSeqFile(oracle.readAsBytesSync()),
        sourceName: 'OutputVoltage_XML.seq');
    // Run from the package root so package:test resolves for the generated
    // file. corpusSeqDir is <pkg>/corpus/seq.
    final pkgRoot = corpusSeqDir.parent.parent;
    final genDir = Directory('${pkgRoot.path}/test/.export_gen')
      ..createSync(recursive: true);
    try {
      // No _test suffix: runnable by explicit path, invisible to discovery.
      final genPath = '${genDir.path}/oracle_gen.dart';
      File(genPath).writeAsStringSync(source);
      final result = Process.runSync(
          'dart', ['test', 'test/.export_gen/oracle_gen.dart'],
          workingDirectory: pkgRoot.path);
      expect(result.exitCode, 0,
          reason: 'generated suite must run green:\n'
              '${result.stdout}\n${result.stderr}');
      final out = result.stdout.toString();
      expect(out, contains('All tests skipped.'),
          reason: 'the oracle sequence reaches a module stub and must skip');
      expect(out, contains('pending stub'),
          reason: 'the skip must carry the boilerplate contract wording');
      expect(out, contains('teststand_nidcpower.py'),
          reason: 'the skip must name the pending module target');
    } finally {
      genDir.deleteSync(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
