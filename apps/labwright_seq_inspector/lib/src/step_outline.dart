library;

import 'package:labwright_seq/labwright_seq.dart';

import 'sequence_outline.dart';

class StepOutline {
  StepOutline({
    required this.name,
    required this.type,
    this.adapter,
    this.target,
    this.callTargetIndex,
    this.externalCall,
    this.limits,
    this.limitsDetail,
    this.units,
    this.dataSource,
    this.runMode,
    this.comment,
    this.expressions = const [],
    this.callArgs = const [],
    this.measurementParams = const [],
    this.connectorParams = const [],
    this.flowHeader,
    this.flowDepth = 0,
    required this.notes,
  });

  final String name;
  final String type;

  final String? flowHeader;

  final int flowDepth;

  final String? comment;

  final String? runMode;

  final SeqAdapter? adapter;

  final String? target;

  final int? callTargetIndex;

  final String? externalCall;

  final String? limits;

  final LimitsOutline? limitsDetail;

  final String? units;

  final String? dataSource;

  final List<(String, String)> expressions;

  final List<CallArgOutline> callArgs;

  final List<MeasurementParamOutline> measurementParams;

  final List<ConnectorParamOutline> connectorParams;

  final List<String> notes;

  ({String label, String tooltip})? get targetDisplay {
    final targetText = target;
    if (targetText == null) return null;
    final label = pathBasename(targetText);
    return (label: label.isEmpty ? targetText : label, tooltip: targetText);
  }

  factory StepOutline.of(Step step, SeqFile file, {int flowDepth = 0}) {
    final module = step.module;
    SeqAdapter? adapter;
    String? target;
    int? callTargetIndex;
    String? externalCall;
    if (module.adapter != SeqAdapter.none) {
      adapter = module.adapter;
      target = switch (module.adapter) {
        SeqAdapter.python => module.target ?? '(target not yet recovered)',
        _ => module.target ?? '(none)',
      };
      if (module.adapter == SeqAdapter.sequenceCall) {
        final resolved = file.resolveCall(step);
        if (resolved != null) {
          callTargetIndex = file.sequences.indexOf(resolved);
        } else {
          externalCall = module.sequenceFile ?? '';
        }
      }
    }

    final settings = step.settings;
    final runMode = settings.isNormalMode ? null : settings.mode;
    final notes = <String>[];
    if (settings.flowSummary != null) notes.add('flow ${settings.flowSummary}');
    String resolveTarget(String target) => target.startsWith('ID#:')
        ? (file.stepNameForId(target) ?? target)
        : target;
    if (settings.customTrueTarget case final target?) {
      notes.add('cust-true→${resolveTarget(target)}');
    }
    if (settings.customFalseTarget case final target?) {
      notes.add('cust-false→${resolveTarget(target)}');
    }
    if (module.adapter == SeqAdapter.labView) {
      final lv = <String>[];
      if (module.viNamespace != null) lv.add('lib ${module.viNamespace}');
      if (module.viProjectPath != null) lv.add('proj ${module.viProjectPath}');
      if (lv.isNotEmpty) notes.add('vi: ${lv.join(', ')}');
    }
    if (module.adapter == SeqAdapter.python) {
      final py = <String>[];
      if (module.pythonModulePath != null)
        py.add('mod ${module.pythonModulePath}');
      if (module.pythonClassName != null)
        py.add('class ${module.pythonClassName}');
      if (module.pythonVersion != null) py.add('py ${module.pythonVersion}');
      if (py.isNotEmpty) notes.add('python: ${py.join(', ')}');
    }
    if (settings.loadOption != null &&
        settings.loadOption != 'PreloadWhenExecuted') {
      notes.add('load ${settings.loadOption}');
    }
    if (settings.unloadOption != null &&
        settings.unloadOption != 'UnloadWithFile') {
      notes.add('unload ${settings.unloadOption}');
    }
    if (settings.isLooping) notes.add('loop ${settings.loopType}');
    if (settings.ignoresRunTimeErrors == true) notes.add('ignore-RTE');
    if (settings.failureCausesSequenceFailure == false)
      notes.add('no-seq-fail');
    if (settings.recordsResult == false) notes.add('no-record');
    final addl = step.additionalResults;
    if (addl.isNotEmpty) {
      String fmt(AdditionalResult a) =>
          a.condition != null ? '${a.name} if ${a.condition}' : a.name;
      notes.add('+results: ${addl.map(fmt).join(', ')}');
    }
    if (settings.usesMutex == true) {
      notes.add(
        'mutex${settings.mutexName != null ? ' ${settings.mutexName}' : ''}',
      );
    }
    final res = step.result;
    if (res != null && res.hasRecordedOutcome) {
      final resultBits = <String>[];
      if (res.status != null) resultBits.add('status ${res.status}');
      if (res.errorOccurred == true) {
        final code = res.errorCode;
        resultBits.add('error${code != null ? ' $code' : ''}');
      }
      if (res.reportText != null) resultBits.add('report "${res.reportText}"');
      if (resultBits.isNotEmpty) notes.add('result ${resultBits.join('; ')}');
    }

    final expressions = <(String, String)>[
      if (settings.precondition case final e?) ('Precondition', e),
      if (settings.customExpression case final e?) ('Custom condition', e),
      if (settings.preExpression case final e?) ('Pre-expression', e),
      if (settings.postExpression case final e?) ('Post-expression', e),
      if (settings.statusExpression case final e?) ('Status', e),
      if (settings.loopInitialize case final e?) ('Loop init', e),
      if (settings.loopWhile case final e?) ('Loop while', e),
      if (settings.loopIncrement case final e?) ('Loop increment', e),
      if (settings.loopStatus case final e?) ('Loop status', e),
    ];

    final limits = step.limits;
    return StepOutline(
      name: step.name,
      type: step.type ?? '?',
      adapter: adapter,
      target: target,
      callTargetIndex: callTargetIndex,
      externalCall: externalCall,
      limits: limits?.summary,
      limitsDetail: limits == null ? null : LimitsOutline.of(limits),
      units: step.resultUnits,
      dataSource: step.dataSource,
      runMode: runMode,
      comment: step.comment,
      expressions: expressions,
      callArgs: [
        for (final param in module.callParameters) CallArgOutline.of(param),
      ],
      measurementParams: [
        for (final param in step.measurementParameters)
          MeasurementParamOutline.of(param),
      ],
      connectorParams: [
        for (final param in module.viParameters)
          ConnectorParamOutline.of(param),
      ],
      flowHeader: step.flowControl?.header,
      flowDepth: flowDepth,
      notes: notes,
    );
  }

  String get summary {
    final adapter = this.adapter;
    final out = StringBuffer('$name [$type]');
    if (flowHeader != null) out.write('  {flow: $flowHeader}');
    if (adapter != null) out.write(' -> ${adapter.name}: $target');
    if (limits != null) {
      out.write('  {limits $limits${units != null ? ' $units' : ''}}');
    } else if (units != null) {
      out.write('  {units $units}');
    }
    if (limitsDetail == null && dataSource != null) {
      out.write('  {data-source $dataSource}');
    }
    if (runMode != null) out.write('  {mode $runMode}');
    if (comment != null) out.write('  // $comment');
    if (notes.isNotEmpty) out.write('  (${notes.join('; ')})');
    for (final (label, value) in expressions) {
      out.write('  {$label: $value}');
    }
    if (callArgs.isNotEmpty) {
      out.write('  {args: ${callArgs.map((a) => a.line).join('; ')}}');
    }
    if (measurementParams.isNotEmpty) {
      out.write(
        '  {params: ${measurementParams.map((p) => p.line).join('; ')}}',
      );
    }
    if (connectorParams.isNotEmpty) {
      out.write('  {conn: ${connectorParams.map((p) => p.line).join('; ')}}');
    }
    return out.toString();
  }
}

class ConnectorParamOutline {
  ConnectorParamOutline({
    required this.name,
    this.connectorNumber,
    this.displayType,
    this.boundExpression,
  });

  final String name;
  final int? connectorNumber;
  final String? displayType;
  final String? boundExpression;

  factory ConnectorParamOutline.of(CallParameter p) => ConnectorParamOutline(
    name: p.name,
    connectorNumber: p.connectorNumber,
    displayType: p.displayType,
    boundExpression: p.boundExpression,
  );

  String get label =>
      connectorNumber != null ? '#$connectorNumber $name' : name;

  String get cell {
    final out = StringBuffer();
    if (displayType != null) out.write(displayType);
    if (boundExpression != null)
      out.write('${out.isEmpty ? '' : ' '}←$boundExpression');
    return out.isEmpty ? '(unwired)' : out.toString();
  }

  String get line {
    final out = StringBuffer();
    if (connectorNumber != null) out.write('#$connectorNumber ');
    out.write(name);
    if (displayType != null) out.write(' ($displayType)');
    if (boundExpression != null) out.write('←$boundExpression');
    return out.toString();
  }
}

class CallArgOutline {
  CallArgOutline({
    required this.name,
    this.direction,
    this.boundExpression,
    this.displayType,
  });

  final String name;
  final String? direction;
  final String? boundExpression;
  final String? displayType;

  factory CallArgOutline.of(CallParameter p) => CallArgOutline(
    name: p.name,
    direction: p.direction,
    boundExpression: p.boundExpression,
    displayType: p.displayType,
  );

  String get label => direction != null ? '$name ($direction)' : name;

  String get value => boundExpression ?? displayType ?? '(unbound)';

  String get line {
    final out = StringBuffer(name);
    if (direction != null) out.write(' $direction');
    if (boundExpression != null) out.write('←$boundExpression');
    return out.toString();
  }
}

class MeasurementParamOutline {
  MeasurementParamOutline({
    required this.name,
    this.dataType,
    this.direction,
    this.value,
    this.isArray = false,
    this.typeSpecialization,
    this.logged,
    this.enumValues = const [],
  });

  final String name;
  final String? dataType;
  final String? direction;
  final String? value;
  final bool isArray;

  final String? typeSpecialization;

  final bool? logged;

  final List<String> enumValues;

  factory MeasurementParamOutline.of(MeasurementParameter p) =>
      MeasurementParamOutline(
        name: p.name,
        dataType: p.dataType,
        direction: p.direction,
        value: p.value,
        isArray: p.isArray,
        typeSpecialization: p.typeSpecialization,
        logged: p.logged,
        enumValues: [
          for (final item in p.enumValues) '${item.name}=${item.value ?? '?'}',
        ],
      );

  String get _enumChip {
    if (enumValues.isEmpty) return '';
    final shown = enumValues.take(6).join(', ');
    final more = enumValues.length > 6 ? ', …(${enumValues.length})' : '';
    return '{$shown$more}';
  }

  String get label => switch (direction) {
    final direction? => '$name (${direction.toLowerCase()})',
    null => name,
  };

  String get cell {
    final out = StringBuffer();
    if (dataType != null) {
      out.write(dataType);
      if (typeSpecialization != null) out.write(' ($typeSpecialization)');
      if (isArray) out.write('[]');
    }
    if (value != null) out.write('${out.isEmpty ? '' : ' '}= $value');
    if (enumValues.isNotEmpty) out.write('${out.isEmpty ? '' : ' '}$_enumChip');
    if (logged == false) out.write('${out.isEmpty ? '' : ' '}· not logged');
    return out.isEmpty ? '(unbound)' : out.toString();
  }

  String get line {
    final direction = this.direction;
    final out = StringBuffer(name);
    if (direction != null) out.write(' ${direction.toLowerCase()}');
    if (dataType != null) {
      out.write(' $dataType');
      if (typeSpecialization != null) out.write(' ($typeSpecialization)');
      if (isArray) out.write('[]');
    }
    if (value != null) out.write(' = $value');
    if (enumValues.isNotEmpty) out.write(' {${enumValues.join(', ')}}');
    if (logged == false) out.write(' [not logged]');
    return out.toString();
  }
}

String _count(int count, String label) =>
    '$count $label${count == 1 ? '' : 's'}';

String outlineSummary(SeqOutline outline, {int? typeCount}) {
  final parts = [
    _count(outline.sequences.length, 'sequence'),
    _count(outline.totalSteps, 'step'),
    if (typeCount != null) _count(typeCount, 'type'),
  ];
  return parts.join(' · ');
}

class LimitsOutline {
  LimitsOutline({
    this.comparison,
    this.low,
    this.high,
    this.nominal,
    this.thresholdType,
    this.dataSource,
  });

  final String? comparison;
  final String? low;
  final String? high;
  final String? nominal;
  final String? thresholdType;
  final String? dataSource;

  factory LimitsOutline.of(StepLimits l) => LimitsOutline(
    comparison: l.comparison,
    low: l.low,
    high: l.high,
    nominal: l.nominal,
    thresholdType: l.thresholdType,
    dataSource: l.dataSource,
  );

  List<(String, String)> get rows => [
    if (comparison case final value?) ('Comparison', value),
    if (low case final value?) ('Low', value),
    if (high case final value?) ('High', value),
    if (nominal case final value?) ('Nominal', value),
    if (thresholdType case final value?) ('Threshold', value),
    if (dataSource case final value?) ('Data source', value),
  ];
}

bool stepMatches(StepOutline s, String query) {
  if (query.isEmpty) return true;
  bool hit(String? x) => x != null && x.toLowerCase().contains(query);
  if (hit(s.name) ||
      hit(s.type) ||
      hit(s.adapter?.name) ||
      hit(s.target) ||
      hit(s.limits) ||
      hit(s.units) ||
      hit(s.dataSource) ||
      hit(s.runMode) ||
      hit(s.flowHeader) ||
      hit(s.comment)) {
    return true;
  }
  for (final note in s.notes) {
    if (note.toLowerCase().contains(query)) return true;
  }
  for (final (label, value) in s.expressions) {
    if (label.toLowerCase().contains(query) ||
        value.toLowerCase().contains(query)) {
      return true;
    }
  }
  for (final arg in s.callArgs) {
    if (arg.name.toLowerCase().contains(query) ||
        (arg.boundExpression?.toLowerCase().contains(query) ?? false) ||
        (arg.displayType?.toLowerCase().contains(query) ?? false)) {
      return true;
    }
  }
  for (final param in s.measurementParams) {
    if (param.line.toLowerCase().contains(query)) return true;
  }
  for (final param in s.connectorParams) {
    if (param.line.toLowerCase().contains(query)) return true;
  }
  return false;
}

bool _varMatches(VarOutline v, String query) =>
    v.name.toLowerCase().contains(query) ||
    (v.type?.toLowerCase().contains(query) ?? false) ||
    (v.value?.toLowerCase().contains(query) ?? false) ||
    (v.comment?.toLowerCase().contains(query) ?? false);

SeqOutline filterSequences(SeqOutline outline, String query) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return outline;
  final kept = <SequenceOutline>[];
  for (final seq in outline.sequences) {
    if (seq.name.toLowerCase().contains(needle) ||
        (seq.comment?.toLowerCase().contains(needle) ?? false)) {
      kept.add(seq);
      continue;
    }
    final varHit =
        seq.parameters.any((v) => _varMatches(v, needle)) ||
        seq.locals.any((v) => _varMatches(v, needle));
    final groups = <StepGroupOutline>[];
    for (final group in seq.groups) {
      final steps = group.steps.where((s) => stepMatches(s, needle)).toList();
      if (steps.isNotEmpty) groups.add(StepGroupOutline(group.name, steps));
    }
    if (groups.isNotEmpty || varHit) {
      kept.add(
        SequenceOutline(
          name: seq.name,
          parameters: varHit ? seq.parameters : const [],
          locals: varHit ? seq.locals : const [],
          groups: groups,
          comment: seq.comment,
        ),
      );
    }
  }
  return SeqOutline(kept);
}

class VarOutline {
  VarOutline({
    required this.name,
    this.type,
    this.value,
    this.isArray = false,
    this.containerCount,
    this.comment,
  });
  final String name;
  final String? type;
  final String? value;

  final bool isArray;

  final int? containerCount;

  final String? comment;

  factory VarOutline.of(SeqVariable v) => VarOutline(
    name: v.name,
    type: v.type,
    value: v.value,
    isArray: v.isArray,
    containerCount: v.containerCount,
    comment: v.comment,
  );

  String get label {
    final out = StringBuffer('$name : ${type ?? '(untyped)'}');
    if (value != null) {
      out.write(' = $value');
    } else if (containerCount != null) {
      out.write(
        isArray
            ? ' [$containerCount]'
            : ' {$containerCount ${containerCount == 1 ? 'field' : 'fields'}}',
      );
    }
    if (comment != null) out.write('  // $comment');
    return out.toString();
  }
}
