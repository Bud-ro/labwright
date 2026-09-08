import 'scalar_read.dart';
import 'seq_module.dart';
import 'seq_property.dart';
import 'seq_typedefs.dart';

class Step {
  Step(this.raw);

  final SeqProperty raw;

  String? _scalarOf(String key) => nonEmpty(raw.prop(key)?.scalar);
  int? _intOf(String key) => int.tryParse(_scalarOf(key) ?? '');
  bool? _flagOf(String key) => parseFlag(_scalarOf(key));

  String get name => raw.name;

  String? get type => raw.typeName;

  StepType? get stepType => StepType.of(type);

  String? get comment => nonEmpty(raw.directiveAttribute('%COMMENT'));

  String? get description => _scalarOf('Description');

  int? get activeStateCode => _intOf('Active');

  String? get pinMapPath => _scalarOf('PinMapPath');

  String? get inputBuffer => _scalarOf('InBuf');

  String? get category => _scalarOf('Category');

  bool? get suppressesNextResult => _flagOf('SuppressNextResult');

  String? get evaluatedConditionExpression => _scalarOf('EvaluatedConditionExpr');

  bool? get usesComparisonExpression => _flagOf('UseCompExpr');

  String? get arraySubscriptExpression => _scalarOf('SubscriptExpr');
  int? get arrayOffset => _intOf('Offset');
  int? get iterationTypeCode => _intOf('IterationType');
  String? get elementRestorerLocal => _scalarOf('ElementRestorerLocal');
  bool? get autoClosesAtEndOfFile => _flagOf('AutoCloseAtEndofFile');
  String? get fieldMappingExpression => _scalarOf('FieldMappingExpr');

  String? get evaluatedArrayExpression => _scalarOf('EvaluatedArrayExpr');
  String? get evaluatedArrayElementExpression => _scalarOf('EvaluatedArrayElementExpr');
  String? get evaluatedSubscriptExpression => _scalarOf('EvaluatedSubscriptExpr');
  String? get evaluatedOffsetExpression => _scalarOf('EvaluatedOffsetExpr');

  String? get timeoutExpression => _scalarOf('TimeoutExpr');
  bool? get timeoutEnabled => _flagOf('TimeoutEnabled');
  bool? get errorsOnTimeout => _flagOf('ErrorOnTimeout');

  String? get statementHandle => _scalarOf('StatementHandle');
  String? get databaseHandle => _scalarOf('DatabaseHandle');

  String? get sqlStatement => _scalarOf('SQLStatement');
  bool? get requiresParameters => _flagOf('RequiresParameters');
  int? get pageSize => _intOf('PageSize');
  String? get numberOfRecordsSelectedExpression => _scalarOf('NumberOfRecordsSelected');

  int? get dbCommandTimeoutCode => _intOf('CommandTimeout');
  int? get dbCommandTypeCode => _intOf('CommandType');
  int? get dbLockTypeCode => _intOf('LockType');
  int? get dbCursorLocationCode => _intOf('CursorLocation');
  int? get dbCursorTypeCode => _intOf('CursorType');
  int? get dbCacheSize => _intOf('CacheSize');
  int? get dbMarshalOptionsCode => _intOf('MarshalOptions');
  int? get dbMaxRecordsToSelect => _intOf('MaxRecordsToSelect');

  String? get dbConnectionString => _scalarOf('ConnectionString');

  String? get popupTitleExpression => _scalarOf('TitleExpr');
  String? get popupMessageExpression => _scalarOf('MessageExpr');

  List<String> get popupButtonLabelExpressions {
    final labels = <String>[];
    for (var i = 1; i <= 6; i++) {
      final label = _scalarOf('Button${i}Label');
      if (label != null && label != '""') labels.add(label);
    }
    return labels;
  }

  bool? get popupShowsResponse => _flagOf('ShowResponse');
  String? get popupDefaultResponseExpression => _scalarOf('DefaultResponseExpr');

  String? get executablePath => _scalarOf('Executable');
  String? get executableArguments => _scalarOf('Arguments');
  String? get executableWaitCondition => _scalarOf('WaitCondition');
  String? get executableInitialWindowState => _scalarOf('InitialWindowState');

  String? get syncNameOrReferenceExpression => _scalarOf('NameOrRefExpr');
  int? get syncOperationCode => _intOf('Operation');
  int? get syncLifetimeCode => _intOf('Lifetime');
  bool? get syncCreatesIfMissing => _flagOf('CreateIfDoesNotExist');

  String? get referencedSequenceCallName => _scalarOf('SeqCallName');
  int? get referencedSequenceCallStepGroupCode => _intOf('SeqCallStepGroupIdx');
  bool? get specifiesBySequenceCall => _flagOf('SpecifyBySeqCall');
  int? get waitForTargetCode => _intOf('WaitForTarget');

  String? get threadReferenceExpression => _scalarOf('ThreadRefExpr');
  String? get executionReferenceExpression => _scalarOf('ExecutionRefExpr');
  String? get waitTimeExpression => _scalarOf('TimeExpr');

  StepSettings get settings => StepSettings(raw.prop('TS'));

  StepModule get module => StepModule.fromSData(raw.at(['TS', 'SData']));

  StepTypeInfo get typeInfo => StepTypeInfo(raw);

  FlowControl? get flowControl => FlowControl.fromStep(this);

  StepLimits? get limits => StepLimits.fromStep(raw);

  String? get resultUnits => nonEmpty(raw.prop('Result')?.prop('Units')?.scalar);

  StepResult? get result {
    final result = raw.prop('Result');
    return result == null ? null : StepResult(result);
  }

  String? get dataSource => _scalarOf('DataSource');

  String? get id => nonEmpty(raw.prop('TS')?.prop('Id')?.scalar);

  List<MeasurementParameter> get measurementParameters {
    final params = raw.prop('Measurement')?.prop('Parameters');
    final kids = params?.array ?? params?.subProps ?? const <SeqProperty>[];
    return [for (final parameter in kids) MeasurementParameter(parameter)];
  }

  String? get measurementName => nonEmpty(raw.prop('Measurement')?.prop('Name')?.scalar);

  List<AdditionalResult> get additionalResults {
    final out = <AdditionalResult>[];
    void walk(SeqProperty node) {
      final kids = [...node.subProps, ...?node.array];
      if (node.name == 'AdditionalResults') {
        out.addAll(kids.map(AdditionalResult.new));
        return;
      }
      kids.forEach(walk);
    }

    walk(raw);
    return out;
  }

  @override
  String toString() => 'Step($name : ${type ?? '?'})';
}

enum StepType {
  statement('Statement'),

  label('Label'),

  wait('NI_Wait'),

  ifBlock('NI_Flow_If', FlowKind.ifBlock),
  elseIf('NI_Flow_ElseIf', FlowKind.elseIf),
  elseBlock('NI_Flow_Else', FlowKind.elseBlock),
  whileLoop('NI_Flow_While', FlowKind.whileLoop),
  doWhile('NI_Flow_DoWhile', FlowKind.doWhile),
  forLoop('NI_Flow_For', FlowKind.forLoop),
  forEach('NI_Flow_ForEach', FlowKind.forEach),
  selectBlock('NI_Flow_Select', FlowKind.selectBlock),
  caseBlock('NI_Flow_Case', FlowKind.caseBlock),
  flowEnd('NI_Flow_End', FlowKind.end),
  breakStep('NI_Flow_Break', FlowKind.breakStmt),

  breakCustom('NI_Flow_Break_Custom', FlowKind.breakStmt),

  continueStep('NI_Flow_Continue', FlowKind.continueStmt),

  other('')
  ;

  const StepType(this.wire, [this.flowKind]);

  final String wire;

  final FlowKind? flowKind;

  static final Map<String, StepType> _byWire = {
    for (final type in values)
      if (type != other) type.wire: type,
  };

  static StepType from(String token) => _byWire[token] ?? other;

  static StepType? of(String? token) => token == null ? null : from(token);
}

enum FlowKind {
  ifBlock('if'),
  elseIf('else if'),
  elseBlock('else'),
  whileLoop('while'),
  doWhile('do-while'),
  forLoop('for'),
  forEach('for each'),
  selectBlock('select'),
  caseBlock('case'),
  end('end'),
  breakStmt('break'),
  continueStmt('continue')
  ;

  const FlowKind(this.label);

  final String label;

  bool get opensBlock => const {
    ifBlock,
    whileLoop,
    doWhile,
    forLoop,
    forEach,
    selectBlock,
    caseBlock,
  }.contains(this);

  bool get closesBlock => this == end;

  bool get isContinuation => this == elseIf || this == elseBlock;
}

class FlowControl {
  FlowControl._(this.kind, this._node);

  final FlowKind kind;

  final SeqProperty? _node;

  static FlowControl? fromStep(Step step) {
    final kind = step.stepType?.flowKind;
    return kind == null ? null : FlowControl._(kind, step.raw);
  }

  String? get condition => nonEmpty(_node?.prop('ConditionExpr')?.scalar);

  String? get initialization => nonEmpty(_node?.prop('InitializationExpr')?.scalar);

  String? get increment => nonEmpty(_node?.prop('IncrementExpr')?.scalar);

  String? get arrayExpr => nonEmpty(_node?.prop('ArrayExpr')?.scalar);

  String? get arrayElement => nonEmpty(_node?.prop('ArrayElementExpr')?.scalar);

  String? get itemExpression => nonEmpty(_node?.prop('ItemExpr')?.scalar);

  bool get isDefaultCase => kind == FlowKind.caseBlock && parseFlag(_node?.prop('IsDefault')?.scalar) == true;

  String get header => switch (kind) {
    FlowKind.ifBlock => 'if (${condition ?? ''})',
    FlowKind.elseIf => 'else if (${condition ?? ''})',
    FlowKind.elseBlock => 'else',
    FlowKind.whileLoop => 'while (${condition ?? ''})',
    FlowKind.doWhile => 'do-while (${condition ?? ''})',
    FlowKind.forLoop =>
      'for (${[
        initialization,
        condition,
        increment,
      ].whereType<String>().join('; ')})',
    FlowKind.forEach => 'for each (${arrayElement ?? '?'} in ${arrayExpr ?? '?'})',
    FlowKind.selectBlock => 'select (${itemExpression ?? ''})',
    FlowKind.caseBlock => isDefaultCase ? 'case (default)' : 'case (${itemExpression ?? ''})',
    FlowKind.end => 'end',
    FlowKind.breakStmt => 'break',
    FlowKind.continueStmt => 'continue',
  };

  @override
  String toString() => 'FlowControl(${kind.name})';
}

class AdditionalResult {
  AdditionalResult(this.raw);

  final SeqProperty raw;

  String get name => raw.name;

  String? get kind => nonEmpty(raw.attributes['classname']);

  String? get condition => nonEmpty(raw.prop('Condition')?.scalar);
}

class StepResult {
  StepResult(this.raw);

  final SeqProperty raw;

  String? get status => nonEmpty(raw.prop('Status')?.scalar);

  String? get reportText => nonEmpty(raw.prop('ReportText')?.scalar);

  bool? get passFail => parseFlag(raw.prop('PassFail')?.scalar);

  SeqProperty? get _error => raw.prop('Error');

  String? get errorCode => nonEmpty(_error?.prop('Code')?.scalar);

  String? get errorMessage => nonEmpty(_error?.prop('Msg')?.scalar);

  bool? get errorOccurred => parseFlagStrict(_error?.prop('Occurred')?.scalar);

  bool get hasRecordedOutcome => status != null || reportText != null || errorOccurred == true;
}

class StepLimits {
  StepLimits({
    this.comparison,
    this.comparisonExpression,
    this.low,
    this.high,
    this.nominal,
    this.thresholdType,
    this.dataSource,
    this.raw,
  });

  final String? comparison;

  final String? comparisonExpression;

  final String? low;
  final String? high;
  final String? nominal;

  final String? thresholdType;

  final String? dataSource;

  final SeqProperty? raw;

  String? get lowExpression => nonEmpty(raw?.prop('LowExpr')?.scalar);
  String? get highExpression => nonEmpty(raw?.prop('HighExpr')?.scalar);
  String? get nominalExpression => nonEmpty(raw?.prop('NominalExpr')?.scalar);

  bool? get usesLowExpression => parseFlag(raw?.prop('UseLowExpr')?.scalar);
  bool? get usesHighExpression => parseFlag(raw?.prop('UseHighExpr')?.scalar);

  static StepLimits? fromStep(SeqProperty step) {
    final comp = nonEmpty(step.prop('Comp')?.scalar);
    final lim = step.prop('Limits');
    if (comp == null && lim == null) return null;
    return StepLimits(
      comparison: comp,
      comparisonExpression: nonEmpty(step.prop('CompExpr')?.scalar),
      low: nonEmpty(lim?.prop('Low')?.scalar),
      high: nonEmpty(lim?.prop('High')?.scalar),
      nominal: nonEmpty(lim?.prop('Nominal')?.scalar),
      thresholdType: nonEmpty(lim?.prop('ThresholdType')?.scalar),
      dataSource: nonEmpty(step.prop('DataSource')?.scalar),
      raw: lim,
    );
  }

  String get summary => '${comparison ?? '?'} [${low ?? '?'}, ${high ?? '?'}]';

  @override
  String toString() => 'StepLimits($summary)';
}

/// Values of a step's `TS.Mode` property.
enum StepRunMode {
  normal('Normal'),

  /// The step is not executed.
  skip('Skip'),

  /// The step reports Passed regardless of its result.
  pass('Pass'),

  /// The step reports Failed regardless of its result.
  fail('Fail')
  ;

  const StepRunMode(this.wire);

  final String wire;

  static StepRunMode? ofWire(String? token) {
    for (final value in values) {
      if (value.wire == token) return value;
    }
    return null;
  }
}

/// Values of a step's `TS.PassAct`, `TS.FailAct`, `TS.CustTrueAct` and
/// `TS.CustFalseAct` properties.
enum StepFlowAction {
  next('Next'),

  goto('Goto'),

  gotoStep('GotoStep'),

  terminate('Terminate')
  ;

  const StepFlowAction(this.wire);

  final String wire;

  static StepFlowAction? ofWire(String? token) {
    for (final value in values) {
      if (value.wire == token) return value;
    }
    return null;
  }
}

class StepSettings {
  StepSettings(this._ts);

  final SeqProperty? _ts;

  String? _scalar(String key) => nonEmpty(_ts?.prop(key)?.scalar);

  String? get mode => _scalar('Mode');

  bool get isNormalMode => mode == null || mode == 'Normal';

  StepRunMode? get runMode => StepRunMode.ofWire(mode);

  String? get loadOption => _scalar('LoadOpt');

  String? get unloadOption => _scalar('UnloadOpt');

  String? get icon {
    var name = _scalar('Icon');
    if (name == null) return null;
    final slash = name.lastIndexOf(RegExp(r'[\\/]'));
    if (slash >= 0) name = name.substring(slash + 1);
    if (name.toLowerCase().endsWith('.ico')) {
      name = name.substring(0, name.length - 4);
    }
    return (name.isEmpty || name.toLowerCase() == 'ni_blank') ? null : name;
  }

  String? get precondition => _scalar('PreCond');

  String? get loopType => _scalar('LoopType');

  String? get loopInitialize => _scalar('LoopInitialize');
  String? get loopWhile => _scalar('LoopWhile');
  String? get loopIncrement => _scalar('LoopIncrement');
  String? get loopStatus => _scalar('LoopStatus');

  bool get isLooping => loopType != null && loopType != 'NoLooping';

  String? get passAction => _scalar('PassAct');

  String? get failAction => _scalar('FailAct');

  StepFlowAction? get passFlowAction => StepFlowAction.ofWire(passAction);

  StepFlowAction? get failFlowAction => StepFlowAction.ofWire(failAction);

  String? get passActionTarget => _flowTarget('PassActTarget');

  String? get failActionTarget => _flowTarget('FailActTarget');

  String? get customTrueTarget => _flowTarget('CustTrueActTarget');
  String? get customFalseTarget => _flowTarget('CustFalseActTarget');

  String? get customExpression => _scalar('CustExpr');

  String? get customTrueAction => _scalar('CustTrueAct');
  String? get customFalseAction => _scalar('CustFalseAct');

  String? _flowTarget(String key) => nonEmpty(unwrapExprString(_scalar(key)));

  bool? _bool(String key) => parseFlagStrict(_scalar(key));

  bool? get failureCausesSequenceFailure => _bool('StepFCSeqF');

  bool? get ignoresRunTimeErrors => _bool('IgnoreRTE');

  bool? get recordsResult => _bool('ResultOption');

  String? get flowSummary {
    if (passAction == null && failAction == null) return null;
    String side(String? act, String? target) {
      final actionText = act ?? '?';
      return (actionText != 'Next' && target != null) ? '$actionText→$target' : actionText;
    }

    return '${side(passAction, passActionTarget)}/'
        '${side(failAction, failActionTarget)}';
  }

  String? get preExpression => _scalar('PreExpr');
  String? get postExpression => _scalar('PostExpr');
  String? get statusExpression => _scalar('StatusExpr');

  bool? get usesMutex => _bool('UseMutex');

  String? get mutexName => _scalar('MutexNameOrRef');

  int? _int(String key) => int.tryParse(_scalar(key) ?? '');

  bool? get canEditCode => _bool('CanEditCode');

  bool? get canEditModulePrototype => _bool('CanEditModulePrototype');

  bool? get canSpecifyModule => _bool('CanSpecifyModule');

  bool? get canEditParameterAdditionalResults => _bool('CanEditParameterAdditionalResults');

  bool? get switchEnabled => _bool('SwitchEnabled');

  int? get switchOperationCode => _int('SwitchOperation');

  int? get multiconnectModeCode => _int('MulticonnectMode');

  int? get switchOperationOrderCode => _int('OperationOrder');

  int? get connectionLifetimeCode => _int('ConnectionLifetime');

  bool? get waitForDebounce => _bool('WaitForDebounce');

  String? get virtualDeviceName => _scalar('VirtualDeviceName');

  String? get routeGroupConnect => _scalar('RouteGroupConnect');
  String? get routeGroupDisconnect => _scalar('RouteGroupDisconnect');

  int? get batchSyncCode => _int('BatchSyncOpt');

  int? get loopOptionCode => _int('LoopOpt');

  int? get preconditionInteractiveCode => _int('PrecondIntExe');

  String? get windowActivation => _scalar('WindowActivation');

  bool? get producesNoResult => _bool('NoResult');

  String? get adapterName => _scalar('Adapter');

  bool? get hasModule => _bool('HasModule');

  List<String> get requirementLinks => scalarValues(_ts?.prop('Requirements')?.prop('Links'));
}
