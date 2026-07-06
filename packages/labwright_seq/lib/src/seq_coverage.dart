import 'seq_file.dart';
import 'seq_module.dart';
import 'seq_property.dart';
import 'seq_step.dart';
import 'seq_typedefs.dart';

/// A property's direct child nodes: its named sub-properties followed by its
/// array elements (if any). Names the `[...subProps, ...?array]` idiom the
/// recursive tree walkers below repeat.
extension on SeqProperty {
  List<SeqProperty> get children => [...subProps, ...?array];
}

/// How much of a sequence file's property tree the typed lens actually surfaces.
///
/// The analog of the VI reader's coverage metric: a `.seq` decodes into a large
/// PropertyObject tree, but only some nodes are given *typed meaning* by
/// `SeqFile`/`Sequence`/`Step`/`StepSettings`/`StepModule`/`SeqVariable`. This
/// counts every node in the `Data` tree (`total`) and how many the lens
/// explains (`modeled`) — honest about how much is still raw.
class SeqCoverage {
  const SeqCoverage({
    required this.total,
    required this.modeled,
    this.plumbing = 0,
  });

  /// Total property nodes in the file's `Data` tree.
  final int total;

  /// Nodes the typed lens surfaces with **meaning** (a typed accessor reaches
  /// them). This is the benchmark we drive *up over time* — it stays below 100%
  /// while [plumbing] nodes remain raw, and rises as they are decoded.
  final int modeled;

  /// Nodes we **recognize as NI-internal metadata and deliberately defer** — the
  /// "later" bucket (e.g. the `%ATTRIBUTES` type-system namespace, LabVIEW build
  /// /deploy descriptors, `TDChecksum`). Accounted for, but not given typed
  /// meaning, so we are honest about not having decoded them.
  final int plumbing;

  /// Nodes that are neither modeled nor recognized plumbing — the true gap. The
  /// goal is **zero**: every node should be one or the other.
  int get unaccounted => total - modeled - plumbing;

  /// Raw modeled fraction `modeled/total` — the deferred-work benchmark that
  /// stays below 100% until the [plumbing] is decoded.
  double get ratio => total == 0 ? 0 : modeled / total;

  /// Accounted-for fraction `(modeled+plumbing)/total` — the completeness axis we
  /// drive to **100%**: every node is either modeled or recognized as plumbing.
  double get accountedRatio => total == 0 ? 0 : (modeled + plumbing) / total;

  SeqCoverage operator +(SeqCoverage o) => SeqCoverage(
    total: total + o.total,
    modeled: modeled + o.modeled,
    plumbing: plumbing + o.plumbing,
  );
}

/// The `TS` step-setting keys the lens surfaces (kept in sync with [StepSettings]
/// and [Step] — the step's unique id, run mode, module load/unload, precondition,
/// the four loop expressions, pre/post/status expressions, pass/fail actions and
/// their jump targets, the custom-condition expression + its true/false actions,
/// the step icon, and the boolean flags step-fail-causes-sequence-fail /
/// ignore-run-time-errors / record-result). Each is a `TS` child.
const _settingKeys = [
  'Id', 'Mode', 'LoadOpt', 'UnloadOpt', 'PreCond', 'Icon',
  'LoopType', 'LoopWhile', 'LoopInitialize', 'LoopIncrement', 'LoopStatus',
  'PreExpr', 'PostExpr', 'StatusExpr',
  'PassAct', 'FailAct',
  'PassActTarget', 'FailActTarget', 'CustTrueActTarget', 'CustFalseActTarget',
  'CustExpr', 'CustTrueAct', 'CustFalseAct',
  'StepFCSeqF', 'IgnoreRTE', 'ResultOption', 'NoResult',
  'UseMutex', 'MutexNameOrRef', 'Adapter', 'HasModule',
  // edit-permission flags
  'CanEditCode', 'CanEditModulePrototype', 'CanSpecifyModule',
  'CanEditParameterAdditionalResults',
  // switch/IVI settings
  'SwitchEnabled', 'SwitchOperation', 'MulticonnectMode', 'OperationOrder',
  'ConnectionLifetime', 'WaitForDebounce', 'VirtualDeviceName',
  'RouteGroupConnect', 'RouteGroupDisconnect',
  // execution / batch / window options
  'BatchSyncOpt', 'LoopOpt', 'PrecondIntExe', 'WindowActivation',
];

/// The code-module call-parameter descriptor fields the [CallParameter] lens
/// surfaces (kept in sync with it) — the bound value/display keys for each
/// adapter, the type/sub-type/flags codes, and the array/result-action fields.
const _callParamKeys = [
  'Name', 'Label', 'ConnectorNumber',
  'ArgVal', 'ArgumentValue', 'DisplayType', 'Direction', 'WireRequirement',
  'ArgDisplayVal', 'ArgumentDisplayValue', 'Caption', 'AdditionalResult',
  'Type', 'NumType', 'ObjType', 'StructType', 'ArrayType', 'ClusterType',
  'LegacyClusterType', 'ReferenceType',
  'Flags', 'NumEls', 'ResultAct', 'ArgValImag',
  'StrSize', 'StrPass', 'NumPass', 'ElemPass', 'ArrayClusterEls',
  'ArrayDimensionsSize', 'DefaultArraySize', 'PartiallySpecified',
  'UseDefaultValues', 'TypeValid',
  // COM/ActiveX automation parameter descriptor fields
  'IID', 'IsUserOptional', 'IsByRef',
];

/// The step **type**-definition fields the [StepTypeInfo] lens surfaces (flat
/// siblings of `TS` under a step in a text/INI export).
const _stepTypeKeys = [
  'CodeTemplates',
  'DescriptionFormat',
  'DefaultNameFormat',
  'BlockStartTypes',
  'BlockEndTypes',
  'AppliesToBlockStructure',
  'CanEncapsulate',
  'Substeps',
];

/// The result-hint descriptor fields each `AdditionalResultsHints`/`CustomResults`
/// element carries (surfaced as raw structure; NI-internal Flags/CheckedState
/// codes are not decoded).
const _resultHintKeys = [
  'Name',
  'Type',
  'ValueToLog',
  'Condition',
  'IsAnyType',
  'Flags',
  'CheckedState',
  'Elements',
];

/// The `SData` module-call configuration fields the [StepModule] lens surfaces —
/// SequenceCall target specification, threading / async execution, remote
/// execution, and the Python adapter's interpreter-session settings.
const _sdataSettingKeys = [
  // SequenceCall target
  'SeqNameExpr', 'SFPathExpr', 'SpecifyByExpr', 'UseCurFile', 'UsePrototype',
  // threading / async
  'ThreadOpt', 'ExecModelOpt', 'CreateThreadSuspended', 'AutoWaitAsync',
  'AsyncThreadExpr', 'Trace', 'IgnoreTerminate', 'ExecSync',
  'AsyncApartmentThreaded', 'ThreadAffinityOption', 'CustomThreadAffinity',
  // new-execution model selection
  'ExecTypeMask', 'ExecTypeMaskExpr', 'ExecBreakOnEntryExpr',
  'ExecModelPath', 'ExecModelPathExpr',
  // remote execution
  'RemoteExecution', 'RemoteHost', 'RemoteHostExpr', 'SpecifyHostByExpr',
  // legacy LabVIEW VI adapter (VI path stored directly on SData)
  'ViPath', 'ShowFrntPnl', 'PassInBuf', 'PassInvocInfo', 'PassContextPtr',
  // misc module config
  'CodeTemplateName', 'ModuleWorkspacePath', 'AlwaysRunInProcess',
];

/// The LabVIEW VI-call (`SData.ViCall`) settings the lens surfaces beyond the
/// VI path — remote/real-time deployment and node options.
const _viCallSettingKeys = [
  'RemoteVIPath',
  'RemoteHost',
  'RemoteHostByExpr',
  'AutoDetectLVRT',
  'NodeOperationMode',
  'CallType',
  'VIType',
  'ClassPath',
  'RemoteProjectPath',
];

/// The Python-adapter session fields under `SData.PythonCall` the lens surfaces.
const _pythonSessionKeys = [
  'InterpreterLocation',
  'ClassInstanceLocation',
  'OperationType',
  'OperationScope',
  'InterpreterSessionScope',
  'CreateIfInterpreterDoesNotExist',
  'UseAdapterSettingsForInterpreterSession',
  'DefaultParamCategoryForArray',
];

/// The set of nodes the typed lens surfaces with meaning, by object identity.
/// Shared by [measureCoverage] (counts it) and [coverageGaps] (inverts it).
Set<SeqProperty> _modeledNodes(SeqFile file) {
  final modeled = <SeqProperty>{};
  void mark(SeqProperty? node) {
    if (node != null) modeled.add(node);
  }

  void markKeys(SeqProperty? owner, List<String> keys) {
    for (final key in keys) {
      mark(owner?.prop(key));
    }
  }

  /// Marks [p] and its direct children (named sub-properties and array elements)
  /// — for a container the lens surfaces as accessible structured data whose
  /// one-level contents are read out (RTS settings, Requirements.Links, the file
  /// globals list).
  void markContainer(SeqProperty? node) {
    if (node == null) return;
    mark(node);
    for (final child in node.children) {
      mark(child);
    }
  }

  /// Marks [p] and its entire subtree — for a pure-data container the lens
  /// surfaces as raw structure for full access (a SequenceCall's actual
  /// arguments / parameter prototype), whose contents are NI-internal
  /// per-argument descriptors not given individual typed meaning.
  void markSubtree(SeqProperty? node) {
    if (node == null) return;
    mark(node);
    for (final child in node.children) {
      markSubtree(child);
    }
  }

  mark(file.data);
  mark(file.data.prop('Seq'));
  for (final seq in file.sequences) {
    mark(seq.raw);
    markKeys(seq.raw, ['Setup', 'Main', 'Cleanup']);
    mark(seq.raw.prop('Locals'));
    mark(seq.raw.prop('Parameters'));
    // Locals/parameters are user variables — the SeqVariable lens applies to a
    // variable and, recursively, to every member of a struct/cluster variable,
    // so the whole variable subtree is modeled user data.
    for (final variable in [...seq.locals, ...seq.parameters]) {
      markSubtree(variable.raw);
    }
    markKeys(seq.raw, [
      'RecordResults',
      'GotoCleanupOnFail',
      'FailureAction',
      'StoreResults',
    ]);
    markContainer(seq.raw.prop('Requirements'));
    markContainer(seq.raw.prop('Requirements')?.prop('Links'));
    markContainer(seq.raw.prop('RTS'));
    for (final step in seq.steps) {
      mark(step.raw);
      final ts = step.raw.prop('TS');
      mark(ts);
      markKeys(ts, _settingKeys);
      markKeys(step.raw, _stepTypeKeys);
      markKeys(step.raw, [
        'Description', 'Active', 'InBuf', 'PinMapPath',
        'Category', 'SuppressNextResult', 'EvaluatedConditionExpr',
        'UseCompExpr', 'CompExpr', 'CompareCase', 'Operation',
        // select/case flow expressions (NI_Flow_Select / NI_Flow_Case)
        'ItemExpr', 'EvaluatedItemExpr', 'IsDefault', 'CustomLoop',
        // array / for-each iteration step fields
        'SubscriptExpr', 'Offset', 'IterationType', 'ElementRestorerLocal',
        'AutoCloseAtEndofFile', 'FieldMappingExpr',
        'EvaluatedArrayExpr', 'EvaluatedArrayElementExpr',
        'EvaluatedSubscriptExpr', 'EvaluatedOffsetExpr',
        'EvaluatedInitializationExpr', 'EvaluatedIncrementExpr',
        // synchronization step fields (Lock / Rendezvous / Queue / Notification)
        'Lifetime', 'LifetimeRefExpr', 'NameOrRefExpr', 'CreateIfDoesNotExist',
        'AlreadyExistsExpr', 'NumThreadsWaitingExpr', 'LockLifetime',
        // wait / timeout step fields
        'TimeoutExpr', 'TimeoutEnabled', 'ErrorOnTimeout', 'TimeExpr',
        // database step fields + ADO recordset/command settings
        'StatementHandle', 'DatabaseHandle', 'SQLStatement',
        'RequiresParameters', 'PageSize', 'NumberOfRecordsSelected',
        'CommandTimeout', 'CommandType', 'LockType', 'CursorLocation',
        'CursorType', 'CacheSize', 'MarshalOptions', 'MaxRecordsToSelect',
        'EvaluatedFieldMappingExpr',
        // sequence-call-by-reference / Run / Wait-on-thread-or-execution
        'SeqCallName', 'SeqCallStepGroupIdx', 'SpecifyBySeqCall',
        'WaitForTarget', 'ThreadRefExpr', 'ExecutionRefExpr',
        // message-popup / dialog step instance fields
        'MessageExpr', 'TitleExpr', 'DefaultResponse', 'DefaultResponseExpr',
        'ShowResponse', 'NumberLines', 'MaxResponseLength', 'ActiveCtrl',
        'DefaultButton', 'CancelButton', 'TimerButton', 'TimeToWait',
        'CenterDialog', 'Floating', 'CtrlArrangement', 'ButtonLocation',
        'ButtonAlignment', 'ResizeDialog', 'Modal',
        'Button1Label', 'Button2Label', 'Button3Label',
        'Button5Label', 'Button6Label',
        // measurement / instrument step instance fields
        'ExpectedNumMeas', 'ExtraMeasAction', 'ExtraDataAction',
        'UseIndividualDataSources', 'InstrumentStepDescription',
        'Button4Label', 'MeasToRepeat',
        // execute-process step instance fields
        'Executable', 'ExecutableExpr', 'ExecutableCalled', 'SpecifyExeByExpr',
        'Arguments', 'InitialWindowState', 'WaitCondition', 'SetErrorCode',
        'TerminateOnAbort', 'SpecifyPathByExpr',
        'ProcessHandle', 'ProcessHandlePtr', 'ProcessHandleExpr',
        'StoreProcessHandle', 'ExitCodeStatusAction', 'ExitCodeErrorAction',
        // read/parse-record (CSV / file stream) step instance fields
        'CsvFilePath', 'CsvFilePathExpr', 'SkipLines', 'SkipLinesExpr',
        'ScanForTag', 'ScanForTagExpr', 'IgnoreTagCase', 'InputRecordStreamExpr',
        'ParseRecordPrototype', 'RecordPrototypeExpr', 'AllowExtraFieldsInRecord',
        'ColumnListSource',
        // database step instance fields
        'ConnectionString', 'RecordToOperateOn', 'RecordIndex',
        // remote / network (host-by-expr, call-by-reference) step fields
        'RemoteHost', 'RemoteHostByExpr', 'PortNumber', 'Timeout',
        'SequenceFile', 'SequenceFileExpr',
        // misc per-step instance flags / expressions
        'PulseNotifyOpt', 'AutoClear', 'IsAutoClearExpr', 'IsSetExpr',
        'ByRef', 'DataExpr', 'WhichNotificationExpr',
      ]);
      // Std stream redirect descriptors + working-dir spec (Source/Dest/Expr/
      // IsExpr/Type/Text) and the limit-string record — raw step structure.
      for (final key in ['StdInput', 'StdOutput', 'WorkingDir']) {
        markSubtree(step.raw.prop(key));
      }
      markSubtree(step.raw.prop('Limits')?.prop('String'));
      // Message-popup file-attachment record + measurement data arrays — raw.
      markSubtree(step.raw.prop('FileData'));
      markSubtree(step.raw.prop('NumericArray'));
      markSubtree(step.raw.prop('DataSourceArray'));
      markSubtree(step.raw.prop('ColumnList'));
      markSubtree(step.raw.prop('Position'));
      markSubtree(step.raw.prop('RemoteSettings'));
      markSubtree(step.raw.prop('StdError'));
      markContainer(step.raw.prop('Menu'));
      markContainer(step.raw.prop('NI_Data'));
      markContainer(step.raw.prop('NI_Data')?.prop('EditPanels'));
      // Result-recording hint lists (the step type's defaults at step level, the
      // instance's recording hints under TS): each element + its descriptor
      // fields, surfaced as raw structure.
      void markHints(SeqProperty? list) {
        if (list == null) return;
        mark(list);
        for (final element in list.children) {
          mark(element);
          markKeys(element, _resultHintKeys);
          // The hint's logged-value `Type` is a full NI type descriptor
          // (ArrayDimensions/ValueType/ClassName internals) — raw subtree.
          markSubtree(element.prop('Type'));
        }
      }

      markHints(step.raw.prop('AdditionalResultsHints'));
      markHints(ts?.prop('AdditionalResultsHints'));
      markHints(ts?.prop('CustomResults'));
      markContainer(ts?.prop('Requirements'));
      markContainer(ts?.prop('Requirements')?.prop('Links'));
      mark(ts?.prop('SData')); // empty/none SData containers
      final sdata = step.module.raw;
      mark(sdata);
      // SData module-call config (SequenceCall / threading / remote) the lens
      // surfaces (StepModule.*), plus the prototype + actual-arguments containers.
      markKeys(sdata, _sdataSettingKeys);
      markSubtree(sdata?.prop('Prototype'));
      markSubtree(sdata?.prop('ActualArgs'));
      mark(step.raw.prop('Measurement')?.prop('Name'));
      for (final rec in ['ViCall', 'Call', 'PythonCall']) {
        mark(sdata?.prop(rec));
      }
      markKeys(sdata?.prop('PythonCall'), _pythonSessionKeys);
      final viCall = sdata?.prop('ViCall');
      mark(viCall?.prop('VIPath'));
      markKeys(viCall, [
        'Namespace',
        'ProjectPath',
        'CallName',
        'VIDescription',
        'ShowFrnPnl',
        ..._viCallSettingKeys,
      ]);
      void markParam(SeqProperty node) {
        mark(node);
        markKeys(node, _callParamKeys);
        // The parameter's "additional results" spec (Input/Output sides, or a
        // single AdditionalResult with Condition/Flags/CheckedState) is surfaced
        // as raw structure via the lens.
        final addl = node.prop('AdditionalResults');
        mark(addl);
        for (final side in ['Input', 'Output']) {
          final sideProp = addl?.prop(side);
          mark(sideProp);
          for (final child in sideProp?.subProps ?? const <SeqProperty>[]) {
            mark(child);
          }
        }
        markContainer(node.prop('AdditionalResult'));
        markContainer(node.prop('ArrayDimensionsSize'));
        // A cluster/array parameter's elements are themselves parameter
        // descriptors (same fields) — recurse so the whole connector type tree is
        // covered, however deeply nested. The element-type *prototype* is a pure
        // NI type descriptor (its Cluster/UserData/ComplexParts internals), so it
        // is surfaced whole as raw structure.
        final els = node.prop('ArrayClusterEls');
        mark(els);
        for (final element in els?.array ?? const <SeqProperty>[]) {
          markParam(element);
        }
        markSubtree(node.prop('ArrayClusterProto'));
      }

      mark(viCall?.prop('Parms'));
      for (final parameter in step.module.viParameters) {
        markParam(parameter.raw);
      }
      // The LabVIEW VI adapter can also hang a `VIModule` container directly off
      // the step (legacy module slot, distinct from TS.SData.ViCall). Same shape:
      // ViCall.{VIPath, Parms[]}.
      final viModuleCall = step.raw.prop('VIModule')?.prop('ViCall');
      mark(step.raw.prop('VIModule'));
      mark(viModuleCall);
      mark(viModuleCall?.prop('VIPath'));
      final viModuleParms = viModuleCall?.prop('Parms');
      mark(viModuleParms);
      for (final parameter in viModuleParms?.array ?? const <SeqProperty>[]) {
        markParam(parameter);
      }
      final call = sdata?.prop('Call');
      mark(call?.prop('LibPath'));
      mark(call?.prop('Func'));
      // The ActiveX/COM automation adapter's call binding (`Call.*`): the target
      // object/server/interface/member identity + COM VTable/type-lib internals.
      markKeys(call, [
        'CoClass',
        'CoClassName',
        'ObjectVariable',
        'Server',
        'ServerName',
        'Interface',
        'InterfaceName',
        'InterfaceType',
        'Member',
        'MemberName',
        'MemberType',
        'HasMemberInfo',
        'HasReturnValue',
        'TypeLibVersion',
        'VTableIndex',
      ]);
      // The C/ActiveX adapter's connector list (`Call.Parms`), like ViCall.Parms.
      final callParms = call?.prop('Parms');
      mark(callParms);
      for (final parameter in callParms?.array ?? const <SeqProperty>[]) {
        markParam(parameter);
      }
      mark(sdata?.prop('SeqName'));
      mark(sdata?.prop('SFPath'));
      markKeys(sdata, ['ModuleSrcPath', 'ModulePrjPath', 'ModuleCreateSrcType']);
      final pyCall = sdata?.prop('PythonCall');
      markKeys(pyCall, [
        'FunctionOrAttributeName',
        'ModulePath',
        'ClassName',
        'PythonVersion',
        'PythonVirtualEnvironmentPath',
      ]);
      mark(call?.prop('Parameters'));
      mark(sdata?.prop('PythonCall')?.prop('Parameters'));
      for (final parameter in step.module.callParameters) {
        markParam(parameter.raw);
      }
      if (step.flowControl != null) {
        markKeys(step.raw, [
          'ConditionExpr',
          'InitializationExpr',
          'IncrementExpr',
          'ArrayExpr',
          'ArrayElementExpr',
          'OffsetExpr',
        ]);
      }
      mark(step.raw.prop('Comp'));
      mark(step.raw.prop('DataSource'));
      final limits = step.raw.prop('Limits');
      mark(limits);
      markKeys(limits, [
        'Low',
        'High',
        'Nominal',
        'ThresholdType',
        'LowExpr',
        'HighExpr',
        'NominalExpr',
        'UseLowExpr',
        'UseHighExpr',
        'ThresholdTypeExpr',
        'UseThresholdTypeExpr',
        'UseNominalExpr',
      ]);
      // The step's recorded-result slot — its full outcome record (status, report
      // text, error, numeric/measurement sub-records, pass/fail) is surfaced via
      // the StepResult lens.
      markSubtree(step.raw.prop('Result'));
      // Message-popup / UI step font records, surfaced as raw structure.
      for (final key in ['ButtonFontData', 'MsgFontData', 'RespFontData']) {
        markSubtree(step.raw.prop(key));
      }
      void markAddl(SeqProperty node) {
        if (node.name == 'AdditionalResults') {
          mark(node);
          for (final element in node.children) {
            mark(element);
            mark(element.prop('Condition'));
          }
          return;
        }
        for (final child in node.children) {
          markAddl(child);
        }
      }

      markAddl(step.raw);
      final meas = step.raw.prop('Measurement');
      mark(meas);
      mark(meas?.prop('Version')); // IVI/measurement-plugin schema version tag
      final mparams = meas?.prop('Parameters');
      mark(mparams);
      for (final parameter in step.measurementParameters) {
        mark(parameter.raw);
        markKeys(parameter.raw, [
          'Name',
          'Type',
          'Direction',
          'Dimension',
          'ArgumentValue',
          'TypeSpecialization',
          'Log',
          'ID',
          'MessageType',
        ]);
        final enumDef = parameter.raw.prop('EnumDefinition');
        mark(enumDef);
        for (final element in enumDef?.array ?? const <SeqProperty>[]) {
          mark(element);
        }
      }
    }
  }

  markKeys(file.data, [
    'ModelFile',
    'ModelOption',
    'LoadOpt',
    'UnloadOpt',
    'Version',
    'BatchSync',
    'SFGlobalsScope',
    'Type',
  ]);
  markContainer(file.data.prop('Requirements'));
  markContainer(file.data.prop('Requirements')?.prop('Links'));
  // The file globals (FileGlobalDefaults) the lens lists — each global carries a
  // full value descriptor (type internals, array prototypes), surfaced raw.
  markSubtree(file.data.prop('FileGlobalDefaults'));

  final measPlugins = file.measurementPlugIns;
  if (measPlugins != null) {
    mark(measPlugins.raw);
    for (final key in [
      'PinMapPath',
      'EnableMonitoring',
      'SpecificationsFilePaths',
      'LevelsFilePaths',
      'TimingFilePaths',
      'PatternFilePaths',
    ]) {
      final node = measPlugins.raw.prop(key);
      mark(node);
      for (final element in node?.array ?? const <SeqProperty>[]) {
        mark(element);
      }
    }
  }

  return modeled;
}

/// Property names that are **NI-internal plumbing**: recognized metadata we
/// deliberately do not give typed meaning (the "decode later" bucket), so the
/// semantic-coverage axis can honestly reach 100%. Each whole subtree is
/// classified, since these nodes' internals are themselves undecoded NI data.
///
/// - `%ATTRIBUTES`: the legacy-INI per-object NI type-system attribute namespace
///   (an `NI`-rooted dictionary), a serialization artifact of the INI form.
/// - The LabVIEW VI-call **build / deployment / class-node** descriptors a
///   `ViCall` carries for packed-library and malleable-VI tooling — NI-internal
///   LabVIEW machinery, not TestStand test logic.
const _plumbingNames = {
  '%ATTRIBUTES',
  'TDChecksum',
  'VI',
  'ExpressVIName',
  'NodeProperties',
  'NodeLibraryName',
  'NodeLibraryGenericTypeName',
  'NodeClassDataName',
  'NodeUsesDataValueReference',
  'NodeIgnoresInternalErrors',
  'PrototypeFlags',
  'BuildSpecificationName',
  'ArrayParametersMatchLVArrayDimenions',
  'OverrideBinaryClassPath',
  'OverrideBinaryVIPath',
  'OverrideBinaryProjectPath',
  'OverrideBinaryNamespace',
  'OverrideBinaryVIChecksum',
  'OverrideModuleOptions',
};

/// The set of nodes classified as NI-internal [_plumbingNames] plumbing (whole
/// subtrees), excluding any already in [modeled] (modeling always wins).
Set<SeqProperty> _plumbingNodes(SeqFile file, Set<SeqProperty> modeled) {
  final plumbing = <SeqProperty>{};
  void markSubtree(SeqProperty node) {
    if (!modeled.contains(node)) plumbing.add(node);
    for (final child in node.children) {
      markSubtree(child);
    }
  }

  void walk(SeqProperty node) {
    if (_plumbingNames.contains(node.name)) {
      markSubtree(node);
      return;
    }
    for (final child in node.children) {
      walk(child);
    }
  }

  walk(file.data);
  return plumbing;
}

/// Measures [SeqCoverage] for [f] (the `Data` tree only; the type list is
/// excluded as a separate concern). Modeled nodes are collected in a set that
/// dedupes by object identity ([SeqProperty] declares no custom `==`); plumbing
/// nodes are the recognized-but-deferred NI-internal metadata.
SeqCoverage measureCoverage(SeqFile file) {
  final modeled = _modeledNodes(file);
  final plumbing = _plumbingNodes(file, modeled);
  // Count **unique** nodes by object identity — the INI builder structurally
  // shares inherited type subtrees (the same SeqProperty appears at many
  // positions), and [modeled]/[plumbing] are identity sets, so `total` must
  // dedupe the same way. Modeling a shared subtree once covers all its positions.
  final all = <SeqProperty>{};
  void count(SeqProperty node) {
    if (!all.add(node)) return;
    for (final child in node.children) {
      count(child);
    }
  }

  count(file.data);
  return SeqCoverage(total: all.length, modeled: modeled.length, plumbing: plumbing.length);
}

/// The dotted `Data`-tree paths of every **unaccounted** node — neither modeled
/// nor recognized NI-internal [_plumbingNames] plumbing — each mapped to how many
/// such nodes share that path shape. Array elements collapse to a `[]` segment so
/// repeated elements aggregate. Diagnostic for completion work: ranking these by
/// count shows exactly where [SeqCoverage.unaccounted] mass is and what to model
/// next, until the total reaches zero.
///
/// Every unaccounted node is counted at its own path (no subtree pruning), so the
/// per-path counts sum to [SeqCoverage.unaccounted] — an honest map of the mass,
/// even where unaccounted nodes nest under a modeled container. (The
/// [weightBySubtree] parameter is retained for call-compatibility but no longer
/// changes the result, since each node is already counted exactly once.)
Map<String, int> coverageGaps(SeqFile file, {bool weightBySubtree = false}) {
  final modeled = _modeledNodes(file);
  final plumbing = _plumbingNodes(file, modeled);
  final accounted = modeled.union(plumbing);
  final gaps = <String, int>{};

  void walk(SeqProperty node, String path) {
    if (!accounted.contains(node)) {
      gaps.update(path, (n) => n + 1, ifAbsent: () => 1);
    }
    for (final child in node.subProps) {
      walk(child, '$path.${child.name}');
    }
    if (node.array != null) {
      for (final child in node.array!) {
        walk(child, '$path.[]');
      }
    }
  }

  walk(file.data, file.data.name);
  return gaps;
}
