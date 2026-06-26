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
    var xml = 0, binary = 0, other = 0, totalSeqs = 0, totalSteps = 0, withAction = 0, withModule = 0, totalLocals = 0, withLimits = 0, withBinaryBody = 0, resolvedCalls = 0, withMode = 0;
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
                if (step.settings.mode != null) withMode++;
                if (step.module.adapter != SeqAdapter.none &&
                    step.module.adapter != SeqAdapter.unknown) {
                  withModule++;
                }
                if (step.limits != null) withLimits++;
                if (sf.resolveCall(step) != null) resolvedCalls++;
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
          // The zlib body inflates and holds the same PropertyObject model.
          final body = inflateBinaryBody(bytes);
          expect(body, isNotNull, reason: '${f.path}: no inflatable body');
          if (body != null) {
            withBinaryBody++;
            expect(String.fromCharCodes(body), contains('Sequence'));
            // The body name pool surfaces the model's property names.
            final names = binaryBodyStrings(bytes).map((s) => s.text).toSet();
            expect(names, containsAll(['Sequence', 'Step', 'Locals']),
                reason: '${f.path}: body strings missing model names');
            // And there is a sizeable contiguous string table.
            expect(binaryStringTable(bytes).length, greaterThanOrEqualTo(5),
                reason: '${f.path}: no contiguous string table');
          }
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
    expect(withMode, greaterThan(0), reason: 'no step run-modes recovered');
    expect(withModule, greaterThan(0), reason: 'no module-adapter bindings recovered');
    expect(totalLocals, greaterThan(0), reason: 'no sequence locals recovered');
    expect(withLimits, greaterThan(0), reason: 'no test limits recovered');
    expect(resolvedCalls, greaterThan(0), reason: 'no intra-file sequence calls resolved');
    // ignore: avoid_print
    print('teststand corpus: $xml XML / $binary binary / $other other · '
        '$totalSeqs sequences · $totalSteps steps · $withAction with pass/fail actions · '
        '$withModule with module bindings · $totalLocals locals · $withLimits limit tests · '
        '$withBinaryBody binary bodies inflated · $resolvedCalls intra-file calls');
  });

  test('every binary TOF1 body frames into a record region + string table', () {
    var binary = 0, framed = 0, withSentinels = 0, totalStrings = 0;
    // Leading-word invariants (recon).
    var word2Is1 = 0, word1InSet = 0;
    final word1Values = <int>{};
    final failures = <String>[];
    for (final f in seqs) {
      final bytes = f.readAsBytesSync();
      if (detectSeqFormat(bytes) != SeqFormat.binary) continue;
      binary++;
      final layout = analyzeBinaryBody(bytes);
      if (layout == null) {
        failures.add('${f.path}: no layout');
        continue;
      }
      framed++;
      totalStrings += layout.stringCount;
      if (layout.sentinelCount > 0) withSentinels++;
      // The record region is non-empty and strictly precedes the string region,
      // which itself holds a real packed table.
      if (layout.recordRegionLength <= 0 ||
          layout.recordRegionLength >= layout.inflatedSize ||
          layout.stringCount < 5) {
        failures.add('${f.path}: $layout');
      }
      final w = layout.leadingWords;
      if (w.length >= 3 && w[2] == 1) word2Is1++;
      if (w.length >= 2 && (w[1] == 16 || w[1] == 118)) {
        word1InSet++;
        word1Values.add(w[1]);
      }
      // The string region splits into multiple packed tables (segments).
      final segments = binaryStringSegments(bytes);
      if (layout.segmentCount != segments.length || layout.segmentCount < 6) {
        failures.add('${f.path}: ${layout.segmentCount} segments');
      }
    }
    // ignore: avoid_print
    print('binary framing: $framed/$binary framed · '
        '$withSentinels with ff-sentinels · $totalStrings strings total · '
        'word2==1 $word2Is1/$binary · word1∈{16,118} $word1InSet/$binary '
        '(values $word1Values) · all ≥6 string segments');
    expect(framed, binary, reason: 'some binary bodies did not frame');
    expect(failures, isEmpty, reason: failures.join('\n'));
    // Decoded record-header invariants (recon): the 3rd leading u32 is a
    // constant 1, and the 2nd is one of two values, across the whole corpus.
    expect(word2Is1, binary, reason: 'leadingWords[2] != 1 in some files');
    expect(word1InSet, binary, reason: 'leadingWords[1] not in {16,118}');
  });
}
