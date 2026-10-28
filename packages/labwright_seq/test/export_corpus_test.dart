@Tags(['corpus'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:labwright_seq/labwright_seq.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

void main() {
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
    final f = File('${corpusSeqDir.path}/seq-corpus/rosetta/OutputVoltage_XML.seq');
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
      final oracle = File('${corpusSeqDir.path}/seq-corpus/rosetta/OutputVoltage_XML.seq');
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
    'project export: every sequence file lowers to a module, analyze is clean, dart run exits green',
    () {
      final projDir = Directory('${corpusSeqDir.path}/seq-corpus/sources/NIVeriStandAdd-Ons__ECU-HIL-Demo');
      expect(projDir.existsSync(), isTrue, reason: 'the ECU-HIL-Demo project must be fetched with the corpus');
      final byPath = <String, SeqFile>{};
      for (final f in projDir.listSync(recursive: true).whereType<File>()) {
        if (!f.path.toLowerCase().endsWith('.seq')) continue;
        final rel = f.path.substring(projDir.path.length + 1).replaceAll(r'\', '/');
        try {
          byPath[rel] = parseSeqFile(f.readAsBytesSync());
        } on FormatException catch (_) {}
      }
      final project = exportSeqProjectToLabwright(byPath);
      expect(project.files.keys, containsAll(['main.dart', 'analysis_options.yaml']));
      final allSource = project.files.values.join('\n');
      final crossCalls = RegExp(r'await [a-z0-9_]+_seq\.\w+\([^;\n]*\);').allMatches(allSource).length;
      expect((byPath.length, project.files.length, crossCalls), (16, 18, 0));

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
        expect(run.exitCode, 0, reason: 'fresh project export must run green:\n${run.stdout}\n${run.stderr}');
        expect(run.stdout.toString(), contains('0 failed, 0 errors,'));
      } finally {
        genDir.deleteSync(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );

  test(
    'tree export: every source tree lowers to a package with its VIs beside the sequences, '
    'the packages analyze clean, and the measures hold',
    () {
      final sources = Directory('${corpusSeqDir.path}/seq-corpus/sources');
      final trees = [
        ...sources.listSync().whereType<Directory>(),
        Directory('${corpusSeqDir.path}/seq-corpus/rosetta'),
      ]..sort((a, b) => a.path.compareTo(b.path));
      final out = Directory.systemTemp.createTempSync('seq_tree_export_');
      try {
        final stopwatch = Stopwatch()..start();
        var sequenceFiles = 0, unparsed = 0, labViewSteps = 0, lowered = 0, stubbed = 0, withoutDiagram = 0;
        var viFunctions = 0, viLowered = 0, viStubbed = 0, declarations = 0, files = 0;
        final unlocated = <String, int>{};
        final refusals = <String, int>{};
        final seq = SeqExportStats();
        for (final tree in trees) {
          final name = tree.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
          final target = Directory('${out.path}/$name');
          final export = exportSeqTree(
            tree,
            packageName: seqSnakeCase(name),
            pathDependencies: {
              for (final package in const ['labwright', 'labwright_lv_runtime'])
                package: seqRelativeDirectory(from: target.path, to: '${pkgRoot.path}/packages/$package'),
            },
          );
          export.write(target);
          final m = export.measures;
          files += export.files.length;
          sequenceFiles += m.sequenceFiles;
          unparsed += m.unparsedSequenceFiles;
          labViewSteps += m.labViewSteps;
          lowered += m.stepsLowered;
          stubbed += m.stepsStubbed;
          withoutDiagram += m.stepsWithoutDiagram;
          m.stepsUnlocated.forEach((kind, n) => unlocated[kind.name] = (unlocated[kind.name] ?? 0) + n);
          viFunctions += m.viFunctions;
          viLowered += m.viLowered;
          viStubbed += m.viStubbed;
          m.refusalsByKind.forEach((kind, n) => refusals[kind] = (refusals[kind] ?? 0) + n);
          declarations += m.declarations;
          seq
            ..viCallSites += m.seq.viCallSites
            ..viCallSitesStubbed += m.seq.viCallSitesStubbed
            ..viCallSitesUnboundInputs += m.seq.viCallSitesUnboundInputs
            ..viArgsTranslated += m.seq.viArgsTranslated
            ..viArgsEvalFallback += m.seq.viArgsEvalFallback
            ..viOutputsBound += m.seq.viOutputsBound
            ..viOutputsUnbound += m.seq.viOutputsUnbound
            ..viParametersNotTaken += m.seq.viParametersNotTaken;
        }
        print(
          'tree export: ${trees.length} trees · $files files · ${stopwatch.elapsed} · '
          '$sequenceFiles sequence files ($unparsed not parsed) · $labViewSteps LabVIEW steps: '
          '$lowered lowered · $stubbed refused · $withoutDiagram without diagram · unlocated $unlocated · '
          'VIs: $viFunctions emitted · $viLowered lowered · $viStubbed refused $refusals · '
          '$declarations declarations · call sites: ${seq.viCallSites} · ${seq.viCallSitesUnboundInputs} with '
          'inputs the step leaves unwired · args ${seq.viArgsTranslated} translated / '
          '${seq.viArgsEvalFallback} eval · outputs ${seq.viOutputsBound} bound / ${seq.viOutputsUnbound} unbound · '
          '${seq.viParametersNotTaken} parameters not taken',
        );
        _writePackageConfig(out);
        final analyze = Process.runSync('dart', ['analyze', out.path]);
        expect(analyze.exitCode, 0, reason: 'exported trees must analyze clean:\n${analyze.stdout}');
        expect(
          (
            sequenceFiles: sequenceFiles,
            unparsed: unparsed,
            labViewSteps: labViewSteps,
            lowered: lowered,
            stubbed: stubbed,
            withoutDiagram: withoutDiagram,
            unlocated: [for (final kind in unlocated.keys.toList()..sort()) '$kind ${unlocated[kind]}'].join(', '),
            viFunctions: viFunctions,
            viLowered: viLowered,
            viStubbed: viStubbed,
            declarations: declarations,
            callSites: seq.viCallSites,
            unwiredInputs: seq.viCallSitesUnboundInputs,
            argsTranslated: seq.viArgsTranslated,
            argsEval: seq.viArgsEvalFallback,
            outputsBound: seq.viOutputsBound,
            outputsUnbound: seq.viOutputsUnbound,
            notTaken: seq.viParametersNotTaken,
          ),
          kSeqTreeExportMeasures,
        );
      } finally {
        out.deleteSync(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

/// What exporting every corpus source tree yields.
const kSeqTreeExportMeasures = (
  sequenceFiles: 45,
  unparsed: 0,
  labViewSteps: 89,
  lowered: 15,
  stubbed: 72,
  withoutDiagram: 0,
  unlocated: 'project 2',
  viFunctions: 110,
  viLowered: 29,
  viStubbed: 81,
  declarations: 31,
  callSites: 87,
  unwiredInputs: 61,
  argsTranslated: 36,
  argsEval: 9,
  outputsBound: 3,
  outputsUnbound: 2,
  notTaken: 0,
);

/// Resolves the exported packages' imports from this test's own package configuration, so the
/// analyzer runs without a `pub get` in the scratch directory.
void _writePackageConfig(Directory out) {
  final configUri = Isolate.packageConfigSync!;
  final config = jsonDecode(File.fromUri(configUri).readAsStringSync()) as Map<String, dynamic>;
  for (final package in (config['packages']! as List<dynamic>).cast<Map<String, dynamic>>()) {
    package['rootUri'] = configUri.resolve(package['rootUri']! as String).toString();
  }
  Directory('${out.path}/.dart_tool').createSync();
  File('${out.path}/.dart_tool/package_config.json').writeAsStringSync(jsonEncode(config));
  File('${out.path}/pubspec.yaml').writeAsStringSync('name: seq_tree_exports\nenvironment:\n  sdk: ^3.11.0\n');
}
