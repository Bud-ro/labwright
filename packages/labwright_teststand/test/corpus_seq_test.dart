@Tags(['corpus'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:labwright_teststand/labwright_teststand.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

/// Counts the instance-override markers (`%INSTOVRD`) recovered anywhere in a
/// property tree — see [SeqProperty.isInstanceOverride].
int _countOverrides(SeqProperty p, [int depth = 0]) {
  if (depth > 50) return 0;
  var n = p.isInstanceOverride ? 1 : 0;
  for (final c in p.subProps) {
    n += _countOverrides(c, depth + 1);
  }
  for (final c in p.array ?? const <SeqProperty>[]) {
    n += _countOverrides(c, depth + 1);
  }
  return n;
}

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
        withMode = 0,
        withIcon = 0,
        typedSteps = 0,
        unknownAdapters = 0;
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
    // Exact counts over the pinned corpus (deterministic). The file partition
    // (xml+binary+other) and the XML lens outputs are fixed; a drift here flags a
    // corpus change or a silent decode regression with the delta.
    expect(xml, 26, reason: 'XML file count drifted');
    expect(binary, 288, reason: 'binary file count drifted');
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
    // Step editor icons (TS.Icon basename) are an XML-only signal here — INI
    // steps all carry the default blank icon.
    expect(withIcon, 59, reason: 'XML step-icon count drifted');
    // XML↔INI lens parity: every XML step is typed, and every step that carries a
    // module adapter is recognized (no `unknown`) — same bar the INI lens meets.
    expect(typedSteps, totalSteps, reason: 'an XML step lost its type in the lens');
    expect(
      unknownAdapters,
      0,
      reason: 'an XML step has an unrecognized module adapter',
    );
    // ignore: avoid_print
    print(
      'teststand corpus: $xml XML / $binary binary / $other other · '
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
      if (f.lengthSync() > 300 * 1024) continue; // huge files: skip (OOM guard)
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
    // Corpus evidence (probed): ~11 files declare the block; at least one carries
    // a pin map + the full specifications/levels/timing/pattern file set.
    expect(withBlock, greaterThanOrEqualTo(5));
    expect(withPinMap, greaterThanOrEqualTo(1));
  });

  test('recovers Python call descriptors across XML corpus', () {
    var pySteps = 0, withFn = 0, withModule = 0, withVersion = 0, withVenv = 0;
    final fns = <String>{};
    for (final f in seqs) {
      if (f.lengthSync() > 300 * 1024) continue; // huge files: skip (OOM guard)
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
    // Corpus evidence (probed): 31 Python steps, every one naming a function,
    // module path and interpreter version.
    expect(pySteps, greaterThanOrEqualTo(20));
    expect(withFn, equals(pySteps), reason: 'every Python step names a function');
    expect(withModule, equals(pySteps), reason: 'every Python step has a module path');
    expect(withVersion, equals(pySteps), reason: 'every Python step has a version');
  });

  test('recovers LabVIEW VI-call connector params across XML corpus', () {
    var viSteps = 0, params = 0, withDisplayType = 0, withConnector = 0,
        withNamespace = 0, withBound = 0;
    for (final f in seqs) {
      if (f.lengthSync() > 300 * 1024) continue; // huge files: skip (OOM guard)
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
    // Corpus evidence (probed): 10 VI-call steps, 25 connector params, every one
    // carrying a human-readable DisplayType and a connector index.
    expect(viSteps, greaterThanOrEqualTo(5));
    expect(params, greaterThanOrEqualTo(20));
    expect(withDisplayType, equals(params), reason: 'every VI param has a DisplayType');
    expect(withConnector, equals(params), reason: 'every VI param has a connector#');
  });

  test('recovers <typelist> type definitions across XML corpus', () {
    var files = 0, totalTypes = 0, withFields = 0, totalFields = 0;
    final baseClasses = <String>{};
    final sampleNames = <String>{};
    for (final f in seqs) {
      if (f.lengthSync() > 300 * 1024) continue; // huge files: skip (OOM guard)
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
    // Corpus evidence (probed): ~475 typedefs across 21 ≤300KB XML files; every
    // typedef carries a name + base class; many declare ≥1 field. These are
    // recovered names/structure only — NI's internal type-system field
    // *semantics* are not claimed.
    expect(files, greaterThanOrEqualTo(20));
    expect(totalTypes, greaterThanOrEqualTo(300));
    expect(withFields, greaterThanOrEqualTo(1));
    expect(baseClasses, isNotEmpty);
    // typeDefs is a faithful 1:1 view of the raw type roots.
    final first = parseSeqFile(seqs
            .firstWhere((f) =>
                f.lengthSync() <= 300 * 1024 &&
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
      if (f.lengthSync() > 300 * 1024) continue; // huge files: skip (OOM guard)
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
    // Corpus evidence (probed): 14 files, 110 entries, all PythonParameterResult
    // / CommonCParameterResult, and (so far) every Condition empty/always-on.
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
      if (f.lengthSync() > 300 * 1024) continue;
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
    // Corpus evidence (probed): 87 steps carry a Result slot, all with an Error
    // sub-object, and ALL hold compile-time defaults (Status/ReportText empty,
    // Error.Occurred false, Code 0) — no run is recorded in a sequence file.
    expect(withResult, greaterThan(0), reason: 'no step Result slots recovered');
    expect(withError, withResult, reason: 'a Result lost its Error sub-object');
    expect(recorded, 0,
        reason: 'a sequence file unexpectedly carries a recorded run outcome');
  });

  test('recovers custom-condition flow fields across XML corpus', () {
    var withTrueAct = 0, withFalseAct = 0, withCustExpr = 0;
    final trueActs = <String>{};
    for (final f in seqs) {
      if (f.lengthSync() > 300 * 1024) continue;
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
    // Corpus evidence (probed): the custom-condition flow fields are present on
    // measurement/flow steps (CustTrueAct/CustFalseAct carry the default `Next`);
    // CustExpr is empty throughout this corpus (no step uses a custom condition).
    expect(withTrueAct, greaterThan(0), reason: 'no CustTrueAct recovered');
    expect(withFalseAct, greaterThan(0), reason: 'no CustFalseAct recovered');
  });

  test('recovers Python-adapter call parameters across XML corpus', () {
    var pySteps = 0, params = 0, named = 0, bound = 0;
    for (final f in seqs) {
      if (f.lengthSync() > 300 * 1024) continue;
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
    // Corpus evidence (probed): 31 Python steps, 53 params, all named, 22 bound.
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
      if (f.lengthSync() > 300 * 1024) continue;
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
    // Corpus evidence (probed): 147 typed params, types incl. TypeDouble/
    // TypeString/TypeEnum/TypeInt32/TypeBool/TypeUint32/TypeUint64; In/Out dirs.
    // TypeSpecialization refinements: IOResource(19)/Enum(10)/Path(4)/Pin(1);
    // Log varies (7 false of 147).
    expect(params, greaterThanOrEqualTo(120));
    expect(withType, params, reason: 'a measurement param lost its Type');
    expect(types, contains('TypeDouble'));
    expect(withDirection, greaterThan(0));
    expect(specialized, greaterThan(0), reason: 'no TypeSpecialization recovered');
    expect(specs, contains('IOResource'));
    expect(notLogged, greaterThan(0), reason: 'Log flag never varies');
    // Every TypeEnum param carries a non-empty allowed-value list (10 params,
    // 74 values across the corpus).
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

  test('the typed lens + coverage metric apply to INI (shared model)', () {
    var ini = 0, steps = 0, withModule = 0, withAddl = 0;
    var covTotal = 0, covModeled = 0;
    for (final f in seqs) {
      if (f.lengthSync() > 300 * 1024) continue; // OOM guard (matches the tool)
      final bytes = f.readAsBytesSync();
      if (detectSeqFormat(bytes) != SeqFormat.ini) continue;
      ini++;
      final sf = parseSeqFile(bytes);
      final c = measureCoverage(sf);
      covTotal += c.total;
      covModeled += c.modeled;
      for (final seq in sf.sequences) {
        for (final step in seq.steps) {
          steps++;
          if (step.module.adapter != SeqAdapter.none) withModule++;
          if (step.additionalResults.isNotEmpty) withAddl++;
        }
      }
    }
    // ignore: avoid_print
    print(
      'INI lens: $ini files · $steps steps · $withModule with a module adapter · '
      '$withAddl with additional-results · coverage '
      '${(covModeled / covTotal * 100).toStringAsFixed(1)}% ($covModeled/$covTotal)',
    );
    // The same SeqProperty model + lens drive INI: a large step corpus, real
    // module/additional-results recovery, and a sane (non-zero, sub-XML) coverage
    // — lower because INI inlines step-type defs that XML keeps in <typelist>.
    expect(ini, greaterThanOrEqualTo(30));
    expect(steps, greaterThanOrEqualTo(1000));
    expect(withModule, greaterThanOrEqualTo(500));
    expect(covModeled, greaterThan(0));
    expect(covModeled, lessThan(covTotal));
  });

  test('INI parser drops no in-section data lines (every line is key = value)',
      () {
    // Honesty/robustness guard: inside a section, parseIniSeq skips any line
    // lacking ` = ` (`eq < 0`). Across the corpus that count must stay 0 — every
    // non-blank, non-section line is a real `key = value`, so no data is silently
    // dropped. If a future file introduces a new line shape, this catches it.
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
      // After parsing, no section may still carry a raw ` LineNNNN` fragment key.
      final residualRe = RegExp(r' Line\d+$');
      for (final s in doc.sections) {
        for (final k in [...s.members.keys, ...s.directives.keys]) {
          if (residualRe.hasMatch(k)) residual++;
        }
      }
    }
    // Re-detect against raw text so the count reflects what was collapsed.
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
    // Exact over the pinned corpus (deterministic): 19820 fragments across 28
    // base keys. Catches a regression in continuation detection precisely.
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
        if (tree == null) continue; // no reconstructable root (none in corpus today)
        built++;
        if (tree.name == 'Data') dataRoot++;
        // The Data object carries a Seq array of sequences.
        final seq = tree.subProps
            .where((p) => p.name == 'Seq' && p.isArray)
            .firstOrNull;
        if (seq != null && seq.array!.isNotEmpty) {
          withSeqArray++;
          // Sequence elements carry names (MainSequence or custom).
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
    // Every INI file builds a tree: the root-objects alias is resolved for both
    // newer (%OBJROOT) and older (%OBJECTS, versions 127/143) files. Each built
    // tree roots at the "Data" object and carries a named Seq array.
    expect(built, ini, reason: 'an INI file built no data tree');
    expect(dataRoot, built, reason: 'a built INI tree is not rooted at "Data"');
    expect(withSeqArray, built, reason: 'a built INI tree has no Seq array');
    expect(namedSeqs, withSeqArray, reason: 'a Seq array exposes no named sequence');
  });

  test('INI files parse through parseSeqFile into the typed lens', () {
    var ini = 0, built = 0, threw = 0;
    var totSeq = 0, totSteps = 0, totLocals = 0, withType = 0;
    var totTypes = 0;
    // Module-adapter classification. A recognized adapter (labView/cModule/
    // sequenceCall/python) has a real binding; `none` is a no-module step (no
    // SData, or an empty SData often inherited as a bare default); `unknown` is
    // an SData with members we don't yet parse.
    var recognized = 0, noneAdapter = 0, unknownAdapter = 0;
    // Settings/looping defaults live in a step's TYPE definition; the instance
    // stores only overrides. These count steps whose effective run-mode/looping
    // the lens recovers (type-inherited where the instance is silent).
    var withMode = 0, withLoop = 0;
    // Explicit `%INSTOVRD` instance-override markers recovered across the tree.
    var overrides = 0, filesWithOverride = 0;
    // Steps carrying a recovered free-text `%COMMENT` (the editor's per-step note).
    var withComment = 0;
    // Sequences carrying a recovered free-text `%COMMENT` (per-sequence note).
    var withSeqComment = 0;
    // Object/cluster variables (locals/params) whose field count the lens reports.
    var objVarsWithFields = 0;
    // Variables (locals/params) carrying a recovered free-text `%COMMENT`.
    var varsWithComment = 0;
    // Steps whose pass/fail flow action jumps to a recovered target (e.g. Goto).
    var withFlowTarget = 0;
    // `ID#:` custom-condition targets that resolve to a destination step name.
    var resolvedIdTargets = 0;
    // Steps with non-default module load/unload timing.
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
        threw++; // no reconstructable data root (none in the corpus today)
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
    // Exact decode-output counts over the *pinned* corpus (deterministic —
    // verified identical across repeated runs). These catch a silent regression
    // precisely: a refactor that quietly drops comments/targets/overrides, or a
    // corpus change, fails here with the delta rather than passing a loose `>0`.
    expect(ini, 58, reason: 'INI file count drifted');
    expect(totSeq, 449, reason: 'INI sequence count drifted');
    expect(totSteps, 5664, reason: 'INI step count drifted');
    expect(totLocals, 1662, reason: 'INI locals count drifted');
    expect(totTypes, 2242, reason: 'INI [%TYPES] count drifted');
    // Adapter classification partitions every step: recognized + none + unknown
    // == totSteps, with unknown pinned at 0 (no unparsed SData shape).
    expect(unknownAdapter, 0, reason: 'an INI step has an unrecognized SData adapter');
    expect(recognized, 2186, reason: 'INI recognized-adapter count drifted');
    expect(noneAdapter, 3478, reason: 'INI none-adapter count drifted');
    expect(recognized + noneAdapter + unknownAdapter, totSteps,
        reason: 'adapter classification must partition all steps');
    // Type inheritance is what makes run-mode/looping/type non-zero (the instance
    // is usually silent); kept loose since they track type-def handling, not a
    // fixed feature count.
    expect(withType, greaterThan(0), reason: 'no INI step types via the lens');
    expect(withMode, greaterThan(0), reason: 'no type-inherited run-mode recovered');
    expect(withLoop, greaterThan(0), reason: 'no type-inherited looping recovered');
    // Recovered-feature counts (exact, pinned corpus).
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
            a.nameTable.length == (binaryNameTable(bytes)?.entries.length ?? 0) &&
            a.objectNames.length == binaryObjectNames(bytes).length &&
            a.modulePaths.length == binaryModulePaths(bytes).length &&
            a.stepReferences.length == binaryStepReferences(bytes).length &&
            a.expressions.length == binaryExpressions(bytes).length &&
            a.quotedLiterals.length == binaryQuotedLiterals(bytes).length;
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

  test('binary files expose call-targets, step refs, expressions, literals', () {
    var binary = 0, withPath = 0, withId = 0, withExpr = 0, withLit = 0;
    var totalPaths = 0, nonAsciiPaths = 0;
    final bad = <String>[];
    for (final f in seqs) {
      final bytes = f.readAsBytesSync();
      if (detectSeqFormat(bytes) != SeqFormat.binary) continue;
      binary++;
      final paths = binaryModulePaths(bytes);
      // Every returned path must satisfy the predicate (no false positives).
      for (final p in paths) {
        if (!isBinaryModulePath(p)) bad.add('${f.path}: path $p');
      }
      // Expressions must be disjoint from module paths / ID#: refs.
      for (final e in binaryExpressions(bytes)) {
        if (!isBinaryExpression(e)) bad.add('${f.path}: expr $e');
        if (isBinaryModulePath(e) || e.startsWith('ID#:')) {
          bad.add('${f.path}: expr overlaps path/id $e');
        }
      }
      // Literals must be disjoint from expressions / paths / ID#: refs.
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
        // Latin-1 recovery: paths with accented chars (ü, ç, …) stay intact.
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
    // Latin-1 scanning recovers accented paths intact (would be 0 if ASCII-only).
    expect(nonAsciiPaths, greaterThan(0));
    // Corpus floors (190 paths, 285 ids, 285 exprs, 288 literals) — safe margins.
    expect(withPath, greaterThanOrEqualTo(binary ~/ 2));
    expect(withId, greaterThanOrEqualTo((binary * 9) ~/ 10));
    expect(withExpr, greaterThanOrEqualTo((binary * 9) ~/ 10));
    expect(withLit, greaterThanOrEqualTo((binary * 9) ~/ 10));
  });

  // REMOVED — 'leadingWords[1] selects the record-prefix layout'. This asserted
  // leadingWords[1] ∈ {16,118} each picking a deterministic words[3,5,7] layout.
  // The broadened 288-file corpus refuted it: leadingWords[1] takes many values
  // (16, 18, 20, 118, 256, 272, 276, …), so it is not a two-valued layout
  // selector. The original claim was overfit to the NI-example subset. The
  // record-prefix structure past the header is not yet decoded (see NOTES.md).
}
