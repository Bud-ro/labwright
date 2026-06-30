import 'seq_file.dart';
import 'seq_property.dart';

/// How much of a sequence file's property tree the typed lens actually surfaces.
///
/// The analog of the VI reader's coverage metric: a `.seq` decodes into a large
/// PropertyObject tree, but only some nodes are given *typed meaning* by
/// `SeqFile`/`Sequence`/`Step`/`StepSettings`/`StepModule`/`SeqVariable`. This
/// counts every node in the `Data` tree (`total`) and how many the lens
/// explains (`modeled`) — honest about how much is still raw.
class SeqCoverage {
  const SeqCoverage({required this.total, required this.modeled});

  /// Total property nodes in the file's `Data` tree.
  final int total;

  /// Nodes the typed lens surfaces with meaning.
  final int modeled;

  double get ratio => total == 0 ? 0 : modeled / total;

  SeqCoverage operator +(SeqCoverage o) =>
      SeqCoverage(total: total + o.total, modeled: modeled + o.modeled);
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
  'UseDefaultValues',
];

/// The step **type**-definition fields the [StepTypeInfo] lens surfaces (flat
/// siblings of `TS` under a step in a text/INI export).
const _stepTypeKeys = [
  'CodeTemplates', 'DescriptionFormat', 'DefaultNameFormat',
  'BlockStartTypes', 'BlockEndTypes', 'AppliesToBlockStructure',
  'CanEncapsulate', 'Substeps',
];

/// The result-hint descriptor fields each `AdditionalResultsHints`/`CustomResults`
/// element carries (surfaced as raw structure; NI-internal Flags/CheckedState
/// codes are not decoded).
const _resultHintKeys = [
  'Name', 'Type', 'ValueToLog', 'Condition', 'IsAnyType', 'Flags',
  'CheckedState', 'Elements',
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
];

/// The LabVIEW VI-call (`SData.ViCall`) settings the lens surfaces beyond the
/// VI path — remote/real-time deployment and node options.
const _viCallSettingKeys = [
  'RemoteVIPath', 'RemoteHost', 'RemoteHostByExpr', 'AutoDetectLVRT',
  'NodeOperationMode', 'CallType', 'VIType', 'ClassPath', 'RemoteProjectPath',
];

/// The Python-adapter session fields under `SData.PythonCall` the lens surfaces.
const _pythonSessionKeys = [
  'InterpreterLocation', 'ClassInstanceLocation', 'OperationType',
  'OperationScope', 'InterpreterSessionScope', 'CreateIfInterpreterDoesNotExist',
  'UseAdapterSettingsForInterpreterSession', 'DefaultParamCategoryForArray',
];

/// The set of nodes the typed lens surfaces with meaning, by object identity.
/// Shared by [measureCoverage] (counts it) and [coverageGaps] (inverts it).
Set<SeqProperty> _modeledNodes(SeqFile f) {
  final modeled = <SeqProperty>{};
  void mark(SeqProperty? p) {
    if (p != null) modeled.add(p);
  }

  /// Marks [p] and its direct children (named sub-properties and array elements)
  /// — for a container the lens surfaces as accessible structured data whose
  /// one-level contents are read out (RTS settings, Requirements.Links, the file
  /// globals list).
  void markContainer(SeqProperty? p) {
    if (p == null) return;
    mark(p);
    for (final c in p.subProps) {
      mark(c);
    }
    for (final c in p.array ?? const <SeqProperty>[]) {
      mark(c);
    }
  }

  /// Marks [p] and its entire subtree — for a pure-data container the lens
  /// surfaces as raw structure for full access (a SequenceCall's actual
  /// arguments / parameter prototype), whose contents are NI-internal
  /// per-argument descriptors not given individual typed meaning.
  void markSubtree(SeqProperty? p) {
    if (p == null) return;
    mark(p);
    for (final c in [...p.subProps, ...?p.array]) {
      markSubtree(c);
    }
  }

  mark(f.data);
  mark(f.data.prop('Seq'));
  for (final seq in f.sequences) {
    mark(seq.raw);
    for (final g in ['Setup', 'Main', 'Cleanup']) {
      mark(seq.raw.prop(g));
    }
    mark(seq.raw.prop('Locals'));
    mark(seq.raw.prop('Parameters'));
    for (final v in [...seq.locals, ...seq.parameters]) {
      mark(v.raw);
    }
    // Sequence-level settings the lens surfaces (Sequence.* / runtimeSettings).
    for (final k in ['RecordResults', 'GotoCleanupOnFail', 'FailureAction']) {
      mark(seq.raw.prop(k));
    }
    markContainer(seq.raw.prop('Requirements')); // + Links list
    markContainer(seq.raw.prop('Requirements')?.prop('Links'));
    markContainer(seq.raw.prop('RTS')); // entry-point / run-time settings
    for (final step in seq.steps) {
      mark(step.raw);
      final ts = step.raw.prop('TS');
      mark(ts);
      for (final k in _settingKeys) {
        mark(ts?.prop(k));
      }
      // Step type-definition metadata the lens surfaces (Step.typeInfo).
      for (final k in _stepTypeKeys) {
        mark(step.raw.prop(k));
      }
      // Step instance-level fields the lens surfaces (Step.*).
      for (final k in [
        'Description', 'Active', 'InBuf', 'PinMapPath',
        'Category', 'SuppressNextResult', 'EvaluatedConditionExpr',
        'UseCompExpr', 'CompExpr',
        // array / for-each iteration step fields
        'SubscriptExpr', 'Offset', 'IterationType', 'ElementRestorerLocal',
        'AutoCloseAtEndofFile', 'FieldMappingExpr',
        'EvaluatedArrayExpr', 'EvaluatedArrayElementExpr',
        'EvaluatedSubscriptExpr', 'EvaluatedOffsetExpr',
        // wait / timeout step fields
        'TimeoutExpr', 'TimeoutEnabled', 'ErrorOnTimeout',
        // database step handles
        'StatementHandle', 'DatabaseHandle',
      ]) {
        mark(step.raw.prop(k));
      }
      markContainer(step.raw.prop('Menu'));
      markContainer(step.raw.prop('NI_Data'));
      markContainer(step.raw.prop('NI_Data')?.prop('EditPanels'));
      // Result-recording hint lists (the step type's defaults at step level, the
      // instance's recording hints under TS): each element + its descriptor
      // fields, surfaced as raw structure.
      void markHints(SeqProperty? list) {
        if (list == null) return;
        mark(list);
        for (final e in [...list.subProps, ...?list.array]) {
          mark(e);
          for (final k in _resultHintKeys) {
            mark(e.prop(k));
          }
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
      for (final k in _sdataSettingKeys) {
        mark(sdata?.prop(k));
      }
      markSubtree(sdata?.prop('Prototype'));
      markSubtree(sdata?.prop('ActualArgs'));
      mark(step.raw.prop('Measurement')?.prop('Name'));
      for (final rec in ['ViCall', 'Call', 'PythonCall']) {
        mark(sdata?.prop(rec));
      }
      for (final k in _pythonSessionKeys) {
        mark(sdata?.prop('PythonCall')?.prop(k));
      }
      final viCall = sdata?.prop('ViCall');
      mark(viCall?.prop('VIPath'));
      for (final k in [
        'Namespace', 'ProjectPath', 'CallName', 'VIDescription', 'ShowFrnPnl',
        ..._viCallSettingKeys,
      ]) {
        mark(viCall?.prop(k));
      }
      void markParam(SeqProperty p) {
        mark(p);
        for (final k in _callParamKeys) {
          mark(p.prop(k));
        }
        // The parameter's "additional results" spec (Input/Output sides, or a
        // single AdditionalResult with Condition/Flags/CheckedState) is surfaced
        // as raw structure via the lens.
        final addl = p.prop('AdditionalResults');
        mark(addl);
        for (final side in ['Input', 'Output']) {
          final s = addl?.prop(side);
          mark(s);
          for (final c in s?.subProps ?? const <SeqProperty>[]) {
            mark(c);
          }
        }
        markContainer(p.prop('AdditionalResult'));
        markContainer(p.prop('ArrayDimensionsSize')); // per-dimension sizes
        // A cluster/array parameter's elements are themselves parameter
        // descriptors (same fields) — recurse so the whole connector type tree is
        // covered, however deeply nested.
        for (final e in p.prop('ArrayClusterEls')?.array ?? const <SeqProperty>[]) {
          markParam(e);
        }
      }

      mark(viCall?.prop('Parms'));
      for (final p in step.module.viParameters) {
        markParam(p.raw);
      }
      mark(sdata?.prop('Call')?.prop('LibPath'));
      mark(sdata?.prop('Call')?.prop('Func'));
      // The C/ActiveX adapter's connector list (`Call.Parms`), like ViCall.Parms.
      final callParms = sdata?.prop('Call')?.prop('Parms');
      mark(callParms);
      for (final p in callParms?.array ?? const <SeqProperty>[]) {
        markParam(p);
      }
      mark(sdata?.prop('SeqName'));
      mark(sdata?.prop('SFPath'));
      for (final k in ['ModuleSrcPath', 'ModulePrjPath', 'ModuleCreateSrcType']) {
        mark(sdata?.prop(k));
      }
      final pyCall = sdata?.prop('PythonCall');
      for (final k in [
        'FunctionOrAttributeName', 'ModulePath', 'ClassName',
        'PythonVersion', 'PythonVirtualEnvironmentPath',
      ]) {
        mark(pyCall?.prop(k));
      }
      mark(sdata?.prop('Call')?.prop('Parameters'));
      mark(sdata?.prop('PythonCall')?.prop('Parameters'));
      for (final p in step.module.callParameters) {
        markParam(p.raw);
      }
      if (step.flowControl != null) {
        for (final k in [
          'ConditionExpr', 'InitializationExpr', 'IncrementExpr',
          'ArrayExpr', 'ArrayElementExpr', 'OffsetExpr',
        ]) {
          mark(step.raw.prop(k));
        }
      }
      mark(step.raw.prop('Comp'));
      mark(step.raw.prop('DataSource'));
      final lim = step.raw.prop('Limits');
      mark(lim);
      for (final k in [
        'Low', 'High', 'Nominal', 'ThresholdType',
        'LowExpr', 'HighExpr', 'NominalExpr', 'UseLowExpr', 'UseHighExpr',
      ]) {
        mark(lim?.prop(k));
      }
      final result = step.raw.prop('Result');
      mark(result);
      mark(result?.prop('Units'));
      mark(result?.prop('Status'));
      mark(result?.prop('ReportText'));
      mark(result?.prop('Common'));
      mark(result?.prop('PassFail'));
      final error = result?.prop('Error');
      mark(error);
      for (final k in ['Code', 'Msg', 'Occurred']) {
        mark(error?.prop(k));
      }
      void markAddl(SeqProperty p) {
        if (p.name == 'AdditionalResults') {
          mark(p);
          for (final e in [...p.subProps, ...?p.array]) {
            mark(e);
            mark(e.prop('Condition'));
          }
          return;
        }
        for (final c in [...p.subProps, ...?p.array]) {
          markAddl(c);
        }
      }

      markAddl(step.raw);
      final meas = step.raw.prop('Measurement');
      mark(meas);
      final mparams = meas?.prop('Parameters');
      mark(mparams);
      for (final p in step.measurementParameters) {
        mark(p.raw);
        for (final k in [
          'Name', 'Type', 'Direction', 'Dimension', 'ArgumentValue',
          'TypeSpecialization', 'Log', 'ID', 'MessageType',
        ]) {
          mark(p.raw.prop(k));
        }
        final ed = p.raw.prop('EnumDefinition');
        mark(ed);
        for (final e in ed?.array ?? const <SeqProperty>[]) {
          mark(e);
        }
      }
    }
  }

  // File-level settings the lens surfaces (SeqFile.*).
  for (final k in [
    'ModelFile', 'ModelOption', 'LoadOpt', 'UnloadOpt', 'Version',
    'BatchSync', 'SFGlobalsScope', 'Type',
  ]) {
    mark(f.data.prop(k));
  }
  markContainer(f.data.prop('Requirements'));
  markContainer(f.data.prop('Requirements')?.prop('Links'));
  // The file globals (FileGlobalDefaults children) the lens lists.
  markContainer(f.data.prop('FileGlobalDefaults'));

  final mp = f.measurementPlugIns;
  if (mp != null) {
    mark(mp.raw);
    for (final k in [
      'PinMapPath', 'EnableMonitoring', 'SpecificationsFilePaths',
      'LevelsFilePaths', 'TimingFilePaths', 'PatternFilePaths',
    ]) {
      final node = mp.raw.prop(k);
      mark(node);
      for (final e in node?.array ?? const <SeqProperty>[]) {
        mark(e);
      }
    }
  }

  return modeled;
}

/// Measures [SeqCoverage] for [f] (the `Data` tree only; the type list is
/// excluded as a separate concern). Modeled nodes are collected in a set that
/// dedupes by object identity ([SeqProperty] declares no custom `==`).
SeqCoverage measureCoverage(SeqFile f) {
  final modeled = _modeledNodes(f);
  var total = 0;
  void count(SeqProperty p) {
    total++;
    for (final c in p.subProps) {
      count(c);
    }
    if (p.array != null) {
      for (final c in p.array!) {
        count(c);
      }
    }
  }

  count(f.data);
  return SeqCoverage(total: total, modeled: modeled.length);
}

/// The dotted `Data`-tree paths of nodes the typed lens does **not** surface,
/// each mapped to how many such nodes share that path shape. Diagnostic for
/// completion work: shows exactly where model coverage is still raw, ranked by
/// mass. Array elements collapse to a `[]` path segment so repeated elements
/// aggregate. Paths are pruned: once a node is unmodeled it represents its whole
/// subtree, so its descendants are not also reported (avoids double-counting a
/// raw subtree as hundreds of separate gaps).
Map<String, int> coverageGaps(SeqFile f) {
  final modeled = _modeledNodes(f);
  final gaps = <String, int>{};
  void walk(SeqProperty p, String path, bool ancestorRaw) {
    final raw = ancestorRaw || !modeled.contains(p);
    // Only tally the topmost unmodeled node of a raw subtree.
    if (raw && !ancestorRaw) gaps.update(path, (n) => n + 1, ifAbsent: () => 1);
    for (final c in p.subProps) {
      walk(c, '$path.${c.name}', raw);
    }
    if (p.array != null) {
      for (final c in p.array!) {
        walk(c, '$path.[]', raw);
      }
    }
  }

  walk(f.data, f.data.name, false);
  return gaps;
}
