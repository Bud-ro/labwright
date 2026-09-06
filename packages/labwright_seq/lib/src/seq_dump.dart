import 'dart:typed_data';

import 'seq_binary.dart';
import 'seq_file.dart';
import 'seq_format.dart';
import 'seq_module.dart';
import 'seq_step.dart';

const _enumValueCap = 6;

String dumpSeqFile(SeqFile file) {
  final out = StringBuffer();
  final header = file.header;
  out.writeln(
    '${header.fileType ?? 'TestStand file'} '
    '(${header.productName ?? '?'} v${header.fileVersion ?? '?'}, ${header.format.name})',
  );
  out.writeln('${file.types.length} types · ${file.sequences.length} sequences');

  for (final seq in file.sequences) {
    out.writeln();
    out.writeln('Sequence: ${seq.name}');
    if (seq.comment != null) out.writeln('  // ${seq.comment}');
    _dumpVars(out, 'Parameters', seq.parameters);
    _dumpVars(out, 'Locals', seq.locals);
    for (final group in StepGroup.values) {
      final steps = seq.stepsIn(group);
      if (steps.isEmpty) continue;
      out.writeln('  ${group.key}:');
      for (final step in steps) {
        out.writeln('    - ${_dumpStep(step, file)}');
      }
    }
  }
  _dumpPlugins(out, file);
  _dumpTypes(out, file);
  out.writeln();
  out.writeln('=== Sequence logic ===');
  out.write(exportSequenceLogic(file));
  return out.toString();
}

String exportSequenceLogic(SeqFile file) {
  final out = StringBuffer();
  for (final seq in file.sequences) {
    out.writeln('sequence ${seq.name}${_paramSignature(seq)}:${_seqSummary(seq)}');
    for (final group in StepGroup.values) {
      final steps = seq.stepsIn(group);
      if (steps.isEmpty) continue;
      out.writeln('  ${group.key}:');
      _emitLogic(out, steps, file, baseIndent: 2);
    }
    out.writeln();
  }
  return out.toString();
}

String _paramSignature(Sequence seq) {
  final params = seq.parameters;
  if (params.isEmpty) return '';
  String one(SeqVariable p) {
    final ty = p.type != null ? ': ${p.type}' : '';
    final val = p.value != null ? ' = ${p.value}' : '';
    return '${p.name}$ty$val';
  }

  return '(${params.map(one).join(', ')})';
}

String _seqSummary(Sequence seq) {
  final steps = seq.steps.length;
  final locals = seq.locals.length;
  if (steps == 0 && locals == 0) return '';
  final parts = [
    '$steps ${steps == 1 ? 'step' : 'steps'}',
    if (locals > 0) '$locals ${locals == 1 ? 'local' : 'locals'}',
  ];
  return '  // ${parts.join(', ')}';
}

void _emitLogic(StringBuffer out, List<Step> steps, SeqFile file, {required int baseIndent}) {
  var depth = baseIndent;
  String ind(int depth) => '  ' * depth;
  for (final step in steps) {
    final fc = step.flowControl;
    if (fc == null) {
      out.writeln('${ind(depth)}${_logicStepLine(step, file)}');
      continue;
    }
    if (fc.kind.closesBlock) {
      if (depth > baseIndent) depth--;
      out.writeln('${ind(depth)}}');
    } else if (fc.kind.isContinuation) {
      final effectiveDepth = depth > baseIndent ? depth - 1 : baseIndent;
      out.writeln('${ind(effectiveDepth)}} ${fc.header} {');
      depth = effectiveDepth + 1;
    } else if (fc.kind.opensBlock) {
      out.writeln('${ind(depth)}${fc.header} {');
      depth++;
    } else {
      out.writeln('${ind(depth)}${fc.header}');
    }
  }
}

String _logicStepLine(Step step, SeqFile file) {
  final out = StringBuffer(step.name);
  final module = step.module;
  if (module.adapter != SeqAdapter.none && module.target != null) {
    out.write(' → ${module.target}');
    if (module.adapter == SeqAdapter.sequenceCall && file.resolveCall(step) == null) {
      final sf = module.sequenceFile;
      if (sf != null && sf.isNotEmpty) out.write(' in $sf');
    }
  }
  final pre = step.settings.precondition;
  if (pre != null) out.write('  [if $pre]');
  final lim = step.limits;
  if (lim != null) out.write('  [${lim.summary}]');
  final loop = _loopAnnotation(step.settings);
  if (loop != null) out.write('  $loop');
  final jump = _jumpAnnotation(step.settings, file);
  if (jump != null) out.write('  $jump');
  return out.toString();
}

String? _loopAnnotation(StepSettings set) {
  if (!set.isLooping) return null;
  final type = set.loopType ?? 'loop';
  final whileExpr = set.loopWhile;
  return whileExpr != null ? '[loop $type while $whileExpr]' : '[loop $type]';
}

String? _jumpAnnotation(StepSettings set, SeqFile file) {
  String resolve(String target) => target.startsWith('ID#:') ? (file.stepNameForId(target) ?? target) : target;
  String? side(String label, String? act, String? target) {
    if (act == null || act == 'Next') return null;
    return target != null ? 'on $label → ${resolve(target)}' : 'on $label: $act';
  }

  final parts = [
    side('pass', set.passAction, set.passActionTarget),
    side('fail', set.failAction, set.failActionTarget),
  ].whereType<String>();
  return parts.isEmpty ? null : '[${parts.join(', ')}]';
}

void _dumpPlugins(StringBuffer out, SeqFile file) {
  final mp = file.measurementPlugIns;
  if (mp == null || !mp.isNotEmpty) return;
  out.writeln();
  out.writeln('Measurement plug-ins:');
  if (mp.pinMapPath != null) out.writeln('  pin map: ${mp.pinMapPath}');
  void list(String label, List<String> paths) {
    if (paths.isNotEmpty) out.writeln('  $label: ${paths.join(', ')}');
  }

  list('specifications', mp.specificationFiles);
  list('levels', mp.levelsFiles);
  list('timing', mp.timingFiles);
  list('patterns', mp.patternFiles);
}

void _dumpTypes(StringBuffer out, SeqFile file) {
  final defs = file.typeDefs;
  if (defs.isEmpty) return;
  out.writeln();
  out.writeln('Types (${defs.length}):');
  for (final typeDef in defs) {
    final base = typeDef.baseClass != null ? ' : ${typeDef.baseClass}' : '';
    out.writeln('  ${typeDef.name}$base');
    for (final field in typeDef.fields) {
      final ty = field.type != null ? ' [${field.type}]' : '';
      out.writeln('      .${field.name}$ty');
    }
  }
}

void _dumpVars(StringBuffer out, String label, List<SeqVariable> vars) {
  if (vars.isEmpty) return;
  out.writeln('  $label:');
  for (final variable in vars) {
    out.writeln('    • ${variable.name} : ${variable.type ?? '(untyped)'}${_varSuffix(variable)}');
  }
}

String _varSuffix(SeqVariable v) {
  final out = StringBuffer();
  if (v.value != null) {
    out.write(' = ${v.value}');
  } else if (v.containerCount != null) {
    out.write(
      v.isArray ? ' [${v.containerCount}]' : ' {${v.containerCount} ${v.containerCount == 1 ? 'field' : 'fields'}}',
    );
  }
  if (v.comment != null) out.write('  // ${v.comment}');
  return out.toString();
}

String _dumpCallParam(CallParameter p) {
  final out = StringBuffer(p.name);
  if (p.direction != null) out.write(' ${p.direction}');
  if (p.boundExpression != null) out.write('←${p.boundExpression}');
  return out.toString();
}

String _dumpViParam(CallParameter p) {
  final out = StringBuffer();
  if (p.connectorNumber != null) out.write('#${p.connectorNumber} ');
  out.write(p.name);
  if (p.displayType != null) out.write(' (${p.displayType})');
  if (p.boundExpression != null) out.write('←${p.boundExpression}');
  return out.toString();
}

String _dumpStep(Step step, SeqFile file) {
  final parts = StringBuffer('${step.name} [${step.type ?? '?'}]');

  final module = step.module;
  if (module.adapter != SeqAdapter.none) {
    final target = switch (module.adapter) {
      SeqAdapter.python => module.target ?? '(target not yet recovered)',
      _ => module.target ?? '(none)',
    };
    parts.write(' -> ${module.adapter.name}: $target');
    if (module.adapter == SeqAdapter.sequenceCall) {
      parts.write(
        file.resolveCall(step) != null
            ? ' (in this file)'
            : ' (external${module.sequenceFile != null ? ': ${module.sequenceFile}' : ''})',
      );
    }
    final args = module.callParameters;
    if (args.isNotEmpty) {
      parts.write('  {args: ${args.map(_dumpCallParam).join('; ')}}');
    }
    if (module.adapter == SeqAdapter.labView) {
      final lv = <String>[];
      if (module.viNamespace != null) lv.add('lib ${module.viNamespace}');
      if (module.viProjectPath != null) lv.add('proj ${module.viProjectPath}');
      if (lv.isNotEmpty) parts.write('  {vi: ${lv.join(', ')}}');
      final vps = module.viParameters;
      if (vps.isNotEmpty) {
        parts.write('  {conn: ${vps.map(_dumpViParam).join('; ')}}');
      }
    }
    if (module.adapter == SeqAdapter.python) {
      final py = <String>[];
      if (module.pythonModulePath != null) py.add('mod ${module.pythonModulePath}');
      if (module.pythonClassName != null) py.add('class ${module.pythonClassName}');
      if (module.pythonVersion != null) py.add('py ${module.pythonVersion}');
      if (py.isNotEmpty) parts.write('  {python: ${py.join(', ')}}');
    }
  }

  final limits = step.limits;
  final units = step.resultUnits;
  if (limits != null) {
    parts.write('  {limits ${limits.summary}${units != null ? ' $units' : ''}}');
  } else if (units != null) {
    parts.write('  {units $units}');
  }
  if (limits == null && step.dataSource != null) {
    parts.write('  {data-source ${step.dataSource}}');
  }

  final settings = step.settings;
  if (settings.icon != null) parts.write('  {icon ${settings.icon}}');
  final notes = <String>[];
  if (!settings.isNormalMode) notes.add('mode ${settings.mode}');
  if (settings.flowSummary != null) notes.add('flow ${settings.flowSummary}');
  if (settings.loadOption != null && settings.loadOption != 'PreloadWhenExecuted') {
    notes.add('load ${settings.loadOption}');
  }
  if (settings.unloadOption != null && settings.unloadOption != 'UnloadWithFile') {
    notes.add('unload ${settings.unloadOption}');
  }
  String resolveTarget(String target) => target.startsWith('ID#:') ? (file.stepNameForId(target) ?? target) : target;
  if (settings.customExpression != null) notes.add('cust-cond ${settings.customExpression}');
  if (settings.customTrueTarget != null) {
    notes.add('cust-true→${resolveTarget(settings.customTrueTarget!)}');
  }
  if (settings.customFalseTarget != null) {
    notes.add('cust-false→${resolveTarget(settings.customFalseTarget!)}');
  }
  if (settings.isLooping) {
    final lp = <String>[];
    if (settings.loopWhile != null) lp.add('while ${settings.loopWhile}');
    if (settings.loopInitialize != null) lp.add('init ${settings.loopInitialize}');
    if (settings.loopIncrement != null) lp.add('incr ${settings.loopIncrement}');
    notes.add('loop ${settings.loopType}${lp.isEmpty ? '' : ' [${lp.join('; ')}]'}');
  }
  if (settings.precondition != null) notes.add('if ${settings.precondition}');
  if (settings.ignoresRunTimeErrors == true) notes.add('ignore-RTE');
  if (settings.failureCausesSequenceFailure == false) notes.add('no-seq-fail');
  if (settings.recordsResult == false) notes.add('no-record');
  if (settings.usesMutex == true) {
    notes.add('mutex${settings.mutexName != null ? ' ${settings.mutexName}' : ''}');
  }
  if (notes.isNotEmpty) parts.write('  (${notes.join('; ')})');

  final mp = step.measurementParameters;
  if (mp.isNotEmpty) {
    String fmt(MeasurementParameter p) {
      final out = StringBuffer(p.name);
      if (p.direction != null) out.write(' ${p.direction!.toLowerCase()}');
      if (p.dataType != null) out.write(' ${p.dataType}');
      if (p.typeSpecialization != null) out.write(' (${p.typeSpecialization})');
      if (p.isArray) out.write('[]');
      if (p.value != null) out.write(' = ${p.value}');
      final ev = p.enumValues;
      if (ev.isNotEmpty) {
        final shown = ev.take(_enumValueCap).map((e) => '${e.name}=${e.value ?? '?'}');
        final more = ev.length > _enumValueCap ? ', …(${ev.length})' : '';
        out.write(' {${shown.join(', ')}$more}');
      }
      if (p.logged == false) out.write(' [not logged]');
      return out.toString();
    }

    parts.write('  {params: ${mp.map(fmt).join('; ')}}');
  }

  final addl = step.additionalResults;
  if (addl.isNotEmpty) {
    String fmt(AdditionalResult a) => a.condition != null ? '${a.name} if ${a.condition}' : a.name;
    parts.write('  {+results: ${addl.map(fmt).join(', ')}}');
  }

  final res = step.result;
  if (res != null && res.hasRecordedOutcome) {
    final resultBits = <String>[];
    if (res.status != null) resultBits.add('status ${res.status}');
    if (res.errorOccurred == true) {
      final code = res.errorCode;
      final msg = res.errorMessage;
      resultBits.add('error${code != null ? ' $code' : ''}${msg != null ? ' "$msg"' : ''}');
    }
    if (res.reportText != null) resultBits.add('report "${res.reportText}"');
    if (resultBits.isNotEmpty) parts.write('  {result: ${resultBits.join('; ')}}');
  }

  if (step.comment != null) parts.write('  // ${step.comment}');

  return parts.toString();
}

String dumpBinaryRecon(Uint8List seqBytes) {
  if (detectSeqFormat(seqBytes) != SeqFormat.binary) {
    return '(not a binary TOF1 file)';
  }
  final header = detectSeqHeader(seqBytes);
  final out = StringBuffer();
  out.writeln(
    '${header.fileType ?? 'TestStand file'} '
    '(${header.productName ?? '?'} v${header.fileVersion ?? '?'}, ${header.format.name})',
  );

  final analysis = analyzeBinary(seqBytes);
  if (analysis == null) {
    out.writeln('(binary body did not inflate/frame — recon unavailable)');
    return out.toString();
  }
  out.writeln(
    'inflated body ${analysis.inflatedSize} bytes · ${analysis.strings.length} '
    'strings · ${analysis.nameTable.length} name-table entries',
  );

  out.writeln();
  out.writeln('=== Layout ===');
  if (analysis.layout case final l?) {
    out.writeln('  record region: ${l.recordRegionLength} bytes');
    out.writeln('  string region @ ${l.stringRegionOffset}');
    out.writeln('  record sentinels: ${l.sentinelCount}');
    out.writeln(
      '  strings in region: ${l.stringCount} · tables: '
      '${l.segmentCount}',
    );
    if (l.leadingWords.isNotEmpty) {
      out.writeln('  leading record words: ${l.leadingWords.join(', ')}');
    }
  } else {
    out.writeln('  (body did not frame into record/string regions)');
  }

  _reconSection(out, 'Named-record headers', [
    for (final record in analysis.namedRecords)
      '${record.name} ×${record.count}  (raw tag ${record.rawTag}, not modeled)',
  ]);
  _reconSection(out, 'Object names', analysis.objectNames);
  _reconSection(out, 'Module call-targets', analysis.modulePaths);
  _reconSection(out, 'Step references', analysis.stepReferences);
  _reconSection(out, 'Expressions (test logic)', analysis.expressions);
  _reconSection(out, 'Quoted literals (values)', analysis.quotedLiterals);
  _reconSection(out, 'Inline numeric values', [for (final value in analysis.scalarDoubles) '$value']);
  _reconSection(out, 'Named scalar values', [
    for (final scalar in analysis.namedScalars)
      '${scalar.name} = ${scalar.value}  (raw type ${scalar.rawTypeCode}, not modeled)',
  ]);

  out.writeln();
  out.writeln(
    '(record links not yet decoded: the above are recovered values; the '
    'variable-length record grammar tying each to its step tree is not yet '
    'recovered)',
  );
  return out.toString();
}

void _reconSection(
  StringBuffer b,
  String title,
  List<String> items, {
  int cap = 40,
}) {
  if (items.isEmpty) return;
  b.writeln();
  b.writeln('=== $title (${items.length}) ===');
  for (final it in items.take(cap)) {
    b.writeln('  $it');
  }
  if (items.length > cap) b.writeln('  … and ${items.length - cap} more');
}
