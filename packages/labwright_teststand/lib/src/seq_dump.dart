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
  return b.toString();
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
  }

  final limits = step.limits;
  if (limits != null) parts.write('  {limits ${limits.summary}}');

  final s = step.settings;
  final notes = <String>[];
  if (!s.isNormalMode) notes.add('mode ${s.mode}');
  if (s.flowSummary != null) notes.add('flow ${s.flowSummary}');
  String resolveTarget(String t) =>
      t.startsWith('ID#:') ? (file.stepNameForId(t) ?? t) : t;
  if (s.customTrueTarget != null) {
    notes.add('cust-true→${resolveTarget(s.customTrueTarget!)}');
  }
  if (s.customFalseTarget != null) {
    notes.add('cust-false→${resolveTarget(s.customFalseTarget!)}');
  }
  if (s.isLooping) notes.add('loop ${s.loopType}');
  if (s.precondition != null) notes.add('if ${s.precondition}');
  if (notes.isNotEmpty) parts.write('  (${notes.join('; ')})');

  if (step.comment != null) parts.write('  // ${step.comment}');

  return parts.toString();
}
