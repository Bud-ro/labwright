@Tags(['corpus'])
library;

import 'dart:io';
import 'dart:typed_data';

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

  final seqs = corpusSeqDir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.seq'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  test('every parseable corpus .seq exports to balanced, non-empty Dart', () {
    var exported = 0;
    var flowHeaviest = 0;
    File? flowHeaviestFile;
    for (final f in seqs) {
      final SeqFile file;
      try {
        file = parseSeqFile(Uint8List.fromList(f.readAsBytesSync()));
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
    expect(exported, greaterThan(300),
        reason: 'XML+INI+binary corpus should all export');
    // ignore: avoid_print
    print('exported $exported files; most flow steps: $flowHeaviest '
        '(${flowHeaviestFile?.uri.pathSegments.last})');
  });

  test('the Rosetta oracle export carries sequences, steps, and stubs', () {
    final f = File('${corpusSeqDir.path}/rosetta/OutputVoltage_XML.seq');
    if (!f.existsSync()) return;
    final file = parseSeqFile(Uint8List.fromList(f.readAsBytesSync()));
    final source = exportSeqFileToDart(file);
    expect(source, contains('Future<void> mainSequence(TsRuntime ts'));
    for (final seq in file.sequences) {
      for (final step in seq.steps) {
        expect(source, contains(step.name),
            reason: 'step must appear as code or ordered comment');
      }
    }
    expect(source, contains('UnimplementedError'),
        reason: 'code-module stubs must be present');
    expect(source, contains('class TsRuntime'));
  });

  test('generated Dart passes dart analyze (oracle + flow-heaviest file)', () {
    File? flowHeaviestFile;
    var flowHeaviest = -1;
    for (final f in seqs) {
      final SeqFile file;
      try {
        file = parseSeqFile(Uint8List.fromList(f.readAsBytesSync()));
      } catch (_) {
        continue;
      }
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
    final targets = <File>[
      File('${corpusSeqDir.path}/rosetta/OutputVoltage_XML.seq'),
      if (flowHeaviestFile != null) flowHeaviestFile,
    ].where((f) => f.existsSync()).toList();

    final dir = Directory.systemTemp.createTempSync('seq_export_');
    try {
      final generated = <String>[];
      for (final f in targets) {
        final file = parseSeqFile(Uint8List.fromList(f.readAsBytesSync()));
        final out =
            '${dir.path}/${f.uri.pathSegments.last.replaceAll('.seq', '')}.dart';
        File(out).writeAsStringSync(
            exportSeqFileToDart(file, sourceName: f.uri.pathSegments.last));
        generated.add(out);
      }
      final result = Process.runSync('dart', ['analyze', ...generated]);
      expect(result.exitCode, 0,
          reason: 'generated Dart must analyze clean:\n${result.stdout}');
    } finally {
      dir.deleteSync(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
