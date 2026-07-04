@Tags(['corpus'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:labwright_seq/labwright_seq.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

/// Validates the TestStand → labwright E2E exporter
/// ([exportSeqFileToLabwright]) over the real corpus:
///  * every parseable corpus `.seq` exports a balanced program with exactly
///    one `main()`, the prefixed labwright import, and one `lw.sequence` per
///    sequence;
///  * stubs are generated for VI calls ONLY — every other module adapter
///    marks its step `ctx.pending(...)` inline with the target named;
///  * the flagship guarantee: the oracle's generated program actually RUNS
///    under `dart run` (the E2E execution surface — not `dart test`), exits
///    0, and reports its module-bound steps as pending with targets named.
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
    var exported = 0, withViStub = 0, withPending = 0;
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
      expect('Future<void> main() async {'.allMatches(source).length, 1,
          reason: '${f.path}: exactly one generated main');
      expect(
          "import 'package:labwright/labwright.dart' as lw;"
              .allMatches(source)
              .length,
          1,
          reason: '${f.path}: prefixed labwright import');
      expect('lw.sequence('.allMatches(source).length, file.sequences.length,
          reason: '${f.path}: one lw.sequence per sequence');
      // Stub policy: VI calls only. Any UnimplementedError-throwing stub in
      // the program must be a labView stub; other adapters go ctx.pending.
      for (final m in RegExp(r"UnimplementedError\('(\w+) call")
          .allMatches(source)) {
        expect(m.group(1), 'labView',
            reason: '${f.path}: non-VI adapter got a stub');
      }
      if (source.contains("UnimplementedError('labView call")) withViStub++;
      if (source.contains('ctx.pending(')) withPending++;
    }
    expect(exported, greaterThan(300),
        reason: 'XML+INI+binary corpus should all export');
    expect(withViStub, greaterThanOrEqualTo(5),
        reason: 'the corpus has VI-call files; their stubs must be generated');
    expect(withPending, greaterThan(50),
        reason: 'non-VI module calls must surface as pending markers');
    // ignore: avoid_print
    print('labwright export: $exported programs · $withViStub with VI stubs '
        '· $withPending with pending markers');
  });

  test('the oracle program runs under dart run: exit 0, pending named', () {
    final oracle = File('${corpusSeqDir.path}/rosetta/OutputVoltage_XML.seq');
    expect(oracle.existsSync(), isTrue,
        reason: 'the Rosetta oracle must be fetched with the corpus');
    final source = exportSeqFileToLabwright(
        parseSeqFile(oracle.readAsBytesSync()),
        sourceName: 'OutputVoltage_XML.seq');
    // Run from the package root so package:labwright resolves (dev_dep).
    final pkgRoot = corpusSeqDir.parent.parent;
    final genDir = Directory('${pkgRoot.path}/test/.export_gen')
      ..createSync(recursive: true);
    try {
      final genPath = '${genDir.path}/oracle_gen.dart';
      File(genPath).writeAsStringSync(source);
      final result = Process.runSync(
          'dart', ['run', 'test/.export_gen/oracle_gen.dart'],
          workingDirectory: pkgRoot.path,
          environment: {'LABWRIGHT_REPORT': 'jsonl'});
      expect(result.exitCode, 0,
          reason: 'pending-only boilerplate must exit green:\n'
              '${result.stdout}\n${result.stderr}');
      final events = [
        for (final line
            in const LineSplitter().convert(result.stdout.toString()))
          if (line.startsWith('{'))
            (jsonDecode(line) as Map).cast<String, Object?>(),
      ];
      final steps = events.where((e) => e['e'] == 'step').toList();
      expect(steps, isNotEmpty, reason: 'oracle steps must register');
      // The oracle's six steps are all Python module calls — every one is
      // boilerplate pending with its module named; none may fail.
      expect(steps.map((e) => e['status']), everyElement('pending'));
      expect(steps.map((e) => '${e['detail']}').join('\n'),
          contains('python call:'));
      final end = events.lastWhere((e) => e['e'] == 'seq-end');
      expect(end['seq'], 'MainSequence');
      expect(end['status'], 'pending');
    } finally {
      genDir.deleteSync(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
