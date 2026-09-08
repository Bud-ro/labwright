import 'scalar_read.dart';
import 'seq_file.dart';
import 'seq_property.dart';

enum SeqAdapter {
  labView,

  cModule,

  python,

  dotNet,

  sequenceCall,

  none,

  unknown,
}

/// Values of a sequence call's `ThreadOpt` property.
enum SequenceCallThreadOption {
  newThread(1),

  newExecution(2)
  ;

  const SequenceCallThreadOption(this.code);

  final int code;

  static SequenceCallThreadOption? ofCode(int? code) {
    for (final value in values) {
      if (value.code == code) return value;
    }
    return null;
  }
}

class StepModule {
  StepModule({
    required this.adapter,
    this.target,
    this.viPath,
    this.libPath,
    this.function,
    this.sequenceName,
    this.sequenceFile,
    this.raw,
  });

  final SeqAdapter adapter;

  final String? target;

  final String? viPath;

  final String? libPath;
  final String? function;

  final String? sequenceName;
  final String? sequenceFile;

  final SeqProperty? raw;

  List<CallParameter> get callParameters => _params(
    raw?.prop('Call')?.prop('Parameters') ?? raw?.prop('PythonCall')?.prop('Parameters'),
  );

  List<CallParameter> _params(SeqProperty? container) => container == null
      ? const []
      : [for (final element in container.array ?? container.subProps) CallParameter(element)];

  SeqProperty? get _viCall => raw?.prop('ViCall');

  String? get viNamespace => nonEmpty(_viCall?.prop('Namespace')?.scalar);

  String? get viProjectPath => nonEmpty(_viCall?.prop('ProjectPath')?.scalar);

  String? get viCallName => nonEmpty(_viCall?.prop('CallName')?.scalar);

  String? get viDescription => nonEmpty(_viCall?.prop('VIDescription')?.scalar);

  bool get showsFrontPanel => _viCall?.prop('ShowFrnPnl')?.scalar == 'true';

  bool? get legacyShowsFrontPanel => _dataFlag('ShowFrntPnl');
  bool? get legacyPassesInputBuffer => _dataFlag('PassInBuf');
  bool? get legacyPassesInvocationInfo => _dataFlag('PassInvocInfo');
  bool? get legacyPassesContextPointer => _dataFlag('PassContextPtr');

  List<CallParameter> get viParameters => _params(_viCall?.prop('Parms'));

  SeqProperty? get _pyCall => raw?.prop('PythonCall');

  String? get pythonFunction => nonEmpty(_pyCall?.prop('FunctionOrAttributeName')?.scalar);

  String? get pythonModulePath => nonEmpty(_pyCall?.prop('ModulePath')?.scalar);

  String? get pythonClassName => nonEmpty(_pyCall?.prop('ClassName')?.scalar);

  String? get pythonVersion => nonEmpty(_pyCall?.prop('PythonVersion')?.scalar);

  String? get pythonVenvPath => nonEmpty(_pyCall?.prop('PythonVirtualEnvironmentPath')?.scalar);

  String? get assemblyPath => _dataScalar('AssemblyPath');

  String? get dotNetClassName => _dataScalar('ClassName');

  List<DotNetCall> get dotNetCalls => [
    for (final row in raw?.prop('Calls')?.array ?? const <SeqProperty>[]) DotNetCall(row),
  ];

  String? get moduleSourcePath => _dataScalar('ModuleSrcPath');

  String? get moduleProjectPath => _dataScalar('ModulePrjPath');

  int? get moduleSourceTypeCode => _dataInt('ModuleCreateSrcType');

  String? _dataScalar(String key) => nonEmpty(raw?.prop(key)?.scalar);
  bool? _dataFlag(String key) => parseFlag(raw?.prop(key)?.scalar);
  int? _dataInt(String key) => int.tryParse(raw?.prop(key)?.scalar ?? '');

  String? get sequenceNameExpression => _dataScalar('SeqNameExpr');
  String? get sequenceFileExpression => _dataScalar('SFPathExpr');

  bool? get specifiesByExpression => _dataFlag('SpecifyByExpr');

  bool? get usesCurrentFile => _dataFlag('UseCurFile');

  bool? get usesPrototype => _dataFlag('UsePrototype');

  SeqProperty? get prototype => raw?.prop('Prototype');
  SeqProperty? get actualArguments => raw?.prop('ActualArgs');

  List<SequenceCallArgument> get sequenceArguments {
    final args = actualArguments;
    if (args == null) return const [];
    return [
      for (final row in [...args.subProps, ...?args.array]) SequenceCallArgument(row),
    ];
  }

  List<SeqVariable> get prototypeParameters => [
    for (final p in prototype?.subProps ?? const <SeqProperty>[]) SeqVariable(p),
  ];

  bool resolvesLocalCall({String? ownFilePath}) {
    if (usesCurrentFile == true) return true;
    if (sequenceFile == null && sequenceNameExpression == null) return true;
    final named = sequenceFile;
    if (named == null || ownFilePath == null) return false;
    String base(String p) => p.replaceAll(r'\', '/').split('/').last.toLowerCase();
    return base(named) == base(ownFilePath);
  }

  int? get threadOptionCode => _dataInt('ThreadOpt');

  SequenceCallThreadOption? get threadOption => SequenceCallThreadOption.ofCode(threadOptionCode);

  int? get executionModelOptionCode => _dataInt('ExecModelOpt');

  bool? get createsThreadSuspended => _dataFlag('CreateThreadSuspended');
  bool? get autoWaitsAsync => _dataFlag('AutoWaitAsync');

  String? get asyncThreadExpression => _dataScalar('AsyncThreadExpr');

  String? get traceMode => _dataScalar('Trace');

  bool? get ignoresTerminate => _dataFlag('IgnoreTerminate');

  bool? get remoteExecution => _dataFlag('RemoteExecution');
  String? get remoteHost => _dataScalar('RemoteHost');
  String? get remoteHostExpression => _dataScalar('RemoteHostExpr');
  bool? get specifiesHostByExpression => _dataFlag('SpecifyHostByExpr');

  bool? get executesSynchronously => _dataFlag('ExecSync');
  bool? get asyncApartmentThreaded => _dataFlag('AsyncApartmentThreaded');
  int? get threadAffinityOptionCode => _dataInt('ThreadAffinityOption');
  String? get customThreadAffinity => _dataScalar('CustomThreadAffinity');

  int? get executionTypeMaskCode => _dataInt('ExecTypeMask');
  String? get executionTypeMaskExpression => _dataScalar('ExecTypeMaskExpr');
  String? get executionModelPath => _dataScalar('ExecModelPath');
  String? get executionModelPathExpression => _dataScalar('ExecModelPathExpr');
  String? get executionBreakOnEntryExpression => _dataScalar('ExecBreakOnEntryExpr');

  String? get viRemoteVIPath => nonEmpty(_viCall?.prop('RemoteVIPath')?.scalar);
  String? get viRemoteHost => nonEmpty(_viCall?.prop('RemoteHost')?.scalar);
  bool? get viRemoteHostByExpression => parseFlag(_viCall?.prop('RemoteHostByExpr')?.scalar);
  bool? get viAutoDetectRealTime => parseFlag(_viCall?.prop('AutoDetectLVRT')?.scalar);
  int? get viNodeOperationModeCode => int.tryParse(_viCall?.prop('NodeOperationMode')?.scalar ?? '');

  int? get viCallTypeCode => int.tryParse(_viCall?.prop('CallType')?.scalar ?? '');
  int? get viTypeCode => int.tryParse(_viCall?.prop('VIType')?.scalar ?? '');
  String? get viClassPath => nonEmpty(_viCall?.prop('ClassPath')?.scalar);
  String? get viRemoteProjectPath => nonEmpty(_viCall?.prop('RemoteProjectPath')?.scalar);

  int? get pythonDefaultParamCategoryForArrayCode =>
      int.tryParse(_pyCall?.prop('DefaultParamCategoryForArray')?.scalar ?? '');

  String? get codeTemplateName => _dataScalar('CodeTemplateName');
  String? get moduleWorkspacePath => _dataScalar('ModuleWorkspacePath');
  int? get alwaysRunInProcessCode => _dataInt('AlwaysRunInProcess');

  String? get pythonInterpreterLocation => nonEmpty(_pyCall?.prop('InterpreterLocation')?.scalar);
  String? get pythonClassInstanceLocation => nonEmpty(_pyCall?.prop('ClassInstanceLocation')?.scalar);

  int? get pythonOperationTypeCode => int.tryParse(_pyCall?.prop('OperationType')?.scalar ?? '');
  int? get pythonOperationScopeCode => int.tryParse(_pyCall?.prop('OperationScope')?.scalar ?? '');
  int? get pythonInterpreterSessionScopeCode => int.tryParse(_pyCall?.prop('InterpreterSessionScope')?.scalar ?? '');

  bool? get pythonCreatesInterpreterIfMissing => parseFlag(_pyCall?.prop('CreateIfInterpreterDoesNotExist')?.scalar);
  bool? get pythonUsesAdapterSessionSettings =>
      parseFlag(_pyCall?.prop('UseAdapterSettingsForInterpreterSession')?.scalar);

  factory StepModule.fromSData(SeqProperty? sdata) {
    if (sdata == null || sdata.subProps.isEmpty) {
      return StepModule(adapter: SeqAdapter.none);
    }

    final vi = sdata.prop('ViCall');
    if (vi != null) {
      final path = nonEmpty(vi.prop('VIPath')?.scalar);
      return StepModule(adapter: SeqAdapter.labView, viPath: path, target: path, raw: sdata);
    }

    final directVi = nonEmpty(sdata.prop('ViPath')?.scalar);
    if (directVi != null) {
      return StepModule(adapter: SeqAdapter.labView, viPath: directVi, target: directVi, raw: sdata);
    }

    final call = sdata.prop('Call');
    if (call != null) {
      final lib = nonEmpty(call.prop('LibPath')?.scalar);
      final fn = nonEmpty(call.prop('Func')?.scalar);
      final target = lib == null ? fn : (fn == null ? lib : '$lib:$fn');
      return StepModule(
        adapter: SeqAdapter.cModule,
        libPath: lib,
        function: fn,
        target: target,
        raw: sdata,
      );
    }

    final py = sdata.prop('PythonCall');
    if (py != null) {
      final fn = nonEmpty(py.prop('FunctionOrAttributeName')?.scalar);
      final cls = nonEmpty(py.prop('ClassName')?.scalar);
      final callee = fn == null ? null : (cls != null ? '$cls.$fn' : fn);
      return StepModule(adapter: SeqAdapter.python, target: callee, raw: sdata);
    }

    if (sdata.prop('Calls') != null || sdata.prop('AssemblyPath') != null) {
      final cls = nonEmpty(sdata.prop('ClassName')?.scalar);
      final members = [
        for (final row in sdata.prop('Calls')?.array ?? const <SeqProperty>[])
          if (nonEmpty(row.prop('MemberName')?.scalar) != null) row.prop('MemberName')!.scalar!,
      ];
      final target = cls == null && members.isEmpty
          ? nonEmpty(sdata.prop('AssemblyPath')?.scalar)
          : [if (cls != null) cls, if (members.isNotEmpty) members.last].join('.');
      return StepModule(adapter: SeqAdapter.dotNet, target: target, raw: sdata);
    }

    if (sdata.prop('SeqName') != null || sdata.prop('SFPath') != null) {
      final sn = nonEmpty(sdata.prop('SeqName')?.scalar);
      final sf = nonEmpty(sdata.prop('SFPath')?.scalar);
      return StepModule(
        adapter: SeqAdapter.sequenceCall,
        sequenceName: sn,
        sequenceFile: sf,
        target: sn ?? sf,
        raw: sdata,
      );
    }

    return StepModule(adapter: SeqAdapter.unknown, raw: sdata);
  }

  @override
  String toString() => 'StepModule(${adapter.name}${target != null ? ': $target' : ''})';
}

class DotNetCall {
  DotNetCall(this.raw);

  final SeqProperty raw;

  String? get className => nonEmpty(raw.prop('ClassName')?.scalar);

  String? get memberName => nonEmpty(raw.prop('MemberName')?.scalar);

  int? get memberTypeCode => int.tryParse(raw.prop('MemberType')?.scalar ?? '');

  List<CallParameter> get parameters => [
    for (final p in raw.prop('Params')?.array ?? const <SeqProperty>[]) CallParameter(p),
  ];
}

class SequenceCallArgument {
  SequenceCallArgument(this.raw);

  final SeqProperty raw;

  String get name => raw.name;

  bool? get usesDefault => parseFlag(raw.prop('UseDef')?.scalar);

  String? get expression => nonEmpty(raw.prop('Expr')?.scalar);

  int? get parameterTypeCode => _int('ParamType');

  int? get parameterRepresentationCode => _int('ParamRepresentation');

  int? get flagsCode => _int('Flags');

  int? _int(String key) => int.tryParse(nonEmpty(raw.prop(key)?.scalar) ?? '');

  @override
  String toString() =>
      'SequenceCallArgument($name'
      '${usesDefault == true
          ? ' = <default>'
          : expression != null
          ? ' ← $expression'
          : ''})';
}

/// Values of a call parameter's `Direction` property.
enum CallParameterDirection {
  input('1', 'in'),

  output('2', 'out'),

  inOut('3', 'in/out')
  ;

  const CallParameterDirection(this.code, this.label);

  final String code;

  final String label;

  static CallParameterDirection? ofCode(String? code) {
    for (final value in values) {
      if (value.code == code) return value;
    }
    return null;
  }
}

class CallParameter {
  CallParameter(this.raw);

  final SeqProperty raw;

  String get name => nonEmpty(raw.prop('Name')?.scalar) ?? nonEmpty(raw.prop('Label')?.scalar) ?? raw.name;

  int? get connectorNumber => _int('ConnectorNumber');

  String? get boundExpression => nonEmpty(raw.prop('ArgVal')?.scalar) ?? nonEmpty(raw.prop('ArgumentValue')?.scalar);

  String? get displayType => nonEmpty(raw.prop('DisplayType')?.scalar);

  String? get directionCode => nonEmpty(raw.prop('Direction')?.scalar);

  CallParameterDirection? get directionKind => CallParameterDirection.ofCode(directionCode);

  String? get direction => directionKind?.label;

  int? _int(String key) => int.tryParse(nonEmpty(raw.prop(key)?.scalar) ?? '');

  String? get displayValue =>
      nonEmpty(raw.prop('ArgDisplayVal')?.scalar) ?? nonEmpty(raw.prop('ArgumentDisplayValue')?.scalar);

  String? get caption => nonEmpty(raw.prop('Caption')?.scalar);

  int? get typeCode => _int('Type');

  int? get numberTypeCode => _int('NumType');
  int? get objectTypeCode => _int('ObjType');
  int? get structTypeCode => _int('StructType');

  int? get flagsCode => _int('Flags');

  int? get elementCount => _int('NumEls');

  int? get resultActionCode => _int('ResultAct');

  SeqProperty? get additionalResults => raw.prop('AdditionalResults');

  @override
  String toString() => 'CallParameter($name${boundExpression != null ? ' ← $boundExpression' : ''})';
}

class MeasurementParameter {
  MeasurementParameter(this.raw);

  final SeqProperty raw;

  String get name => nonEmpty(raw.prop('Name')?.scalar) ?? raw.name;

  String? get dataType => nonEmpty(raw.prop('Type')?.scalar);

  String? get direction => nonEmpty(raw.prop('Direction')?.scalar);

  String? get value => nonEmpty(raw.prop('ArgumentValue')?.scalar);

  bool get isArray => (int.tryParse(raw.prop('Dimension')?.scalar ?? '') ?? 0) > 0;

  String? get typeSpecialization {
    final text = nonEmpty(raw.prop('TypeSpecialization')?.scalar);
    return text == 'None' ? null : text;
  }

  bool? get logged => parseFlagStrict(raw.prop('Log')?.scalar);

  List<({String name, String? value})> get enumValues {
    final elems = raw.prop('EnumDefinition')?.array ?? const <SeqProperty>[];
    return [for (final element in elems) (name: element.name, value: nonEmpty(element.scalar))];
  }

  String? get messageType => nonEmpty(raw.prop('MessageType')?.scalar);
}
