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
    test(
      'teststand corpus',
      () {},
      skip: 'corpus absent — run tool/fetch_seq_corpus.dart',
    );
    return;
  }

  final seqs =
      corpusSeqDir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.seq'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  test('corpus has .seq files', () => expect(seqs, isNotEmpty));

  test('every XML .seq parses; binary .seq is classified, not mis-parsed', () {
    var xml = 0,
        binary = 0,
        other = 0,
        totalSeqs = 0,
        totalSteps = 0,
        withAction = 0,
        withModule = 0,
        totalLocals = 0,
        withLimits = 0,
        withBinaryBody = 0,
        resolvedCalls = 0,
        withMode = 0;
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
            expect(
              names,
              containsAll(['Sequence', 'Step', 'Locals']),
              reason: '${f.path}: body strings missing model names',
            );
            // And there is a sizeable contiguous string table.
            expect(
              binaryStringTable(bytes).length,
              greaterThanOrEqualTo(5),
              reason: '${f.path}: no contiguous string table',
            );
          }
        case SeqFormat.ini:
        case SeqFormat.unknown:
          other++;
      }
    }
    printOnFailure(
      'xml=$xml binary=$binary other=$other '
      'sequences=$totalSeqs steps=$totalSteps withAction=$withAction',
    );
    expect(failures, isEmpty, reason: failures.take(5).join('\n'));
    expect(xml, greaterThan(0));
    expect(
      totalSeqs,
      greaterThan(0),
      reason: 'XML lens recovered no sequences',
    );
    expect(totalSteps, greaterThan(0), reason: 'XML lens recovered no steps');
    expect(
      withAction,
      greaterThan(0),
      reason: 'no step settings (PassAct) recovered',
    );
    expect(withMode, greaterThan(0), reason: 'no step run-modes recovered');
    expect(
      withModule,
      greaterThan(0),
      reason: 'no module-adapter bindings recovered',
    );
    expect(totalLocals, greaterThan(0), reason: 'no sequence locals recovered');
    expect(withLimits, greaterThan(0), reason: 'no test limits recovered');
    expect(
      resolvedCalls,
      greaterThan(0),
      reason: 'no intra-file sequence calls resolved',
    );
    // ignore: avoid_print
    print(
      'teststand corpus: $xml XML / $binary binary / $other other · '
      '$totalSeqs sequences · $totalSteps steps · $withAction with pass/fail actions · '
      '$withModule with module bindings · $totalLocals locals · $withLimits limit tests · '
      '$withBinaryBody binary bodies inflated · $resolvedCalls intra-file calls',
    );
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
    print(
      'binary framing: $framed/$binary framed · '
      '$withSentinels with ff-sentinels · $totalStrings strings total · '
      'word2==1 $word2Is1/$binary · word1∈{16,118} $word1InSet/$binary '
      '(values $word1Values) · all ≥6 string segments',
    );
    expect(framed, binary, reason: 'some binary bodies did not frame');
    expect(failures, isEmpty, reason: failures.join('\n'));
    // Decoded record-header invariants (recon): the 3rd leading u32 is a
    // constant 1, and the 2nd is one of two values, across the whole corpus.
    expect(word2Is1, binary, reason: 'leadingWords[2] != 1 in some files');
    expect(word1InSet, binary, reason: 'leadingWords[1] not in {16,118}');
  });

  // Expression-like marker: a TestStand expression/value string carries a member
  // access (Locals./Step./Foo.Bar), a call/quote, or an operator with operands.
  bool isExprLike(String s) =>
      (s.contains('.') && RegExp(r'[A-Za-z]\.[A-Za-z]').hasMatch(s)) ||
      s.contains('(') ||
      s.contains(')') ||
      s.contains('"') ||
      (RegExp(r'[+\-*/=<>!]').hasMatch(s) &&
          RegExp(r'[A-Za-z0-9]').hasMatch(s));

  test('binary string region has a content-identified property-name table', () {
    var binary = 0,
        nameFound = 0,
        hasModelTokens = 0,
        notLargest = 0,
        isFirst = 0,
        valuesOutsideName = 0;
    final failures = <String>[];
    for (final f in seqs) {
      final bytes = f.readAsBytesSync();
      if (detectSeqFormat(bytes) != SeqFormat.binary) continue;
      binary++;
      final segs = binaryStringSegments(bytes);
      final name = binaryNameTable(bytes);
      if (name == null) {
        failures.add('${f.path}: no name table');
        continue;
      }
      nameFound++;
      final texts = {for (final e in name.entries) e.text};
      if (texts.contains('Step') ||
          texts.contains('Sequence') ||
          texts.contains('Locals')) {
        hasModelTokens++;
      } else {
        failures.add('${f.path}: name table lacks core model tokens');
      }
      // The name table is never the largest — value/expression tables are bigger.
      if (segs.any((s) => s.entries.length > name.entries.length)) notLargest++;
      // Strong (not universal) tendency: the name table is the first segment.
      if (segs.isNotEmpty && name.offset == segs.first.offset) isFirst++;
      // Expressions live OUTSIDE the name table: some other segment carries them.
      // (The largest segment is NOT reliably the expression table — refuted.)
      if (segs.any(
        (s) =>
            s.offset != name.offset && s.entries.any((e) => isExprLike(e.text)),
      )) {
        valuesOutsideName++;
      }
    }
    // ignore: avoid_print
    print(
      'binary name table: $nameFound/$binary found · '
      '$hasModelTokens/$binary carry core tokens · '
      '$notLargest/$binary smaller than another segment · '
      '$isFirst/$binary are the first segment · '
      '$valuesOutsideName/$binary have expressions outside the name table',
    );
    expect(failures, isEmpty, reason: failures.join('\n'));
    // Firm corpus invariants: a content-identified name table always exists,
    // always carries the core tokens, and is never the largest segment.
    expect(
      nameFound,
      binary,
      reason: 'no content-identified name table somewhere',
    );
    expect(hasModelTokens, binary, reason: 'name table missing core tokens');
    expect(
      notLargest,
      binary,
      reason: 'name table is the largest segment somewhere',
    );
    // Names vs. values are separated: every file has expression-like strings in
    // a segment other than the name table.
    expect(
      valuesOutsideName,
      binary,
      reason: 'a file has no expressions outside its name table',
    );
  });

  test('binary name table is the ordered pool opening with a fixed scaffold', () {
    var binary = 0, rooted = 0, scaffoldOk = 0, recordIndexesData = 0;
    final failures = <String>[];
    for (final f in seqs) {
      final bytes = f.readAsBytesSync();
      if (detectSeqFormat(bytes) != SeqFormat.binary) continue;
      binary++;
      final name = binaryNameTable(bytes);
      if (name == null) {
        failures.add('${f.path}: no name table');
        continue;
      }
      final names = [for (final e in name.entries) e.text];
      if (names.isEmpty || names.first != 'SequenceFileData') continue;
      rooted++;
      // The first five entries are the fixed PropertyObject container scaffold.
      final prefix = names.take(binaryNameScaffold.length).toList();
      var matches = prefix.length == binaryNameScaffold.length;
      for (var i = 0; matches && i < binaryNameScaffold.length; i++) {
        if (prefix[i] != binaryNameScaffold[i]) matches = false;
      }
      if (matches) {
        scaffoldOk++;
      } else {
        failures.add('${f.path}: prefix $prefix != $binaryNameScaffold');
      }
      // The record stream opens by referencing the scaffold by index: the 3rd
      // record word is the constant 1, which selects name[1] == 'Data'.
      final words = binaryRecordWords(bytes);
      if (words.length >= 3 && words[2] == 1 && names[1] == 'Data') {
        recordIndexesData++;
      }
    }
    // ignore: avoid_print
    print(
      'binary name pool: $rooted/$binary rooted at SequenceFileData · '
      '$scaffoldOk/$rooted open with the 5-entry scaffold · '
      '$recordIndexesData/$rooted record word[2]==1 -> name[1]==Data',
    );
    expect(failures, isEmpty, reason: failures.join('\n'));
    // Firm: the vast majority of binary files are full sequence files rooted at
    // SequenceFileData, and every such file opens with the exact scaffold and
    // has its record stream reference name[1]=='Data' by the constant index 1.
    expect(rooted, greaterThanOrEqualTo(80), reason: 'few files are rooted');
    expect(
      scaffoldOk,
      rooted,
      reason: 'a rooted file lacks the scaffold prefix',
    );
    expect(
      recordIndexesData,
      rooted,
      reason: 'record word[2] does not index name[1]==Data',
    );
  });
}
