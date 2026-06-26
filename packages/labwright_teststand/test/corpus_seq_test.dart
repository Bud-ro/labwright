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
    var xml = 0, binary = 0, other = 0, totalSeqs = 0, totalSteps = 0, withAction = 0, withModule = 0, totalLocals = 0, withLimits = 0;
    final failures = <String>[];
    for (final f in seqs) {
      final bytes = f.readAsBytesSync();
      switch (detectSeqFormat(bytes)) {
        case SeqFormat.xml:
          xml++;
          try {
            final sf = parseSeqFile(bytes);
            totalSeqs += sf.sequences.length;
            for (final s in sf.sequences) {
              totalLocals += s.locals.length;
              for (final step in s.steps) {
                totalSteps++;
                if (step.settings.passAction != null) withAction++;
                if (step.module.adapter != SeqAdapter.none &&
                    step.module.adapter != SeqAdapter.unknown) {
                  withModule++;
                }
                if (step.limits != null) withLimits++;
              }
            }
          } catch (e) {
            failures.add('${f.path}: $e');
          }
        case SeqFormat.binary:
          binary++;
          // Decoding isn't implemented yet — it must refuse, not fabricate.
          expect(() => parseSeqFile(bytes), throwsA(isA<UnsupportedError>()));
          // The binary header (file-type + product) IS recoverable.
          final bh = detectSeqHeader(bytes);
          expect(bh.fileType, 'SequenceFile');
          expect(bh.productName, 'TestStand');
        case SeqFormat.ini:
        case SeqFormat.unknown:
          other++;
      }
    }
    printOnFailure('xml=$xml binary=$binary other=$other '
        'sequences=$totalSeqs steps=$totalSteps withAction=$withAction');
    expect(failures, isEmpty, reason: failures.take(5).join('\n'));
    expect(xml, greaterThan(0));
    expect(totalSeqs, greaterThan(0), reason: 'XML lens recovered no sequences');
    expect(totalSteps, greaterThan(0), reason: 'XML lens recovered no steps');
    expect(withAction, greaterThan(0), reason: 'no step settings (PassAct) recovered');
    expect(withModule, greaterThan(0), reason: 'no module-adapter bindings recovered');
    expect(totalLocals, greaterThan(0), reason: 'no sequence locals recovered');
    expect(withLimits, greaterThan(0), reason: 'no test limits recovered');
    // ignore: avoid_print
    print('teststand corpus: $xml XML / $binary binary / $other other · '
        '$totalSeqs sequences · $totalSteps steps · $withAction with pass/fail actions · '
        '$withModule with module bindings · $totalLocals locals · $withLimits limit tests');
  });
}
