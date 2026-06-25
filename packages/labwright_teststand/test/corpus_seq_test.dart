@Tags(['corpus'])
library;

import 'dart:io';

import 'package:labwright_teststand/labwright_teststand.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

/// Validates the M1 XML reader against the real fetched corpus: every XML `.seq`
/// must parse without throwing, and the typed lens must recover sequences and
/// steps. Binary `TOF1` files must be honestly classified and refused (not
/// silently mis-parsed). Self-skips when the corpus is absent.
void main() {
  if (!corpusSeqDir.existsSync()) {
    test('teststand corpus', () {}, skip: 'corpus absent — run tool/fetch_seq_corpus.dart');
    return;
  }

  final seqs = corpusSeqDir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.toLowerCase().endsWith('.seq'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  test('corpus has .seq files', () => expect(seqs, isNotEmpty));

  test('every XML .seq parses; binary .seq is classified, not mis-parsed', () {
    var xml = 0, binary = 0, other = 0, totalSeqs = 0, totalSteps = 0;
    final failures = <String>[];
    for (final f in seqs) {
      final bytes = f.readAsBytesSync();
      switch (detectSeqFormat(bytes)) {
        case SeqFormat.xml:
          xml++;
          try {
            final sf = parseSeqFile(bytes);
            totalSeqs += sf.sequences.length;
            totalSteps += sf.sequences.fold(0, (a, s) => a + s.steps.length);
          } catch (e) {
            failures.add('${f.path}: $e');
          }
        case SeqFormat.binary:
          binary++;
          // Decoding isn't implemented yet — it must refuse, not fabricate.
          expect(() => parseSeqFile(bytes), throwsA(isA<UnsupportedError>()));
        case SeqFormat.ini:
        case SeqFormat.unknown:
          other++;
      }
    }
    printOnFailure('xml=$xml binary=$binary other=$other '
        'sequences=$totalSeqs steps=$totalSteps');
    expect(failures, isEmpty, reason: failures.take(5).join('\n'));
    expect(xml, greaterThan(0));
    expect(totalSeqs, greaterThan(0), reason: 'XML lens recovered no sequences');
    expect(totalSteps, greaterThan(0), reason: 'XML lens recovered no steps');
    // ignore: avoid_print
    print('teststand corpus: $xml XML / $binary binary / $other other · '
        '$totalSeqs sequences · $totalSteps steps recovered');
  });
}
