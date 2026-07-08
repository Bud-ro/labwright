@Tags(['corpus'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:labwright_seq/labwright_seq.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

/// Counts the instance-override markers (`%INSTOVRD`) anywhere in a tree.
int _countOverrides(SeqProperty p, [int depth = 0]) {
  if (depth > 50) return 0;
  return p.subProps
      .followedBy(p.array ?? const <SeqProperty>[])
      .fold(p.isInstanceOverride ? 1 : 0, (n, c) => n + _countOverrides(c, depth + 1));
}

/// Byte-level ASCII substring search — avoids materializing a whole inflated
/// body as a String (peak memory in corpus sweeps).
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

/// Per-file size ceiling on coverage accumulation — a runtime bound for a
/// hypothetical pathological giant, set well above every real corpus file.
const _maxProbeBytes = 8 * 1024 * 1024;

bool _isExprLike(String s) =>
    (s.contains('.') && RegExp(r'[A-Za-z]\.[A-Za-z]').hasMatch(s)) ||
    s.contains('(') ||
    s.contains(')') ||
    s.contains('"') ||
    (RegExp(r'[+\-*/=<>!]').hasMatch(s) && RegExp(r'[A-Za-z0-9]').hasMatch(s));

/// Validates the readers against the real fetched corpus (rosetta excluded —
/// the twin oracles have their own suite): every XML/INI `.seq` parses into
/// the shared typed model with pinned recovery counts, every binary `.seq`
/// parses to the honest PARTIAL model, and the binary recon lenses never
/// fabricate. Self-skips when the corpus is absent.
void main() {
  if (!corpusSeqDir.existsSync()) {
    test('teststand corpus', () {}, skip: 'corpus absent — run tool/fetch_seq_corpus.dart');
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

  test('XML+INI corpus (single pass): typed-lens recovery counts are pinned, nothing fabricates', () {
    var xml = 0, ini = 0, binary = 0;
    final failures = <String>[];

    // XML lens counters.
    var xmlSeqs = 0, xmlSteps = 0, withAction = 0, withModule = 0, xmlLocals = 0, withLimits = 0;
    var resolvedCalls = 0, withMode = 0, withIcon = 0, typedSteps = 0, unknownAdapters = 0;
    var xmlCov = const SeqCoverage(total: 0, modeled: 0);
    // Measurement plug-ins.
    var mpBlocks = 0, mpPinMaps = 0;
    // Python descriptors + call params.
    var pySteps = 0, pyFn = 0, pyModule = 0, pyVersion = 0, pyParamSteps = 0, pyParams = 0, pyNamed = 0, pyBound = 0;
    // VI calls.
    var viSteps = 0, viParams = 0, viDisplayType = 0, viConnector = 0;
    // Typelist typedefs.
    var typedefFiles = 0, totalTypes = 0, typesWithFields = 0;
    int? firstXmlTypeDefs;
    final baseClasses = <String>{};
    // Additional results / step results / custom condition.
    var arFiles = 0, arEntries = 0;
    final arKinds = <String>{};
    var withResult = 0, withError = 0, recordedOutcomes = 0;
    var custTrueAct = 0, custFalseAct = 0;
    // Measurement parameters.
    var measParams = 0, measTyped = 0, measDirected = 0, measSpecialized = 0, measNotLogged = 0;
    var measEnumParams = 0, measEnumValues = 0;
    final measTypes = <String>{}, measSpecs = <String>{};

    // Shared XML+INI logic-export counters.
    var flowOpeners = 0, flowEnds = 0, conds = 0, forInit = 0, forIncr = 0, eachArr = 0, eachElem = 0;
    var ifWhile = 0, forLoops = 0, eachLoops = 0, seqsWithFlow = 0, balancedSeqs = 0, totalFlowSeqs = 0;
    var jumpSteps = 0, filesWithJump = 0, exportsWithJump = 0;
    var loopSteps = 0, filesWithLoop = 0, exportsWithLoop = 0;
    var externalCalls = 0, filesWithExternal = 0, exportsMarked = 0;
    var sigParams = 0, sigTyped = 0, filesWithParams = 0, exportsSigned = 0;
    // Newly-modeled lens accessors (XML+INI).
    var adapterName = 0, stepDesc = 0, codeTemplates = 0, runtimeEP = 0;
    var switchSettings = 0, seqCallExpr = 0, threading = 0, pyInterp = 0;
    var clusterEls = 0, dbStep = 0, limitExpr = 0, fileSettings = 0, fileGlobals = 0;

    // INI lens counters.
    var iniCovFiles = 0, iniCovSteps = 0, iniCovModule = 0;
    var iniCov = const SeqCoverage(total: 0, modeled: 0);
    var iniSeqType = 0, iniSfRoot = 0, iniDataNamed = 0, iniTreeBuilt = 0, iniDataRoot = 0;
    var iniWithSeqArray = 0, iniNamedSeqs = 0;
    var iniThrew = 0, iniBuilt = 0, iniSeqCount = 0, iniStepCount = 0, iniLocals = 0, iniWithType = 0, iniTypes = 0;
    var iniRecognized = 0, iniNone = 0, iniUnknown = 0, iniWithMode = 0, iniWithLoop = 0;
    var overrides = 0, filesWithOverride = 0, stepComments = 0, seqComments = 0, varComments = 0;
    var objVarsWithFields = 0, withFlowTarget = 0, resolvedIdTargets = 0, withModuleTiming = 0;
    var iniSkippedLines = 0, iniFragments = 0, iniResidual = 0;
    final iniFragmentKeys = <String>{};

    for (final f in seqs) {
      final bytes = f.readAsBytesSync();
      final fmt = detectSeqFormat(bytes);
      if (fmt == SeqFormat.binary) {
        binary++;
        continue; // the binary recon sweep below owns these
      }
      if (fmt != SeqFormat.xml && fmt != SeqFormat.ini) continue;

      // ── INI document layer (sections, continuations, raw-line audit) ──
      if (fmt == SeqFormat.ini) {
        ini++;
        final doc = parseIniSeqBytes(bytes);
        if (doc.header.fileType == 'SequenceFile') iniSeqType++;
        if (doc.sections.any((s) => s.isDef && s.members['SF'] == 'SequenceFileData')) iniSfRoot++;
        if (doc.sections.any((s) => s.name == 'Data')) iniDataNamed++;
        final residualRe = RegExp(r' Line\d+$');
        for (final s in doc.sections) {
          for (final k in [...s.members.keys, ...s.directives.keys]) {
            if (residualRe.hasMatch(k)) iniResidual++;
          }
        }
        final tree = iniDataTree(doc);
        if (tree != null) {
          iniTreeBuilt++;
          if (tree.name == 'Data') iniDataRoot++;
          final seq = tree.subProps.where((p) => p.name == 'Seq' && p.isArray).firstOrNull;
          if (seq != null && seq.array!.isNotEmpty) {
            iniWithSeqArray++;
            if (seq.array!.any((s) => s.name.isNotEmpty && s.name != '[0]')) iniNamedSeqs++;
          }
        }
        // Raw text: every in-section data line is `key = value`, and every
        // ` LineNNNN` continuation fragment is reassembled.
        final text = latin1.decode(bytes, allowInvalid: true);
        var inSection = false;
        for (final raw in const LineSplitter().convert(text)) {
          final line = raw.trimRight();
          if (line.isEmpty) continue;
          if (line.startsWith('[') && line.endsWith(']')) {
            inSection = true;
            continue;
          }
          if (inSection && !line.contains(' = ')) iniSkippedLines++;
        }
        for (final m in RegExp(r'^(.+) Line(\d+)\s*=', multiLine: true).allMatches(text)) {
          iniFragments++;
          iniFragmentKeys.add(m.group(1)!.trim());
        }
      }

      // ── shared typed model ──
      final SeqFile sf;
      try {
        sf = parseSeqFile(bytes);
      } on FormatException catch (e) {
        if (fmt == SeqFormat.ini) {
          iniThrew++;
        } else {
          failures.add('${f.path}: $e');
        }
        continue;
      }

      if (fmt == SeqFormat.xml) {
        xml++;
        xmlCov += measureCoverage(sf);
        final mp = sf.measurementPlugIns;
        if (mp != null) {
          mpBlocks++;
          if (mp.pinMapPath != null) mpPinMaps++;
        }
        typedefFiles++;
        firstXmlTypeDefs ??= sf.typeDefs.length;
        for (final t in sf.typeDefs) {
          totalTypes++;
          if (t.baseClass != null) baseClasses.add(t.baseClass!);
          if (t.fields.isNotEmpty) typesWithFields++;
        }
      } else {
        iniBuilt++;
        iniTypes += sf.types.length;
        final ovr = _countOverrides(sf.data);
        overrides += ovr;
        if (ovr > 0) filesWithOverride++;
        if (bytes.length <= _maxProbeBytes) {
          iniCovFiles++;
          iniCov += measureCoverage(sf);
        }
      }

      // New-accessor file-level counters.
      if (sf.modelFile != null || sf.contentVersion != null || sf.fileTypeCode != null) fileSettings++;
      if (sf.fileGlobals.isNotEmpty) fileGlobals++;

      var arAny = false;
      var fileJump = false, fileLoop = false, fileExternal = false, fileParams = false;
      for (final q in sf.sequences) {
        if (q.runtimeSettings?.entryPointNameExpression != null) runtimeEP++;
        if (fmt == SeqFormat.xml) {
          xmlSeqs++;
          xmlLocals += q.locals.length;
        } else {
          iniSeqCount++;
          iniLocals += q.locals.length;
          if (q.comment != null) seqComments++;
          for (final v in [...q.locals, ...q.parameters]) {
            if (!v.isArray && v.containerCount != null && v.containerCount! > 0) objVarsWithFields++;
            if (v.comment != null) varComments++;
          }
        }
        if (q.parameters.isNotEmpty) {
          fileParams = true;
          for (final p in q.parameters) {
            sigParams++;
            if (p.type != null) sigTyped++;
          }
        }

        var depth = 0, minDepth = 0, localFlow = 0;
        for (final step in q.steps) {
          final set = step.settings;
          final m = step.module;

          if (fmt == SeqFormat.xml) {
            xmlSteps++;
            if (step.type != null) typedSteps++;
            if (set.passAction != null) withAction++;
            if (set.mode != null) withMode++;
            if (set.icon != null) withIcon++;
            if (m.adapter == SeqAdapter.unknown) unknownAdapters++;
            if (m.adapter != SeqAdapter.none && m.adapter != SeqAdapter.unknown) withModule++;
            if (step.limits != null) withLimits++;
            if (sf.resolveCall(step) != null) resolvedCalls++;

            if (m.adapter == SeqAdapter.python) {
              pySteps++;
              if (m.pythonFunction != null) pyFn++;
              if (m.pythonModulePath != null) pyModule++;
              if (m.pythonVersion != null) pyVersion++;
              final args = m.callParameters;
              if (args.isNotEmpty) {
                pyParamSteps++;
                for (final a in args) {
                  pyParams++;
                  if (a.name.isNotEmpty) pyNamed++;
                  if (a.boundExpression != null) pyBound++;
                }
              }
            }
            if (m.adapter == SeqAdapter.labView && m.viParameters.isNotEmpty) {
              viSteps++;
              for (final p in m.viParameters) {
                viParams++;
                if (p.displayType != null) viDisplayType++;
                if (p.connectorNumber != null) viConnector++;
              }
            }
            for (final a in step.additionalResults) {
              arAny = true;
              arEntries++;
              if (a.kind != null) arKinds.add(a.kind!);
            }
            final r = step.result;
            if (r != null) {
              withResult++;
              if (r.errorOccurred != null) withError++;
              if (r.hasRecordedOutcome) recordedOutcomes++;
            }
            if (set.customTrueAction != null) custTrueAct++;
            if (set.customFalseAction != null) custFalseAct++;
            for (final p in step.measurementParameters) {
              measParams++;
              if (p.dataType != null) {
                measTyped++;
                measTypes.add(p.dataType!);
              }
              if (p.direction != null) measDirected++;
              if (p.typeSpecialization != null) {
                measSpecialized++;
                measSpecs.add(p.typeSpecialization!);
              }
              if (p.logged == false) measNotLogged++;
              if (p.dataType == 'TypeEnum') {
                measEnumParams++;
                measEnumValues += p.enumValues.length;
              }
            }
          } else {
            iniStepCount++;
            if (step.type != null) iniWithType++;
            switch (m.adapter) {
              case SeqAdapter.none:
                iniNone++;
              case SeqAdapter.unknown:
                iniUnknown++;
              default:
                iniRecognized++;
            }
            if (set.mode != null) iniWithMode++;
            if (set.loopType != null) iniWithLoop++;
            if (step.comment != null) stepComments++;
            if (set.passActionTarget != null || set.failActionTarget != null) withFlowTarget++;
            for (final t in [set.customTrueTarget, set.customFalseTarget]) {
              if (t != null && t.startsWith('ID#:') && sf.stepNameForId(t) != null) resolvedIdTargets++;
            }
            final lo = set.loadOption, uo = set.unloadOption;
            if ((lo != null && lo != 'PreloadWhenExecuted') || (uo != null && uo != 'UnloadWithFile')) {
              withModuleTiming++;
            }
            if (bytes.length <= _maxProbeBytes) {
              iniCovSteps++;
              if (m.adapter != SeqAdapter.none) iniCovModule++;
            }
          }

          // Shared: new-accessor counters.
          if (set.adapterName != null) adapterName++;
          if (set.switchEnabled != null || set.canEditCode != null) switchSettings++;
          if (step.description != null) stepDesc++;
          if (step.typeInfo.codeTemplates.isNotEmpty) codeTemplates++;
          if (m.sequenceNameExpression != null || m.specifiesByExpression != null) seqCallExpr++;
          if (m.threadOptionCode != null) threading++;
          if (m.pythonInterpreterLocation != null || m.pythonOperationTypeCode != null) pyInterp++;
          for (final p in [...m.viParameters, ...m.callParameters]) {
            if (p.caption != null || p.typeCode != null) clusterEls++;
          }
          if (step.sqlStatement != null || step.statementHandle != null) dbStep++;
          if (step.limits?.lowExpression != null || step.limits?.comparisonExpression != null) limitExpr++;

          // Shared: structured flow control.
          final fc = step.flowControl;
          if (fc != null) {
            localFlow++;
            if (fc.kind.opensBlock) {
              flowOpeners++;
              depth++;
            } else if (fc.kind == FlowKind.end) {
              flowEnds++;
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
          // Shared: logic-export annotation triggers.
          if ((set.passAction != null && set.passAction != 'Next') ||
              (set.failAction != null && set.failAction != 'Next')) {
            jumpSteps++;
            fileJump = true;
          }
          if (fc == null && set.isLooping) {
            loopSteps++;
            fileLoop = true;
          }
          if (m.adapter == SeqAdapter.sequenceCall &&
              sf.resolveCall(step) == null &&
              (m.sequenceFile ?? '').isNotEmpty) {
            externalCalls++;
            fileExternal = true;
          }
        }
        if (localFlow > 0) {
          totalFlowSeqs++;
          seqsWithFlow++;
          if (depth == 0 && minDepth == 0) balancedSeqs++;
        }
      }
      if (arAny) arFiles++;

      // One logic export per file covers all four annotation gates.
      if (fileJump || fileLoop || fileExternal || fileParams) {
        final logic = exportSequenceLogic(sf);
        if (fileJump) {
          filesWithJump++;
          if (logic.contains(RegExp(r'\[on (pass|fail)'))) exportsWithJump++;
        }
        if (fileLoop) {
          filesWithLoop++;
          if (logic.contains('[loop ')) exportsWithLoop++;
        }
        if (fileExternal) {
          filesWithExternal++;
          if (logic.contains(RegExp(r' in \S+\.seq'))) exportsMarked++;
        }
        if (fileParams) {
          filesWithParams++;
          if (logic.contains(RegExp(r'^sequence .+\([^)]', multiLine: true))) exportsSigned++;
        }
      }
    }

    print(
      'teststand corpus: $xml XML / $ini INI / $binary binary · '
      '$xmlSeqs+$iniSeqCount sequences · $xmlSteps+$iniStepCount steps · '
      'XML modeled ${(xmlCov.ratio * 100).toStringAsFixed(1)}% · INI modeled ${(iniCov.ratio * 100).toStringAsFixed(1)}% · '
      '$overrides overrides in $filesWithOverride files · $iniFragments INI fragments / ${iniFragmentKeys.length} keys',
    );
    expect(failures, isEmpty, reason: failures.take(5).join('\n'));

    final pins = <(String, Object?, Object)>[
      // XML lens (exact counts pin the corpus + recovery together).
      ('XML file count', xml, 25),
      ('INI file count', ini, 43),
      ('unknown-format file count', seqs.length - xml - ini - binary, 0),
      ('XML sequence count', xmlSeqs, 29),
      ('XML step count', xmlSteps, 141),
      ('XML steps with pass/fail actions', withAction, 141),
      ('XML typed steps (none lost in the lens)', typedSteps, xmlSteps),
      ('XML steps with run-mode', withMode, greaterThan(0)),
      ('XML module bindings', withModule, 61),
      ('XML locals', xmlLocals, 34),
      ('XML limit tests', withLimits, 10),
      ('XML intra-file calls resolved', resolvedCalls, 4),
      ('XML step icons', withIcon, 59),
      ('XML unknown adapters', unknownAdapters, 0),
      ('XML coverage: unaccounted nodes', xmlCov.unaccounted, 0),
      ('XML coverage ratio', xmlCov.ratio, greaterThan(0.984)),
      // Measurement plug-ins.
      ('files with a MeasurementPlugIns block', mpBlocks, greaterThanOrEqualTo(5)),
      ('files with a pin map', mpPinMaps, greaterThanOrEqualTo(1)),
      // Python descriptors + call params.
      ('python steps', pySteps, greaterThanOrEqualTo(20)),
      ('python steps naming a function', pyFn, pySteps),
      ('python steps with a module path', pyModule, pySteps),
      ('python steps with a version', pyVersion, pySteps),
      ('python call params', pyParams, greaterThanOrEqualTo(45)),
      ('python params named', pyNamed, pyParams),
      ('python params with a bound value', pyBound, greaterThan(0)),
      ('python param steps', pyParamSteps, greaterThan(0)),
      // VI calls.
      ('VI-call steps with params', viSteps, greaterThanOrEqualTo(5)),
      ('VI connector params', viParams, greaterThanOrEqualTo(20)),
      ('VI params with DisplayType', viDisplayType, viParams),
      ('VI params with connector#', viConnector, viParams),
      // Typelist.
      ('XML files scanned for typedefs', typedefFiles, greaterThanOrEqualTo(20)),
      ('typedefs recovered', totalTypes, greaterThanOrEqualTo(300)),
      ('typedefs with fields', typesWithFields, greaterThanOrEqualTo(1)),
      ('typedef base classes', baseClasses, isNotEmpty),
      ('first XML file typeDefs mirror types', firstXmlTypeDefs, greaterThan(0)),
      // Additional results / step results / custom conditions.
      ('files with additional-results specs', arFiles, greaterThanOrEqualTo(10)),
      ('additional-results entries', arEntries, greaterThanOrEqualTo(100)),
      ('additional-results kinds', arKinds, everyElement(anyOf(contains('ParameterResult'), isNotEmpty))),
      ('steps with a Result slot', withResult, greaterThan(0)),
      ('Results keeping their Error sub-object', withError, withResult),
      ('recorded (non-default) outcomes in sequence files', recordedOutcomes, 0),
      ('custom-condition true actions', custTrueAct, greaterThan(0)),
      ('custom-condition false actions', custFalseAct, greaterThan(0)),
      // Measurement parameters.
      ('measurement params', measParams, greaterThanOrEqualTo(120)),
      ('measurement params typed', measTyped, measParams),
      ('measurement param types', measTypes, contains('TypeDouble')),
      ('measurement params with direction', measDirected, greaterThan(0)),
      ('measurement params specialized', measSpecialized, greaterThan(0)),
      ('measurement specializations', measSpecs, contains('IOResource')),
      ('measurement params not logged', measNotLogged, greaterThan(0)),
      ('measurement enum params', measEnumParams, greaterThan(0)),
      ('measurement enum values cover their params', measEnumValues, greaterThanOrEqualTo(measEnumParams)),
      // Flow control (XML+INI).
      ('flow-control openers', flowOpeners, greaterThan(0)),
      ('flow ends match openers', flowEnds, flowOpeners),
      ('flow-bearing sequences balanced', balancedSeqs, totalFlowSeqs),
      ('if/while/for conditions', conds, ifWhile + forLoops),
      ('for initializations', forInit, forLoops),
      ('for increments', forIncr, forLoops),
      ('for-each array expressions', eachArr, eachLoops),
      ('for-each element bindings', eachElem, eachLoops),
      ('sequences with flow', seqsWithFlow, greaterThan(0)),
      // Logic-export annotations.
      ('pass/fail jump steps', jumpSteps, greaterThan(0)),
      ('files annotating jumps in the export', exportsWithJump, filesWithJump),
      ('looping non-flow steps', loopSteps, greaterThan(0)),
      ('files annotating loops in the export', exportsWithLoop, filesWithLoop),
      ('external seq-calls', externalCalls, greaterThan(0)),
      ('files marking external calls with a file', exportsMarked, filesWithExternal),
      ('sequence parameters', sigParams, greaterThan(0)),
      ('parameters carrying a type', sigTyped, sigParams),
      ('files rendering signatures in the export', exportsSigned, filesWithParams),
      // Newly-modeled lens accessors.
      ('adapter names surfaced', adapterName, greaterThan(0)),
      ('step descriptions surfaced', stepDesc, greaterThan(0)),
      ('code templates surfaced', codeTemplates, greaterThan(0)),
      ('RTS entry-point names surfaced', runtimeEP, greaterThan(0)),
      ('switch/edit settings surfaced', switchSettings, greaterThan(0)),
      ('SequenceCall expressions surfaced', seqCallExpr, greaterThan(0)),
      ('threading settings surfaced', threading, greaterThan(0)),
      ('python interpreter settings surfaced', pyInterp, greaterThan(0)),
      ('param type descriptors surfaced', clusterEls, greaterThan(0)),
      ('database step fields surfaced', dbStep, greaterThan(0)),
      ('limit expressions surfaced', limitExpr, greaterThan(0)),
      ('file-level settings surfaced', fileSettings, greaterThan(0)),
      ('file globals surfaced', fileGlobals, greaterThan(0)),
      // INI document layer.
      ('INI headers typed SequenceFile', iniSeqType, ini),
      ('INI files defining SF=SequenceFileData', iniSfRoot, ini),
      ('INI files naming an object "Data"', iniDataNamed, ini),
      ('INI data trees built', iniTreeBuilt, ini),
      ('INI trees rooted at "Data"', iniDataRoot, iniTreeBuilt),
      ('INI trees with a non-empty Seq array', iniWithSeqArray, iniTreeBuilt),
      ('INI Seq arrays exposing named sequences', iniNamedSeqs, iniWithSeqArray),
      ('INI in-section lines without " = "', iniSkippedLines, 0),
      ('INI residual ` LineNNNN` keys', iniResidual, 0),
      ('INI continuation fragments', iniFragments, 4783),
      ('INI continuation base keys', iniFragmentKeys.length, 21),
      // INI typed lens (exact pins).
      ('INI files that threw', iniThrew, 0),
      ('INI files built into SeqFiles', iniBuilt, ini),
      ('INI sequence count', iniSeqCount, 426),
      ('INI step count', iniStepCount, 5500),
      ('INI locals count', iniLocals, 1561),
      ('INI [%TYPES] count', iniTypes, 1969),
      ('INI unknown adapters', iniUnknown, 0),
      ('INI recognized adapters', iniRecognized, 2040),
      ('INI none adapters', iniNone, 3460),
      ('INI adapter partition', iniRecognized + iniNone + iniUnknown, iniStepCount),
      ('INI typed steps', iniWithType, greaterThan(0)),
      ('INI type-inherited run-modes', iniWithMode, greaterThan(0)),
      ('INI type-inherited looping', iniWithLoop, greaterThan(0)),
      ('%INSTOVRD overrides', overrides, 12811),
      ('INI step comments', stepComments, 663),
      ('INI sequence comments', seqComments, 102),
      ('INI variable comments', varComments, 37),
      ('INI object variables with fields', objVarsWithFields, 78),
      ('INI flow targets', withFlowTarget, 58),
      ('INI resolved ID#: targets', resolvedIdTargets, 12),
      ('INI non-default module load/unload', withModuleTiming, 62),
      // INI coverage.
      ('INI files covered', iniCovFiles, greaterThanOrEqualTo(30)),
      ('INI covered steps', iniCovSteps, greaterThanOrEqualTo(1000)),
      ('INI covered steps with a module', iniCovModule, greaterThanOrEqualTo(500)),
      ('INI coverage: unaccounted nodes', iniCov.unaccounted, 0),
      ('INI coverage ratio', iniCov.ratio, greaterThan(0.995)),
    ];
    for (final (label, actual, want) in pins) {
      expect(actual, want, reason: label);
    }
  });

  test('binary corpus (single pass): partial model is honest, recon lenses never fabricate', () {
    var binary = 0, withBinaryBody = 0, binaryWithSequences = 0, binaryStepsRecovered = 0;
    var binaryTypedSteps = 0, binaryModuleSteps = 0;
    var framed = 0, withSentinels = 0, totalStrings = 0, word2Is1 = 0;
    var nameFound = 0, hasModelTokens = 0, notLargest = 0, isFirst = 0, valuesOutsideName = 0;
    var rooted = 0, prefix2Ok = 0, scaffold5Ok = 0, recordIndexesData = 0, objNamesOk = 0;
    var analyzeChecked = 0;
    var withPath = 0, withId = 0, withExpr = 0, withLit = 0, totalPaths = 0, nonAsciiPaths = 0;
    var realTot = 0, realHit = 0, fakeTot = 0, fakeHit = 0;
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
      binary++;

      // Partial typed model: never throws, no structural tokens as names,
      // step types from the file's own table, module targets look like
      // targets. (A sequence whose record walk decoded its group arrays is
      // walk-corroborated and MAY collide with a structural token — the
      // corpus has a sandbox sequence literally named `Sequence`.)
      final partial = parseSeqFile(bytes);
      if (partial.sequences.isNotEmpty) binaryWithSequences++;
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
        binaryStepsRecovered += seq.steps.length;
        for (final step in seq.steps) {
          if (step.type != null) {
            binaryTypedSteps++;
            expect(
              partialTypeNames,
              contains(step.type),
              reason: '${f.path}: step ${step.name} type outside the table',
            );
          }
          final m = step.module;
          if (m.adapter != SeqAdapter.none && m.adapter != SeqAdapter.unknown) {
            binaryModuleSteps++;
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
        withBinaryBody++;
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

      // Framing: record region + ≥2 string segments + leading-word pins.
      final layout = analyzeBinaryBody(bytes);
      if (layout == null) {
        failures.add('${f.path}: no layout');
      } else {
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
        final segments = binaryStringSegments(bytes);
        if (layout.segmentCount != segments.length || layout.segmentCount < 2) {
          failures.add('${f.path}: ${layout.segmentCount} segments');
        }

        // Content-identified name table: carries the core model tokens, is
        // not (usually) the largest segment, and expressions live outside it.
        final name = binaryNameTable(bytes);
        if (name == null) {
          failures.add('${f.path}: no name table');
        } else {
          nameFound++;
          final texts = {for (final e in name.entries) e.text};
          if (['Step', 'Sequence', 'Locals'].any(texts.contains)) {
            hasModelTokens++;
          } else {
            failures.add('${f.path}: name table lacks core model tokens');
          }
          if (segments.any((s) => s.entries.length > name.entries.length)) notLargest++;
          if (segments.isNotEmpty && name.offset == segments.first.offset) isFirst++;
          if (segments.any((s) => s.offset != name.offset && s.entries.any((e) => _isExprLike(e.text)))) {
            valuesOutsideName++;
          }

          // Ordered pool opening with the fixed scaffold.
          final names = [for (final e in name.entries) e.text];
          if (names.isNotEmpty && names.first == 'SequenceFileData') {
            rooted++;
            if (names.length >= 2 && names[1] == 'Data') {
              prefix2Ok++;
            } else {
              failures.add('${f.path}: prefix ${names.take(2).toList()} != [SequenceFileData, Data]');
            }
            final n = binaryNameScaffold.length;
            if (names.length >= n && Iterable<int>.generate(n).every((i) => names[i] == binaryNameScaffold[i])) {
              scaffold5Ok++;
            }
            final words = binaryRecordWords(bytes);
            if (words.length >= 3 && words[2] == 1 && names[1] == 'Data') recordIndexesData++;
            final objNames = binaryObjectNames(bytes);
            if (objNames.isNotEmpty && objNames.first != 'SequenceFileData') {
              objNamesOk++;
            } else if (objNames.isNotEmpty) {
              failures.add('${f.path}: scaffold prefix not dropped ($objNames)');
            }
          }

          // Object-record triplet: real name indexes hit far above a control
          // band of fake indexes (a real signal, not noise).
          final nameLen = name.entries.length;
          if (body != null && nameLen > 5) {
            final rr = layout.recordRegionLength.clamp(0, body.length);
            for (var idx = 5; idx < nameLen; idx++) {
              realTot++;
              if (tripletExists(body, rr, idx)) realHit++;
            }
            for (var k = 0; k < nameLen - 5; k++) {
              fakeTot++;
              if (tripletExists(body, rr, nameLen + 1 + k)) fakeHit++;
            }
          }
        }
      }

      // analyzeBinary matches every individual helper (single-inflate path).
      final a = analyzeBinary(bytes);
      if (a == null) {
        failures.add('${f.path}: analyzeBinary null');
      } else {
        analyzeChecked++;
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

      // Recovered call-targets, step refs, expressions, literals: each pool
      // entry satisfies its own predicate and never overlaps another class.
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
        withPath++;
        totalPaths += paths.length;
        nonAsciiPaths += paths.where((p) => p.codeUnits.any((u) => u >= 0x80)).length;
      }
      if (binaryStepReferences(bytes).isNotEmpty) withId++;
      if (binaryExpressions(bytes).isNotEmpty) withExpr++;
      if (binaryQuotedLiterals(bytes).isNotEmpty) withLit++;
    }

    final realRate = realHit / realTot;
    final fakeRate = fakeHit / fakeTot;
    print(
      'binary recon: $binary binaries · $binaryWithSequences with sequences · $binaryStepsRecovered steps '
      '($binaryTypedSteps typed, $binaryModuleSteps with modules) · $framed framed ($withSentinels sentinels, '
      '$totalStrings strings) · $rooted rooted ($scaffold5Ok scaffold, $isFirst first-segment) · '
      'triplet ${(realRate * 100).toStringAsFixed(1)}% vs control ${(fakeRate * 100).toStringAsFixed(1)}% · '
      '$withPath with paths ($totalPaths, $nonAsciiPaths non-ASCII)',
    );
    expect(failures, isEmpty, reason: failures.take(8).join('\n'));

    final pins = <(String, Object?, Object)>[
      ('binary file count', binary, 163),
      ('bodies inflated', withBinaryBody, 163),
      // Partial-parse recovery floors: steps laid out before their group
      // markers are honestly kept OUT of the typed tree — raising these is
      // the grouping-decode roadmap, not a tuning knob.
      ('binaries decoding ≥1 sequence', binaryWithSequences, greaterThanOrEqualTo(80)),
      ('binary steps in the typed model', binaryStepsRecovered, greaterThanOrEqualTo(30)),
      ('binary typed steps', binaryTypedSteps, greaterThanOrEqualTo(25)),
      ('binary module-bound steps', binaryModuleSteps, greaterThanOrEqualTo(10)),
      ('bodies framed', framed, binary),
      ('leadingWords[2] == 1', word2Is1, binary),
      ('name tables found', nameFound, binary),
      ('name tables with core tokens', hasModelTokens, binary),
      ('name table not the largest segment', notLargest / binary, greaterThan(0.95)),
      ('expressions outside the name table', valuesOutsideName, binary),
      ('pools rooted at SequenceFileData', rooted, greaterThanOrEqualTo(80)),
      ('rooted pools opening [.., Data]', prefix2Ok, rooted),
      ('rooted pools with the full scaffold', scaffold5Ok / rooted, greaterThan(0.95)),
      ('record word[2] indexes name[1]==Data', recordIndexesData, rooted),
      ('rooted files exposing object names', objNamesOk, rooted),
      ('analyzeBinary consistency checks', analyzeChecked, binary),
      ('triplet real-name hit rate', realRate, greaterThan(0.8)),
      ('triplet real-vs-control separation', realRate - fakeRate, greaterThan(0.25)),
      ('real-name triplet samples', realTot, greaterThan(0)),
      ('files with ≥1 module path', withPath, greaterThanOrEqualTo(binary ~/ 2)),
      ('non-ASCII module paths', nonAsciiPaths, greaterThan(0)),
      ('files with ≥1 ID#: ref', withId, greaterThanOrEqualTo((binary * 9) ~/ 10)),
      ('files with ≥1 expression', withExpr, greaterThanOrEqualTo((binary * 9) ~/ 10)),
      ('files with ≥1 quoted literal', withLit, greaterThanOrEqualTo((binary * 9) ~/ 10)),
    ];
    for (final (label, actual, want) in pins) {
      expect(actual, want, reason: label);
    }
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
      if (f == null) return; // pinned file absent from this corpus checkout
      final sf = parseSeqFile(f.readAsBytesSync());
      final indexed = <SeqProperty>[];
      collectIndexed(sf.data, indexed);
      for (final t in sf.types) {
        collectIndexed(t, indexed);
      }
      // The file stores single-element sparse arrays at index [1].
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
