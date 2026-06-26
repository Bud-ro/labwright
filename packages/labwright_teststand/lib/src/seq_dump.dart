import 'seq_file.dart';

/// Renders a [SeqFile] as a faithful, sequence-editor-like text view — the M4
/// "viewer" in text form. Pure (returns a String); honest (shows
/// `(not yet recovered)` / omits a field rather than inventing one).
String dumpSeqFile(SeqFile f) {
  final b = StringBuffer();
  final h = f.header;
  b.writeln('${h.fileType ?? 'TestStand file'} '
      '(${h.productName ?? '?'} v${h.fileVersion ?? '?'}, ${h.format.name})');
  b.writeln('${f.types.length} types · ${f.sequences.length} sequences');

  for (final seq in f.sequences) {
    b.writeln();
    b.writeln('Sequence: ${seq.name}');
    if (seq.comment != null) b.writeln('  // ${seq.comment}');
    _dumpVars(b, 'Parameters', seq.parameters);
    _dumpVars(b, 'Locals', seq.locals);
    for (final group in StepGroup.values) {
      final steps = seq.stepsIn(group);
      if (steps.isEmpty) continue;
      b.writeln('  ${group.key}:');
      for (final step in steps) {
        b.writeln('    - ${_dumpStep(step, f)}');
      }
    }
  }
  _dumpPlugins(b, f);
  _dumpTypes(b, f);
  b.writeln();
  b.writeln('=== Sequence logic ===');
  b.write(exportSequenceLogic(f));
  return b.toString();
}

/// Renders each sequence's steps as readable, **nested** control-flow pseudocode
/// — the structured logic view, complementary to the flat per-step listing above.
///
/// The `NI_Flow_*` step types form structured blocks: If/ElseIf/Else, While,
/// For, ForEach open a block closed by a matching `NI_Flow_End` (corpus-verified
/// balanced), and each carries its real condition / loop expressions (see
/// [FlowControl]). Ordinary steps render at the current indent with their call
/// target + key gating expression / limits. Built entirely from already-recovered
/// fields — no new decode.
String exportSequenceLogic(SeqFile f) {
  final b = StringBuffer();
  for (final seq in f.sequences) {
    b.writeln('sequence ${seq.name}:');
    for (final group in StepGroup.values) {
      final steps = seq.stepsIn(group);
      if (steps.isEmpty) continue;
      b.writeln('  ${group.key}:');
      _emitLogic(b, steps, baseIndent: 2);
    }
    b.writeln();
  }
  return b.toString();
}

/// Emits [steps] as indented logic, opening/closing blocks on `NI_Flow_*` steps.
/// [baseIndent] is the starting indent depth (in 2-space units). Indent never
/// drops below [baseIndent], so a malformed/unbalanced block can't underflow.
void _emitLogic(StringBuffer b, List<Step> steps, {required int baseIndent}) {
  var depth = baseIndent;
  String ind(int d) => '  ' * d;
  for (final step in steps) {
    final fc = step.flowControl;
    if (fc == null) {
      b.writeln('${ind(depth)}${_logicStepLine(step)}');
      continue;
    }
    if (fc.kind.closesBlock) {
      if (depth > baseIndent) depth--;
      b.writeln('${ind(depth)}}');
    } else if (fc.kind.isContinuation) {
      // `} else if (…) {` — dedent to the opener level, then re-open.
      final d = depth > baseIndent ? depth - 1 : baseIndent;
      b.writeln('${ind(d)}} ${fc.header} {');
      depth = d + 1;
    } else if (fc.kind.opensBlock) {
      b.writeln('${ind(depth)}${fc.header} {');
      depth++;
    } else {
      // break / continue — a statement at the current level.
      b.writeln('${ind(depth)}${fc.header}');
    }
  }
}

/// A concise one-line logic rendering of a non-flow step: its name, the module
/// target it calls, and the most decision-relevant annotations (precondition,
/// limits) — kept short so the nested structure stays readable.
String _logicStepLine(Step step) {
  final b = StringBuffer(step.name);
  final m = step.module;
  if (m.adapter != SeqAdapter.none && m.target != null) {
    b.write(' → ${m.target}');
  }
  final pre = step.settings.precondition;
  if (pre != null) b.write('  [if $pre]');
  final lim = step.limits;
  if (lim != null) b.write('  [${lim.summary}]');
  return b.toString();
}

/// Lists the Semiconductor-Test-System resource set the file declares (pin map +
/// specifications/levels/timing/pattern files) — the external files the sequence
/// depends on. Omitted when the file declares none.
void _dumpPlugins(StringBuffer b, SeqFile f) {
  final mp = f.measurementPlugIns;
  if (mp == null || !mp.isNotEmpty) return;
  b.writeln();
  b.writeln('Measurement plug-ins:');
  if (mp.pinMapPath != null) b.writeln('  pin map: ${mp.pinMapPath}');
  void list(String label, List<String> paths) {
    if (paths.isNotEmpty) b.writeln('  $label: ${paths.join(', ')}');
  }

  list('specifications', mp.specificationFiles);
  list('levels', mp.levelsFiles);
  list('timing', mp.timingFiles);
  list('patterns', mp.patternFiles);
}

/// Lists the `<typelist>` type definitions and their declared fields. This is
/// recovered structure (type name, base class, field names + type tokens) — not
/// an interpretation of NI's internal type-system semantics.
void _dumpTypes(StringBuffer b, SeqFile f) {
  final defs = f.typeDefs;
  if (defs.isEmpty) return;
  b.writeln();
  b.writeln('Types (${defs.length}):');
  for (final t in defs) {
    final base = t.baseClass != null ? ' : ${t.baseClass}' : '';
    b.writeln('  ${t.name}$base');
    for (final field in t.fields) {
      final ty = field.type != null ? ' [${field.type}]' : '';
      b.writeln('      .${field.name}$ty');
    }
  }
}

void _dumpVars(StringBuffer b, String label, List<SeqVariable> vars) {
  if (vars.isEmpty) return;
  b.writeln('  $label:');
  for (final v in vars) {
    b.writeln('    • ${v.name} : ${v.type ?? '(untyped)'}${_varSuffix(v)}');
  }
}

/// The trailing detail for a variable: ` = value` for a scalar, else a container
/// size (` [N]` array / ` {N fields}` object), plus ` // comment` when present.
String _varSuffix(SeqVariable v) {
  final b = StringBuffer();
  if (v.value != null) {
    b.write(' = ${v.value}');
  } else if (v.containerCount != null) {
    b.write(v.isArray
        ? ' [${v.containerCount}]'
        : ' {${v.containerCount} ${v.containerCount == 1 ? 'field' : 'fields'}}');
  }
  if (v.comment != null) b.write('  // ${v.comment}');
  return b.toString();
}

/// Renders one module call argument as `name[ dir][←expr]` — e.g.
/// `LoginName in←FileGlobals.UserToAutoLogin`, `Return Value out`.
String _dumpCallParam(CallParameter p) {
  final b = StringBuffer(p.name);
  if (p.direction != null) b.write(' ${p.direction}');
  if (p.boundExpression != null) b.write('←${p.boundExpression}');
  return b.toString();
}

/// Renders one LabVIEW VI-call connector parameter as
/// `[#conn ]label[ (DisplayType)][←expr]` — e.g.
/// `#11 sequence context (Object Reference)←ThisContext`.
String _dumpViParam(CallParameter p) {
  final b = StringBuffer();
  if (p.connectorNumber != null) b.write('#${p.connectorNumber} ');
  b.write(p.name);
  if (p.displayType != null) b.write(' (${p.displayType})');
  if (p.boundExpression != null) b.write('←${p.boundExpression}');
  return b.toString();
}

String _dumpStep(Step step, SeqFile file) {
  final parts = StringBuffer('${step.name} [${step.type ?? '?'}]');

  final m = step.module;
  if (m.adapter != SeqAdapter.none) {
    final target = switch (m.adapter) {
      SeqAdapter.python => m.target ?? '(target not yet recovered)',
      _ => m.target ?? '(none)',
    };
    parts.write(' -> ${m.adapter.name}: $target');
    if (m.adapter == SeqAdapter.sequenceCall) {
      parts.write(file.resolveCall(step) != null
          ? ' (in this file)'
          : ' (external${m.sequenceFile != null ? ': ${m.sequenceFile}' : ''})');
    }
    final args = m.callParameters;
    if (args.isNotEmpty) {
      parts.write('  {args: ${args.map(_dumpCallParam).join('; ')}}');
    }
    // LabVIEW VI call: the library/project that owns the VI and its connector
    // pane (the terminals wired to the subVI), when recovered.
    if (m.adapter == SeqAdapter.labView) {
      final lv = <String>[];
      if (m.viNamespace != null) lv.add('lib ${m.viNamespace}');
      if (m.viProjectPath != null) lv.add('proj ${m.viProjectPath}');
      if (lv.isNotEmpty) parts.write('  {vi: ${lv.join(', ')}}');
      final vps = m.viParameters;
      if (vps.isNotEmpty) {
        parts.write('  {conn: ${vps.map(_dumpViParam).join('; ')}}');
      }
    }
    // Python call: the module file, owning class, and interpreter version.
    if (m.adapter == SeqAdapter.python) {
      final py = <String>[];
      if (m.pythonModulePath != null) py.add('mod ${m.pythonModulePath}');
      if (m.pythonClassName != null) py.add('class ${m.pythonClassName}');
      if (m.pythonVersion != null) py.add('py ${m.pythonVersion}');
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
  // The data-source expression (measured value / pass-fail criterion). Shown for
  // non-limit steps (e.g. PassFailTest); for a limit test it already rides along
  // the limits chip's structured detail, so it isn't repeated here.
  if (limits == null && step.dataSource != null) {
    parts.write('  {data-source ${step.dataSource}}');
  }

  final s = step.settings;
  if (s.icon != null) parts.write('  {icon ${s.icon}}');
  final notes = <String>[];
  if (!s.isNormalMode) notes.add('mode ${s.mode}');
  if (s.flowSummary != null) notes.add('flow ${s.flowSummary}');
  // Module load/unload timing, only when it differs from the common default.
  if (s.loadOption != null && s.loadOption != 'PreloadWhenExecuted') {
    notes.add('load ${s.loadOption}');
  }
  if (s.unloadOption != null && s.unloadOption != 'UnloadWithFile') {
    notes.add('unload ${s.unloadOption}');
  }
  String resolveTarget(String t) =>
      t.startsWith('ID#:') ? (file.stepNameForId(t) ?? t) : t;
  // The custom-condition expression (the step's own true/false branch test),
  // shown before its branch targets.
  if (s.customExpression != null) notes.add('cust-cond ${s.customExpression}');
  if (s.customTrueTarget != null) {
    notes.add('cust-true→${resolveTarget(s.customTrueTarget!)}');
  }
  if (s.customFalseTarget != null) {
    notes.add('cust-false→${resolveTarget(s.customFalseTarget!)}');
  }
  if (s.isLooping) {
    // The loop's actual logic: continue condition, init, and increment exprs.
    final lp = <String>[];
    if (s.loopWhile != null) lp.add('while ${s.loopWhile}');
    if (s.loopInitialize != null) lp.add('init ${s.loopInitialize}');
    if (s.loopIncrement != null) lp.add('incr ${s.loopIncrement}');
    notes.add('loop ${s.loopType}${lp.isEmpty ? '' : ' [${lp.join('; ')}]'}');
  }
  if (s.precondition != null) notes.add('if ${s.precondition}');
  // Notable non-default execution flags.
  if (s.ignoresRunTimeErrors == true) notes.add('ignore-RTE');
  if (s.failureCausesSequenceFailure == false) notes.add('no-seq-fail');
  if (s.recordsResult == false) notes.add('no-record');
  // Step mutex synchronization, only when the step actually locks one.
  if (s.usesMutex == true) {
    notes.add('mutex${s.mutexName != null ? ' ${s.mutexName}' : ''}');
  }
  if (notes.isNotEmpty) parts.write('  (${notes.join('; ')})');

  // Measurement-step formal parameters: name [direction] [type][\[\]] [= value].
  final mp = step.measurementParameters;
  if (mp.isNotEmpty) {
    String fmt(MeasurementParameter p) {
      final b = StringBuffer(p.name);
      if (p.direction != null) b.write(' ${p.direction!.toLowerCase()}');
      if (p.dataType != null) b.write(' ${p.dataType}');
      if (p.typeSpecialization != null) b.write(' (${p.typeSpecialization})');
      if (p.isArray) b.write('[]');
      if (p.value != null) b.write(' = ${p.value}');
      // The enum's allowed values for a TypeEnum param (capped for readability).
      final ev = p.enumValues;
      if (ev.isNotEmpty) {
        final shown = ev.take(6).map((e) => '${e.name}=${e.value ?? '?'}');
        final more = ev.length > 6 ? ', …(${ev.length})' : '';
        b.write(' {${shown.join(', ')}$more}');
      }
      if (p.logged == false) b.write(' [not logged]');
      return b.toString();
    }

    parts.write('  {params: ${mp.map(fmt).join('; ')}}');
  }

  // "Additional Results" recording spec: the extra values the step logs, each
  // with its gating condition when one is set.
  final addl = step.additionalResults;
  if (addl.isNotEmpty) {
    String fmt(AdditionalResult a) =>
        a.condition != null ? '${a.name} if ${a.condition}' : a.name;
    parts.write('  {+results: ${addl.map(fmt).join(', ')}}');
  }

  // A recorded run outcome (`Result`), shown only when it carries non-default
  // values (a sequence file's un-run steps hold only defaults → nothing shown).
  final res = step.result;
  if (res != null && res.hasRecordedOutcome) {
    final r = <String>[];
    if (res.status != null) r.add('status ${res.status}');
    if (res.errorOccurred == true) {
      final code = res.errorCode;
      final msg = res.errorMessage;
      r.add('error${code != null ? ' $code' : ''}${msg != null ? ' "$msg"' : ''}');
    }
    if (res.reportText != null) r.add('report "${res.reportText}"');
    if (r.isNotEmpty) parts.write('  {result: ${r.join('; ')}}');
  }

  if (step.comment != null) parts.write('  // ${step.comment}');

  return parts.toString();
}
