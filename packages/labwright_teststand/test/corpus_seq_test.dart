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
            // The body name pool surfaces the model's property names. (A few
            // small/atypical files carry only some of these tokens, so we
            // require at least one rather than all three — holds 288/288.)
            final names = binaryBodyStrings(bytes).map((s) => s.text).toSet();
            expect(
              ['Sequence', 'Step', 'Locals'].any(names.contains),
              isTrue,
              reason: '${f.path}: body strings missing all core model names',
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

  test('every INI .seq parses into a header + sections (Rosetta form)', () {
    var ini = 0, parsed = 0, sfRoot = 0, dataNamed = 0, seqType = 0;
    final failures = <String>[];
    for (final f in seqs) {
      final bytes = f.readAsBytesSync();
      if (detectSeqFormat(bytes) != SeqFormat.ini) continue;
      ini++;
      try {
        final doc = parseIniSeqBytes(bytes);
        parsed++;
        // Header recovers the file kind + product (was null before the INI reader).
        if (doc.header.fileType == 'SequenceFile') seqType++;
        // The %OBJROOT alias to SequenceFileData is the firm structural anchor.
        if (doc.sections.any(
          (s) => s.isDef && s.members['SF'] == 'SequenceFileData',
        )) {
          sfRoot++;
        }
        // The root data object is named "Data".
        if (doc.sections.any((s) => s.name == 'Data')) dataNamed++;
      } catch (e) {
        failures.add('${f.path}: $e');
      }
    }
    // ignore: avoid_print
    print(
      'INI corpus: $parsed/$ini parsed · $seqType SequenceFile header · '
      '$sfRoot define SF=SequenceFileData · $dataNamed name an object "Data"',
    );
    expect(failures, isEmpty, reason: failures.take(5).join('\n'));
    expect(ini, greaterThan(0), reason: 'no INI files in corpus');
    expect(parsed, ini, reason: 'some INI file failed to parse');
    // Firm invariants verified across all 58 INI files in the corpus.
    expect(seqType, ini, reason: 'an INI header lacks Type=SequenceFile');
    expect(sfRoot, ini, reason: 'an INI lacks the SF=SequenceFileData root');
    expect(dataNamed, ini, reason: 'an INI names no object "Data"');
  });

  test('every binary TOF1 body frames into a record region + string table', () {
    var binary = 0, framed = 0, withSentinels = 0, totalStrings = 0;
    // Leading-word recon. word[2] is a constant 1 across the corpus; word[1]
    // varies widely (the earlier "∈ {16,118} selector" was overfit to the small
    // NI-example set — see NOTES.md), so we report its spread, not assert it.
    var word2Is1 = 0;
    final word1Values = <int, int>{};
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
      if (w.length >= 2) word1Values[w[1]] = (word1Values[w[1]] ?? 0) + 1;
      // The string region splits into packed tables (segments); the count is
      // consistent with binaryStringSegments and is at least 2 (record region +
      // ≥1 string table). Most files have many more; a few small ones have 2–5.
      final segments = binaryStringSegments(bytes);
      if (layout.segmentCount != segments.length || layout.segmentCount < 2) {
        failures.add('${f.path}: ${layout.segmentCount} segments');
      }
    }
    // ignore: avoid_print
    print(
      'binary framing: $framed/$binary framed · '
      '$withSentinels with ff-sentinels · $totalStrings strings total · '
      'word2==1 $word2Is1/$binary · word1 spread $word1Values · '
      'all ≥2 string segments',
    );
    expect(framed, binary, reason: 'some binary bodies did not frame');
    expect(failures, isEmpty, reason: failures.join('\n'));
    // Record-header invariant that holds across the whole corpus: the 3rd
    // leading u32 is a constant 1. (word[1] is NOT a fixed small set — refuted.)
    expect(word2Is1, binary, reason: 'leadingWords[2] != 1 in some files');
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
    // The name table is almost never the largest segment (value/expression
    // tables are bigger) — holds for the vast majority, not 100% (one file's
    // name table edges out its others).
    expect(
      notLargest / binary,
      greaterThan(0.95),
      reason: 'name table is the largest segment too often ($notLargest/$binary)',
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
    var binary = 0, rooted = 0, prefix2Ok = 0, scaffold5Ok = 0, recordIndexesData = 0;
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
      // Firm prefix (holds for every rooted file): the pool opens with the
      // container root then 'Data'.
      if (names.length >= 2 && names[1] == 'Data') {
        prefix2Ok++;
      } else {
        failures.add('${f.path}: prefix ${names.take(2).toList()} != [SequenceFileData, Data]');
      }
      // The full 5-entry scaffold [SequenceFileData,Data,Objs,Seq,[0]] is the
      // common case but NOT universal — real-world files also use other roots
      // (e.g. [...,Data,Attributes,Obj,TestStand]). Counted, not required.
      final prefix = names.take(binaryNameScaffold.length).toList();
      var matches = prefix.length == binaryNameScaffold.length;
      for (var i = 0; matches && i < binaryNameScaffold.length; i++) {
        if (prefix[i] != binaryNameScaffold[i]) matches = false;
      }
      if (matches) scaffold5Ok++;
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
      '$prefix2Ok/$rooted open with [SequenceFileData, Data] · '
      '$scaffold5Ok/$rooted with the full 5-entry scaffold · '
      '$recordIndexesData/$rooted record word[2]==1 -> name[1]==Data',
    );
    expect(failures, isEmpty, reason: failures.join('\n'));
    // Firm: most binary files are full sequence files rooted at SequenceFileData;
    // every such file opens with the [SequenceFileData, Data] prefix and has its
    // record stream reference name[1]=='Data' by the constant index 1.
    expect(rooted, greaterThanOrEqualTo(80), reason: 'few files are rooted');
    expect(prefix2Ok, rooted, reason: 'a rooted file lacks the [..,Data] prefix');
    // The full 5-entry scaffold is the dominant (not universal) root shape.
    expect(
      scaffold5Ok / rooted,
      greaterThan(0.95),
      reason: 'the 5-entry scaffold is rarer than expected ($scaffold5Ok/$rooted)',
    );
    expect(
      recordIndexesData,
      rooted,
      reason: 'record word[2] does not index name[1]==Data',
    );
  });

  // The object-record triplet [u32 name-index][u32 field][u32 count] (with a
  // 00000000 / ffffffff boundary before) — a corroborated structural signal, but
  // a noisy one (see the real-vs-control assertion below).
  int u32(List<int> b, int i) =>
      b[i] | b[i + 1] << 8 | b[i + 2] << 16 | b[i + 3] << 24;
  bool tripletExists(List<int> body, int rr, int idx) {
    for (var i = 0; i + 12 <= rr; i++) {
      if (u32(body, i) != idx) continue;
      final field = u32(body, i + 4);
      final count = u32(body, i + 8);
      if (field < 1 || field > 100000) continue;
      if (count < 1 || count > 1000) continue;
      final preOk =
          i < 4 ||
          (body[i - 1] == 0 &&
              body[i - 2] == 0 &&
              body[i - 3] == 0 &&
              body[i - 4] == 0) ||
          (body[i - 1] == 0xff &&
              body[i - 2] == 0xff &&
              body[i - 3] == 0xff &&
              body[i - 4] == 0xff);
      if (preOk) return true;
    }
    return false;
  }

  test('object-record triplet is a real signal (real names >> control)', () {
    var realTot = 0, realHit = 0, fakeTot = 0, fakeHit = 0;
    for (final f in seqs) {
      final bytes = f.readAsBytesSync();
      if (detectSeqFormat(bytes) != SeqFormat.binary) continue;
      final body = inflateBinaryBody(bytes);
      final layout = analyzeBinaryBody(bytes);
      final name = binaryNameTable(bytes);
      if (body == null || layout == null || name == null) continue;
      final nameLen = name.entries.length;
      if (nameLen <= 5) continue;
      final rr = layout.recordRegionLength.clamp(0, body.length);
      final span = nameLen - 5;
      for (var idx = 5; idx < nameLen; idx++) {
        realTot++;
        if (tripletExists(body, rr, idx)) realHit++;
      }
      // negative control: same count of indices just ABOVE nameLen (not names).
      for (var k = 0; k < span; k++) {
        fakeTot++;
        if (tripletExists(body, rr, nameLen + 1 + k)) fakeHit++;
      }
    }
    final realRate = realHit / realTot;
    final fakeRate = fakeHit / fakeTot;
    // ignore: avoid_print
    print(
      'object-record triplet: real names ${(realRate * 100).toStringAsFixed(1)}% '
      '($realHit/$realTot) vs control ${(fakeRate * 100).toStringAsFixed(1)}% '
      '($fakeHit/$fakeTot)',
    );
    expect(realTot, greaterThan(0));
    // The triplet is a genuine signal: real name indices match far more often
    // than control indices. (Not clean enough to *extract* objects — the control
    // rate is ~40% — but well above it, corroborating the record shape. On the
    // broadened corpus the real rate is ~86%, down from the small-corpus 98%.)
    expect(
      realRate,
      greaterThan(0.8),
      reason: 'real-name triplet rate too low ($realRate)',
    );
    expect(
      realRate - fakeRate,
      greaterThan(0.25),
      reason: 'triplet not distinguishable from control',
    );
  });

  test(
    'analyzeBinary matches the individual helpers (single-inflate path)',
    () {
      var binary = 0, checked = 0;
      final failures = <String>[];
      for (final f in seqs) {
        final bytes = f.readAsBytesSync();
        if (detectSeqFormat(bytes) != SeqFormat.binary) continue;
        binary++;
        final a = analyzeBinary(bytes);
        if (a == null) {
          failures.add('${f.path}: analyzeBinary null');
          continue;
        }
        checked++;
        final ok =
            a.inflatedSize == (inflateBinaryBody(bytes)?.length ?? 0) &&
            a.strings.length == binaryBodyStrings(bytes).length &&
            a.stringTable.length == binaryStringTable(bytes).length &&
            a.layout?.recordRegionLength ==
                analyzeBinaryBody(bytes)?.recordRegionLength &&
            a.nameTable.length == (binaryNameTable(bytes)?.entries.length ?? 0);
        if (!ok) failures.add('${f.path}: analyzeBinary != helpers');
      }
      expect(failures, isEmpty, reason: failures.take(5).join('\n'));
      expect(
        checked,
        binary,
        reason: 'analyzeBinary failed on some binary file',
      );
    },
  );

  test('binaryObjectNames recovers names past the scaffold', () {
    var binary = 0, rooted = 0, withNames = 0;
    final failures = <String>[];
    for (final f in seqs) {
      final bytes = f.readAsBytesSync();
      if (detectSeqFormat(bytes) != SeqFormat.binary) continue;
      binary++;
      final table = binaryNameTable(bytes);
      final rootedHere =
          table != null &&
          table.entries.isNotEmpty &&
          table.entries.first.text == 'SequenceFileData';
      if (!rootedHere) continue;
      rooted++;
      final names = binaryObjectNames(bytes);
      // Scaffold prefix is dropped: the list no longer starts with the root.
      if (names.isNotEmpty && names.first != 'SequenceFileData') withNames++;
      if (names.isNotEmpty && names.first == 'SequenceFileData') {
        failures.add('${f.path}: scaffold prefix not dropped ($names)');
      }
    }
    // ignore: avoid_print
    print(
      'binaryObjectNames: $withNames/$rooted rooted files expose ≥1 '
      'recovered object name (of $binary binary)',
    );
    expect(failures, isEmpty, reason: failures.take(5).join('\n'));
    expect(rooted, greaterThanOrEqualTo(80));
    // Every rooted file defines at least one object beyond the scaffold.
    expect(withNames, rooted, reason: 'a rooted file exposed no object names');
  });

  // REMOVED — 'leadingWords[1] selects the record-prefix layout'. This asserted
  // leadingWords[1] ∈ {16,118} each picking a deterministic words[3,5,7] layout.
  // The broadened 288-file corpus refuted it: leadingWords[1] takes many values
  // (16, 18, 20, 118, 256, 272, 276, …), so it is not a two-valued layout
  // selector. The original claim was overfit to the NI-example subset. The
  // record-prefix structure past the header is not yet decoded (see NOTES.md).
}
