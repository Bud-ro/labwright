@Tags(['corpus'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:labwright_seq/labwright_seq.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';
import 'snapshot_check.dart';

int _countOverrides(SeqProperty p, [int depth = 0]) {
  if (depth > 50) return 0;
  return p.subProps
      .followedBy(p.array ?? const <SeqProperty>[])
      .fold(p.isInstanceOverride ? 1 : 0, (n, c) => n + _countOverrides(c, depth + 1));
}

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

const _maxProbeBytes = 8 * 1024 * 1024;

bool _isExprLike(String s) =>
    (s.contains('.') && RegExp(r'[A-Za-z]\.[A-Za-z]').hasMatch(s)) ||
    s.contains('(') ||
    s.contains(')') ||
    s.contains('"') ||
    (RegExp(r'[+\-*/=<>!]').hasMatch(s) && RegExp(r'[A-Za-z0-9]').hasMatch(s));

final _binaryReconCounters =
    'binary binaryWithSequences binaryStepsRecovered binaryTypedSteps binaryModuleSteps withSentinels '
            'totalStrings notLargest isFirst rooted scaffold5Ok realTot realHit fakeTot fakeHit withPath totalPaths '
            'nonAsciiPaths withId withExpr withLit'
        .split(' ');

final _xmlIniCounters =
    'xmlFiles iniFiles binaryFiles xmlSeqs xmlSteps withAction withMode withModule xmlLocals withLimits '
            'resolvedCalls withIcon mpBlocks mpPinMaps pySteps pyParams pyParamSteps pyBound viSteps viParams '
            'typedefFiles totalTypes typesWithFields arFiles arEntries withResult custTrueAct custFalseAct measParams '
            'measDirected measSpecialized measNotLogged measEnumParams measEnumValues flowOpeners ifWhile forLoops '
            'eachLoops seqsWithFlow jumpSteps filesWithJump loopSteps filesWithLoop externalCalls filesWithExternal '
            'sigParams filesWithParams adapterName stepDesc codeTemplates runtimeEP switchSettings seqCallExpr threading '
            'pyInterp clusterEls dbStep limitExpr fileSettings fileGlobals iniFragments iniSeqCount iniStepCount '
            'iniLocals iniTypes iniRecognized iniNone iniWithType iniWithMode iniWithLoop overrides filesWithOverride '
            'stepComments seqComments varComments objVarsWithFields withFlowTarget resolvedIdTargets withModuleTiming '
            'iniCovFiles iniCovSteps iniCovModule'
        .split(' ');

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
    int? firstXmlTypeDefs;
    final baseClasses = <String>{}, arKinds = <String>{};
    final measTypes = <String>{}, measSpecs = <String>{};
    final iniFragmentKeys = <String>{};

    for (final f in seqs) {
      final bytes = f.readAsBytesSync();
      final fmt = detectSeqFormat(bytes);
      if (fmt == SeqFormat.binary) {
        tally.bump('binaryFiles');
        continue;
      }
      if (fmt != SeqFormat.xml && fmt != SeqFormat.ini) continue;

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
        xmlCov += measureCoverage(sf);
        final mp = sf.measurementPlugIns;
        if (mp != null) {
          tally.bump('mpBlocks');
          if (mp.pinMapPath != null) tally.bump('mpPinMaps');
        }
        tally.bump('typedefFiles');
        firstXmlTypeDefs ??= sf.typeDefs.length;
        for (final t in sf.typeDefs) {
          tally.bump('totalTypes');
          if (t.baseClass != null) baseClasses.add(t.baseClass!);
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
          iniCov += measureCoverage(sf);
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
                if (fc.condition != null) tally.bump('conds');
              case FlowKind.forLoop:
                tally.bump('forLoops');
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

    final laws = <(String, Object?, Object)>[
      ('unknown-format file count', seqs.length - tally['xmlFiles'] - tally['iniFiles'] - tally['binaryFiles'], 0),
      ('XML typed steps (none lost in the lens)', tally['typedSteps'], tally['xmlSteps']),
      ('XML unknown adapters', tally['unknownAdapters'], 0),
      ('XML coverage: unaccounted nodes', xmlCov.unaccounted, 0),
      ('python steps naming a function', tally['pyFn'], tally['pySteps']),
      ('python steps with a module path', tally['pyModule'], tally['pySteps']),
      ('python steps with a version', tally['pyVersion'], tally['pySteps']),
      ('python params named', tally['pyNamed'], tally['pyParams']),
      ('VI params with DisplayType', tally['viDisplayType'], tally['viParams']),
      ('VI params with connector#', tally['viConnector'], tally['viParams']),
      ('additional-results kinds', arKinds, everyElement(anyOf(contains('ParameterResult'), isNotEmpty))),
      ('Results keeping their Error sub-object', tally['withError'], tally['withResult']),
      ('recorded (non-default) outcomes in sequence files', tally['recordedOutcomes'], 0),
      ('measurement params typed', tally['measTyped'], tally['measParams']),
      ('measurement param types', measTypes, contains('TypeDouble')),
      ('measurement specializations', measSpecs, contains('IOResource')),
      ('flow ends match openers', tally['flowEnds'], tally['flowOpeners']),
      ('flow-bearing sequences balanced', tally['balancedSeqs'], tally['totalFlowSeqs']),
      ('if/while/for conditions', tally['conds'], tally['ifWhile'] + tally['forLoops']),
      ('for initializations', tally['forInit'], tally['forLoops']),
      ('for increments', tally['forIncr'], tally['forLoops']),
      ('for-each array expressions', tally['eachArr'], tally['eachLoops']),
      ('for-each element bindings', tally['eachElem'], tally['eachLoops']),
      ('files annotating jumps in the export', tally['exportsWithJump'], tally['filesWithJump']),
      ('files annotating loops in the export', tally['exportsWithLoop'], tally['filesWithLoop']),
      ('files marking external calls with a file', tally['exportsMarked'], tally['filesWithExternal']),
      ('parameters carrying a type', tally['sigTyped'], tally['sigParams']),
      ('files rendering signatures in the export', tally['exportsSigned'], tally['filesWithParams']),
      ('INI headers typed SequenceFile', tally['iniSeqType'], tally['iniFiles']),
      ('INI files defining SF=SequenceFileData', tally['iniSfRoot'], tally['iniFiles']),
      ('INI files naming an object "Data"', tally['iniDataNamed'], tally['iniFiles']),
      ('INI data trees built', tally['iniTreeBuilt'], tally['iniFiles']),
      ('INI trees rooted at "Data"', tally['iniDataRoot'], tally['iniTreeBuilt']),
      ('INI trees with a non-empty Seq array', tally['iniWithSeqArray'], tally['iniTreeBuilt']),
      ('INI Seq arrays exposing named sequences', tally['iniNamedSeqs'], tally['iniWithSeqArray']),
      ('INI in-section lines without " = "', tally['iniSkippedLines'], 0),
      ('INI residual ` LineNNNN` keys', tally['iniResidual'], 0),
      ('INI files that threw', tally['iniThrew'], 0),
      ('INI files built into SeqFiles', tally['iniBuilt'], tally['iniFiles']),
      ('INI unknown adapters', tally['iniUnknown'], 0),
      ('INI adapter partition', tally['iniRecognized'] + tally['iniNone'] + tally['iniUnknown'], tally['iniStepCount']),
      ('INI coverage: unaccounted nodes', iniCov.unaccounted, 0),
    ];
    for (final (label, actual, want) in laws) {
      expect(actual, want, reason: label);
    }

    expectCorpusSnapshot('xml_ini', {
      for (final key in _xmlIniCounters) key: tally[key],
      'xmlCovTotal': xmlCov.total,
      'xmlCovModeled': xmlCov.modeled,
      'xmlCovPlumbing': xmlCov.plumbing,
      'baseClasses': baseClasses.length,
      'firstXmlTypeDefs': firstXmlTypeDefs ?? -1,
      'arKinds': arKinds.length,
      'measTypes': measTypes.length,
      'measSpecs': measSpecs.length,
      'iniFragmentKeys': iniFragmentKeys.length,
      'iniCovTotal': iniCov.total,
      'iniCovModeled': iniCov.modeled,
      'iniCovPlumbing': iniCov.plumbing,
    });
  });

  test('binary corpus (single pass): partial model is honest, recon lenses never fabricate', () {
    final tally = Tally();
    final failures = <String>[];

    int u32(List<int> b, int i) => b[i] | b[i + 1] << 8 | b[i + 2] << 16 | b[i + 3] << 24;
    bool tripletExists(List<int> body, int rr, int idx) {
      for (var i = 0; i + 12 <= rr; i++) {
        if (u32(body, i) != idx) continue;
        final field = u32(body, i + 4);
        final count = u32(body, i + 8);
        if (field < 1 || field > 100000) continue;
        if (count < 1 || count > 1000) continue;
        if (i < 4 || u32(body, i - 4) == 0 || u32(body, i - 4) == 0xffffffff) return true;
      }
      return false;
    }

    for (final f in seqs) {
      final bytes = f.readAsBytesSync();
      if (detectSeqFormat(bytes) != SeqFormat.binary) continue;
      tally.bump('binary');

      final partial = parseSeqFile(bytes);
      if (partial.sequences.isNotEmpty) tally.bump('binaryWithSequences');
      final partialTypeNames = {for (final t in partial.types) t.name};
      final walkBacked = {
        for (final o in binarySequenceOutlines(bytes))
          if (o.groupArrays.isNotEmpty) o.name,
      };
      for (final seq in partial.sequences) {
        expect(seq.name, isNotEmpty);
        if (!walkBacked.contains(seq.name)) {
          expect(
            const {'Sequence', 'Calls', 'ResultList', 'Objs', 'Seq', 'Obj', 'Data'},
            isNot(contains(seq.name)),
            reason: '${f.path}: structural token as sequence name',
          );
        }
        tally.bump('binaryStepsRecovered', seq.steps.length);
        for (final step in seq.steps) {
          if (step.type != null) {
            tally.bump('binaryTypedSteps');
            expect(
              partialTypeNames,
              contains(step.type),
              reason: '${f.path}: step ${step.name} type outside the table',
            );
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
        }
      }
      final bh = detectSeqHeader(bytes);
      expect(bh.fileType, 'SequenceFile');
      expect(bh.productName, 'TestStand');
      final body = inflateBinaryBody(bytes);
      expect(body, isNotNull, reason: '${f.path}: no inflatable body');
      if (body != null) {
        tally.bump('withBinaryBody');
        expect(_bodyContains(body, 'Sequence'), isTrue, reason: '${f.path}: body lacks the Sequence token');
        final bodyNames = binaryBodyStrings(bytes).map((s) => s.text).toSet();
        expect(
          ['Sequence', 'Step', 'Locals'].any(bodyNames.contains),
          isTrue,
          reason: '${f.path}: body strings missing all core model names',
        );
        expect(
          binaryStringTable(bytes).length,
          greaterThanOrEqualTo(5),
          reason: '${f.path}: no contiguous string table',
        );
      }

      final layout = analyzeBinaryBody(bytes);
      if (layout == null) {
        failures.add('${f.path}: no layout');
      } else {
        tally.bump('framed');
        tally.bump('totalStrings', layout.stringCount);
        if (layout.sentinelCount > 0) tally.bump('withSentinels');
        if (layout.recordRegionLength <= 0 ||
            layout.recordRegionLength >= layout.inflatedSize ||
            layout.stringCount < 5) {
          failures.add('${f.path}: $layout');
        }
        final w = layout.leadingWords;
        if (w.length >= 3 && w[2] == 1) tally.bump('word2Is1');
        final segments = binaryStringSegments(bytes);
        if (layout.segmentCount != segments.length || layout.segmentCount < 2) {
          failures.add('${f.path}: ${layout.segmentCount} segments');
        }

        final name = binaryNameTable(bytes);
        if (name == null) {
          failures.add('${f.path}: no name table');
        } else {
          tally.bump('nameFound');
          final texts = {for (final e in name.entries) e.text};
          if (['Step', 'Sequence', 'Locals'].any(texts.contains)) {
            tally.bump('hasModelTokens');
          } else {
            failures.add('${f.path}: name table lacks core model tokens');
          }
          if (segments.any((s) => s.entries.length > name.entries.length)) tally.bump('notLargest');
          if (segments.isNotEmpty && name.offset == segments.first.offset) tally.bump('isFirst');
          if (segments.any((s) => s.offset != name.offset && s.entries.any((e) => _isExprLike(e.text)))) {
            tally.bump('valuesOutsideName');
          }

          final names = [for (final e in name.entries) e.text];
          if (names.isNotEmpty && names.first == 'SequenceFileData') {
            tally.bump('rooted');
            if (names.length >= 2 && names[1] == 'Data') {
              tally.bump('prefix2Ok');
            } else {
              failures.add('${f.path}: prefix ${names.take(2).toList()} != [SequenceFileData, Data]');
            }
            final n = binaryNameScaffold.length;
            if (names.length >= n && Iterable<int>.generate(n).every((i) => names[i] == binaryNameScaffold[i])) {
              tally.bump('scaffold5Ok');
            }
            final words = binaryRecordWords(bytes);
            if (words.length >= 3 && words[2] == 1 && names[1] == 'Data') tally.bump('recordIndexesData');
            final objNames = binaryObjectNames(bytes);
            if (objNames.isNotEmpty && objNames.first != 'SequenceFileData') {
              tally.bump('objNamesOk');
            } else if (objNames.isNotEmpty) {
              failures.add('${f.path}: scaffold prefix not dropped ($objNames)');
            }
          }

          final nameLen = name.entries.length;
          if (body != null && nameLen > 5) {
            final rr = layout.recordRegionLength.clamp(0, body.length);
            for (var idx = 5; idx < nameLen; idx++) {
              tally.bump('realTot');
              if (tripletExists(body, rr, idx)) tally.bump('realHit');
            }
            for (var k = 0; k < nameLen - 5; k++) {
              tally.bump('fakeTot');
              if (tripletExists(body, rr, nameLen + 1 + k)) tally.bump('fakeHit');
            }
          }
        }
      }

      final a = analyzeBinary(bytes);
      if (a == null) {
        failures.add('${f.path}: analyzeBinary null');
      } else {
        tally.bump('analyzeChecked');
        final ok =
            a.inflatedSize == (inflateBinaryBody(bytes)?.length ?? 0) &&
            a.strings.length == binaryBodyStrings(bytes).length &&
            a.stringTable.length == binaryStringTable(bytes).length &&
            a.layout?.recordRegionLength == analyzeBinaryBody(bytes)?.recordRegionLength &&
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

      final paths = binaryModulePaths(bytes);
      for (final p in paths) {
        if (!isBinaryModulePath(p)) failures.add('${f.path}: path $p');
      }
      for (final e in binaryExpressions(bytes)) {
        if (!isBinaryExpression(e)) failures.add('${f.path}: expr $e');
        if (isBinaryModulePath(e) || e.startsWith('ID#:')) failures.add('${f.path}: expr overlaps path/id $e');
      }
      for (final l in binaryQuotedLiterals(bytes)) {
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
      if (binaryStepReferences(bytes).isNotEmpty) tally.bump('withId');
      if (binaryExpressions(bytes).isNotEmpty) tally.bump('withExpr');
      if (binaryQuotedLiterals(bytes).isNotEmpty) tally.bump('withLit');
    }

    final realRate = tally['realHit'] / tally['realTot'];
    final fakeRate = tally['fakeHit'] / tally['fakeTot'];
    print(
      'binary recon: ${tally['binary']} binaries · ${tally['binaryWithSequences']} with sequences · '
      '${tally['binaryStepsRecovered']} steps (${tally['binaryTypedSteps']} typed, '
      '${tally['binaryModuleSteps']} with modules) · ${tally['framed']} framed '
      '(${tally['withSentinels']} sentinels, ${tally['totalStrings']} strings) · '
      '${tally['rooted']} rooted (${tally['scaffold5Ok']} scaffold, ${tally['isFirst']} first-segment) · '
      'triplet ${(realRate * 100).toStringAsFixed(1)}% vs control ${(fakeRate * 100).toStringAsFixed(1)}% · '
      '${tally['withPath']} with paths (${tally['totalPaths']}, ${tally['nonAsciiPaths']} non-ASCII)',
    );
    expect(failures, isEmpty, reason: failures.take(8).join('\n'));

    final laws = <(String, Object?, Object)>[
      ('bodies inflated', tally['withBinaryBody'], tally['binary']),
      ('bodies framed', tally['framed'], tally['binary']),
      ('leadingWords[2] == 1', tally['word2Is1'], tally['binary']),
      ('name tables found', tally['nameFound'], tally['binary']),
      ('name tables with core tokens', tally['hasModelTokens'], tally['binary']),
      ('expressions outside the name table', tally['valuesOutsideName'], tally['binary']),
      ('rooted pools opening [.., Data]', tally['prefix2Ok'], tally['rooted']),
      ('record word[2] indexes name[1]==Data', tally['recordIndexesData'], tally['rooted']),
      ('rooted files exposing object names', tally['objNamesOk'], tally['rooted']),
      ('analyzeBinary consistency checks', tally['analyzeChecked'], tally['binary']),
    ];
    for (final (label, actual, want) in laws) {
      expect(actual, want, reason: label);
    }

    expectCorpusSnapshot('binary_recon', {
      for (final key in _binaryReconCounters) key: tally[key],
    });
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
