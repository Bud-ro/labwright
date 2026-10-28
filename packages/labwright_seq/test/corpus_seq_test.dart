@Tags(['corpus'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:labwright_seq/labwright_seq.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

int _countOverrides(SeqProperty p, [int depth = 0]) {
  if (depth > 50) return 0;
  return p.subProps
      .followedBy(p.array ?? const <SeqProperty>[])
      .fold(p.isInstanceOverride ? 1 : 0, (n, c) => n + _countOverrides(c, depth + 1));
}

const _maxProbeBytes = 8 * 1024 * 1024;

const kXmlIniNonzero = <String, Map<String, int>>{};

const kXmlIniMismatches = <String, Map<String, int>>{};

void main() {
  final seqs =
      corpusSeqDir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.seq'))
          .where((f) => !f.path.replaceAll(r'\', '/').contains('/rosetta/'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  test('corpus has .seq files', () => expect(seqs, isNotEmpty));

  test('XML+INI corpus (single pass): typed-lens recovery counts are pinned, nothing fabricates', () {
    final tally = Tally();
    final failures = <String>[];
    var xmlCov = const SeqCoverage(total: 0, modeled: 0);
    var iniCov = const SeqCoverage(total: 0, modeled: 0);
    final arKinds = <String>{};
    final measTypes = <String>{}, measSpecs = <String>{};
    final iniFragmentKeys = <String>{};

    for (final f in seqs) {
      tally.file = corpusSeqRelativePath(f.path);
      final bytes = f.readAsBytesSync();
      final fmt = detectSeqFormat(bytes);
      if (fmt == SeqFormat.binary) {
        tally.bump('binaryFiles');
        continue;
      }
      if (fmt != SeqFormat.xml && fmt != SeqFormat.ini) {
        tally.bump('unknownFormat');
        continue;
      }

      if (fmt == SeqFormat.ini) {
        tally.bump('iniFiles');
        final doc = parseIniSeqBytes(bytes);
        if (doc.header.fileType == 'SequenceFile') tally.bump('iniSeqType');
        if (doc.sections.any((s) => s.isDef && s.members['SF'] == 'SequenceFileData')) tally.bump('iniSfRoot');
        if (doc.sections.any((s) => s.name == 'Data')) tally.bump('iniDataNamed');
        final residualRe = RegExp(r' Line\d+$');
        for (final s in doc.sections) {
          for (final k in [...s.members.keys, ...s.directives.keys]) {
            if (residualRe.hasMatch(k)) tally.bump('iniResidual');
          }
        }
        final tree = iniDataTree(doc);
        if (tree != null) {
          tally.bump('iniTreeBuilt');
          if (tree.name == 'Data') tally.bump('iniDataRoot');
          final seq = tree.subProps.where((p) => p.name == 'Seq' && p.isArray).firstOrNull;
          if (seq != null && seq.array!.isNotEmpty) {
            tally.bump('iniWithSeqArray');
            if (seq.array!.any((s) => s.name.isNotEmpty && s.name != '[0]')) tally.bump('iniNamedSeqs');
          }
        }
        final text = latin1.decode(bytes, allowInvalid: true);
        var inSection = false;
        for (final raw in const LineSplitter().convert(text)) {
          final line = raw.trimRight();
          if (line.isEmpty) continue;
          if (line.startsWith('[') && line.endsWith(']')) {
            inSection = true;
            continue;
          }
          if (inSection && !line.contains(' = ')) tally.bump('iniSkippedLines');
        }
        for (final m in RegExp(r'^(.+) Line(\d+)\s*=', multiLine: true).allMatches(text)) {
          tally.bump('iniFragments');
          iniFragmentKeys.add(m.group(1)!.trim());
        }
      }

      final SeqFile sf;
      try {
        sf = parseSeqFile(bytes);
      } on FormatException catch (e) {
        if (fmt == SeqFormat.ini) {
          tally.bump('iniThrew');
        } else {
          failures.add('${f.path}: $e');
        }
        continue;
      }

      if (fmt == SeqFormat.xml) {
        tally.bump('xmlFiles');
        final cov = measureCoverage(sf);
        xmlCov += cov;
        tally.bump('xmlUnaccounted', cov.unaccounted);
        final mp = sf.measurementPlugIns;
        if (mp != null) {
          tally.bump('mpBlocks');
          if (mp.pinMapPath != null) tally.bump('mpPinMaps');
        }
        tally.bump('typedefFiles');
        for (final t in sf.typeDefs) {
          tally.bump('totalTypes');
          if (t.fields.isNotEmpty) tally.bump('typesWithFields');
        }
      } else {
        tally.bump('iniBuilt');
        tally.bump('iniTypes', sf.types.length);
        final ovr = _countOverrides(sf.data);
        tally.bump('overrides', ovr);
        if (ovr > 0) tally.bump('filesWithOverride');
        if (bytes.length <= _maxProbeBytes) {
          tally.bump('iniCovFiles');
          final cov = measureCoverage(sf);
          iniCov += cov;
          tally.bump('iniUnaccounted', cov.unaccounted);
        }
      }

      if (sf.modelFile != null || sf.contentVersion != null || sf.fileTypeCode != null) tally.bump('fileSettings');
      if (sf.fileGlobals.isNotEmpty) tally.bump('fileGlobals');

      var arAny = false;
      var fileJump = false, fileLoop = false, fileExternal = false, fileParams = false;
      for (final q in sf.sequences) {
        if (q.runtimeSettings?.entryPointNameExpression != null) tally.bump('runtimeEP');
        if (fmt == SeqFormat.xml) {
          tally.bump('xmlSeqs');
          tally.bump('xmlLocals', q.locals.length);
        } else {
          tally.bump('iniSeqCount');
          tally.bump('iniLocals', q.locals.length);
          if (q.comment != null) tally.bump('seqComments');
          for (final v in [...q.locals, ...q.parameters]) {
            if (!v.isArray && v.containerCount != null && v.containerCount! > 0) tally.bump('objVarsWithFields');
            if (v.comment != null) tally.bump('varComments');
          }
        }
        if (q.parameters.isNotEmpty) {
          fileParams = true;
          for (final p in q.parameters) {
            tally.bump('sigParams');
            if (p.type != null) tally.bump('sigTyped');
          }
        }

        var depth = 0, minDepth = 0, localFlow = 0;
        for (final step in q.steps) {
          final set = step.settings;
          final m = step.module;

          if (fmt == SeqFormat.xml) {
            tally.bump('xmlSteps');
            if (step.type != null) tally.bump('typedSteps');
            if (set.passAction != null) tally.bump('withAction');
            if (set.mode != null) tally.bump('withMode');
            if (set.icon != null) tally.bump('withIcon');
            if (m.adapter == SeqAdapter.unknown) tally.bump('unknownAdapters');
            if (m.adapter != SeqAdapter.none && m.adapter != SeqAdapter.unknown) tally.bump('withModule');
            if (step.limits != null) tally.bump('withLimits');
            if (sf.resolveCall(step) != null) tally.bump('resolvedCalls');

            if (m.adapter == SeqAdapter.python) {
              tally.bump('pySteps');
              if (m.pythonFunction != null) tally.bump('pyFn');
              if (m.pythonModulePath != null) tally.bump('pyModule');
              if (m.pythonVersion != null) tally.bump('pyVersion');
              final args = m.callParameters;
              if (args.isNotEmpty) {
                tally.bump('pyParamSteps');
                for (final a in args) {
                  tally.bump('pyParams');
                  if (a.name.isNotEmpty) tally.bump('pyNamed');
                  if (a.boundExpression != null) tally.bump('pyBound');
                }
              }
            }
            if (m.adapter == SeqAdapter.labView && m.viParameters.isNotEmpty) {
              tally.bump('viSteps');
              for (final p in m.viParameters) {
                tally.bump('viParams');
                if (p.displayType != null) tally.bump('viDisplayType');
                if (p.connectorNumber != null) tally.bump('viConnector');
              }
            }
            for (final a in step.additionalResults) {
              arAny = true;
              tally.bump('arEntries');
              if (a.kind != null) arKinds.add(a.kind!);
            }
            final r = step.result;
            if (r != null) {
              tally.bump('withResult');
              if (r.errorOccurred != null) tally.bump('withError');
              if (r.hasRecordedOutcome) tally.bump('recordedOutcomes');
            }
            if (set.customTrueAction != null) tally.bump('custTrueAct');
            if (set.customFalseAction != null) tally.bump('custFalseAct');
            for (final p in step.measurementParameters) {
              tally.bump('measParams');
              if (p.dataType != null) {
                tally.bump('measTyped');
                measTypes.add(p.dataType!);
              }
              if (p.direction != null) tally.bump('measDirected');
              if (p.typeSpecialization != null) {
                tally.bump('measSpecialized');
                measSpecs.add(p.typeSpecialization!);
              }
              if (p.logged == false) tally.bump('measNotLogged');
              if (p.dataType == 'TypeEnum') {
                tally.bump('measEnumParams');
                tally.bump('measEnumValues', p.enumValues.length);
              }
            }
          } else {
            tally.bump('iniStepCount');
            if (step.type != null) tally.bump('iniWithType');
            tally.bump('iniAdapters');
            switch (m.adapter) {
              case SeqAdapter.none:
                tally.bump('iniNone');
              case SeqAdapter.unknown:
                tally.bump('iniUnknown');
              default:
                tally.bump('iniRecognized');
            }
            if (set.mode != null) tally.bump('iniWithMode');
            if (set.loopType != null) tally.bump('iniWithLoop');
            if (step.comment != null) tally.bump('stepComments');
            if (set.passActionTarget != null || set.failActionTarget != null) tally.bump('withFlowTarget');
            for (final t in [set.customTrueTarget, set.customFalseTarget]) {
              if (t != null && t.startsWith('ID#:') && sf.stepNameForId(t) != null) tally.bump('resolvedIdTargets');
            }
            final lo = set.loadOption, uo = set.unloadOption;
            if ((lo != null && lo != 'PreloadWhenExecuted') || (uo != null && uo != 'UnloadWithFile')) {
              tally.bump('withModuleTiming');
            }
            if (bytes.length <= _maxProbeBytes) {
              tally.bump('iniCovSteps');
              if (m.adapter != SeqAdapter.none) tally.bump('iniCovModule');
            }
          }

          if (set.adapterName != null) tally.bump('adapterName');
          if (set.switchEnabled != null || set.canEditCode != null) tally.bump('switchSettings');
          if (step.description != null) tally.bump('stepDesc');
          if (step.typeInfo.codeTemplates.isNotEmpty) tally.bump('codeTemplates');
          if (m.sequenceNameExpression != null || m.specifiesByExpression != null) tally.bump('seqCallExpr');
          if (m.threadOptionCode != null) tally.bump('threading');
          if (m.pythonInterpreterLocation != null || m.pythonOperationTypeCode != null) tally.bump('pyInterp');
          for (final p in [...m.viParameters, ...m.callParameters]) {
            if (p.caption != null || p.typeCode != null) tally.bump('clusterEls');
          }
          if (step.sqlStatement != null || step.statementHandle != null) tally.bump('dbStep');
          if (step.limits?.lowExpression != null || step.limits?.comparisonExpression != null) tally.bump('limitExpr');

          final fc = step.flowControl;
          if (fc != null) {
            localFlow++;
            if (fc.kind.opensBlock) {
              tally.bump('flowOpeners');
              depth++;
            } else if (fc.kind == FlowKind.end) {
              tally.bump('flowEnds');
              depth--;
              if (depth < minDepth) minDepth = depth;
            }
            switch (fc.kind) {
              case FlowKind.ifBlock:
              case FlowKind.elseIf:
              case FlowKind.whileLoop:
                tally.bump('ifWhile');
                tally.bump('condLoops');
                if (fc.condition != null) tally.bump('conds');
              case FlowKind.forLoop:
                tally.bump('forLoops');
                tally.bump('condLoops');
                if (fc.initialization != null) tally.bump('forInit');
                if (fc.condition != null) tally.bump('conds');
                if (fc.increment != null) tally.bump('forIncr');
              case FlowKind.forEach:
                tally.bump('eachLoops');
                if (fc.arrayExpr != null) tally.bump('eachArr');
                if (fc.arrayElement != null) tally.bump('eachElem');
              default:
                break;
            }
          }
          if ((set.passAction != null && set.passAction != 'Next') ||
              (set.failAction != null && set.failAction != 'Next')) {
            tally.bump('jumpSteps');
            fileJump = true;
          }
          if (fc == null && set.isLooping) {
            tally.bump('loopSteps');
            fileLoop = true;
          }
          if (m.adapter == SeqAdapter.sequenceCall &&
              sf.resolveCall(step) == null &&
              (m.sequenceFile ?? '').isNotEmpty) {
            tally.bump('externalCalls');
            fileExternal = true;
          }
        }
        if (localFlow > 0) {
          tally.bump('totalFlowSeqs');
          tally.bump('seqsWithFlow');
          if (depth == 0 && minDepth == 0) tally.bump('balancedSeqs');
        }
      }
      if (arAny) tally.bump('arFiles');

      if (fileJump || fileLoop || fileExternal || fileParams) {
        final logic = exportSequenceLogic(sf);
        if (fileJump) {
          tally.bump('filesWithJump');
          if (logic.contains(RegExp(r'\[on (pass|fail)'))) tally.bump('exportsWithJump');
        }
        if (fileLoop) {
          tally.bump('filesWithLoop');
          if (logic.contains('[loop ')) tally.bump('exportsWithLoop');
        }
        if (fileExternal) {
          tally.bump('filesWithExternal');
          if (logic.contains(RegExp(r' in \S+\.seq'))) tally.bump('exportsMarked');
        }
        if (fileParams) {
          tally.bump('filesWithParams');
          if (logic.contains(RegExp(r'^sequence .+\([^)]', multiLine: true))) tally.bump('exportsSigned');
        }
      }
    }

    print(
      'teststand corpus: ${tally['xmlFiles']} XML / ${tally['iniFiles']} INI / ${tally['binaryFiles']} binary · '
      '${tally['xmlSeqs']}+${tally['iniSeqCount']} sequences · ${tally['xmlSteps']}+${tally['iniStepCount']} steps · '
      'XML modeled ${(xmlCov.ratio * 100).toStringAsFixed(1)}% · INI modeled ${(iniCov.ratio * 100).toStringAsFixed(1)}% · '
      '${tally['overrides']} overrides in ${tally['filesWithOverride']} files · '
      '${tally['iniFragments']} INI fragments / ${iniFragmentKeys.length} keys',
    );
    expect(failures, isEmpty, reason: failures.take(5).join('\n'));

    expect(arKinds, everyElement(anyOf(contains('ParameterResult'), isNotEmpty)));
    expect(measTypes, contains('TypeDouble'));
    expect(measSpecs, contains('IOResource'));
    for (final key in const [
      'unknownFormat',
      'unknownAdapters',
      'xmlUnaccounted',
      'recordedOutcomes',
      'iniSkippedLines',
      'iniResidual',
      'iniThrew',
      'iniUnknown',
      'iniUnaccounted',
    ]) {
      expect(tally.nonzero(key), kXmlIniNonzero[key] ?? const <String, int>{}, reason: key);
    }
    for (final (a, b) in const [
      ('typedSteps', 'xmlSteps'),
      ('pyFn', 'pySteps'),
      ('pyModule', 'pySteps'),
      ('pyVersion', 'pySteps'),
      ('pyNamed', 'pyParams'),
      ('viDisplayType', 'viParams'),
      ('viConnector', 'viParams'),
      ('withError', 'withResult'),
      ('measTyped', 'measParams'),
      ('flowEnds', 'flowOpeners'),
      ('balancedSeqs', 'totalFlowSeqs'),
      ('forInit', 'forLoops'),
      ('forIncr', 'forLoops'),
      ('eachArr', 'eachLoops'),
      ('eachElem', 'eachLoops'),
      ('exportsWithJump', 'filesWithJump'),
      ('exportsWithLoop', 'filesWithLoop'),
      ('exportsMarked', 'filesWithExternal'),
      ('sigTyped', 'sigParams'),
      ('exportsSigned', 'filesWithParams'),
      ('iniSeqType', 'iniFiles'),
      ('iniSfRoot', 'iniFiles'),
      ('iniDataNamed', 'iniFiles'),
      ('iniTreeBuilt', 'iniFiles'),
      ('iniDataRoot', 'iniTreeBuilt'),
      ('iniWithSeqArray', 'iniTreeBuilt'),
      ('iniNamedSeqs', 'iniWithSeqArray'),
      ('iniBuilt', 'iniFiles'),
    ]) {
      expect(tally.mismatches(a, b), kXmlIniMismatches['$a/$b'] ?? const <String, int>{}, reason: '$a == $b');
    }
    expect(tally.mismatches('conds', 'condLoops'), const <String, int>{}, reason: 'if/while/for conditions');
    expect(tally.mismatches('iniAdapters', 'iniStepCount'), const <String, int>{}, reason: 'INI adapter partition');
  });

  test('binary corpus (single pass): the lifted model carries the same lenses as XML', () {
    final tally = Tally();
    final failures = <String>[];
    var coverage = const SeqCoverage(total: 0, modeled: 0);

    for (final f in seqs) {
      tally.file = corpusSeqRelativePath(f.path);
      final bytes = f.readAsBytesSync();
      if (detectSeqFormat(bytes) != SeqFormat.binary) continue;
      tally.bump('binary');

      final file = parseSeqFile(bytes);
      expect(file.binary, isNotNull, reason: f.path);
      if (file.sequences.isNotEmpty) tally.bump('binaryWithSequences');
      final typeNames = {for (final t in file.types) t.name};
      for (final seq in file.sequences) {
        expect(seq.name, isNotEmpty);
        tally.bump('binaryStepsRecovered', seq.steps.length);
        for (final step in seq.steps) {
          if (step.type != null) {
            tally.bump('binaryTypedSteps');
            expect(typeNames, contains(step.type), reason: '${f.path}: step ${step.name} type outside the table');
          }
          final m = step.module;
          if (m.adapter != SeqAdapter.none && m.adapter != SeqAdapter.unknown) {
            tally.bump('binaryModuleSteps');
            if (m.viPath != null) {
              expect(m.viPath, contains('.vi'), reason: '${f.path}: ${step.name} VIPath ${m.viPath}');
            }
            if (m.pythonModulePath != null) {
              expect(m.pythonModulePath, endsWith('.py'), reason: '${f.path}: ${step.name} python module');
            }
          }
          if (step.flowControl != null) tally.bump('binaryFlowSteps');
        }
      }
      coverage = coverage + measureCoverage(file);
      final bh = detectSeqHeader(bytes);
      expect(bh.fileType, 'SequenceFile');
      expect(bh.productName, 'TestStand');
      expect(bh.fileVersion, isNotNull);

      final analysis = analyzeBinary(bytes);
      if (analysis == null || !analysis.grammarApplies) {
        failures.add('${f.path}: grammar does not apply');
        continue;
      }
      tally.bump('framed');
      final paths = analysis.modulePaths;
      for (final p in paths) {
        if (!isBinaryModulePath(p)) failures.add('${f.path}: path $p');
      }
      for (final e in analysis.expressions) {
        if (!isBinaryExpression(e)) failures.add('${f.path}: expr $e');
        if (isBinaryModulePath(e) || e.startsWith('ID#:')) failures.add('${f.path}: expr overlaps path/id $e');
      }
      for (final l in analysis.quotedLiterals) {
        if (!isBinaryQuotedLiteral(l)) failures.add('${f.path}: lit $l');
        if (isBinaryExpression(l) || isBinaryModulePath(l) || l.startsWith('ID#:')) {
          failures.add('${f.path}: literal overlaps expr/path/id $l');
        }
      }
      if (paths.isNotEmpty) {
        tally.bump('withPath');
        tally.bump('totalPaths', paths.length);
        tally.bump('nonAsciiPaths', paths.where((p) => p.codeUnits.any((u) => u >= 0x80)).length);
      }
      final stepNames = {
        for (final seq in file.sequences)
          for (final step in seq.steps) step.name,
      };
      if (!analysis.objectNames.toSet().containsAll(stepNames)) failures.add('${f.path}: object names miss steps');
    }

    print(
      'binary corpus: ${tally['binary']} binaries · ${tally['binaryWithSequences']} with sequences · '
      '${tally['binaryStepsRecovered']} steps (${tally['binaryTypedSteps']} typed, '
      '${tally['binaryModuleSteps']} with modules, ${tally['binaryFlowSteps']} flow control) · '
      'model coverage ${(coverage.ratio * 100).toStringAsFixed(1)}% · '
      '${tally['withPath']} with paths (${tally['totalPaths']}, ${tally['nonAsciiPaths']} non-ASCII)',
    );
    expect(failures, isEmpty, reason: failures.take(8).join('\n'));
    expect(tally['binaryWithSequences'], tally['binary'], reason: 'every binary lifts its sequences');
    expect(tally['framed'], tally['binary']);
    expect(tally['binaryTypedSteps'], tally['binaryStepsRecovered'], reason: 'every binary step names its type');
    expect(coverage.ratio, greaterThan(0.3));
  });
  group('pinned corpus files (reader correctness)', () {
    File? pin(String suffix) => seqs.where((f) => f.path.replaceAll(r'\', '/').endsWith(suffix)).firstOrNull;

    void collectIndexed(SeqProperty p, List<SeqProperty> out, [int depth = 0]) {
      if (depth > 60) return;
      if (p.attributes.containsKey('arrayindex')) out.add(p);
      for (final c in p.subProps.followedBy(p.array ?? const <SeqProperty>[])) {
        collectIndexed(c, out, depth + 1);
      }
    }

    test('64BitIntegersDLL.seq: sparse XML arrays keep their true arrayindex', () {
      final f = pin('Media/64BitSupport/64BitIntegersDLL.seq');
      if (f == null) return;
      final sf = parseSeqFile(f.readAsBytesSync());
      final indexed = <SeqProperty>[];
      collectIndexed(sf.data, indexed);
      for (final t in sf.types) {
        collectIndexed(t, indexed);
      }
      expect(indexed.where((p) => p.attributes['arrayindex'] == '[1]'), isNotEmpty);
    });

    test('DBSeq.seq: nonzero %LO low bounds yield hi - lo + 1 declared lengths', () {
      final f = pin('michael-harhay-arx-CICDUtility-02c6c67/DBLog/DBSeq.seq');
      if (f == null) return;
      final sf = parseSeqFile(f.readAsBytesSync());
      final sparse = <SeqProperty>[];
      void walk(SeqProperty p, [int depth = 0]) {
        if (depth > 60) return;
        if (p.name == 'ColumnList' && p.lowIndices?.firstOrNull == 1) sparse.add(p);
        for (final c in p.subProps.followedBy(p.array ?? const <SeqProperty>[])) {
          walk(c, depth + 1);
        }
      }

      walk(sf.data);
      expect(sparse, isNotEmpty, reason: 'file declares %LO: ColumnList = [1]');
      for (final p in sparse) {
        expect(p.declaredArrayLength, p.highIndices!.single - 1 + 1);
      }
      expect(sparse.map((p) => p.declaredArrayLength), contains(2), reason: '%LO [1] with %HI [2] is 2 elements');
    });

    test('testXNode.seq: EXTDATA sections classify apart from the data tree', () {
      final f = pin('Media/XNode/testXNode.seq');
      if (f == null) return;
      final doc = parseIniSeqBytes(f.readAsBytesSync());
      final ext = doc.extDataSections.toList();
      expect(ext, hasLength(12));
      expect(ext.map((s) => s.extDataKind).toSet(), {'STRUCT', 'CLUST', 'DNSTRUCT'});
      expect(ext.map((s) => s.path).toSet(), {'Error', 'Error.Code', 'Error.Msg', 'Error.Occurred'});
      expect(ext.every((s) => s.path.isNotEmpty && !s.path.contains(',')), isTrue);
      expect(iniDataTree(doc), isNotNull, reason: 'the data tree still assembles without EXTDATA pseudo-members');
    });

    test('TestIVIPowerSupplyReferences.seq: split [__Header__] Path reassembles', () {
      final f = pin('IVIPowerSupply/TestIVIPowerSupplyReferences.seq');
      if (f == null) return;
      final doc = parseIniSeqBytes(f.readAsBytesSync());
      expect(doc.headerFields.keys.any((k) => RegExp(r' Line\d+$').hasMatch(k)), isFalse);
      expect(doc.headerFields['Path'], endsWith(r'TestIVIPowerSupplyReferences.seq"'));
    });
  });
}
