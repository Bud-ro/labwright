import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_teststand/labwright_teststand.dart';
import 'package:labwright_teststand_inspector/src/document_view.dart';
import 'package:labwright_teststand_inspector/src/property_outline.dart';
import 'package:labwright_teststand_inspector/src/sequence_outline.dart';

/// Resolves the gitignored TestStand corpus (`<repoRoot>/corpus/seq/`) by
/// walking up to the directory holding `corpus/seq-sources.json`, so it works
/// regardless of the test runner's CWD. Mirrors the package's corpus_dirs.dart.
Directory _corpusSeqDir() {
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    if (File('${dir.path}/corpus/seq-sources.json').existsSync()) {
      return Directory('${dir.path}/corpus/seq');
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return Directory('corpus/seq');
}

/// End-to-end smoke test: drive every real `.seq` through the same path the app
/// uses (SeqDocument.parse → the view helpers) and assert nothing throws and the
/// variant is sane. Self-skips when the corpus is absent so the default
/// `flutter test` stays green without it.
void main() {
  final corpus = _corpusSeqDir();
  if (!corpus.existsSync()) {
    test('teststand corpus smoke', () {},
        skip: 'corpus absent — run tool/fetch_seq_corpus.dart');
    return;
  }

  final seqs = corpus
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.toLowerCase().endsWith('.seq'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  test('corpus has .seq files', () => expect(seqs, isNotEmpty));

  test('every .seq parses into a sane document and renders through the app helpers',
      () {
    var xml = 0, binary = 0, other = 0;
    final failures = <String>[];
    for (final f in seqs) {
      final bytes = f.readAsBytesSync();
      try {
        final doc = SeqDocument.parse(bytes);
        switch (doc) {
          case XmlSeqDocument(:final file):
            xml++;
            expect(doc.header.format, SeqFormat.xml, reason: f.path);
            // Every view helper the app calls must run and produce output.
            expect(documentText(doc), isNotEmpty, reason: f.path);
            expect(documentTitle(doc), isNotEmpty, reason: f.path);
            expect(coverageLabel(measureCoverage(file)), isNotEmpty,
                reason: f.path);
            SeqOutline.of(file); // shapes without throwing
            final root = propertyTree(file);
            expect(root.name, isNotEmpty, reason: f.path);
          case BinarySeqDocument():
            binary++;
            expect(doc.header.format, SeqFormat.binary, reason: f.path);
            // The recon facts helper must run on every binary file.
            expect(binaryHeaderRows(doc), isNotEmpty, reason: f.path);
          case UnknownSeqDocument():
            other++;
        }
      } catch (e) {
        failures.add('${f.path}: $e');
      }
    }
    // ignore: avoid_print
    print('corpus smoke: ${seqs.length} files — '
        '$xml xml, $binary binary, $other other; ${failures.length} failures');
    expect(failures, isEmpty, reason: failures.join('\n'));
  });
}
