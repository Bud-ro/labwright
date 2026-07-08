@Tags(['corpus'])
library;

import 'dart:io';

import 'package:labwright_seq/labwright_seq.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

/// Validates the TestStand → Dart exporter over the real corpus:
///  * every parseable corpus `.seq` exports without throwing, non-empty, with
///    balanced braces;
///  * the content-exact Rosetta twin's export carries its sequence function,
///    every step (as code or ordered comment), and stubs for its code modules;
///  * the flagship guarantee: a generated file passes `dart analyze` with zero
///    issues (checked by actually running the analyzer on the two shape
///    extremes — the minimal oracle and the most flow-control-heavy file).
void main() {
  if (!corpusSeqDir.existsSync()) {
    test('dart export (skipped: corpus not fetched)', () {}, skip: true);
    return;
  }

  final seqs = corpusSeqDir.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.seq')).toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  test('every parseable corpus .seq exports to balanced, non-empty Dart', () {
    var exported = 0;
    var flowHeaviest = 0;
    File? flowHeaviestFile;
    for (final f in seqs) {
      final SeqFile file;
      try {
        file = parseSeqFile(f.readAsBytesSync());
      } catch (_) {
        continue; // unparseable files are covered by corpus_seq_test
      }
      final source = exportSeqFileToDart(file, sourceName: f.path);
      exported++;
      expect(source, isNotEmpty, reason: f.path);
      final opens = '{'.allMatches(source).length;
      final closes = '}'.allMatches(source).length;
      expect(opens, closes, reason: '${f.path}: unbalanced braces');
      var flow = 0;
      for (final seq in file.sequences) {
        for (final step in seq.steps) {
          if (step.flowControl != null) flow++;
        }
      }
      if (flow > flowHeaviest) {
        flowHeaviest = flow;
        flowHeaviestFile = f;
      }
    }
    expect(exported, greaterThan(240), reason: 'XML+INI+binary corpus should all export');
    // ignore: avoid_print
    print(
      'exported $exported files; most flow steps: $flowHeaviest '
      '(${flowHeaviestFile?.uri.pathSegments.last})',
    );
  });

  test('the Rosetta oracle export carries sequences, steps, and stubs', () {
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
    // No per-file runtime: engine state is top-level, the built-in
    // helpers are hosted (package:labwright/shims.dart, imported as ts),
    // and untranslated expressions land in the ts.eval fallback.
    expect(source, isNot(contains('class TsRuntime')));
    expect(source, contains("import 'package:labwright/shims.dart' as ts;"));
    expect(source, isNot(contains('_eval(')), reason: 'no underscore-prefixed generated helpers remain');
  });

  test('EVERY parseable corpus export passes dart analyze (one batch run)', () {
    // The whole-corpus compile gate: the review fleet found 14/388 exports
    // failing analyze while the old two-file gate stayed green. All plain
    // exports land in one dir and one analyzer invocation checks them all
    // — the generator's type choices must never reject its own output.
    // In-package (not systemTemp) so package:labwright/shims.dart
    // resolves; its own analysis options mirror what a generated project
    // ships (dynamic engine state by design → strict-casts off).
    final pkgRoot = corpusSeqDir.parent.parent;
    final dir = Directory('${pkgRoot.path}/test/.export_gen_batch')..createSync(recursive: true);
    try {
      File('${dir.path}/analysis_options.yaml').writeAsStringSync('analyzer:\n  language:\n    strict-casts: false\n');
      var n = 0; // ignore: prefer_final_locals
      for (final f in seqs) {
        final SeqFile file;
        try {
          file = parseSeqFile(f.readAsBytesSync());
        } catch (_) {
          continue;
        }
        final out = File('${dir.path}/gen_${n++}.dart');
        out.writeAsStringSync(exportSeqFileToDart(file, sourceName: f.uri.pathSegments.last));
      }
      expect(n, greaterThan(240));
      final result = Process.runSync('dart', ['analyze', 'test/.export_gen_batch'], workingDirectory: pkgRoot.path);
      expect(
        result.exitCode,
        0,
        reason:
            'all generated exports must analyze clean:\n'
            '${result.stdout}',
      );
    } finally {
      dir.deleteSync(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  // (The former oracle + flow-heaviest two-file analyze gate is subsumed
  // by the whole-corpus batch gate above — same export mode, same
  // analyzer, every parseable file.)
}
