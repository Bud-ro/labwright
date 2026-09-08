import 'seq_file.dart';
import 'seq_property.dart';

extension on SeqProperty {
  List<SeqProperty> get children => [...subProps, ...?array];
}

class SeqCoverage {
  const SeqCoverage({
    required this.total,
    required this.modeled,
    this.plumbing = 0,
  });

  final int total;

  final int modeled;

  final int plumbing;

  int get unaccounted => total - modeled - plumbing;

  double get ratio => total == 0 ? 0 : modeled / total;

  double get accountedRatio => total == 0 ? 0 : (modeled + plumbing) / total;

  SeqCoverage operator +(SeqCoverage o) => SeqCoverage(
    total: total + o.total,
    modeled: modeled + o.modeled,
    plumbing: plumbing + o.plumbing,
  );
}

const _settingKeys = [
  'Id',
  'Mode',
  'LoadOpt',
  'UnloadOpt',
  'PreCond',
  'Icon',
  'LoopType',
  'LoopWhile',
  'LoopInitialize',
  'LoopIncrement',
  'LoopStatus',
  'PreExpr',
  'PostExpr',
  'StatusExpr',
  'PassAct',
  'FailAct',
  'PassActTarget',
  'FailActTarget',
  'CustTrueActTarget',
  'CustFalseActTarget',
  'CustExpr',
  'CustTrueAct',
  'CustFalseAct',
  'StepFCSeqF',
  'IgnoreRTE',
  'ResultOption',
  'NoResult',
  'UseMutex',
  'MutexNameOrRef',
  'Adapter',
  'HasModule',
  'CanEditCode',
  'CanEditModulePrototype',
  'CanSpecifyModule',
  'CanEditParameterAdditionalResults',
  'SwitchEnabled',
  'SwitchOperation',
  'MulticonnectMode',
  'OperationOrder',
  'ConnectionLifetime',
  'WaitForDebounce',
  'VirtualDeviceName',
  'RouteGroupConnect',
  'RouteGroupDisconnect',
  'BatchSyncOpt',
  'LoopOpt',
  'PrecondIntExe',
  'WindowActivation',
];

const _callParamKeys = [
  'Name',
  'Label',
  'ConnectorNumber',
  'ArgVal',
  'ArgumentValue',
  'DisplayType',
  'Direction',
  'WireRequirement',
  'ArgDisplayVal',
  'ArgumentDisplayValue',
  'Caption',
  'AdditionalResult',
  'Type',
  'NumType',
  'ObjType',
  'StructType',
  'ArrayType',
  'ClusterType',
  'LegacyClusterType',
  'ReferenceType',
  'Flags',
  'NumEls',
  'ResultAct',
  'ArgValImag',
  'StrSize',
  'StrPass',
  'NumPass',
  'ElemPass',
  'ArrayClusterEls',
  'ArrayDimensionsSize',
  'DefaultArraySize',
  'PartiallySpecified',
  'UseDefaultValues',
  'TypeValid',
  'IID',
  'IsUserOptional',
  'IsByRef',
];

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

const _sdataSettingKeys = [
  'SeqNameExpr',
  'SFPathExpr',
  'SpecifyByExpr',
  'UseCurFile',
  'UsePrototype',
  'ThreadOpt',
  'ExecModelOpt',
  'CreateThreadSuspended',
  'AutoWaitAsync',
  'AsyncThreadExpr',
  'Trace',
  'IgnoreTerminate',
  'ExecSync',
  'AsyncApartmentThreaded',
  'ThreadAffinityOption',
  'CustomThreadAffinity',
  'ExecTypeMask',
  'ExecTypeMaskExpr',
  'ExecBreakOnEntryExpr',
  'ExecModelPath',
  'ExecModelPathExpr',
  'RemoteExecution',
  'RemoteHost',
  'RemoteHostExpr',
  'SpecifyHostByExpr',
  'ViPath',
  'ShowFrntPnl',
  'PassInBuf',
  'PassInvocInfo',
  'PassContextPtr',
  'CodeTemplateName',
  'ModuleWorkspacePath',
  'AlwaysRunInProcess',
];

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

  void markContainer(SeqProperty? node) {
    if (node == null) return;
    mark(node);
    for (final child in node.children) {
      mark(child);
    }
  }

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
    markKeys(seq.raw, [for (final group in StepGroup.values) group.key]);
    mark(seq.raw.prop('Locals'));
    mark(seq.raw.prop('Parameters'));
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
        'Description',
        'Active',
        'InBuf',
        'PinMapPath',
        'Category',
        'SuppressNextResult',
        'EvaluatedConditionExpr',
        'UseCompExpr',
        'CompExpr',
        'CompareCase',
        'Operation',
        'ItemExpr',
        'EvaluatedItemExpr',
        'IsDefault',
        'CustomLoop',
        'SubscriptExpr',
        'Offset',
        'IterationType',
        'ElementRestorerLocal',
        'AutoCloseAtEndofFile',
        'FieldMappingExpr',
        'EvaluatedArrayExpr',
        'EvaluatedArrayElementExpr',
        'EvaluatedSubscriptExpr',
        'EvaluatedOffsetExpr',
        'EvaluatedInitializationExpr',
        'EvaluatedIncrementExpr',
        'Lifetime',
        'LifetimeRefExpr',
        'NameOrRefExpr',
        'CreateIfDoesNotExist',
        'AlreadyExistsExpr',
        'NumThreadsWaitingExpr',
        'LockLifetime',
        'TimeoutExpr',
        'TimeoutEnabled',
        'ErrorOnTimeout',
        'TimeExpr',
        'StatementHandle',
        'DatabaseHandle',
        'SQLStatement',
        'RequiresParameters',
        'PageSize',
        'NumberOfRecordsSelected',
        'CommandTimeout',
        'CommandType',
        'LockType',
        'CursorLocation',
        'CursorType',
        'CacheSize',
        'MarshalOptions',
        'MaxRecordsToSelect',
        'EvaluatedFieldMappingExpr',
        'SeqCallName',
        'SeqCallStepGroupIdx',
        'SpecifyBySeqCall',
        'WaitForTarget',
        'ThreadRefExpr',
        'ExecutionRefExpr',
        'MessageExpr',
        'TitleExpr',
        'DefaultResponse',
        'DefaultResponseExpr',
        'ShowResponse',
        'NumberLines',
        'MaxResponseLength',
        'ActiveCtrl',
        'DefaultButton',
        'CancelButton',
        'TimerButton',
        'TimeToWait',
        'CenterDialog',
        'Floating',
        'CtrlArrangement',
        'ButtonLocation',
        'ButtonAlignment',
        'ResizeDialog',
        'Modal',
        'Button1Label',
        'Button2Label',
        'Button3Label',
        'Button5Label',
        'Button6Label',
        'ExpectedNumMeas',
        'ExtraMeasAction',
        'ExtraDataAction',
        'UseIndividualDataSources',
        'InstrumentStepDescription',
        'Button4Label',
        'MeasToRepeat',
        'Executable',
        'ExecutableExpr',
        'ExecutableCalled',
        'SpecifyExeByExpr',
        'Arguments',
        'InitialWindowState',
        'WaitCondition',
        'SetErrorCode',
        'TerminateOnAbort',
        'SpecifyPathByExpr',
        'ProcessHandle',
        'ProcessHandlePtr',
        'ProcessHandleExpr',
        'StoreProcessHandle',
        'ExitCodeStatusAction',
        'ExitCodeErrorAction',
        'CsvFilePath',
        'CsvFilePathExpr',
        'SkipLines',
        'SkipLinesExpr',
        'ScanForTag',
        'ScanForTagExpr',
        'IgnoreTagCase',
        'InputRecordStreamExpr',
        'ParseRecordPrototype',
        'RecordPrototypeExpr',
        'AllowExtraFieldsInRecord',
        'ColumnListSource',
        'ConnectionString',
        'RecordToOperateOn',
        'RecordIndex',
        'RemoteHost',
        'RemoteHostByExpr',
        'PortNumber',
        'Timeout',
        'SequenceFile',
        'SequenceFileExpr',
        'PulseNotifyOpt',
        'AutoClear',
        'IsAutoClearExpr',
        'IsSetExpr',
        'ByRef',
        'DataExpr',
        'WhichNotificationExpr',
        'DIAdemRefExpr',
        'ShowEnvironment',
        'HostNameExpr',
        'SourceDataExpr',
        'ChannelExpr',
        'CreateChannel',
        'UseName',
        'FirstChannelExpr',
        'LastChannelExpr',
        'PathExpr',
        'Synchronous',
        'UsePathExpr',
        'Path',
      ]);
      for (final key in ['StdInput', 'StdOutput', 'WorkingDir']) {
        markSubtree(step.raw.prop(key));
      }
      markSubtree(step.raw.prop('Limits')?.prop('String'));
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
      void markHints(SeqProperty? list) {
        if (list == null) return;
        mark(list);
        for (final element in list.children) {
          mark(element);
          markKeys(element, _resultHintKeys);
          markSubtree(element.prop('Type'));
        }
      }

      markHints(step.raw.prop('AdditionalResultsHints'));
      markHints(ts?.prop('AdditionalResultsHints'));
      markHints(ts?.prop('CustomResults'));
      markContainer(ts?.prop('Requirements'));
      markContainer(ts?.prop('Requirements')?.prop('Links'));
      mark(ts?.prop('SData'));
      final sdata = step.module.raw;
      mark(sdata);
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
      markSubtree(step.raw.prop('Result'));
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
      mark(meas?.prop('Version'));
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

SeqCoverage measureCoverage(SeqFile file) {
  final modeled = _modeledNodes(file);
  final plumbing = _plumbingNodes(file, modeled);
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
    for (final child in node.array ?? const <SeqProperty>[]) {
      walk(child, '$path.[]');
    }
  }

  walk(file.data, file.data.name);
  return gaps;
}
