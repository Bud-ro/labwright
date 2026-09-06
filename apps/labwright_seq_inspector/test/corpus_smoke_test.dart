import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_seq/labwright_seq.dart';
import 'package:labwright_seq_inspector/src/document_view.dart';
import 'package:labwright_seq_inspector/src/property_outline.dart';
import 'package:labwright_seq_inspector/src/sequence_outline.dart';

Directory _corpusSeqDir() {
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    if (File(
      '${dir.path}/packages/labwright_seq/corpus/seq-sources.json',
    ).existsSync()) {
      return Directory('${dir.path}/packages/labwright_seq/corpus/seq');
    }
    if (File('${dir.path}/corpus/seq-sources.json').existsSync()) {
      return Directory('${dir.path}/corpus/seq');
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return Directory('corpus/seq');
}

void main() {
  final corpus = _corpusSeqDir();
  if (!corpus.existsSync()) {
    test(
      'teststand corpus smoke',
      () {},
      skip: 'corpus absent — run tool/fetch_seq_corpus.dart',
    );
    return;
  }

  final seqs =
      corpus
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.seq'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  test('corpus has .seq files', () => expect(seqs, isNotEmpty));

  test('every .seq parses and renders through the app helpers', () {
    var structured = 0, binary = 0, other = 0, partialTyped = 0;
    final failures = <String>[];
    for (final f in seqs) {
      try {
        final doc = SeqDocument.parse(f.readAsBytesSync());
        switch (doc) {
          case StructuredSeqDocument(:final file):
            structured++;
            expect(
              doc.header.format == SeqFormat.xml ||
                  doc.header.format == SeqFormat.ini,
              isTrue,
              reason: f.path,
            );
            expect(documentText(doc), isNotEmpty, reason: f.path);
            expect(documentTitle(doc), isNotEmpty, reason: f.path);
            expect(
              coverageLabel(measureCoverage(file)),
              isNotEmpty,
              reason: f.path,
            );
            SeqOutline.of(file);
            expect(propertyTree(file).name, isNotEmpty, reason: f.path);
          case BinarySeqDocument():
            binary++;
            expect(doc.header.format, SeqFormat.binary, reason: f.path);
            expect(binaryHeaderRows(doc), isNotEmpty, reason: f.path);
            final partial = doc.partialFile;
            if (partial != null) {
              partialTyped++;
              SeqOutline.of(partial);
              expect(propertyTree(partial).name, isNotEmpty, reason: f.path);
              for (final seq in partial.sequences) {
                expect(seq.name, isNotEmpty, reason: f.path);
              }
            }
          case UnknownSeqDocument():
            other++;
        }
      } catch (e) {
        failures.add('${f.path}: $e');
      }
    }
    // ignore: avoid_print
    print(
      'corpus smoke: ${seqs.length} files — $structured structured, '
      '$binary binary ($partialTyped typed skeleton), $other other; '
      '${failures.length} failures',
    );
    expect(failures, isEmpty, reason: failures.join('\n'));
  });
}
