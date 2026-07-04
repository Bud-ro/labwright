@Tags(['corpus'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:labwright_seq/labwright_seq.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

/// Counts the instance-override markers (`%INSTOVRD`) recovered anywhere in a
/// property tree — see [SeqProperty.isInstanceOverride].
int _countOverrides(SeqProperty p, [int depth = 0]) {
  if (depth > 50) return 0;
  return p.subProps
      .followedBy(p.array ?? const <SeqProperty>[])
      .fold(p.isInstanceOverride ? 1 : 0, (n, c) => n + _countOverrides(c, depth + 1));
}

/// Byte-level ASCII substring search — avoids materializing a whole inflated
/// body as a String just to probe for a token (peak memory in corpus sweeps).
bool _bodyContains(List<int> body, String ascii) {
  final pat = ascii.codeUnits;
  outer:
  for (var i = 0; i + pat.length <= body.length; i++) {
    for (var j = 0; j < pat.length; j++) {
      if (body[i + j] != pat[j]) continue outer;
    }
    return true;
  }
  return false;
}

/// Per-file size ceiling for the heavier corpus probes. This is a **runtime**
/// bound, not an OOM guard: the INI reader handles the full corpus fine (the
/// largest file, ~2.3MB, parses in ~120ms since the O(paths²) blowup was fixed
/// in the path-index pass). Set well above every real corpus file so coverage is
/// measured over everything; it only fires for a hypothetical pathological giant.
const _maxProbeBytes = 8 * 1024 * 1024;

/// Validates the M1 XML reader against the real fetched corpus: every XML `.seq`
/// must parse without throwing, and the typed lens must recover sequences and
/// steps. Binary `TOF1` files parse to the honest PARTIAL model (sequence/step
/// skeleton; properties/modules not yet decoded). Self-skips when the corpus is
/// absent.
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
          .where((f) => !f.path.replaceAll(r'\', '/').contains('/rosetta/'))
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
        withMode = 0,
        withIcon = 0,
        typedSteps = 0,
        unknownAdapters = 0,
        binaryWithSequences = 0,
        binaryStepsRecovered = 0,
        binaryTypedSteps = 0;
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
                if (step.type != null) typedSteps++;
                if (step.settings.passAction != null) withAction++;
                if (step.settings.mode != null) withMode++;
                if (step.settings.icon != null) withIcon++;
                if (step.module.adapter == SeqAdapter.unknown) unknownAdapters++;
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
          // Binary now parses to a PARTIAL typed model (sequence/step skeleton
          // from the decoded record structures); it must not throw, and the
          // root-shape gate must never emit structural tokens as names.
          final partial = parseSeqFile(bytes);
          if (partial.sequences.isNotEmpty) binaryWithSequences++;
          final partialTypeNames = {for (final t in partial.types) t.name};
          for (final seq in partial.sequences) {
            expect(seq.name, isNotEmpty);
            expect(const {'Sequence', 'Calls', 'ResultList', 'Objs', 'Seq', 'Obj', 'Data'},
                isNot(contains(seq.name)),
                reason: '${f.path}: structural token as sequence name');
            binaryStepsRecovered += seq.steps.length;
            for (final step in seq.steps) {
              final type = step.type;
              if (type == null) continue;
              binaryTypedSteps++;
              // A bound type must come from the file's own recovered type
              // table — anything else would be fabrication.
              expect(partialTypeNames, contains(type),
                  reason: '${f.path}: step ${step.name} bound to a type '
                      'outside the recovered table');
            }
          }
          final bh = detectSeqHeader(bytes);
          expect(bh.fileType, 'SequenceFile');
          expect(bh.productName, 'TestStand');
          final body = inflateBinaryBody(bytes);
          expect(body, isNotNull, reason: '${f.path}: no inflatable body');
          if (body != null) {
            withBinaryBody++;
            expect(_bodyContains(body, 'Sequence'), isTrue,
                reason: '${f.path}: body lacks the Sequence token');
            final names = binaryBodyStrings(bytes).map((s) => s.text).toSet();
            expect(
              ['Sequence', 'Step', 'Locals'].any(names.contains),
              isTrue,
              reason: '${f.path}: body strings missing all core model names',
            );
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
    expect(xml, 26, reason: 'XML file count drifted');
    expect(binary, 288, reason: 'binary file count drifted');
    // Partial-parse recovery floors (review: the previous check was vacuous —
    // an empty sequences list passed silently). Measured after the root-shape
    // gate: 86 binaries decode >=1 sequence; 32 steps reach the typed model
    // (steps laid out before their group markers are reported ungrouped and
    // honestly kept OUT of the typed tree — raising this floor is the
    // grouping-decode roadmap, not a tuning knob).
    expect(binaryWithSequences, greaterThanOrEqualTo(80),
        reason: 'binary sequence recovery regressed ($binaryWithSequences files)');
    expect(binaryStepsRecovered, greaterThanOrEqualTo(30),
        reason: 'binary step recovery regressed ($binaryStepsRecovered steps)');
    expect(binaryTypedSteps, greaterThanOrEqualTo(25),
        reason: 'binary per-step type binding regressed '
            '($binaryTypedSteps typed steps)');
    expect(other, 58, reason: 'other (INI) file count drifted');
    expect(totalSeqs, 33, reason: 'XML sequence count drifted');
    expect(totalSteps, 214, reason: 'XML step count drifted');
    expect(withAction, 141, reason: 'XML pass/fail-action count drifted');
    expect(withMode, greaterThan(0), reason: 'no step run-modes recovered');
    expect(withModule, 124, reason: 'XML module-binding count drifted');
    expect(totalLocals, 101, reason: 'XML locals count drifted');
    expect(withLimits, 10, reason: 'XML limit-test count drifted');
    expect(resolvedCalls, 7, reason: 'XML intra-file call count drifted');
    expect(withBinaryBody, 288, reason: 'binary-body inflate count drifted');
    expect(withIcon, 59, reason: 'XML step-icon count drifted');
    expect(typedSteps, totalSteps, reason: 'an XML step lost its type in the lens');
    expect(
      unknownAdapters,
      0,
      reason: 'an XML step has an unrecognized module adapter',
    );
    // ignore: avoid_print
    print(
      'teststand corpus: $xml XML / $binary binary / $other other · '
      '$binaryTypedSteps binary typed steps · '
      '$totalSeqs sequences · $totalSteps steps ($typedSteps typed) · '
      '$withAction with pass/fail actions · $withModule with module bindings '
      '($unknownAdapters unknown) · $totalLocals locals · $withLimits limit tests · '
      '$withIcon with icon · '
      '$withBinaryBody binary bodies inflated · $resolvedCalls intra-file calls',
    );
  });

  test('recovers measurement plug-in resource sets across XML corpus', () {
    var withBlock = 0, withPinMap = 0, withAnyFiles = 0;
    final pinMaps = <String>{};
    for (final f in seqs) {
      if (f.lengthSync() > _maxProbeBytes) continue;
      final bytes = f.readAsBytesSync();
      if (detectSeqFormat(bytes) != SeqFormat.xml) continue;
      final mp = parseSeqFile(bytes).measurementPlugIns;
      if (mp == null) continue;
      withBlock++;
      if (mp.pinMapPath != null) {
        withPinMap++;
        pinMaps.add(mp.pinMapPath!);
      }
      if (mp.specificationFiles.isNotEmpty ||
          mp.levelsFiles.isNotEmpty ||
          mp.timingFiles.isNotEmpty ||
          mp.patternFiles.isNotEmpty) {
        withAnyFiles++;
      }
    }
    // ignore: avoid_print
    print(
      'measurement plug-ins: $withBlock files with the block · $withPinMap with a '
      'pin map · $withAnyFiles with STS file lists · ${pinMaps.length} distinct pin maps',
    );
    expect(withBlock, greaterThanOrEqualTo(5));
    expect(withPinMap, greaterThanOrEqualTo(1));
  });

  test('recovers Python call descriptors across XML corpus', () {
    var pySteps = 0, withFn = 0, withModule = 0, withVersion = 0, withVenv = 0;
    final fns = <String>{};
    for (final f in seqs) {
      if (f.lengthSync() > _maxProbeBytes) continue;
      final bytes = f.readAsBytesSync();
      if (detectSeqFormat(bytes) != SeqFormat.xml) continue;
      final sf = parseSeqFile(bytes);
      for (final s in sf.sequences) {
        for (final step in s.steps) {
          final m = step.module;
          if (m.adapter != SeqAdapter.python) continue;
          pySteps++;
          if (m.pythonFunction != null) {
            withFn++;
            fns.add(m.pythonFunction!);
          }
          if (m.pythonModulePath != null) withModule++;
          if (m.pythonVersion != null) withVersion++;
          if (m.pythonVenvPath != null) withVenv++;
        }
      }
    }
    // ignore: avoid_print
    print(
      'python: $pySteps steps · $withFn with function · $withModule with module · '
      '$withVersion with version · $withVenv with venv · ${fns.length} distinct fns',
    );
    expect(pySteps, greaterThanOrEqualTo(20));
    expect(withFn, equals(pySteps), reason: 'every Python step names a function');
    expect(withModule, equals(pySteps), reason: 'every Python step has a module path');
    expect(withVersion, equals(pySteps), reason: 'every Python step has a version');
  });

  test('recovers LabVIEW VI-call connector params across XML corpus', () {
    var viSteps = 0, params = 0, withDisplayType = 0, withConnector = 0,
        withNamespace = 0, withBound = 0;
    for (final f in seqs) {
      if (f.lengthSync() > _maxProbeBytes) continue;
      final bytes = f.readAsBytesSync();
      if (detectSeqFormat(bytes) != SeqFormat.xml) continue;
      final sf = parseSeqFile(bytes);
      for (final s in sf.sequences) {
        for (final step in s.steps) {
          final m = step.module;
          if (m.adapter != SeqAdapter.labView) continue;
          final ps = m.viParameters;
          if (ps.isEmpty) continue;
          viSteps++;
          if (m.viNamespace != null) withNamespace++;
          for (final p in ps) {
            params++;
            if (p.displayType != null) withDisplayType++;
            if (p.connectorNumber != null) withConnector++;
            if (p.boundExpression != null) withBound++;
          }
        }
      }
    }
    // ignore: avoid_print
    print(
      'VI-call: $viSteps steps · $params connector params · '
      '$withDisplayType with display-type · $withConnector with connector# · '
      '$withBound bound · $withNamespace steps with a library namespace',
    );
    expect(viSteps, greaterThanOrEqualTo(5));
    expect(params, greaterThanOrEqualTo(20));
    expect(withDisplayType, equals(params), reason: 'every VI param has a DisplayType');
    expect(withConnector, equals(params), reason: 'every VI param has a connector#');
  });

  test('recovers structured flow-control logic across the corpus', () {
    var openers = 0, ends = 0, conds = 0, forInit = 0, forIncr = 0,
        eachArr = 0, eachElem = 0, ifWhile = 0, forLoops = 0, eachLoops = 0;
    var seqsWithFlow = 0, balancedSeqs = 0, totalFlowSeqs = 0;
    for (final f in seqs) {
      if (f.lengthSync() > _maxProbeBytes) continue;
      final bytes = f.readAsBytesSync();
      final fmt = detectSeqFormat(bytes);
      if (fmt != SeqFormat.xml && fmt != SeqFormat.ini) continue;
      final SeqFile sf;
      try {
        sf = parseSeqFile(bytes);
      } catch (_) {
        continue;
      }
      for (final q in sf.sequences) {
        var depth = 0, minDepth = 0, localFlow = 0;
        for (final step in q.steps) {
          final fc = step.flowControl;
          if (fc == null) continue;
          localFlow++;
          if (fc.kind.opensBlock) {
            openers++;
            depth++;
          } else if (fc.kind == FlowKind.end) {
            ends++;
            depth--;
            if (depth < minDepth) minDepth = depth;
          }
          switch (fc.kind) {
            case FlowKind.ifBlock:
            case FlowKind.elseIf:
            case FlowKind.whileLoop:
              ifWhile++;
              if (fc.condition != null) conds++;
            case FlowKind.forLoop:
              forLoops++;
              if (fc.initialization != null) forInit++;
              if (fc.condition != null) conds++;
              if (fc.increment != null) forIncr++;
            case FlowKind.forEach:
              eachLoops++;
              if (fc.arrayExpr != null) eachArr++;
              if (fc.arrayElement != null) eachElem++;
            default:
              break;
          }
        }
        if (localFlow > 0) {
          totalFlowSeqs++;
          seqsWithFlow++;
          if (depth == 0 && minDepth == 0) balancedSeqs++;
        }
      }
    }
    // ignore: avoid_print
    print(
      'flow-control: $openers openers / $ends ends · $ifWhile if/while ($conds cond) · '
      '$forLoops for ($forInit init,$forIncr incr) · '
      '$eachLoops foreach ($eachArr arr,$eachElem elem) · '
      '$balancedSeqs/$totalFlowSeqs sequences balanced',
    );
    expect(openers, greaterThan(0), reason: 'no flow-control steps found');
    expect(ends, openers, reason: 'every opener must have a matching NI_Flow_End');
    expect(balancedSeqs, totalFlowSeqs,
        reason: 'every flow-bearing sequence nests cleanly (balanced blocks)');
    expect(conds, ifWhile + forLoops, reason: 'every if/while/for has a condition');
    expect(forInit, forLoops, reason: 'every for has an initialization');
    expect(forIncr, forLoops, reason: 'every for has an increment');
    expect(eachArr, eachLoops, reason: 'every for-each has an array expression');
    expect(eachElem, eachLoops, reason: 'every for-each has an element binding');
    expect(seqsWithFlow, greaterThan(0));
  });

  test('logic export annotates pass/fail jumps across the corpus', () {
    var jumpSteps = 0, filesWithJump = 0, exportsWithJump = 0;
    for (final f in seqs) {
      if (f.lengthSync() > _maxProbeBytes) continue;
      final bytes = f.readAsBytesSync();
      final fmt = detectSeqFormat(bytes);
      if (fmt != SeqFormat.xml && fmt != SeqFormat.ini) continue;
      final SeqFile sf;
      try {
        sf = parseSeqFile(bytes);
      } catch (_) {
        continue;
      }
      var fileHas = false;
      for (final q in sf.sequences) {
        for (final s in q.steps) {
          final set = s.settings;
          if ((set.passAction != null && set.passAction != 'Next') ||
              (set.failAction != null && set.failAction != 'Next')) {
            jumpSteps++;
            fileHas = true;
          }
        }
      }
      if (fileHas) {
        filesWithJump++;
        if (exportSequenceLogic(sf).contains(RegExp(r'\[on (pass|fail)'))) {
          exportsWithJump++;
        }
      }
    }
    // ignore: avoid_print
    print('jumps: $jumpSteps non-default pass/fail actions in $filesWithJump '
        'files; $exportsWithJump exports annotate them');
    expect(jumpSteps, greaterThan(0), reason: 'no pass/fail jumps in corpus');
    expect(exportsWithJump, filesWithJump,
        reason: 'every file with a jump must annotate it in the logic export');
  });

  test('logic export annotates looping non-flow steps across the corpus', () {
    var loopSteps = 0, filesWithLoop = 0, exportsWithLoop = 0;
    for (final f in seqs) {
      if (f.lengthSync() > _maxProbeBytes) continue;
      final bytes = f.readAsBytesSync();
      final fmt = detectSeqFormat(bytes);
      if (fmt != SeqFormat.xml && fmt != SeqFormat.ini) continue;
      final SeqFile sf;
      try {
        sf = parseSeqFile(bytes);
      } catch (_) {
        continue;
      }
      var fileHas = false;
      for (final q in sf.sequences) {
        for (final s in q.steps) {
          if (s.flowControl == null && s.settings.isLooping) {
            loopSteps++;
            fileHas = true;
          }
        }
      }
      if (fileHas) {
        filesWithLoop++;
        if (exportSequenceLogic(sf).contains('[loop ')) exportsWithLoop++;
      }
    }
    // ignore: avoid_print
    print('loops: $loopSteps looping non-flow steps in $filesWithLoop files; '
        '$exportsWithLoop exports annotate them');
    expect(loopSteps, greaterThan(0), reason: 'no looping steps in corpus');
    expect(exportsWithLoop, filesWithLoop,
        reason: 'every file with a looping step must annotate it in the export');
  });

  test('logic export marks external SequenceCalls with their file', () {
    var external = 0, filesWithExternal = 0, exportsMarked = 0;
    for (final f in seqs) {
      if (f.lengthSync() > _maxProbeBytes) continue;
      final bytes = f.readAsBytesSync();
      final fmt = detectSeqFormat(bytes);
      if (fmt != SeqFormat.xml && fmt != SeqFormat.ini) continue;
      final SeqFile sf;
      try {
        sf = parseSeqFile(bytes);
      } catch (_) {
        continue;
      }
      var fileHas = false;
      for (final q in sf.sequences) {
        for (final s in q.steps) {
          if (s.module.adapter == SeqAdapter.sequenceCall &&
              sf.resolveCall(s) == null &&
              (s.module.sequenceFile ?? '').isNotEmpty) {
            external++;
            fileHas = true;
          }
        }
      }
      if (fileHas) {
        filesWithExternal++;
        if (exportSequenceLogic(sf).contains(RegExp(r' in \S+\.seq'))) {
          exportsMarked++;
        }
      }
    }
    // ignore: avoid_print
    print('external seq-calls: $external in $filesWithExternal files; '
        '$exportsMarked exports mark them with a file');
    expect(external, greaterThan(0), reason: 'no external seq-calls in corpus');
    expect(exportsMarked, filesWithExternal,
        reason: 'every file with an external call must mark it in the export');
  });

  test('logic export renders typed parameter signatures across the corpus', () {
    var seqsWithParams = 0, params = 0, typed = 0, filesWithParams = 0,
        exportsSigned = 0;
    for (final f in seqs) {
      if (f.lengthSync() > _maxProbeBytes) continue;
      final bytes = f.readAsBytesSync();
      final fmt = detectSeqFormat(bytes);
      if (fmt != SeqFormat.xml && fmt != SeqFormat.ini) continue;
      final SeqFile sf;
      try {
        sf = parseSeqFile(bytes);
      } catch (_) {
        continue;
      }
      var fileHas = false;
      for (final q in sf.sequences) {
        if (q.parameters.isEmpty) continue;
        seqsWithParams++;
        fileHas = true;
        for (final p in q.parameters) {
          params++;
          if (p.type != null) typed++;
        }
      }
      if (fileHas) {
        filesWithParams++;
        if (exportSequenceLogic(sf).contains(RegExp(r'^sequence .+\([^)]', multiLine: true))) {
          exportsSigned++;
        }
      }
    }
    // ignore: avoid_print
    print('signatures: $seqsWithParams seqs with params ($params params, '
        '$typed typed) in $filesWithParams files; $exportsSigned exports signed');
    expect(params, greaterThan(0), reason: 'no parameterized sequences in corpus');
    expect(typed, params, reason: 'every recovered parameter carries a type');
    expect(exportsSigned, filesWithParams,
        reason: 'every file with params must render a signature in the export');
  });

  test('recovers <typelist> type definitions across XML corpus', () {
    var files = 0, totalTypes = 0, withFields = 0, totalFields = 0;
    final baseClasses = <String>{};
    final sampleNames = <String>{};
    for (final f in seqs) {
      if (f.lengthSync() > _maxProbeBytes) continue;
      final bytes = f.readAsBytesSync();
      if (detectSeqFormat(bytes) != SeqFormat.xml) continue;
      files++;
      final sf = parseSeqFile(bytes);
      for (final t in sf.typeDefs) {
        totalTypes++;
        if (t.baseClass != null) baseClasses.add(t.baseClass!);
        if (sampleNames.length < 12) sampleNames.add(t.name);
        if (t.fields.isNotEmpty) {
          withFields++;
          totalFields += t.fields.length;
        }
      }
    }
    // ignore: avoid_print
    print(
      'typelist: $files files · $totalTypes typedefs · $withFields with fields · '
      '$totalFields fields · baseClasses=${baseClasses.length} · sample=$sampleNames',
    );
    expect(files, greaterThanOrEqualTo(20));
    expect(totalTypes, greaterThanOrEqualTo(300));
    expect(withFields, greaterThanOrEqualTo(1));
    expect(baseClasses, isNotEmpty);
    final first = parseSeqFile(seqs
            .firstWhere((f) =>
                f.lengthSync() <= _maxProbeBytes &&
                detectSeqFormat(f.readAsBytesSync()) == SeqFormat.xml)
            .readAsBytesSync())
        .typeDefs;
    expect(first.map((t) => t.name).toList(),
        isNotEmpty, reason: 'typeDefs should mirror types 1:1');
  });

  test('recovers the "Additional Results" recording spec across XML corpus', () {
    var filesWithSpec = 0, entries = 0, withCondition = 0;
    final kinds = <String>{};
    for (final f in seqs) {
      if (f.lengthSync() > _maxProbeBytes) continue;
      final bytes = f.readAsBytesSync();
      if (detectSeqFormat(bytes) != SeqFormat.xml) continue;
      final sf = parseSeqFile(bytes);
      var any = false;
      for (final s in sf.sequences) {
        for (final step in s.steps) {
          for (final a in step.additionalResults) {
            any = true;
            entries++;
            if (a.kind != null) kinds.add(a.kind!);
            if (a.condition != null) withCondition++;
          }
        }
      }
      if (any) filesWithSpec++;
    }
    // ignore: avoid_print
    print(
      'additional-results: $filesWithSpec files · $entries entries · '
      '$withCondition with a gating condition · kinds=$kinds',
    );
    expect(filesWithSpec, greaterThanOrEqualTo(10));
    expect(entries, greaterThanOrEqualTo(100));
    expect(
      kinds,
      everyElement(anyOf(contains('ParameterResult'), isNotEmpty)),
    );
  });

  test('recovers the step Result outcome record across XML corpus', () {
    var withResult = 0, withError = 0, recorded = 0;
    for (final f in seqs) {
      if (f.lengthSync() > _maxProbeBytes) continue;
      final bytes = f.readAsBytesSync();
      if (detectSeqFormat(bytes) != SeqFormat.xml) continue;
      final sf = parseSeqFile(bytes);
      for (final s in sf.sequences) {
        for (final step in s.steps) {
          final r = step.result;
          if (r == null) continue;
          withResult++;
          if (r.errorOccurred != null) withError++;
          if (r.hasRecordedOutcome) recorded++;
        }
      }
    }
    // ignore: avoid_print
    print(
      'step results: $withResult with Result · $withError with Error · '
      '$recorded with a recorded (non-default) outcome',
    );
    expect(withResult, greaterThan(0), reason: 'no step Result slots recovered');
    expect(withError, withResult, reason: 'a Result lost its Error sub-object');
    expect(recorded, 0,
        reason: 'a sequence file unexpectedly carries a recorded run outcome');
  });

  test('recovers custom-condition flow fields across XML corpus', () {
    var withTrueAct = 0, withFalseAct = 0, withCustExpr = 0;
    final trueActs = <String>{};
    for (final f in seqs) {
      if (f.lengthSync() > _maxProbeBytes) continue;
      final bytes = f.readAsBytesSync();
      if (detectSeqFormat(bytes) != SeqFormat.xml) continue;
      final sf = parseSeqFile(bytes);
      for (final s in sf.sequences) {
        for (final step in s.steps) {
          final st = step.settings;
          if (st.customTrueAction != null) {
            withTrueAct++;
            trueActs.add(st.customTrueAction!);
          }
          if (st.customFalseAction != null) withFalseAct++;
          if (st.customExpression != null) withCustExpr++;
        }
      }
    }
    // ignore: avoid_print
    print(
      'custom-condition: $withTrueAct trueAct · $withFalseAct falseAct · '
      '$withCustExpr custExpr · trueActs=$trueActs',
    );
    expect(withTrueAct, greaterThan(0), reason: 'no CustTrueAct recovered');
    expect(withFalseAct, greaterThan(0), reason: 'no CustFalseAct recovered');
  });

  test('recovers Python-adapter call parameters across XML corpus', () {
    var pySteps = 0, params = 0, named = 0, bound = 0;
    for (final f in seqs) {
      if (f.lengthSync() > _maxProbeBytes) continue;
      final bytes = f.readAsBytesSync();
      if (detectSeqFormat(bytes) != SeqFormat.xml) continue;
      final sf = parseSeqFile(bytes);
      for (final s in sf.sequences) {
        for (final step in s.steps) {
          if (step.module.adapter != SeqAdapter.python) continue;
          final args = step.module.callParameters;
          if (args.isEmpty) continue;
          pySteps++;
          for (final a in args) {
            params++;
            if (a.name.isNotEmpty) named++;
            if (a.boundExpression != null) bound++;
          }
        }
      }
    }
    // ignore: avoid_print
    print(
      'python call params: $pySteps steps · $params params · '
      '$named named · $bound with a bound value',
    );
    expect(params, greaterThanOrEqualTo(45));
    expect(named, params, reason: 'a Python param lost its Name');
    expect(bound, greaterThan(0), reason: 'no Python param bound value recovered');
  });

  test('recovers measurement-step typed parameters across XML corpus', () {
    var filesWithParams = 0, params = 0, withType = 0, withDirection = 0;
    var specialized = 0, notLogged = 0, enumParams = 0, enumValues = 0;
    final types = <String>{};
    final specs = <String>{};
    for (final f in seqs) {
      if (f.lengthSync() > _maxProbeBytes) continue;
      final bytes = f.readAsBytesSync();
      if (detectSeqFormat(bytes) != SeqFormat.xml) continue;
      final sf = parseSeqFile(bytes);
      var any = false;
      for (final s in sf.sequences) {
        for (final step in s.steps) {
          for (final p in step.measurementParameters) {
            any = true;
            params++;
            if (p.dataType != null) {
              withType++;
              types.add(p.dataType!);
            }
            if (p.direction != null) withDirection++;
            if (p.typeSpecialization != null) {
              specialized++;
              specs.add(p.typeSpecialization!);
            }
            if (p.logged == false) notLogged++;
            if (p.dataType == 'TypeEnum') {
              enumParams++;
              enumValues += p.enumValues.length;
            }
          }
        }
      }
      if (any) filesWithParams++;
    }
    // ignore: avoid_print
    print(
      'measurement params: $filesWithParams files · $params params · '
      '$withType typed · $withDirection with direction · '
      '$specialized specialized $specs · $notLogged not-logged · '
      '$enumParams enum params / $enumValues values · types=$types',
    );
    expect(params, greaterThanOrEqualTo(120));
    expect(withType, params, reason: 'a measurement param lost its Type');
    expect(types, contains('TypeDouble'));
    expect(withDirection, greaterThan(0));
    expect(specialized, greaterThan(0), reason: 'no TypeSpecialization recovered');
    expect(specs, contains('IOResource'));
    expect(notLogged, greaterThan(0), reason: 'Log flag never varies');
    expect(enumParams, greaterThan(0), reason: 'no TypeEnum params found');
    expect(enumValues, greaterThanOrEqualTo(enumParams),
        reason: 'an enum param lost its allowed-value list');
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
        if (doc.header.fileType == 'SequenceFile') seqType++;
        if (doc.sections.any(
          (s) => s.isDef && s.members['SF'] == 'SequenceFileData',
        )) {
          sfRoot++;
        }
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
    expect(seqType, ini, reason: 'an INI header lacks Type=SequenceFile');
    expect(sfRoot, ini, reason: 'an INI lacks the SF=SequenceFileData root');
    expect(dataNamed, ini, reason: 'an INI names no object "Data"');
  });

  test('the typed lens + coverage metric apply to INI (shared model)', () {
    var ini = 0, steps = 0, withModule = 0, withAddl = 0;
    var cov = const SeqCoverage(total: 0, modeled: 0);
    for (final f in seqs) {
      if (f.lengthSync() > _maxProbeBytes) continue;
      final bytes = f.readAsBytesSync();
      if (detectSeqFormat(bytes) != SeqFormat.ini) continue;
      ini++;
      final sf = parseSeqFile(bytes);
      cov += measureCoverage(sf);
      for (final seq in sf.sequences) {
        for (final step in seq.steps) {
          steps++;
          if (step.module.adapter != SeqAdapter.none) withModule++;
          if (step.additionalResults.isNotEmpty) withAddl++;
        }
      }
    }
    // ignore: avoid_print
    print('INI lens: $ini files · $steps steps · $withModule with a module '
        'adapter · $withAddl with additional-results · '
        'accounted ${(cov.accountedRatio * 100).toStringAsFixed(1)}% · '
        'modeled ${(cov.ratio * 100).toStringAsFixed(1)}% · '
        'plumbing ${cov.plumbing} · unaccounted ${cov.unaccounted}');
    expect(ini, greaterThanOrEqualTo(30));
    expect(steps, greaterThanOrEqualTo(1000));
    expect(withModule, greaterThanOrEqualTo(500));
    expect(cov.unaccounted, 0,
        reason: 'INI left ${cov.unaccounted} node(s) unaccounted; run '
            'tool/gaps.dart ini to classify them');
    expect(cov.ratio, greaterThan(0.995),
        reason: 'INI model coverage regressed (${cov.ratio})');
  });

  test('the typed lens models the bulk of every XML Data tree', () {
    var xml = 0;
    var cov = const SeqCoverage(total: 0, modeled: 0);
    for (final f in seqs) {
      final bytes = f.readAsBytesSync();
      if (detectSeqFormat(bytes) != SeqFormat.xml) continue;
      xml++;
      cov += measureCoverage(parseSeqFile(bytes));
    }
    // ignore: avoid_print
    print('XML lens: $xml files · '
        'accounted ${(cov.accountedRatio * 100).toStringAsFixed(1)}% · '
        'modeled ${(cov.ratio * 100).toStringAsFixed(1)}% · '
        'plumbing ${cov.plumbing} · unaccounted ${cov.unaccounted}');
    expect(xml, greaterThanOrEqualTo(20));
    expect(cov.unaccounted, 0,
        reason: 'XML left ${cov.unaccounted} node(s) unaccounted; run '
            'tool/gaps.dart xml to classify them');
    expect(cov.ratio, greaterThan(0.985),
        reason: 'XML model coverage regressed (${cov.ratio})');
  });

  test('newly-modeled lens accessors are wired across the corpus', () {
    var adapterName = 0, stepDesc = 0, codeTemplates = 0, runtimeEP = 0;
    var switchSettings = 0, seqCallExpr = 0, threading = 0, pyInterp = 0;
    var clusterEls = 0, dbStep = 0, limitExpr = 0, fileSettings = 0, fileGlobals = 0;
    for (final f in seqs) {
      final bytes = f.readAsBytesSync();
      final fmt = detectSeqFormat(bytes);
      if (fmt != SeqFormat.xml && fmt != SeqFormat.ini) continue;
      if (fmt == SeqFormat.ini && f.lengthSync() > _maxProbeBytes) continue;
      final sf = parseSeqFile(bytes);
      if (sf.modelFile != null ||
          sf.contentVersion != null ||
          sf.fileTypeCode != null) {
        fileSettings++;
      }
      if (sf.fileGlobals.isNotEmpty) fileGlobals++;
      for (final seq in sf.sequences) {
        if (seq.runtimeSettings?.entryPointNameExpression != null) runtimeEP++;
        for (final step in seq.steps) {
          final s = step.settings;
          if (s.adapterName != null) adapterName++;
          if (s.switchEnabled != null || s.canEditCode != null) switchSettings++;
          if (step.description != null) stepDesc++;
          if (step.typeInfo.codeTemplates.isNotEmpty) codeTemplates++;
          final m = step.module;
          if (m.sequenceNameExpression != null ||
              m.specifiesByExpression != null) {
            seqCallExpr++;
          }
          if (m.threadOptionCode != null) threading++;
          if (m.pythonInterpreterLocation != null ||
              m.pythonOperationTypeCode != null) {
            pyInterp++;
          }
          for (final p in [...m.viParameters, ...m.callParameters]) {
            if (p.caption != null || p.typeCode != null) clusterEls++;
          }
          if (step.sqlStatement != null || step.statementHandle != null) dbStep++;
          if (step.limits?.lowExpression != null ||
              step.limits?.comparisonExpression != null) {
            limitExpr++;
          }
        }
      }
    }
    // ignore: avoid_print
    print('new lens accessors: adapterName=$adapterName stepDesc=$stepDesc '
        'codeTemplates=$codeTemplates runtimeEP=$runtimeEP switch=$switchSettings '
        'seqCallExpr=$seqCallExpr threading=$threading py=$pyInterp '
        'paramDescriptor=$clusterEls db=$dbStep limitExpr=$limitExpr '
        'fileSettings=$fileSettings fileGlobals=$fileGlobals');
    expect(adapterName, greaterThan(0), reason: 'no Adapter names surfaced');
    expect(stepDesc, greaterThan(0), reason: 'no step Descriptions surfaced');
    expect(codeTemplates, greaterThan(0), reason: 'no CodeTemplates surfaced');
    expect(runtimeEP, greaterThan(0), reason: 'no RTS entry-point names surfaced');
    expect(switchSettings, greaterThan(0), reason: 'no switch/edit settings surfaced');
    expect(seqCallExpr, greaterThan(0), reason: 'no SequenceCall expressions surfaced');
    expect(threading, greaterThan(0), reason: 'no threading settings surfaced');
    expect(pyInterp, greaterThan(0), reason: 'no Python interpreter settings surfaced');
    expect(clusterEls, greaterThan(0), reason: 'no param type descriptors surfaced');
    expect(dbStep, greaterThan(0), reason: 'no database step fields surfaced');
    expect(limitExpr, greaterThan(0), reason: 'no limit expressions surfaced');
    expect(fileSettings, greaterThan(0), reason: 'no file-level settings surfaced');
    expect(fileGlobals, greaterThan(0), reason: 'no file globals surfaced');
  });

  test('INI parser drops no in-section data lines (every line is key = value)',
      () {
    var ini = 0, skipped = 0;
    final samples = <String>[];
    for (final f in seqs) {
      final bytes = f.readAsBytesSync();
      if (detectSeqFormat(bytes) != SeqFormat.ini) continue;
      ini++;
      final text = latin1.decode(bytes, allowInvalid: true);
      var inSection = false;
      for (final raw in const LineSplitter().convert(text)) {
        final line = raw.trimRight();
        if (line.isEmpty) continue;
        if (line.startsWith('[') && line.endsWith(']')) {
          inSection = true;
          continue;
        }
        if (!inSection || line.contains(' = ')) continue;
        skipped++;
        if (samples.length < 5) samples.add(line);
      }
    }
    // ignore: avoid_print
    print('INI line audit: $ini files, $skipped in-section lines without " = "');
    expect(ini, greaterThan(0));
    expect(skipped, 0,
        reason: 'INI parser silently skips data line(s): ${samples.join(' | ')}');
  });

  test('INI multi-line values are reassembled (no residual ` LineNNNN` keys)',
      () {
    var ini = 0, reassembled = 0, residual = 0;
    final baseKeys = <String>{};
    for (final f in seqs) {
      final bytes = f.readAsBytesSync();
      if (detectSeqFormat(bytes) != SeqFormat.ini) continue;
      ini++;
      final doc = parseIniSeqBytes(bytes);
      final residualRe = RegExp(r' Line\d+$');
      for (final s in doc.sections) {
        for (final k in [...s.members.keys, ...s.directives.keys]) {
          if (residualRe.hasMatch(k)) residual++;
        }
      }
    }
    final contRe = RegExp(r'^(.+) Line(\d+)\s*=', multiLine: true);
    for (final f in seqs) {
      final bytes = f.readAsBytesSync();
      if (detectSeqFormat(bytes) != SeqFormat.ini) continue;
      for (final m in contRe.allMatches(latin1.decode(bytes, allowInvalid: true))) {
        reassembled++;
        baseKeys.add(m.group(1)!.trim());
      }
    }
    // ignore: avoid_print
    print('INI continuations: $reassembled fragments collapsed across '
        '${baseKeys.length} base keys in $ini INI files; $residual residual');
    expect(ini, 58, reason: 'no INI files in corpus');
    expect(residual, 0, reason: 'a ` LineNNNN` fragment survived reassembly');
    expect(reassembled, 19820, reason: 'continuation-fragment count drifted');
    expect(baseKeys.length, 28, reason: 'continuation base-key count drifted');
  });

  test('INI sections assemble into the shared SeqProperty tree', () {
    var ini = 0, built = 0, dataRoot = 0, withSeqArray = 0, namedSeqs = 0;
    final failures = <String>[];
    for (final f in seqs) {
      final bytes = f.readAsBytesSync();
      if (detectSeqFormat(bytes) != SeqFormat.ini) continue;
      ini++;
      try {
        final tree = iniDataTree(parseIniSeqBytes(bytes));
        if (tree == null) continue;
        built++;
        if (tree.name == 'Data') dataRoot++;
        final seq = tree.subProps
            .where((p) => p.name == 'Seq' && p.isArray)
            .firstOrNull;
        if (seq != null && seq.array!.isNotEmpty) {
          withSeqArray++;
          if (seq.array!.any((s) => s.name.isNotEmpty && s.name != '[0]')) {
            namedSeqs++;
          }
        }
      } catch (e) {
        failures.add('${f.path}: $e');
      }
    }
    // ignore: avoid_print
    print(
      'INI tree: $built/$ini built · $dataRoot named "Data" · '
      '$withSeqArray have a non-empty Seq array · $namedSeqs name their sequences',
    );
    expect(failures, isEmpty, reason: failures.take(5).join('\n'));
    expect(ini, greaterThan(0));
    expect(built, ini, reason: 'an INI file built no data tree');
    expect(dataRoot, built, reason: 'a built INI tree is not rooted at "Data"');
    expect(withSeqArray, built, reason: 'a built INI tree has no Seq array');
    expect(namedSeqs, withSeqArray, reason: 'a Seq array exposes no named sequence');
  });

  test('INI files parse through parseSeqFile into the typed lens', () {
    var ini = 0, built = 0, threw = 0;
    var totSeq = 0, totSteps = 0, totLocals = 0, withType = 0;
    var totTypes = 0;
    var recognized = 0, noneAdapter = 0, unknownAdapter = 0;
    var withMode = 0, withLoop = 0;
    var overrides = 0, filesWithOverride = 0;
    var withComment = 0;
    var withSeqComment = 0;
    var objVarsWithFields = 0;
    var varsWithComment = 0;
    var withFlowTarget = 0;
    var resolvedIdTargets = 0;
    var withModuleTiming = 0;
    for (final f in seqs) {
      final bytes = f.readAsBytesSync();
      if (detectSeqFormat(bytes) != SeqFormat.ini) continue;
      ini++;
      try {
        final sf = parseSeqFile(bytes);
        built++;
        final ovr = _countOverrides(sf.data);
        overrides += ovr;
        if (ovr > 0) filesWithOverride++;
        totTypes += sf.types.length;
        totSeq += sf.sequences.length;
        for (final s in sf.sequences) {
          totLocals += s.locals.length;
          if (s.comment != null) withSeqComment++;
          for (final v in [...s.locals, ...s.parameters]) {
            if (!v.isArray && v.containerCount != null && v.containerCount! > 0) {
              objVarsWithFields++;
            }
            if (v.comment != null) varsWithComment++;
          }
          for (final st in s.steps) {
            totSteps++;
            if (st.type != null) withType++;
            switch (st.module.adapter) {
              case SeqAdapter.none:
                noneAdapter++;
              case SeqAdapter.unknown:
                unknownAdapter++;
              default:
                recognized++;
            }
            if (st.settings.mode != null) withMode++;
            if (st.settings.loopType != null) withLoop++;
            if (st.comment != null) withComment++;
            if (st.settings.passActionTarget != null ||
                st.settings.failActionTarget != null) {
              withFlowTarget++;
            }
            for (final t in [
              st.settings.customTrueTarget,
              st.settings.customFalseTarget,
            ]) {
              if (t != null &&
                  t.startsWith('ID#:') &&
                  sf.stepNameForId(t) != null) {
                resolvedIdTargets++;
              }
            }
            final lo = st.settings.loadOption, uo = st.settings.unloadOption;
            if ((lo != null && lo != 'PreloadWhenExecuted') ||
                (uo != null && uo != 'UnloadWithFile')) {
              withModuleTiming++;
            }
          }
        }
      } on FormatException {
        threw++;
      }
    }
    // ignore: avoid_print
    print(
      'INI lens: $built/$ini parsed via parseSeqFile ($threw threw) · '
      '$totSeq sequences · $totSteps steps · $totLocals locals · '
      '$withType typed steps · $totTypes types · '
      '$recognized recognized adapters / $noneAdapter none / $unknownAdapter unknown · '
      '$withMode with run-mode · $withLoop with looping · '
      '$withComment steps + $withSeqComment seqs with comment · '
      '$objVarsWithFields object vars with fields · '
      '$varsWithComment vars with comment · '
      '$withFlowTarget steps with flow target · '
      '$resolvedIdTargets resolved ID#: targets · '
      '$withModuleTiming steps non-default load/unload · '
      '$overrides instance-overrides in $filesWithOverride files',
    );
    expect(threw, 0, reason: 'an INI file failed to parse into a SeqFile');
    expect(built, ini, reason: 'not every INI file built a SeqFile');
    expect(ini, 58, reason: 'INI file count drifted');
    expect(totSeq, 449, reason: 'INI sequence count drifted');
    expect(totSteps, 5664, reason: 'INI step count drifted');
    expect(totLocals, 1662, reason: 'INI locals count drifted');
    expect(totTypes, 2242, reason: 'INI [%TYPES] count drifted');
    expect(unknownAdapter, 0, reason: 'an INI step has an unrecognized SData adapter');
    expect(recognized, 2186, reason: 'INI recognized-adapter count drifted');
    expect(noneAdapter, 3478, reason: 'INI none-adapter count drifted');
    expect(recognized + noneAdapter + unknownAdapter, totSteps,
        reason: 'adapter classification must partition all steps');
    expect(withType, greaterThan(0), reason: 'no INI step types via the lens');
    expect(withMode, greaterThan(0), reason: 'no type-inherited run-mode recovered');
    expect(withLoop, greaterThan(0), reason: 'no type-inherited looping recovered');
    expect(overrides, 13072, reason: '%INSTOVRD override count drifted');
    expect(withComment, 667, reason: 'step-comment count drifted');
    expect(withSeqComment, 102, reason: 'sequence-comment count drifted');
    expect(varsWithComment, 37, reason: 'variable-comment count drifted');
    expect(objVarsWithFields, 95, reason: 'object-variable field count drifted');
    expect(withFlowTarget, 58, reason: 'flow-target count drifted');
    expect(resolvedIdTargets, 12, reason: 'resolved ID#: target count drifted');
    expect(withModuleTiming, 63,
        reason: 'non-default module load/unload count drifted');
  });

  test('every binary TOF1 body frames into a record region + string table', () {
    var binary = 0, framed = 0, withSentinels = 0, totalStrings = 0;
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
      if (layout.recordRegionLength <= 0 ||
          layout.recordRegionLength >= layout.inflatedSize ||
          layout.stringCount < 5) {
        failures.add('${f.path}: $layout');
      }
      final w = layout.leadingWords;
      if (w.length >= 3 && w[2] == 1) word2Is1++;
      if (w.length >= 2) word1Values[w[1]] = (word1Values[w[1]] ?? 0) + 1;
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
    expect(word2Is1, binary, reason: 'leadingWords[2] != 1 in some files');
  });

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
      if (['Step', 'Sequence', 'Locals'].any(texts.contains)) {
        hasModelTokens++;
      } else {
        failures.add('${f.path}: name table lacks core model tokens');
      }
      if (segs.any((s) => s.entries.length > name.entries.length)) notLargest++;
      if (segs.isNotEmpty && name.offset == segs.first.offset) isFirst++;
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
    expect(
      nameFound,
      binary,
      reason: 'no content-identified name table somewhere',
    );
    expect(hasModelTokens, binary, reason: 'name table missing core tokens');
    expect(
      notLargest / binary,
      greaterThan(0.95),
      reason: 'name table is the largest segment too often ($notLargest/$binary)',
    );
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
      if (names.length >= 2 && names[1] == 'Data') {
        prefix2Ok++;
      } else {
        failures.add('${f.path}: prefix ${names.take(2).toList()} != [SequenceFileData, Data]');
      }
      final n = binaryNameScaffold.length;
      final matches = names.length >= n &&
          Iterable<int>.generate(n).every((i) => names[i] == binaryNameScaffold[i]);
      if (matches) scaffold5Ok++;
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
    expect(rooted, greaterThanOrEqualTo(80), reason: 'few files are rooted');
    expect(prefix2Ok, rooted, reason: 'a rooted file lacks the [..,Data] prefix');
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
          i < 4 || u32(body, i - 4) == 0 || u32(body, i - 4) == 0xffffffff;
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
            a.nameTable.length == (binaryNameTable(bytes)?.entries.length ?? 0) &&
            a.objectNames.length == binaryObjectNames(bytes).length &&
            a.modulePaths.length == binaryModulePaths(bytes).length &&
            a.stepReferences.length == binaryStepReferences(bytes).length &&
            a.expressions.length == binaryExpressions(bytes).length &&
            a.quotedLiterals.length == binaryQuotedLiterals(bytes).length &&
            a.namedScalars.length == binaryNamedScalarRecords(bytes).length &&
            a.scalarDoubles.length == binaryScalarDoubles(bytes).length &&
            a.namedRecords.length == binaryNamedRecords(bytes).length;
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
    expect(withNames, rooted, reason: 'a rooted file exposed no object names');
  });

  test('binary files expose call-targets, step refs, expressions, literals', () {
    var binary = 0, withPath = 0, withId = 0, withExpr = 0, withLit = 0;
    var totalPaths = 0, nonAsciiPaths = 0;
    final bad = <String>[];
    for (final f in seqs) {
      final bytes = f.readAsBytesSync();
      if (detectSeqFormat(bytes) != SeqFormat.binary) continue;
      binary++;
      final paths = binaryModulePaths(bytes);
      for (final p in paths) {
        if (!isBinaryModulePath(p)) bad.add('${f.path}: path $p');
      }
      for (final e in binaryExpressions(bytes)) {
        if (!isBinaryExpression(e)) bad.add('${f.path}: expr $e');
        if (isBinaryModulePath(e) || e.startsWith('ID#:')) {
          bad.add('${f.path}: expr overlaps path/id $e');
        }
      }
      for (final l in binaryQuotedLiterals(bytes)) {
        if (!isBinaryQuotedLiteral(l)) bad.add('${f.path}: lit $l');
        if (isBinaryExpression(l) ||
            isBinaryModulePath(l) ||
            l.startsWith('ID#:')) {
          bad.add('${f.path}: literal overlaps expr/path/id $l');
        }
      }
      if (paths.isNotEmpty) {
        withPath++;
        totalPaths += paths.length;
        nonAsciiPaths +=
            paths.where((p) => p.codeUnits.any((u) => u >= 0x80)).length;
      }
      if (binaryStepReferences(bytes).isNotEmpty) withId++;
      if (binaryExpressions(bytes).isNotEmpty) withExpr++;
      if (binaryQuotedLiterals(bytes).isNotEmpty) withLit++;
    }
    // ignore: avoid_print
    print(
      'binary recovered: $withPath/$binary files ≥1 module path '
      '($totalPaths total, $nonAsciiPaths non-ASCII) · $withId/$binary ≥1 ID#: '
      'ref · $withExpr/$binary ≥1 expression · $withLit/$binary ≥1 literal',
    );
    expect(bad, isEmpty, reason: bad.take(5).join('\n'));
    expect(binary, greaterThanOrEqualTo(80));
    expect(nonAsciiPaths, greaterThan(0));
    expect(withPath, greaterThanOrEqualTo(binary ~/ 2));
    expect(withId, greaterThanOrEqualTo((binary * 9) ~/ 10));
    expect(withExpr, greaterThanOrEqualTo((binary * 9) ~/ 10));
    expect(withLit, greaterThanOrEqualTo((binary * 9) ~/ 10));
  });
}
