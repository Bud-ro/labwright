import 'scalar_read.dart';
import 'seq_property.dart';

/// The module-adapter kinds observed in the corpus — the bridge from a step to
/// the code it runs. Only kinds seen in real files are modeled (honesty); others
/// (e.g. .NET, HTBasic) surface as [unknown] until a sample is decoded.
enum SeqAdapter {
  /// LabVIEW VI adapter (`ViCall`/`VICall`) — calls a `.vi`. Older TestStand
  /// (e.g. versions 127/143) instead stores the VI path as a direct `ViPath`
  /// member of `SData` (alongside `PassInBuf`/`PassInvocInfo`), not nested under
  /// a `ViCall` sub-object.
  labView,

  /// C/CVI / DLL adapter (`Call`/`ExternalCall`) — calls a function in a DLL or
  /// a source module.
  cModule,

  /// Python adapter (`PythonCall`/`CPythonCall`). Recognized; its target fields
  /// are not yet decoded.
  python,

  /// Sequence Call (`SeqName`/`SFPath`) — calls another sequence.
  sequenceCall,

  /// The step carries no code module — either no `SData` at all, or an empty
  /// `SData` container (e.g. a flow-control step like `NI_Flow_If`/`NI_Flow_End`,
  /// a `Statement`, `Label`, `NI_Wait`/`NI_Lock`). Across the INI corpus every
  /// empty-`SData` step is one of these no-module types, so an empty `SData`
  /// (often inherited as a bare default from the step's type) means "no adapter",
  /// not "an adapter we failed to read".
  none,

  /// `SData` is present with members, but its adapter record is not yet
  /// recognized (e.g. .NET/HTBasic/an NI plug-in shape not yet decoded). No such
  /// step exists in the current corpus — reserved for shapes we have not seen.
  unknown;
}

/// A step's code-module binding: which adapter and what it targets. Fields are
/// null when absent/empty or not yet decoded — never fabricated.
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

  /// A best-effort human-readable target (VI path, `dll:function`, sequence
  /// name), or null when not yet recovered.
  final String? target;

  /// LabVIEW VI path ([SeqAdapter.labView]).
  final String? viPath;

  /// DLL/source path and function name ([SeqAdapter.cModule]).
  final String? libPath;
  final String? function;

  /// Called sequence name and file ([SeqAdapter.sequenceCall]).
  final String? sequenceName;
  final String? sequenceFile;

  /// The raw `SData` property for full access; null when the step had none.
  final SeqProperty? raw;

  /// The arguments this step's code-module call binds, in declaration order —
  /// the editor's "Module > Parameters" rows. Recovered from the adapter's
  /// `Parameters` list: `SData.Call.Parameters` (the ActiveX/C-module adapter)
  /// or `SData.PythonCall.Parameters` (the Python adapter). The two store a
  /// parameter's bound value under different keys (`ArgVal` vs `ArgumentValue`);
  /// [CallParameter] reads either. Empty when the call passes none, or when an
  /// adapter stores its arguments elsewhere (not yet decoded for other adapters).
  List<CallParameter> get callParameters => _params(
        raw?.prop('Call')?.prop('Parameters') ??
            raw?.prop('PythonCall')?.prop('Parameters'),
      );

  List<CallParameter> _params(SeqProperty? p) =>
      p == null ? const [] : [for (final e in p.array ?? p.subProps) CallParameter(e)];

  SeqProperty? get _viCall => raw?.prop('ViCall');

  /// The LabVIEW library namespace that owns the called VI (`ViCall.Namespace`),
  /// e.g. `NIDCPowerSourceDCVoltage.lvlib` — the `.lvlib`/`.lvclass` the VI lives
  /// in. null for a non-LabVIEW step or when not set.
  String? get viNamespace => nonEmpty(_viCall?.prop('Namespace')?.scalar);

  /// The LabVIEW project the VI call resolves through (`ViCall.ProjectPath`),
  /// e.g. `NIDCPowerSourceDCVoltage.lvproj`. null when absent.
  String? get viProjectPath => nonEmpty(_viCall?.prop('ProjectPath')?.scalar);

  /// An explicit call-name override the editor shows for the VI call
  /// (`ViCall.CallName`); null when the VI's own name is used.
  String? get viCallName => nonEmpty(_viCall?.prop('CallName')?.scalar);

  /// The called VI's documented description (`ViCall.VIDescription`); null when
  /// the VI carries none.
  String? get viDescription => nonEmpty(_viCall?.prop('VIDescription')?.scalar);

  /// Whether the call is configured to show the VI's front panel at run time
  /// (`ViCall.ShowFrnPnl`). false when absent.
  bool get showsFrontPanel => _viCall?.prop('ShowFrnPnl')?.scalar == 'true';

  /// Legacy LabVIEW VI adapter options, for older TestStand files that store the
  /// VI directly on `SData` (a `ViPath` member, not nested under `ViCall`):
  /// whether to show the front panel (`SData.ShowFrntPnl`) and whether to pass the
  /// input buffer / invocation info / sequence-context pointer to the VI
  /// (`SData.PassInBuf` / `PassInvocInfo` / `PassContextPtr`). Each null when
  /// absent (a modern `ViCall` step records none). The VI path itself is [viPath].
  bool? get legacyShowsFrontPanel => _sdFlag('ShowFrntPnl');
  bool? get legacyPassesInputBuffer => _sdFlag('PassInBuf');
  bool? get legacyPassesInvocationInfo => _sdFlag('PassInvocInfo');
  bool? get legacyPassesContextPointer => _sdFlag('PassContextPtr');

  /// The LabVIEW VI call's connector-pane parameters (`ViCall.Parms`), in
  /// declaration order — the terminals wired to the subVI. Each [CallParameter]
  /// exposes its label, display type, bound expression and connector index. The
  /// numeric type codes (`Type`/`NumType`/`ArrayType`/`ClusterType`) are left
  /// raw on [CallParameter.raw] (not yet decoded). Empty for a non-LabVIEW step
  /// or a VI call that wires nothing.
  List<CallParameter> get viParameters => _params(_viCall?.prop('Parms'));

  SeqProperty? get _pyCall => raw?.prop('PythonCall');

  /// The Python function or attribute this step invokes
  /// (`PythonCall.FunctionOrAttributeName`), e.g. `create_instrument_sessions`.
  /// null for a non-Python step or when not set.
  String? get pythonFunction => nonEmpty(_pyCall?.prop('FunctionOrAttributeName')?.scalar);

  /// The Python module file the call loads (`PythonCall.ModulePath`), e.g.
  /// `..\measurements\source_measure_dc_voltage_fal\test.py`. null when absent.
  String? get pythonModulePath => nonEmpty(_pyCall?.prop('ModulePath')?.scalar);

  /// The Python class that owns [pythonFunction] (`PythonCall.ClassName`), when
  /// the call targets a class method; null for a module-level function.
  String? get pythonClassName => nonEmpty(_pyCall?.prop('ClassName')?.scalar);

  /// The Python version the adapter runs the module under
  /// (`PythonCall.PythonVersion`), e.g. `3.9`. null when absent.
  String? get pythonVersion => nonEmpty(_pyCall?.prop('PythonVersion')?.scalar);

  /// The virtual-environment the call resolves its interpreter from
  /// (`PythonCall.PythonVirtualEnvironmentPath`); null when none is configured.
  String? get pythonVenvPath =>
      nonEmpty(_pyCall?.prop('PythonVirtualEnvironmentPath')?.scalar);

  /// The on-disk source file backing the step's code module (`SData.ModuleSrcPath`,
  /// e.g. `numericTests.c`, `64BitSupport\64BitSupport.cpp`) — the C/C++ source
  /// the DLL was built from, where the editor records it. null when absent (the
  /// adapter records the *built* module elsewhere, e.g. [libPath]).
  String? get moduleSourcePath => _sd('ModuleSrcPath');

  /// The project/solution file the code module builds from (`SData.ModulePrjPath`,
  /// e.g. `64BitSupport\64BitSupport.vcproj`); null when absent.
  String? get moduleProjectPath => _sd('ModulePrjPath');

  /// The source-creation-type code (`SData.ModuleCreateSrcType`) recording how the
  /// module's source was created/linked. Verbatim; the NI-internal code→name
  /// mapping is not invented. null when absent.
  int? get moduleSourceTypeCode => _sdInt('ModuleCreateSrcType');

  String? _sd(String key) => nonEmpty(raw?.prop(key)?.scalar);
  bool? _sdFlag(String key) => parseFlag(raw?.prop(key)?.scalar);
  int? _sdInt(String key) => int.tryParse(raw?.prop(key)?.scalar ?? '');


  /// For a SequenceCall step that names its target *by expression*, the sequence
  /// name (`SData.SeqNameExpr`) and sequence-file path (`SData.SFPathExpr`)
  /// expressions; null when the call names a literal target ([sequenceName] /
  /// [sequenceFile]) instead. Paired with [specifiesByExpression].
  String? get sequenceNameExpression => _sd('SeqNameExpr');
  String? get sequenceFileExpression => _sd('SFPathExpr');

  /// Whether the SequenceCall specifies its target by expression
  /// (`SData.SpecifyByExpr`) rather than by a fixed name/path. null when absent.
  bool? get specifiesByExpression => _sdFlag('SpecifyByExpr');

  /// Whether the SequenceCall targets a sequence in the current file
  /// (`SData.UseCurFile`) rather than an external file. null when absent.
  bool? get usesCurrentFile => _sdFlag('UseCurFile');

  /// Whether the call binds arguments through a declared prototype
  /// (`SData.UsePrototype`). null when absent. The prototype's parameter list and
  /// the call's actual arguments are [prototype] / [actualArguments].
  bool? get usesPrototype => _sdFlag('UsePrototype');

  /// The called sequence's parameter prototype (`SData.Prototype`) and the actual
  /// arguments this call binds to it (`SData.ActualArgs`), as raw structure; null
  /// when the step declares none.
  SeqProperty? get prototype => raw?.prop('Prototype');
  SeqProperty? get actualArguments => raw?.prop('ActualArgs');


  /// The threading option code (`SData.ThreadOpt`) — run in the same thread, a
  /// new thread, or a new execution. Verbatim; NI-internal code→name not
  /// invented. null when absent.
  int? get threadOptionCode => _sdInt('ThreadOpt');

  /// The execution-model option code (`SData.ExecModelOpt`). Verbatim; null when
  /// absent.
  int? get executionModelOptionCode => _sdInt('ExecModelOpt');

  /// Whether a spawned thread starts suspended (`SData.CreateThreadSuspended`) /
  /// is auto-waited as async (`SData.AutoWaitAsync`). Each null when absent.
  bool? get createsThreadSuspended => _sdFlag('CreateThreadSuspended');
  bool? get autoWaitsAsync => _sdFlag('AutoWaitAsync');

  /// The expression naming the asynchronous thread the call spawns
  /// (`SData.AsyncThreadExpr`); null when absent.
  String? get asyncThreadExpression => _sd('AsyncThreadExpr');

  /// The step's tracing setting (`SData.Trace`, e.g. `Off`, `Don't Change`) — how
  /// the call affects execution tracing; null when absent.
  String? get traceMode => _sd('Trace');

  /// Whether the call ignores a Terminate request while running
  /// (`SData.IgnoreTerminate`). null when absent.
  bool? get ignoresTerminate => _sdFlag('IgnoreTerminate');


  /// Whether the step executes on a remote host (`SData.RemoteExecution`), and
  /// the host it targets — a literal (`SData.RemoteHost`) or an expression
  /// (`SData.RemoteHostExpr`, selected by `SData.SpecifyHostByExpr`). Each null
  /// when absent.
  bool? get remoteExecution => _sdFlag('RemoteExecution');
  String? get remoteHost => _sd('RemoteHost');
  String? get remoteHostExpression => _sd('RemoteHostExpr');
  bool? get specifiesHostByExpression => _sdFlag('SpecifyHostByExpr');

  /// Whether the call executes synchronously (`SData.ExecSync`) and, for an
  /// async call, its apartment-threading / affinity options
  /// (`AsyncApartmentThreaded`, `ThreadAffinityOption` code, `CustomThreadAffinity`).
  /// Each null when absent.
  bool? get executesSynchronously => _sdFlag('ExecSync');
  bool? get asyncApartmentThreaded => _sdFlag('AsyncApartmentThreaded');
  int? get threadAffinityOptionCode => _sdInt('ThreadAffinityOption');
  String? get customThreadAffinity => _sd('CustomThreadAffinity');

  /// The new-execution model the call runs under, when it spawns one: the
  /// execution-type mask (`ExecTypeMask`, or `ExecTypeMaskExpr`), the model
  /// `.seq` path (`ExecModelPath`, or `ExecModelPathExpr`), and the break-on-entry
  /// expression (`ExecBreakOnEntryExpr`). Each null when absent.
  int? get executionTypeMaskCode => _sdInt('ExecTypeMask');
  String? get executionTypeMaskExpression => _sd('ExecTypeMaskExpr');
  String? get executionModelPath => _sd('ExecModelPath');
  String? get executionModelPathExpression => _sd('ExecModelPathExpr');
  String? get executionBreakOnEntryExpression => _sd('ExecBreakOnEntryExpr');


  /// For a VI call deployed to a remote / LabVIEW Real-Time target: the remote VI
  /// path (`ViCall.RemoteVIPath`), the host (`ViCall.RemoteHost`, or by expression
  /// when `ViCall.RemoteHostByExpr`), whether the adapter auto-detects the RT
  /// engine (`ViCall.AutoDetectLVRT`), and the node operation mode
  /// (`ViCall.NodeOperationMode`, a verbatim code). Each null when absent.
  String? get viRemoteVIPath => nonEmpty(_viCall?.prop('RemoteVIPath')?.scalar);
  String? get viRemoteHost => nonEmpty(_viCall?.prop('RemoteHost')?.scalar);
  bool? get viRemoteHostByExpression => parseFlag(_viCall?.prop('RemoteHostByExpr')?.scalar);
  bool? get viAutoDetectRealTime => parseFlag(_viCall?.prop('AutoDetectLVRT')?.scalar);
  int? get viNodeOperationModeCode =>
      int.tryParse(_viCall?.prop('NodeOperationMode')?.scalar ?? '');

  /// The VI-call type / VI type codes (`ViCall.CallType` / `VIType`) classifying
  /// the call (e.g. standard VI vs. malleable/class node) and the LabVIEW class
  /// the VI belongs to (`ViCall.ClassPath`) with its remote project
  /// (`ViCall.RemoteProjectPath`). Codes verbatim; NI-internal meaning not
  /// invented. Each null when absent. Further LabVIEW VI-node descriptor fields
  /// remain available on [raw] (`SData.ViCall`).
  int? get viCallTypeCode => int.tryParse(_viCall?.prop('CallType')?.scalar ?? '');
  int? get viTypeCode => int.tryParse(_viCall?.prop('VIType')?.scalar ?? '');
  String? get viClassPath => nonEmpty(_viCall?.prop('ClassPath')?.scalar);
  String? get viRemoteProjectPath => nonEmpty(_viCall?.prop('RemoteProjectPath')?.scalar);

  /// The Python adapter's default parameter category for array arguments
  /// (`PythonCall.DefaultParamCategoryForArray`), as a verbatim code; null when
  /// absent.
  int? get pythonDefaultParamCategoryForArrayCode =>
      int.tryParse(_pyCall?.prop('DefaultParamCategoryForArray')?.scalar ?? '');

  /// The code-template the module was generated from (`SData.CodeTemplateName`),
  /// the module workspace/project root (`SData.ModuleWorkspacePath`), and the
  /// always-run-in-process code (`SData.AlwaysRunInProcess`, verbatim). Each null
  /// when absent.
  String? get codeTemplateName => _sd('CodeTemplateName');
  String? get moduleWorkspacePath => _sd('ModuleWorkspacePath');
  int? get alwaysRunInProcessCode => _sdInt('AlwaysRunInProcess');


  /// Where the Python interpreter session is located/scoped
  /// (`PythonCall.InterpreterLocation` / `ClassInstanceLocation`); null when
  /// absent or for a non-Python step.
  String? get pythonInterpreterLocation => nonEmpty(_pyCall?.prop('InterpreterLocation')?.scalar);
  String? get pythonClassInstanceLocation =>
      nonEmpty(_pyCall?.prop('ClassInstanceLocation')?.scalar);

  /// Python session option codes — the operation type/scope
  /// (`PythonCall.OperationType` / `OperationScope`) and interpreter-session
  /// scope (`InterpreterSessionScope`). Verbatim; NI-internal code→name not
  /// invented. Each null when absent.
  int? get pythonOperationTypeCode => int.tryParse(_pyCall?.prop('OperationType')?.scalar ?? '');
  int? get pythonOperationScopeCode => int.tryParse(_pyCall?.prop('OperationScope')?.scalar ?? '');
  int? get pythonInterpreterSessionScopeCode =>
      int.tryParse(_pyCall?.prop('InterpreterSessionScope')?.scalar ?? '');

  /// Whether the Python adapter creates the interpreter if absent
  /// (`PythonCall.CreateIfInterpreterDoesNotExist`) and uses the adapter's
  /// settings for the session (`UseAdapterSettingsForInterpreterSession`). Each
  /// null when absent.
  bool? get pythonCreatesInterpreterIfMissing =>
      parseFlag(_pyCall?.prop('CreateIfInterpreterDoesNotExist')?.scalar);
  bool? get pythonUsesAdapterSessionSettings =>
      parseFlag(_pyCall?.prop('UseAdapterSettingsForInterpreterSession')?.scalar);

  factory StepModule.fromSData(SeqProperty? sdata) {
    if (sdata == null || sdata.subProps.isEmpty) {
      return StepModule(adapter: SeqAdapter.none);
    }

    final vi = sdata.prop('ViCall');
    if (vi != null) {
      final p = nonEmpty(vi.prop('VIPath')?.scalar);
      return StepModule(adapter: SeqAdapter.labView, viPath: p, target: p, raw: sdata);
    }

    final directVi = nonEmpty(sdata.prop('ViPath')?.scalar);
    if (directVi != null) {
      return StepModule(
          adapter: SeqAdapter.labView, viPath: directVi, target: directVi, raw: sdata);
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

/// A single argument a step's code-module call binds — one "Module >
/// Parameters" row in the Sequence Editor: a parameter [name], the
/// [boundExpression] supplying its value, the declared [displayType], and the
/// [direction] (in/out). Read from a `Call.Parameters[n]` property object.
class CallParameter {
  CallParameter(this.raw);

  /// The underlying parameter property object — full access to its details.
  final SeqProperty raw;

  /// The parameter's name, e.g. `LoginName`, `Return Value`, `sequence context`.
  /// The ActiveX/C `Parameters` and Python `Parameters` adapters store it as
  /// `Name`; the LabVIEW VI-call connector list (`ViCall.Parms`) stores it as
  /// `Label`. Either is read, falling back to the element name.
  String get name =>
      nonEmpty(raw.prop('Name')?.scalar) ?? nonEmpty(raw.prop('Label')?.scalar) ?? raw.name;

  /// The connector-pane terminal index this parameter wires to
  /// (`ConnectorNumber`), for a LabVIEW VI call (`ViCall.Parms`); null when
  /// absent (the non-LabVIEW adapters don't store a connector index).
  int? get connectorNumber => _int('ConnectorNumber');

  /// The expression bound to the parameter — what the call passes, e.g.
  /// `Locals.userToLogin`, `ThisContext`,
  /// `FileGlobals.MeasurementPlugIns.PinMapPath` — or null when the call leaves
  /// it unbound. Stored as `ArgVal` by the ActiveX/C adapter and as
  /// `ArgumentValue` by the Python adapter; either is read.
  String? get boundExpression =>
      nonEmpty(raw.prop('ArgVal')?.scalar) ?? nonEmpty(raw.prop('ArgumentValue')?.scalar);

  /// The human-readable parameter type the editor shows (`DisplayType`), e.g.
  /// `String`, `User (Object Reference)`; null when absent.
  String? get displayType => nonEmpty(raw.prop('DisplayType')?.scalar);

  /// The raw `Direction` code exactly as stored (`1`, `2`, `3`, …), or null
  /// when absent. Exposed alongside [direction] so an unrecognized code is left
  /// readable rather than dropped.
  String? get directionCode => nonEmpty(raw.prop('Direction')?.scalar);

  /// A readable parameter direction — `in` (`1`), `out` (`2`), `in/out` (`3`) —
  /// mapped from [directionCode] using the standard TestStand parameter
  /// directions (consistent across the corpus: a `Return Value` reads `2`,
  /// supplied inputs read `1`). null for an absent or unrecognized code, which
  /// stays available raw in [directionCode] rather than being guessed.
  String? get direction => switch (directionCode) {
        '1' => 'in',
        '2' => 'out',
        '3' => 'in/out',
        _ => null,
      };

  int? _int(String key) => int.tryParse(nonEmpty(raw.prop(key)?.scalar) ?? '');

  /// The editor's display rendering of the bound value (`ArgDisplayVal`, the
  /// ActiveX/C adapter; `ArgumentDisplayValue`, the Python adapter) — the
  /// formatted form shown next to the parameter, distinct from the live
  /// [boundExpression]. null when absent.
  String? get displayValue =>
      nonEmpty(raw.prop('ArgDisplayVal')?.scalar) ??
      nonEmpty(raw.prop('ArgumentDisplayValue')?.scalar);

  /// The editor caption for the parameter/connector terminal (`Caption`), e.g. a
  /// LabVIEW control label; null when absent.
  String? get caption => nonEmpty(raw.prop('Caption')?.scalar);

  /// The parameter's TestStand data-type code (`Type`) — the broad kind of the
  /// C/LabVIEW connector value. Surfaced verbatim; the code→name mapping is
  /// NI-internal and not invented. null when absent.
  int? get typeCode => _int('Type');

  /// Sub-type codes refining [typeCode] for a C-module / VI-call connector: the
  /// numeric-format code (`NumType`), the object/reference-type code (`ObjType`),
  /// and the struct/cluster-type code (`StructType`). Each verbatim; null when
  /// absent. Their NI-internal meanings are not invented.
  int? get numberTypeCode => _int('NumType');
  int? get objectTypeCode => _int('ObjType');
  int? get structTypeCode => _int('StructType');

  /// The parameter descriptor's flags word (`Flags`) — a packed bit set of
  /// per-parameter options. Surfaced verbatim as an integer; the individual bit
  /// meanings are NI-internal and not decoded here. null when absent.
  int? get flagsCode => _int('Flags');

  /// The number of elements (`NumEls`) for an array parameter; null when absent
  /// (a scalar parameter records none).
  int? get elementCount => _int('NumEls');

  /// The parameter's result-action code (`ResultAct`) — how the call's value for
  /// this parameter feeds the step result. Verbatim; null when absent.
  int? get resultActionCode => _int('ResultAct');

  /// The parameter's "additional results" recording spec (`AdditionalResults`),
  /// with `Input`/`Output` sub-objects, or null when the parameter records none.
  /// Surfaced as raw structure; the per-side `Flags`/`CheckedState` codes are
  /// NI-internal and not decoded.
  SeqProperty? get additionalResults => raw.prop('AdditionalResults');

  @override
  String toString() =>
      'CallParameter($name${boundExpression != null ? ' ← $boundExpression' : ''})';
}

/// One formal parameter of a **measurement step** (an NI measurement adapter's
/// `Measurement.Parameters` entry) — a named, typed input/output the step's
/// measurement routine takes. Every field is self-describing in the corpus:
/// [name] (`voltage_level`), [dataType] (the TestStand type token `TypeDouble` /
/// `TypeString` / `TypeEnum` / `TypeInt32` / `TypeBool` / `TypeUint32` /
/// `TypeUint64`), [direction] (`In` / `Out`), [isArray] from `Dimension`
/// (`0` = scalar, ≥1 = array), and [value] the bound `ArgumentValue` expression
/// (null when unbound). The sibling `ID` / `Log` / `TypeSpecialization` /
/// `MessageType` / `EnumDefinition` are left raw (not surfaced with meaning).
class MeasurementParameter {
  MeasurementParameter(this.raw);

  /// The underlying parameter property object — full access to every field.
  final SeqProperty raw;

  /// The parameter name (`Name`), e.g. `voltage_level`.
  String get name => nonEmpty(raw.prop('Name')?.scalar) ?? raw.name;

  /// The TestStand data-type token (`Type`), e.g. `TypeDouble`; null if absent.
  String? get dataType => nonEmpty(raw.prop('Type')?.scalar);

  /// The parameter direction (`Direction`) — `In` / `Out`; null if absent.
  String? get direction => nonEmpty(raw.prop('Direction')?.scalar);

  /// The bound value expression (`ArgumentValue`, e.g. `6`), or null when unbound.
  String? get value => nonEmpty(raw.prop('ArgumentValue')?.scalar);

  /// Whether the parameter is an array — `Dimension` ≥ 1 (0 = scalar).
  bool get isArray => (int.tryParse(raw.prop('Dimension')?.scalar ?? '') ?? 0) > 0;

  /// A refinement of [dataType] (`TypeSpecialization`) — `IOResource`, `Path`,
  /// `Pin`, or `Enum`: e.g. a `TypeString` parameter that is actually an
  /// instrument I/O resource, a file path, or a pin reference. null for an
  /// unspecialized parameter (`None`, the common case).
  String? get typeSpecialization {
    final s = nonEmpty(raw.prop('TypeSpecialization')?.scalar);
    return s == 'None' ? null : s;
  }

  /// Whether this parameter's value is recorded to the report (`Log`). True for
  /// most parameters; false for those explicitly excluded from logging. null
  /// when the parameter records no `Log` flag.
  bool? get logged => parseFlagStrict(raw.prop('Log')?.scalar);

  /// For a [dataType] of `TypeEnum`, the enum's allowed values as `(name, value)`
  /// pairs — each `EnumDefinition` element is a named constant (e.g. `DC_VOLTS`)
  /// whose scalar is its integer code (e.g. `1`). Empty for a non-enum parameter
  /// (or an enum whose definition is absent).
  List<({String name, String? value})> get enumValues {
    final elems = raw.prop('EnumDefinition')?.array ?? const <SeqProperty>[];
    return [for (final e in elems) (name: e.name, value: nonEmpty(e.scalar))];
  }

  /// The parameter's message-type token (`MessageType`) — the measurement
  /// plug-in's classification of the parameter; null when unset (empty in the
  /// current corpus, where the field is present but blank on most parameters).
  String? get messageType => nonEmpty(raw.prop('MessageType')?.scalar);
}
