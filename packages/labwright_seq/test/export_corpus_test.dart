@Tags(['corpus'])
library;

import 'dart:io';

import 'package:labwright_seq/labwright_seq.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';
import 'snapshot_check.dart';

void main() {
  if (!corpusSeqDir.existsSync()) {
    test('exporters (skipped: corpus not fetched)', () {}, skip: true);
    return;
  }

  final seqs = corpusSeqDir.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.seq')).toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  final pkgRoot = corpusSeqDir.parent.parent;

  test('every parseable corpus .seq exports balanced Dart AND labwright programs; '
      'every Dart export passes dart analyze (one batch run)', () {
    var exported = 0, withViStub = 0, withInlineThrow = 0, withHelpers = 0;
    var withIntLocals = 0, withSkipComments = 0;
    final stats = SeqExportStats();
    final stubAdapter = RegExp(r'/// Stub for the (\w+) module call');
    final genDir = Directory('${pkgRoot.path}/test/.export_gen_batch')..createSync(recursive: true);
    try {
      File(
        '${genDir.path}/analysis_options.yaml',
      ).writeAsStringSync('analyzer:\n  language:\n    strict-casts: false\n');
      for (final f in seqs) {
        final SeqFile file;
        try {
          file = parseSeqFile(f.readAsBytesSync());
        } catch (_) {
          continue;
        }

        final dartSource = exportSeqFileToDart(file, sourceName: f.path);
        expect(dartSource, isNotEmpty, reason: f.path);
        expect(
          '{'.allMatches(dartSource).length,
          '}'.allMatches(dartSource).length,
          reason: '${f.path}: unbalanced braces',
        );
        File('${genDir.path}/gen_$exported.dart').writeAsStringSync(dartSource);

        final source = exportSeqFileToLabwright(file, sourceName: f.path, stats: stats);
        exported++;
        expect(source, isNot(contains('(call parameters not exported yet)')), reason: f.path);
        expect('{'.allMatches(source).length, '}'.allMatches(source).length, reason: '${f.path}: unbalanced braces');
        expect('void main() {'.allMatches(source).length, 1, reason: '${f.path}: exactly one generated main');
        expect(
          "import 'package:labwright/labwright.dart' as lw;".allMatches(source).length,
          file.sequences.isEmpty ? 0 : 1,
          reason: '${f.path}: prefixed labwright import',
        );
        final tests = 'lw.test('.allMatches(source).length + 'lw.skipTest('.allMatches(source).length;
        if (file.sequences.isNotEmpty) {
          expect(tests, inInclusiveRange(1, file.sequences.length), reason: '${f.path}: one test per ROOT sequence');
          if (tests < file.sequences.length) withHelpers++;
        } else {
          expect(tests, 0, reason: '${f.path}: no sequences, no tests');
        }
        for (final m in stubAdapter.allMatches(source)) {
          expect(m.group(1), 'labView', reason: '${f.path}: non-VI adapter got a module-call stub');
        }
        if (stubAdapter.hasMatch(source)) withViStub++;
        if (source.contains("throw UnimplementedError('")) withInlineThrow++;
        if (RegExp(r'\bint \w+ = ').hasMatch(source)) withIntLocals++;
        if (source.contains('[skipped in source]')) withSkipComments++;
        expect(
          source,
          isNot(contains('break; // Break On Terminate')),
          reason: '${f.path}: a skipped/type-gated break emitted bare',
        );
      }

      expectCorpusSnapshot('export', {
        'exported': exported,
        'withViStub': withViStub,
        'withInlineThrow': withInlineThrow,
        'withHelpers': withHelpers,
        'withIntLocals': withIntLocals,
        'withSkipComments': withSkipComments,
        'callSites': stats.callSites,
        'boundSites': stats.boundSites,
        'localBoundSites': stats.localBoundSites,
        'localBoundSitesRearmed': stats.localBoundSitesRearmed,
        'argsTranslated': stats.argsTranslated,
        'argsByOmission': stats.argsByOmission,
        'argsEvalFallback': stats.argsEvalFallback,
        'payloadNotes': stats.payloadNotes,
        'wiredArgs': stats.wiredArgs,
        for (final e in stats.siteDisarms.entries) 'siteDisarms:${e.key}': e.value,
      });
      print(
        'exports: $exported programs · $withViStub VI stubs · $withInlineThrow inline throws · '
        '$withHelpers helper sequences · $withIntLocals int locals · $withSkipComments skip comments · '
        'call params: ${stats.callSites} sites · ${stats.boundSites} bound · '
        '${stats.localBoundSites} local bound · ${stats.localBoundSitesRearmed} re-armed · '
        '${stats.argsTranslated} args translated · ${stats.argsByOmission} by omission · '
        '${stats.argsEvalFallback} eval-fallback · site disarms: ${stats.siteDisarms} · '
        '${stats.payloadNotes} payload notes · ${stats.wiredArgs} wired args',
      );

      final result = Process.runSync('dart', ['analyze', 'test/.export_gen_batch'], workingDirectory: pkgRoot.path);
      expect(result.exitCode, 0, reason: 'all generated exports must analyze clean:\n${result.stdout}');
    } finally {
      genDir.deleteSync(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('the Rosetta oracle Dart export carries sequences, steps, and stubs', () {
    final f = File('${corpusSeqDir.path}/rosetta/OutputVoltage_XML.seq');
    expect(f.existsSync(), isTrue, reason: 'the Rosetta oracle must be fetched with the corpus');
    final file = parseSeqFile(f.readAsBytesSync());
    final source = exportSeqFileToDart(file);
    expect(source, contains('Future<void> mainSequence('));
    for (final seq in file.sequences) {
      for (final step in seq.steps) {
        expect(source, contains(step.name), reason: 'step must appear as code or ordered comment');
      }
    }
    expect(source, contains('UnimplementedError'), reason: 'code-module stubs must be present');
    expect(source, isNot(contains('class TsRuntime')));
    expect(source, contains("import 'package:labwright/shims.dart' as ts;"));
    expect(source, isNot(contains('_eval(')), reason: 'no underscore-prefixed generated helpers remain');
  });

  test(
    'the oracle labwright program runs under dart run: disarmed skipTest, exit 0',
    () {
      final oracle = File('${corpusSeqDir.path}/rosetta/OutputVoltage_XML.seq');
      expect(oracle.existsSync(), isTrue, reason: 'the Rosetta oracle must be fetched with the corpus');
      final source = exportSeqFileToLabwright(
        parseSeqFile(oracle.readAsBytesSync()),
        sourceName: 'OutputVoltage_XML.seq',
      );
      expect(source, contains('lw.skipTest('));
      expect(source, contains('rename lw.skipTest -> lw.test'));
      expect(source, contains('python call: teststand_nidcpower.py'));
      final genDir = Directory('${pkgRoot.path}/test/.export_gen')..createSync(recursive: true);
      try {
        File('${genDir.path}/oracle_gen.dart').writeAsStringSync(source);
        final result = Process.runSync('dart', [
          'run',
          '-Dlabwright.viewer=false',
          'test/.export_gen/oracle_gen.dart',
        ], workingDirectory: pkgRoot.path);
        expect(result.exitCode, 0, reason: 'disarmed boilerplate must exit green:\n${result.stdout}\n${result.stderr}');
        final out = result.stdout.toString();
        expect(out, contains('SKIP MainSequence'), reason: 'unported boilerplate reports skipped, not passed');
        expect(out, contains('1 test(s) - 0 passed, 0 failed, 0 errors, 1 skipped'));
      } finally {
        genDir.deleteSync(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'project export: cross-module calls bind, analyze is clean, dart run exits green',
    () {
      final projDir = Directory(
        '${corpusSeqDir.path}/michael-harhay-arx_CICDUtility/michael-harhay-arx-CICDUtility-02c6c67',
      );
      expect(projDir.existsSync(), isTrue, reason: 'the CICDUtility project must be fetched with the corpus');
      final byPath = <String, SeqFile>{};
      for (final f in projDir.listSync(recursive: true).whereType<File>()) {
        if (!f.path.toLowerCase().endsWith('.seq')) continue;
        final rel = f.path.substring(projDir.path.length + 1).replaceAll(r'\', '/');
        try {
          byPath[rel] = parseSeqFile(f.readAsBytesSync());
        } on FormatException catch (_) {}
      }
      final project = exportSeqProjectToLabwright(byPath);
      expect(project.files.length, byPath.length + 3, reason: 'one module per input + runtime + main + options');
      expect(project.files.keys, containsAll(['main.dart', 'lw_runtime.dart', 'analysis_options.yaml']));
      final allSource = project.files.values.join('\n');
      final crossCalls = RegExp(r'await [a-z0-9_]+_seq\.\w+\([^;\n]*\);').allMatches(allSource).length;
      final crossCallsWithArgs = RegExp(r'await [a-z0-9_]+_seq\.\w+\([^;\n)][^;\n]*\);').allMatches(allSource).length;
      expectCorpusSnapshot('export_project', {
        'modules': byPath.length,
        'crossCalls': crossCalls,
        'crossCallsWithArgs': crossCallsWithArgs,
      });

      final genDir = Directory('${pkgRoot.path}/test/.export_gen_proj')..createSync(recursive: true);
      try {
        project.files.forEach((name, source) => File('${genDir.path}/$name').writeAsStringSync(source));
        final analyze = Process.runSync('dart', ['analyze', 'test/.export_gen_proj'], workingDirectory: pkgRoot.path);
        expect(analyze.exitCode, 0, reason: 'generated project must analyze clean:\n${analyze.stdout}');
        final run = Process.runSync('dart', [
          'run',
          '-Dlabwright.viewer=false',
          'test/.export_gen_proj/main.dart',
        ], workingDirectory: pkgRoot.path);
        expect(
          run.exitCode,
          0,
          reason:
              'fresh project export must run green (armed tests are fully translated):\n${run.stdout}\n${run.stderr}',
        );
        expect(run.stdout.toString(), contains('0 failed, 0 errors,'));
      } finally {
        genDir.deleteSync(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
