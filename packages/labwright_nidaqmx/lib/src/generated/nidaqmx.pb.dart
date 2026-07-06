// This is a generated file - do not edit.
//
// Generated from nidaqmx.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:core' as $core;

import 'package:fixnum/fixnum.dart' as $fixnum;
import 'package:protobuf/protobuf.dart' as $pb;

import 'data_moniker.pb.dart' as $2;
import 'nidaqmx.pbenum.dart';
import 'session.pb.dart' as $1;

export 'package:protobuf/protobuf.dart' show GeneratedMessageGenericExtensions;

export 'nidaqmx.pbenum.dart';

class CreateTaskRequest extends $pb.GeneratedMessage {
  factory CreateTaskRequest({
    $core.String? sessionName,
    $1.SessionInitializationBehavior? initializationBehavior,
  }) {
    final result = create();
    if (sessionName != null) result.sessionName = sessionName;
    if (initializationBehavior != null) result.initializationBehavior = initializationBehavior;
    return result;
  }

  CreateTaskRequest._();

  factory CreateTaskRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory CreateTaskRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'CreateTaskRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'nidaqmx_grpc'), createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'sessionName')
    ..aE<$1.SessionInitializationBehavior>(2, _omitFieldNames ? '' : 'initializationBehavior',
        enumValues: $1.SessionInitializationBehavior.values)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CreateTaskRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CreateTaskRequest copyWith(void Function(CreateTaskRequest) updates) =>
      super.copyWith((message) => updates(message as CreateTaskRequest)) as CreateTaskRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static CreateTaskRequest create() => CreateTaskRequest._();
  @$core.override
  CreateTaskRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static CreateTaskRequest getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<CreateTaskRequest>(create);
  static CreateTaskRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get sessionName => $_getSZ(0);
  @$pb.TagNumber(1)
  set sessionName($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasSessionName() => $_has(0);
  @$pb.TagNumber(1)
  void clearSessionName() => $_clearField(1);

  @$pb.TagNumber(2)
  $1.SessionInitializationBehavior get initializationBehavior => $_getN(1);
  @$pb.TagNumber(2)
  set initializationBehavior($1.SessionInitializationBehavior value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasInitializationBehavior() => $_has(1);
  @$pb.TagNumber(2)
  void clearInitializationBehavior() => $_clearField(2);
}

class CreateTaskResponse extends $pb.GeneratedMessage {
  factory CreateTaskResponse({
    $core.int? status,
    $1.Session? task,
    $core.bool? newSessionInitialized,
  }) {
    final result = create();
    if (status != null) result.status = status;
    if (task != null) result.task = task;
    if (newSessionInitialized != null) result.newSessionInitialized = newSessionInitialized;
    return result;
  }

  CreateTaskResponse._();

  factory CreateTaskResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory CreateTaskResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'CreateTaskResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'nidaqmx_grpc'), createEmptyInstance: create)
    ..aI(1, _omitFieldNames ? '' : 'status')
    ..aOM<$1.Session>(2, _omitFieldNames ? '' : 'task', subBuilder: $1.Session.create)
    ..aOB(3, _omitFieldNames ? '' : 'newSessionInitialized')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CreateTaskResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CreateTaskResponse copyWith(void Function(CreateTaskResponse) updates) =>
      super.copyWith((message) => updates(message as CreateTaskResponse)) as CreateTaskResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static CreateTaskResponse create() => CreateTaskResponse._();
  @$core.override
  CreateTaskResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static CreateTaskResponse getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<CreateTaskResponse>(create);
  static CreateTaskResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $core.int get status => $_getIZ(0);
  @$pb.TagNumber(1)
  set status($core.int value) => $_setSignedInt32(0, value);
  @$pb.TagNumber(1)
  $core.bool hasStatus() => $_has(0);
  @$pb.TagNumber(1)
  void clearStatus() => $_clearField(1);

  @$pb.TagNumber(2)
  $1.Session get task => $_getN(1);
  @$pb.TagNumber(2)
  set task($1.Session value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasTask() => $_has(1);
  @$pb.TagNumber(2)
  void clearTask() => $_clearField(2);
  @$pb.TagNumber(2)
  $1.Session ensureTask() => $_ensure(1);

  @$pb.TagNumber(3)
  $core.bool get newSessionInitialized => $_getBF(2);
  @$pb.TagNumber(3)
  set newSessionInitialized($core.bool value) => $_setBool(2, value);
  @$pb.TagNumber(3)
  $core.bool hasNewSessionInitialized() => $_has(2);
  @$pb.TagNumber(3)
  void clearNewSessionInitialized() => $_clearField(3);
}

enum CreateAIVoltageChanRequest_TerminalConfigEnum { terminalConfig, terminalConfigRaw, notSet }

enum CreateAIVoltageChanRequest_UnitsEnum { units, unitsRaw, notSet }

class CreateAIVoltageChanRequest extends $pb.GeneratedMessage {
  factory CreateAIVoltageChanRequest({
    $1.Session? task,
    $core.String? physicalChannel,
    $core.String? nameToAssignToChannel,
    InputTermCfgWithDefault? terminalConfig,
    $core.int? terminalConfigRaw,
    $core.double? minVal,
    $core.double? maxVal,
    VoltageUnits2? units,
    $core.int? unitsRaw,
    $core.String? customScaleName,
  }) {
    final result = create();
    if (task != null) result.task = task;
    if (physicalChannel != null) result.physicalChannel = physicalChannel;
    if (nameToAssignToChannel != null) result.nameToAssignToChannel = nameToAssignToChannel;
    if (terminalConfig != null) result.terminalConfig = terminalConfig;
    if (terminalConfigRaw != null) result.terminalConfigRaw = terminalConfigRaw;
    if (minVal != null) result.minVal = minVal;
    if (maxVal != null) result.maxVal = maxVal;
    if (units != null) result.units = units;
    if (unitsRaw != null) result.unitsRaw = unitsRaw;
    if (customScaleName != null) result.customScaleName = customScaleName;
    return result;
  }

  CreateAIVoltageChanRequest._();

  factory CreateAIVoltageChanRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory CreateAIVoltageChanRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static const $core.Map<$core.int, CreateAIVoltageChanRequest_TerminalConfigEnum>
      _CreateAIVoltageChanRequest_TerminalConfigEnumByTag = {
    4: CreateAIVoltageChanRequest_TerminalConfigEnum.terminalConfig,
    5: CreateAIVoltageChanRequest_TerminalConfigEnum.terminalConfigRaw,
    0: CreateAIVoltageChanRequest_TerminalConfigEnum.notSet
  };
  static const $core.Map<$core.int, CreateAIVoltageChanRequest_UnitsEnum> _CreateAIVoltageChanRequest_UnitsEnumByTag = {
    8: CreateAIVoltageChanRequest_UnitsEnum.units,
    9: CreateAIVoltageChanRequest_UnitsEnum.unitsRaw,
    0: CreateAIVoltageChanRequest_UnitsEnum.notSet
  };
  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'CreateAIVoltageChanRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'nidaqmx_grpc'), createEmptyInstance: create)
    ..oo(0, [4, 5])
    ..oo(1, [8, 9])
    ..aOM<$1.Session>(1, _omitFieldNames ? '' : 'task', subBuilder: $1.Session.create)
    ..aOS(2, _omitFieldNames ? '' : 'physicalChannel')
    ..aOS(3, _omitFieldNames ? '' : 'nameToAssignToChannel')
    ..aE<InputTermCfgWithDefault>(4, _omitFieldNames ? '' : 'terminalConfig',
        enumValues: InputTermCfgWithDefault.values)
    ..aI(5, _omitFieldNames ? '' : 'terminalConfigRaw')
    ..aD(6, _omitFieldNames ? '' : 'minVal')
    ..aD(7, _omitFieldNames ? '' : 'maxVal')
    ..aE<VoltageUnits2>(8, _omitFieldNames ? '' : 'units', enumValues: VoltageUnits2.values)
    ..aI(9, _omitFieldNames ? '' : 'unitsRaw')
    ..aOS(10, _omitFieldNames ? '' : 'customScaleName')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CreateAIVoltageChanRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CreateAIVoltageChanRequest copyWith(void Function(CreateAIVoltageChanRequest) updates) =>
      super.copyWith((message) => updates(message as CreateAIVoltageChanRequest)) as CreateAIVoltageChanRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static CreateAIVoltageChanRequest create() => CreateAIVoltageChanRequest._();
  @$core.override
  CreateAIVoltageChanRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static CreateAIVoltageChanRequest getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<CreateAIVoltageChanRequest>(create);
  static CreateAIVoltageChanRequest? _defaultInstance;

  @$pb.TagNumber(4)
  @$pb.TagNumber(5)
  CreateAIVoltageChanRequest_TerminalConfigEnum whichTerminalConfigEnum() =>
      _CreateAIVoltageChanRequest_TerminalConfigEnumByTag[$_whichOneof(0)]!;
  @$pb.TagNumber(4)
  @$pb.TagNumber(5)
  void clearTerminalConfigEnum() => $_clearField($_whichOneof(0));

  @$pb.TagNumber(8)
  @$pb.TagNumber(9)
  CreateAIVoltageChanRequest_UnitsEnum whichUnitsEnum() => _CreateAIVoltageChanRequest_UnitsEnumByTag[$_whichOneof(1)]!;
  @$pb.TagNumber(8)
  @$pb.TagNumber(9)
  void clearUnitsEnum() => $_clearField($_whichOneof(1));

  @$pb.TagNumber(1)
  $1.Session get task => $_getN(0);
  @$pb.TagNumber(1)
  set task($1.Session value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasTask() => $_has(0);
  @$pb.TagNumber(1)
  void clearTask() => $_clearField(1);
  @$pb.TagNumber(1)
  $1.Session ensureTask() => $_ensure(0);

  @$pb.TagNumber(2)
  $core.String get physicalChannel => $_getSZ(1);
  @$pb.TagNumber(2)
  set physicalChannel($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasPhysicalChannel() => $_has(1);
  @$pb.TagNumber(2)
  void clearPhysicalChannel() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.String get nameToAssignToChannel => $_getSZ(2);
  @$pb.TagNumber(3)
  set nameToAssignToChannel($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasNameToAssignToChannel() => $_has(2);
  @$pb.TagNumber(3)
  void clearNameToAssignToChannel() => $_clearField(3);

  @$pb.TagNumber(4)
  InputTermCfgWithDefault get terminalConfig => $_getN(3);
  @$pb.TagNumber(4)
  set terminalConfig(InputTermCfgWithDefault value) => $_setField(4, value);
  @$pb.TagNumber(4)
  $core.bool hasTerminalConfig() => $_has(3);
  @$pb.TagNumber(4)
  void clearTerminalConfig() => $_clearField(4);

  @$pb.TagNumber(5)
  $core.int get terminalConfigRaw => $_getIZ(4);
  @$pb.TagNumber(5)
  set terminalConfigRaw($core.int value) => $_setSignedInt32(4, value);
  @$pb.TagNumber(5)
  $core.bool hasTerminalConfigRaw() => $_has(4);
  @$pb.TagNumber(5)
  void clearTerminalConfigRaw() => $_clearField(5);

  @$pb.TagNumber(6)
  $core.double get minVal => $_getN(5);
  @$pb.TagNumber(6)
  set minVal($core.double value) => $_setDouble(5, value);
  @$pb.TagNumber(6)
  $core.bool hasMinVal() => $_has(5);
  @$pb.TagNumber(6)
  void clearMinVal() => $_clearField(6);

  @$pb.TagNumber(7)
  $core.double get maxVal => $_getN(6);
  @$pb.TagNumber(7)
  set maxVal($core.double value) => $_setDouble(6, value);
  @$pb.TagNumber(7)
  $core.bool hasMaxVal() => $_has(6);
  @$pb.TagNumber(7)
  void clearMaxVal() => $_clearField(7);

  @$pb.TagNumber(8)
  VoltageUnits2 get units => $_getN(7);
  @$pb.TagNumber(8)
  set units(VoltageUnits2 value) => $_setField(8, value);
  @$pb.TagNumber(8)
  $core.bool hasUnits() => $_has(7);
  @$pb.TagNumber(8)
  void clearUnits() => $_clearField(8);

  @$pb.TagNumber(9)
  $core.int get unitsRaw => $_getIZ(8);
  @$pb.TagNumber(9)
  set unitsRaw($core.int value) => $_setSignedInt32(8, value);
  @$pb.TagNumber(9)
  $core.bool hasUnitsRaw() => $_has(8);
  @$pb.TagNumber(9)
  void clearUnitsRaw() => $_clearField(9);

  @$pb.TagNumber(10)
  $core.String get customScaleName => $_getSZ(9);
  @$pb.TagNumber(10)
  set customScaleName($core.String value) => $_setString(9, value);
  @$pb.TagNumber(10)
  $core.bool hasCustomScaleName() => $_has(9);
  @$pb.TagNumber(10)
  void clearCustomScaleName() => $_clearField(10);
}

class CreateAIVoltageChanResponse extends $pb.GeneratedMessage {
  factory CreateAIVoltageChanResponse({
    $core.int? status,
  }) {
    final result = create();
    if (status != null) result.status = status;
    return result;
  }

  CreateAIVoltageChanResponse._();

  factory CreateAIVoltageChanResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory CreateAIVoltageChanResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'CreateAIVoltageChanResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'nidaqmx_grpc'), createEmptyInstance: create)
    ..aI(1, _omitFieldNames ? '' : 'status')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CreateAIVoltageChanResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CreateAIVoltageChanResponse copyWith(void Function(CreateAIVoltageChanResponse) updates) =>
      super.copyWith((message) => updates(message as CreateAIVoltageChanResponse)) as CreateAIVoltageChanResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static CreateAIVoltageChanResponse create() => CreateAIVoltageChanResponse._();
  @$core.override
  CreateAIVoltageChanResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static CreateAIVoltageChanResponse getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<CreateAIVoltageChanResponse>(create);
  static CreateAIVoltageChanResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $core.int get status => $_getIZ(0);
  @$pb.TagNumber(1)
  set status($core.int value) => $_setSignedInt32(0, value);
  @$pb.TagNumber(1)
  $core.bool hasStatus() => $_has(0);
  @$pb.TagNumber(1)
  void clearStatus() => $_clearField(1);
}

enum CreateAOVoltageChanRequest_UnitsEnum { units, unitsRaw, notSet }

class CreateAOVoltageChanRequest extends $pb.GeneratedMessage {
  factory CreateAOVoltageChanRequest({
    $1.Session? task,
    $core.String? physicalChannel,
    $core.String? nameToAssignToChannel,
    $core.double? minVal,
    $core.double? maxVal,
    VoltageUnits2? units,
    $core.int? unitsRaw,
    $core.String? customScaleName,
  }) {
    final result = create();
    if (task != null) result.task = task;
    if (physicalChannel != null) result.physicalChannel = physicalChannel;
    if (nameToAssignToChannel != null) result.nameToAssignToChannel = nameToAssignToChannel;
    if (minVal != null) result.minVal = minVal;
    if (maxVal != null) result.maxVal = maxVal;
    if (units != null) result.units = units;
    if (unitsRaw != null) result.unitsRaw = unitsRaw;
    if (customScaleName != null) result.customScaleName = customScaleName;
    return result;
  }

  CreateAOVoltageChanRequest._();

  factory CreateAOVoltageChanRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory CreateAOVoltageChanRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static const $core.Map<$core.int, CreateAOVoltageChanRequest_UnitsEnum> _CreateAOVoltageChanRequest_UnitsEnumByTag = {
    6: CreateAOVoltageChanRequest_UnitsEnum.units,
    7: CreateAOVoltageChanRequest_UnitsEnum.unitsRaw,
    0: CreateAOVoltageChanRequest_UnitsEnum.notSet
  };
  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'CreateAOVoltageChanRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'nidaqmx_grpc'), createEmptyInstance: create)
    ..oo(0, [6, 7])
    ..aOM<$1.Session>(1, _omitFieldNames ? '' : 'task', subBuilder: $1.Session.create)
    ..aOS(2, _omitFieldNames ? '' : 'physicalChannel')
    ..aOS(3, _omitFieldNames ? '' : 'nameToAssignToChannel')
    ..aD(4, _omitFieldNames ? '' : 'minVal')
    ..aD(5, _omitFieldNames ? '' : 'maxVal')
    ..aE<VoltageUnits2>(6, _omitFieldNames ? '' : 'units', enumValues: VoltageUnits2.values)
    ..aI(7, _omitFieldNames ? '' : 'unitsRaw')
    ..aOS(8, _omitFieldNames ? '' : 'customScaleName')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CreateAOVoltageChanRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CreateAOVoltageChanRequest copyWith(void Function(CreateAOVoltageChanRequest) updates) =>
      super.copyWith((message) => updates(message as CreateAOVoltageChanRequest)) as CreateAOVoltageChanRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static CreateAOVoltageChanRequest create() => CreateAOVoltageChanRequest._();
  @$core.override
  CreateAOVoltageChanRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static CreateAOVoltageChanRequest getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<CreateAOVoltageChanRequest>(create);
  static CreateAOVoltageChanRequest? _defaultInstance;

  @$pb.TagNumber(6)
  @$pb.TagNumber(7)
  CreateAOVoltageChanRequest_UnitsEnum whichUnitsEnum() => _CreateAOVoltageChanRequest_UnitsEnumByTag[$_whichOneof(0)]!;
  @$pb.TagNumber(6)
  @$pb.TagNumber(7)
  void clearUnitsEnum() => $_clearField($_whichOneof(0));

  @$pb.TagNumber(1)
  $1.Session get task => $_getN(0);
  @$pb.TagNumber(1)
  set task($1.Session value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasTask() => $_has(0);
  @$pb.TagNumber(1)
  void clearTask() => $_clearField(1);
  @$pb.TagNumber(1)
  $1.Session ensureTask() => $_ensure(0);

  @$pb.TagNumber(2)
  $core.String get physicalChannel => $_getSZ(1);
  @$pb.TagNumber(2)
  set physicalChannel($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasPhysicalChannel() => $_has(1);
  @$pb.TagNumber(2)
  void clearPhysicalChannel() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.String get nameToAssignToChannel => $_getSZ(2);
  @$pb.TagNumber(3)
  set nameToAssignToChannel($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasNameToAssignToChannel() => $_has(2);
  @$pb.TagNumber(3)
  void clearNameToAssignToChannel() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.double get minVal => $_getN(3);
  @$pb.TagNumber(4)
  set minVal($core.double value) => $_setDouble(3, value);
  @$pb.TagNumber(4)
  $core.bool hasMinVal() => $_has(3);
  @$pb.TagNumber(4)
  void clearMinVal() => $_clearField(4);

  @$pb.TagNumber(5)
  $core.double get maxVal => $_getN(4);
  @$pb.TagNumber(5)
  set maxVal($core.double value) => $_setDouble(4, value);
  @$pb.TagNumber(5)
  $core.bool hasMaxVal() => $_has(4);
  @$pb.TagNumber(5)
  void clearMaxVal() => $_clearField(5);

  @$pb.TagNumber(6)
  VoltageUnits2 get units => $_getN(5);
  @$pb.TagNumber(6)
  set units(VoltageUnits2 value) => $_setField(6, value);
  @$pb.TagNumber(6)
  $core.bool hasUnits() => $_has(5);
  @$pb.TagNumber(6)
  void clearUnits() => $_clearField(6);

  @$pb.TagNumber(7)
  $core.int get unitsRaw => $_getIZ(6);
  @$pb.TagNumber(7)
  set unitsRaw($core.int value) => $_setSignedInt32(6, value);
  @$pb.TagNumber(7)
  $core.bool hasUnitsRaw() => $_has(6);
  @$pb.TagNumber(7)
  void clearUnitsRaw() => $_clearField(7);

  @$pb.TagNumber(8)
  $core.String get customScaleName => $_getSZ(7);
  @$pb.TagNumber(8)
  set customScaleName($core.String value) => $_setString(7, value);
  @$pb.TagNumber(8)
  $core.bool hasCustomScaleName() => $_has(7);
  @$pb.TagNumber(8)
  void clearCustomScaleName() => $_clearField(8);
}

class CreateAOVoltageChanResponse extends $pb.GeneratedMessage {
  factory CreateAOVoltageChanResponse({
    $core.int? status,
  }) {
    final result = create();
    if (status != null) result.status = status;
    return result;
  }

  CreateAOVoltageChanResponse._();

  factory CreateAOVoltageChanResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory CreateAOVoltageChanResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'CreateAOVoltageChanResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'nidaqmx_grpc'), createEmptyInstance: create)
    ..aI(1, _omitFieldNames ? '' : 'status')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CreateAOVoltageChanResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CreateAOVoltageChanResponse copyWith(void Function(CreateAOVoltageChanResponse) updates) =>
      super.copyWith((message) => updates(message as CreateAOVoltageChanResponse)) as CreateAOVoltageChanResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static CreateAOVoltageChanResponse create() => CreateAOVoltageChanResponse._();
  @$core.override
  CreateAOVoltageChanResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static CreateAOVoltageChanResponse getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<CreateAOVoltageChanResponse>(create);
  static CreateAOVoltageChanResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $core.int get status => $_getIZ(0);
  @$pb.TagNumber(1)
  set status($core.int value) => $_setSignedInt32(0, value);
  @$pb.TagNumber(1)
  $core.bool hasStatus() => $_has(0);
  @$pb.TagNumber(1)
  void clearStatus() => $_clearField(1);
}

class StartTaskRequest extends $pb.GeneratedMessage {
  factory StartTaskRequest({
    $1.Session? task,
  }) {
    final result = create();
    if (task != null) result.task = task;
    return result;
  }

  StartTaskRequest._();

  factory StartTaskRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory StartTaskRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'StartTaskRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'nidaqmx_grpc'), createEmptyInstance: create)
    ..aOM<$1.Session>(1, _omitFieldNames ? '' : 'task', subBuilder: $1.Session.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  StartTaskRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  StartTaskRequest copyWith(void Function(StartTaskRequest) updates) =>
      super.copyWith((message) => updates(message as StartTaskRequest)) as StartTaskRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static StartTaskRequest create() => StartTaskRequest._();
  @$core.override
  StartTaskRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static StartTaskRequest getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<StartTaskRequest>(create);
  static StartTaskRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $1.Session get task => $_getN(0);
  @$pb.TagNumber(1)
  set task($1.Session value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasTask() => $_has(0);
  @$pb.TagNumber(1)
  void clearTask() => $_clearField(1);
  @$pb.TagNumber(1)
  $1.Session ensureTask() => $_ensure(0);
}

class StartTaskResponse extends $pb.GeneratedMessage {
  factory StartTaskResponse({
    $core.int? status,
  }) {
    final result = create();
    if (status != null) result.status = status;
    return result;
  }

  StartTaskResponse._();

  factory StartTaskResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory StartTaskResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'StartTaskResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'nidaqmx_grpc'), createEmptyInstance: create)
    ..aI(1, _omitFieldNames ? '' : 'status')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  StartTaskResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  StartTaskResponse copyWith(void Function(StartTaskResponse) updates) =>
      super.copyWith((message) => updates(message as StartTaskResponse)) as StartTaskResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static StartTaskResponse create() => StartTaskResponse._();
  @$core.override
  StartTaskResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static StartTaskResponse getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<StartTaskResponse>(create);
  static StartTaskResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $core.int get status => $_getIZ(0);
  @$pb.TagNumber(1)
  set status($core.int value) => $_setSignedInt32(0, value);
  @$pb.TagNumber(1)
  $core.bool hasStatus() => $_has(0);
  @$pb.TagNumber(1)
  void clearStatus() => $_clearField(1);
}

class StopTaskRequest extends $pb.GeneratedMessage {
  factory StopTaskRequest({
    $1.Session? task,
  }) {
    final result = create();
    if (task != null) result.task = task;
    return result;
  }

  StopTaskRequest._();

  factory StopTaskRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory StopTaskRequest.fromJson($core.String json, [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'StopTaskRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'nidaqmx_grpc'), createEmptyInstance: create)
    ..aOM<$1.Session>(1, _omitFieldNames ? '' : 'task', subBuilder: $1.Session.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  StopTaskRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  StopTaskRequest copyWith(void Function(StopTaskRequest) updates) =>
      super.copyWith((message) => updates(message as StopTaskRequest)) as StopTaskRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static StopTaskRequest create() => StopTaskRequest._();
  @$core.override
  StopTaskRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static StopTaskRequest getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<StopTaskRequest>(create);
  static StopTaskRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $1.Session get task => $_getN(0);
  @$pb.TagNumber(1)
  set task($1.Session value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasTask() => $_has(0);
  @$pb.TagNumber(1)
  void clearTask() => $_clearField(1);
  @$pb.TagNumber(1)
  $1.Session ensureTask() => $_ensure(0);
}

class StopTaskResponse extends $pb.GeneratedMessage {
  factory StopTaskResponse({
    $core.int? status,
  }) {
    final result = create();
    if (status != null) result.status = status;
    return result;
  }

  StopTaskResponse._();

  factory StopTaskResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory StopTaskResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'StopTaskResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'nidaqmx_grpc'), createEmptyInstance: create)
    ..aI(1, _omitFieldNames ? '' : 'status')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  StopTaskResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  StopTaskResponse copyWith(void Function(StopTaskResponse) updates) =>
      super.copyWith((message) => updates(message as StopTaskResponse)) as StopTaskResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static StopTaskResponse create() => StopTaskResponse._();
  @$core.override
  StopTaskResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static StopTaskResponse getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<StopTaskResponse>(create);
  static StopTaskResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $core.int get status => $_getIZ(0);
  @$pb.TagNumber(1)
  set status($core.int value) => $_setSignedInt32(0, value);
  @$pb.TagNumber(1)
  $core.bool hasStatus() => $_has(0);
  @$pb.TagNumber(1)
  void clearStatus() => $_clearField(1);
}

class ClearTaskRequest extends $pb.GeneratedMessage {
  factory ClearTaskRequest({
    $1.Session? task,
  }) {
    final result = create();
    if (task != null) result.task = task;
    return result;
  }

  ClearTaskRequest._();

  factory ClearTaskRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory ClearTaskRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'ClearTaskRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'nidaqmx_grpc'), createEmptyInstance: create)
    ..aOM<$1.Session>(1, _omitFieldNames ? '' : 'task', subBuilder: $1.Session.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ClearTaskRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ClearTaskRequest copyWith(void Function(ClearTaskRequest) updates) =>
      super.copyWith((message) => updates(message as ClearTaskRequest)) as ClearTaskRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static ClearTaskRequest create() => ClearTaskRequest._();
  @$core.override
  ClearTaskRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static ClearTaskRequest getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<ClearTaskRequest>(create);
  static ClearTaskRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $1.Session get task => $_getN(0);
  @$pb.TagNumber(1)
  set task($1.Session value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasTask() => $_has(0);
  @$pb.TagNumber(1)
  void clearTask() => $_clearField(1);
  @$pb.TagNumber(1)
  $1.Session ensureTask() => $_ensure(0);
}

class ClearTaskResponse extends $pb.GeneratedMessage {
  factory ClearTaskResponse({
    $core.int? status,
  }) {
    final result = create();
    if (status != null) result.status = status;
    return result;
  }

  ClearTaskResponse._();

  factory ClearTaskResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory ClearTaskResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'ClearTaskResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'nidaqmx_grpc'), createEmptyInstance: create)
    ..aI(1, _omitFieldNames ? '' : 'status')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ClearTaskResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ClearTaskResponse copyWith(void Function(ClearTaskResponse) updates) =>
      super.copyWith((message) => updates(message as ClearTaskResponse)) as ClearTaskResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static ClearTaskResponse create() => ClearTaskResponse._();
  @$core.override
  ClearTaskResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static ClearTaskResponse getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<ClearTaskResponse>(create);
  static ClearTaskResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $core.int get status => $_getIZ(0);
  @$pb.TagNumber(1)
  set status($core.int value) => $_setSignedInt32(0, value);
  @$pb.TagNumber(1)
  $core.bool hasStatus() => $_has(0);
  @$pb.TagNumber(1)
  void clearStatus() => $_clearField(1);
}

class ReadAnalogScalarF64Request extends $pb.GeneratedMessage {
  factory ReadAnalogScalarF64Request({
    $1.Session? task,
    $core.double? timeout,
  }) {
    final result = create();
    if (task != null) result.task = task;
    if (timeout != null) result.timeout = timeout;
    return result;
  }

  ReadAnalogScalarF64Request._();

  factory ReadAnalogScalarF64Request.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory ReadAnalogScalarF64Request.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'ReadAnalogScalarF64Request',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'nidaqmx_grpc'), createEmptyInstance: create)
    ..aOM<$1.Session>(1, _omitFieldNames ? '' : 'task', subBuilder: $1.Session.create)
    ..aD(2, _omitFieldNames ? '' : 'timeout')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ReadAnalogScalarF64Request clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ReadAnalogScalarF64Request copyWith(void Function(ReadAnalogScalarF64Request) updates) =>
      super.copyWith((message) => updates(message as ReadAnalogScalarF64Request)) as ReadAnalogScalarF64Request;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static ReadAnalogScalarF64Request create() => ReadAnalogScalarF64Request._();
  @$core.override
  ReadAnalogScalarF64Request createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static ReadAnalogScalarF64Request getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<ReadAnalogScalarF64Request>(create);
  static ReadAnalogScalarF64Request? _defaultInstance;

  @$pb.TagNumber(1)
  $1.Session get task => $_getN(0);
  @$pb.TagNumber(1)
  set task($1.Session value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasTask() => $_has(0);
  @$pb.TagNumber(1)
  void clearTask() => $_clearField(1);
  @$pb.TagNumber(1)
  $1.Session ensureTask() => $_ensure(0);

  @$pb.TagNumber(2)
  $core.double get timeout => $_getN(1);
  @$pb.TagNumber(2)
  set timeout($core.double value) => $_setDouble(1, value);
  @$pb.TagNumber(2)
  $core.bool hasTimeout() => $_has(1);
  @$pb.TagNumber(2)
  void clearTimeout() => $_clearField(2);
}

class ReadAnalogScalarF64Response extends $pb.GeneratedMessage {
  factory ReadAnalogScalarF64Response({
    $core.int? status,
    $core.double? value,
  }) {
    final result = create();
    if (status != null) result.status = status;
    if (value != null) result.value = value;
    return result;
  }

  ReadAnalogScalarF64Response._();

  factory ReadAnalogScalarF64Response.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory ReadAnalogScalarF64Response.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'ReadAnalogScalarF64Response',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'nidaqmx_grpc'), createEmptyInstance: create)
    ..aI(1, _omitFieldNames ? '' : 'status')
    ..aD(2, _omitFieldNames ? '' : 'value')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ReadAnalogScalarF64Response clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ReadAnalogScalarF64Response copyWith(void Function(ReadAnalogScalarF64Response) updates) =>
      super.copyWith((message) => updates(message as ReadAnalogScalarF64Response)) as ReadAnalogScalarF64Response;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static ReadAnalogScalarF64Response create() => ReadAnalogScalarF64Response._();
  @$core.override
  ReadAnalogScalarF64Response createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static ReadAnalogScalarF64Response getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<ReadAnalogScalarF64Response>(create);
  static ReadAnalogScalarF64Response? _defaultInstance;

  @$pb.TagNumber(1)
  $core.int get status => $_getIZ(0);
  @$pb.TagNumber(1)
  set status($core.int value) => $_setSignedInt32(0, value);
  @$pb.TagNumber(1)
  $core.bool hasStatus() => $_has(0);
  @$pb.TagNumber(1)
  void clearStatus() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.double get value => $_getN(1);
  @$pb.TagNumber(2)
  set value($core.double value) => $_setDouble(1, value);
  @$pb.TagNumber(2)
  $core.bool hasValue() => $_has(1);
  @$pb.TagNumber(2)
  void clearValue() => $_clearField(2);
}

class WriteAnalogScalarF64Request extends $pb.GeneratedMessage {
  factory WriteAnalogScalarF64Request({
    $1.Session? task,
    $core.bool? autoStart,
    $core.double? timeout,
    $core.double? value,
  }) {
    final result = create();
    if (task != null) result.task = task;
    if (autoStart != null) result.autoStart = autoStart;
    if (timeout != null) result.timeout = timeout;
    if (value != null) result.value = value;
    return result;
  }

  WriteAnalogScalarF64Request._();

  factory WriteAnalogScalarF64Request.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory WriteAnalogScalarF64Request.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'WriteAnalogScalarF64Request',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'nidaqmx_grpc'), createEmptyInstance: create)
    ..aOM<$1.Session>(1, _omitFieldNames ? '' : 'task', subBuilder: $1.Session.create)
    ..aOB(2, _omitFieldNames ? '' : 'autoStart')
    ..aD(3, _omitFieldNames ? '' : 'timeout')
    ..aD(4, _omitFieldNames ? '' : 'value')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  WriteAnalogScalarF64Request clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  WriteAnalogScalarF64Request copyWith(void Function(WriteAnalogScalarF64Request) updates) =>
      super.copyWith((message) => updates(message as WriteAnalogScalarF64Request)) as WriteAnalogScalarF64Request;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static WriteAnalogScalarF64Request create() => WriteAnalogScalarF64Request._();
  @$core.override
  WriteAnalogScalarF64Request createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static WriteAnalogScalarF64Request getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<WriteAnalogScalarF64Request>(create);
  static WriteAnalogScalarF64Request? _defaultInstance;

  @$pb.TagNumber(1)
  $1.Session get task => $_getN(0);
  @$pb.TagNumber(1)
  set task($1.Session value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasTask() => $_has(0);
  @$pb.TagNumber(1)
  void clearTask() => $_clearField(1);
  @$pb.TagNumber(1)
  $1.Session ensureTask() => $_ensure(0);

  @$pb.TagNumber(2)
  $core.bool get autoStart => $_getBF(1);
  @$pb.TagNumber(2)
  set autoStart($core.bool value) => $_setBool(1, value);
  @$pb.TagNumber(2)
  $core.bool hasAutoStart() => $_has(1);
  @$pb.TagNumber(2)
  void clearAutoStart() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.double get timeout => $_getN(2);
  @$pb.TagNumber(3)
  set timeout($core.double value) => $_setDouble(2, value);
  @$pb.TagNumber(3)
  $core.bool hasTimeout() => $_has(2);
  @$pb.TagNumber(3)
  void clearTimeout() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.double get value => $_getN(3);
  @$pb.TagNumber(4)
  set value($core.double value) => $_setDouble(3, value);
  @$pb.TagNumber(4)
  $core.bool hasValue() => $_has(3);
  @$pb.TagNumber(4)
  void clearValue() => $_clearField(4);
}

class WriteAnalogScalarF64Response extends $pb.GeneratedMessage {
  factory WriteAnalogScalarF64Response({
    $core.int? status,
  }) {
    final result = create();
    if (status != null) result.status = status;
    return result;
  }

  WriteAnalogScalarF64Response._();

  factory WriteAnalogScalarF64Response.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory WriteAnalogScalarF64Response.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'WriteAnalogScalarF64Response',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'nidaqmx_grpc'), createEmptyInstance: create)
    ..aI(1, _omitFieldNames ? '' : 'status')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  WriteAnalogScalarF64Response clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  WriteAnalogScalarF64Response copyWith(void Function(WriteAnalogScalarF64Response) updates) =>
      super.copyWith((message) => updates(message as WriteAnalogScalarF64Response)) as WriteAnalogScalarF64Response;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static WriteAnalogScalarF64Response create() => WriteAnalogScalarF64Response._();
  @$core.override
  WriteAnalogScalarF64Response createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static WriteAnalogScalarF64Response getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<WriteAnalogScalarF64Response>(create);
  static WriteAnalogScalarF64Response? _defaultInstance;

  @$pb.TagNumber(1)
  $core.int get status => $_getIZ(0);
  @$pb.TagNumber(1)
  set status($core.int value) => $_setSignedInt32(0, value);
  @$pb.TagNumber(1)
  $core.bool hasStatus() => $_has(0);
  @$pb.TagNumber(1)
  void clearStatus() => $_clearField(1);
}

class GetErrorStringRequest extends $pb.GeneratedMessage {
  factory GetErrorStringRequest({
    $core.int? errorCode,
  }) {
    final result = create();
    if (errorCode != null) result.errorCode = errorCode;
    return result;
  }

  GetErrorStringRequest._();

  factory GetErrorStringRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory GetErrorStringRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'GetErrorStringRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'nidaqmx_grpc'), createEmptyInstance: create)
    ..aI(1, _omitFieldNames ? '' : 'errorCode')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetErrorStringRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetErrorStringRequest copyWith(void Function(GetErrorStringRequest) updates) =>
      super.copyWith((message) => updates(message as GetErrorStringRequest)) as GetErrorStringRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static GetErrorStringRequest create() => GetErrorStringRequest._();
  @$core.override
  GetErrorStringRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static GetErrorStringRequest getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<GetErrorStringRequest>(create);
  static GetErrorStringRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.int get errorCode => $_getIZ(0);
  @$pb.TagNumber(1)
  set errorCode($core.int value) => $_setSignedInt32(0, value);
  @$pb.TagNumber(1)
  $core.bool hasErrorCode() => $_has(0);
  @$pb.TagNumber(1)
  void clearErrorCode() => $_clearField(1);
}

class GetErrorStringResponse extends $pb.GeneratedMessage {
  factory GetErrorStringResponse({
    $core.int? status,
    $core.String? errorString,
  }) {
    final result = create();
    if (status != null) result.status = status;
    if (errorString != null) result.errorString = errorString;
    return result;
  }

  GetErrorStringResponse._();

  factory GetErrorStringResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory GetErrorStringResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'GetErrorStringResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'nidaqmx_grpc'), createEmptyInstance: create)
    ..aI(1, _omitFieldNames ? '' : 'status')
    ..aOS(2, _omitFieldNames ? '' : 'errorString')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetErrorStringResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetErrorStringResponse copyWith(void Function(GetErrorStringResponse) updates) =>
      super.copyWith((message) => updates(message as GetErrorStringResponse)) as GetErrorStringResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static GetErrorStringResponse create() => GetErrorStringResponse._();
  @$core.override
  GetErrorStringResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static GetErrorStringResponse getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<GetErrorStringResponse>(create);
  static GetErrorStringResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $core.int get status => $_getIZ(0);
  @$pb.TagNumber(1)
  set status($core.int value) => $_setSignedInt32(0, value);
  @$pb.TagNumber(1)
  $core.bool hasStatus() => $_has(0);
  @$pb.TagNumber(1)
  void clearStatus() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get errorString => $_getSZ(1);
  @$pb.TagNumber(2)
  set errorString($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasErrorString() => $_has(1);
  @$pb.TagNumber(2)
  void clearErrorString() => $_clearField(2);
}

/// Sample-clock timing. We send the `_raw` int32 variants (the oneof enum variants at
/// field 4/6 are omitted from this subset; field numbers are preserved).
class CfgSampClkTimingRequest extends $pb.GeneratedMessage {
  factory CfgSampClkTimingRequest({
    $1.Session? task,
    $core.String? source,
    $core.double? rate,
    $core.int? activeEdgeRaw,
    $core.int? sampleModeRaw,
    $fixnum.Int64? sampsPerChan,
  }) {
    final result = create();
    if (task != null) result.task = task;
    if (source != null) result.source = source;
    if (rate != null) result.rate = rate;
    if (activeEdgeRaw != null) result.activeEdgeRaw = activeEdgeRaw;
    if (sampleModeRaw != null) result.sampleModeRaw = sampleModeRaw;
    if (sampsPerChan != null) result.sampsPerChan = sampsPerChan;
    return result;
  }

  CfgSampClkTimingRequest._();

  factory CfgSampClkTimingRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory CfgSampClkTimingRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'CfgSampClkTimingRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'nidaqmx_grpc'), createEmptyInstance: create)
    ..aOM<$1.Session>(1, _omitFieldNames ? '' : 'task', subBuilder: $1.Session.create)
    ..aOS(2, _omitFieldNames ? '' : 'source')
    ..aD(3, _omitFieldNames ? '' : 'rate')
    ..aI(5, _omitFieldNames ? '' : 'activeEdgeRaw')
    ..aI(7, _omitFieldNames ? '' : 'sampleModeRaw')
    ..a<$fixnum.Int64>(8, _omitFieldNames ? '' : 'sampsPerChan', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CfgSampClkTimingRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CfgSampClkTimingRequest copyWith(void Function(CfgSampClkTimingRequest) updates) =>
      super.copyWith((message) => updates(message as CfgSampClkTimingRequest)) as CfgSampClkTimingRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static CfgSampClkTimingRequest create() => CfgSampClkTimingRequest._();
  @$core.override
  CfgSampClkTimingRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static CfgSampClkTimingRequest getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<CfgSampClkTimingRequest>(create);
  static CfgSampClkTimingRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $1.Session get task => $_getN(0);
  @$pb.TagNumber(1)
  set task($1.Session value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasTask() => $_has(0);
  @$pb.TagNumber(1)
  void clearTask() => $_clearField(1);
  @$pb.TagNumber(1)
  $1.Session ensureTask() => $_ensure(0);

  @$pb.TagNumber(2)
  $core.String get source => $_getSZ(1);
  @$pb.TagNumber(2)
  set source($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasSource() => $_has(1);
  @$pb.TagNumber(2)
  void clearSource() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.double get rate => $_getN(2);
  @$pb.TagNumber(3)
  set rate($core.double value) => $_setDouble(2, value);
  @$pb.TagNumber(3)
  $core.bool hasRate() => $_has(2);
  @$pb.TagNumber(3)
  void clearRate() => $_clearField(3);

  @$pb.TagNumber(5)
  $core.int get activeEdgeRaw => $_getIZ(3);
  @$pb.TagNumber(5)
  set activeEdgeRaw($core.int value) => $_setSignedInt32(3, value);
  @$pb.TagNumber(5)
  $core.bool hasActiveEdgeRaw() => $_has(3);
  @$pb.TagNumber(5)
  void clearActiveEdgeRaw() => $_clearField(5);

  @$pb.TagNumber(7)
  $core.int get sampleModeRaw => $_getIZ(4);
  @$pb.TagNumber(7)
  set sampleModeRaw($core.int value) => $_setSignedInt32(4, value);
  @$pb.TagNumber(7)
  $core.bool hasSampleModeRaw() => $_has(4);
  @$pb.TagNumber(7)
  void clearSampleModeRaw() => $_clearField(7);

  @$pb.TagNumber(8)
  $fixnum.Int64 get sampsPerChan => $_getI64(5);
  @$pb.TagNumber(8)
  set sampsPerChan($fixnum.Int64 value) => $_setInt64(5, value);
  @$pb.TagNumber(8)
  $core.bool hasSampsPerChan() => $_has(5);
  @$pb.TagNumber(8)
  void clearSampsPerChan() => $_clearField(8);
}

class CfgSampClkTimingResponse extends $pb.GeneratedMessage {
  factory CfgSampClkTimingResponse({
    $core.int? status,
  }) {
    final result = create();
    if (status != null) result.status = status;
    return result;
  }

  CfgSampClkTimingResponse._();

  factory CfgSampClkTimingResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory CfgSampClkTimingResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'CfgSampClkTimingResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'nidaqmx_grpc'), createEmptyInstance: create)
    ..aI(1, _omitFieldNames ? '' : 'status')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CfgSampClkTimingResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CfgSampClkTimingResponse copyWith(void Function(CfgSampClkTimingResponse) updates) =>
      super.copyWith((message) => updates(message as CfgSampClkTimingResponse)) as CfgSampClkTimingResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static CfgSampClkTimingResponse create() => CfgSampClkTimingResponse._();
  @$core.override
  CfgSampClkTimingResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static CfgSampClkTimingResponse getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<CfgSampClkTimingResponse>(create);
  static CfgSampClkTimingResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $core.int get status => $_getIZ(0);
  @$pb.TagNumber(1)
  set status($core.int value) => $_setSignedInt32(0, value);
  @$pb.TagNumber(1)
  $core.bool hasStatus() => $_has(0);
  @$pb.TagNumber(1)
  void clearStatus() => $_clearField(1);
}

/// Begin*Read requests share the read shape; we send fill_mode_raw (enum variant at
/// field 4 omitted). Each returns a Moniker to stream from.
class BeginReadAnalogF64Request extends $pb.GeneratedMessage {
  factory BeginReadAnalogF64Request({
    $1.Session? task,
    $core.int? numSampsPerChan,
    $core.double? timeout,
    $core.int? fillModeRaw,
    $core.int? arraySizeInSamps,
  }) {
    final result = create();
    if (task != null) result.task = task;
    if (numSampsPerChan != null) result.numSampsPerChan = numSampsPerChan;
    if (timeout != null) result.timeout = timeout;
    if (fillModeRaw != null) result.fillModeRaw = fillModeRaw;
    if (arraySizeInSamps != null) result.arraySizeInSamps = arraySizeInSamps;
    return result;
  }

  BeginReadAnalogF64Request._();

  factory BeginReadAnalogF64Request.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory BeginReadAnalogF64Request.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'BeginReadAnalogF64Request',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'nidaqmx_grpc'), createEmptyInstance: create)
    ..aOM<$1.Session>(1, _omitFieldNames ? '' : 'task', subBuilder: $1.Session.create)
    ..aI(2, _omitFieldNames ? '' : 'numSampsPerChan')
    ..aD(3, _omitFieldNames ? '' : 'timeout')
    ..aI(5, _omitFieldNames ? '' : 'fillModeRaw')
    ..aI(6, _omitFieldNames ? '' : 'arraySizeInSamps', fieldType: $pb.PbFieldType.OU3)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  BeginReadAnalogF64Request clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  BeginReadAnalogF64Request copyWith(void Function(BeginReadAnalogF64Request) updates) =>
      super.copyWith((message) => updates(message as BeginReadAnalogF64Request)) as BeginReadAnalogF64Request;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static BeginReadAnalogF64Request create() => BeginReadAnalogF64Request._();
  @$core.override
  BeginReadAnalogF64Request createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static BeginReadAnalogF64Request getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<BeginReadAnalogF64Request>(create);
  static BeginReadAnalogF64Request? _defaultInstance;

  @$pb.TagNumber(1)
  $1.Session get task => $_getN(0);
  @$pb.TagNumber(1)
  set task($1.Session value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasTask() => $_has(0);
  @$pb.TagNumber(1)
  void clearTask() => $_clearField(1);
  @$pb.TagNumber(1)
  $1.Session ensureTask() => $_ensure(0);

  @$pb.TagNumber(2)
  $core.int get numSampsPerChan => $_getIZ(1);
  @$pb.TagNumber(2)
  set numSampsPerChan($core.int value) => $_setSignedInt32(1, value);
  @$pb.TagNumber(2)
  $core.bool hasNumSampsPerChan() => $_has(1);
  @$pb.TagNumber(2)
  void clearNumSampsPerChan() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.double get timeout => $_getN(2);
  @$pb.TagNumber(3)
  set timeout($core.double value) => $_setDouble(2, value);
  @$pb.TagNumber(3)
  $core.bool hasTimeout() => $_has(2);
  @$pb.TagNumber(3)
  void clearTimeout() => $_clearField(3);

  @$pb.TagNumber(5)
  $core.int get fillModeRaw => $_getIZ(3);
  @$pb.TagNumber(5)
  set fillModeRaw($core.int value) => $_setSignedInt32(3, value);
  @$pb.TagNumber(5)
  $core.bool hasFillModeRaw() => $_has(3);
  @$pb.TagNumber(5)
  void clearFillModeRaw() => $_clearField(5);

  @$pb.TagNumber(6)
  $core.int get arraySizeInSamps => $_getIZ(4);
  @$pb.TagNumber(6)
  set arraySizeInSamps($core.int value) => $_setUnsignedInt32(4, value);
  @$pb.TagNumber(6)
  $core.bool hasArraySizeInSamps() => $_has(4);
  @$pb.TagNumber(6)
  void clearArraySizeInSamps() => $_clearField(6);
}

class BeginReadAnalogF64Response extends $pb.GeneratedMessage {
  factory BeginReadAnalogF64Response({
    $core.int? status,
    $2.Moniker? moniker,
  }) {
    final result = create();
    if (status != null) result.status = status;
    if (moniker != null) result.moniker = moniker;
    return result;
  }

  BeginReadAnalogF64Response._();

  factory BeginReadAnalogF64Response.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory BeginReadAnalogF64Response.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'BeginReadAnalogF64Response',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'nidaqmx_grpc'), createEmptyInstance: create)
    ..aI(1, _omitFieldNames ? '' : 'status')
    ..aOM<$2.Moniker>(2, _omitFieldNames ? '' : 'moniker', subBuilder: $2.Moniker.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  BeginReadAnalogF64Response clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  BeginReadAnalogF64Response copyWith(void Function(BeginReadAnalogF64Response) updates) =>
      super.copyWith((message) => updates(message as BeginReadAnalogF64Response)) as BeginReadAnalogF64Response;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static BeginReadAnalogF64Response create() => BeginReadAnalogF64Response._();
  @$core.override
  BeginReadAnalogF64Response createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static BeginReadAnalogF64Response getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<BeginReadAnalogF64Response>(create);
  static BeginReadAnalogF64Response? _defaultInstance;

  @$pb.TagNumber(1)
  $core.int get status => $_getIZ(0);
  @$pb.TagNumber(1)
  set status($core.int value) => $_setSignedInt32(0, value);
  @$pb.TagNumber(1)
  $core.bool hasStatus() => $_has(0);
  @$pb.TagNumber(1)
  void clearStatus() => $_clearField(1);

  @$pb.TagNumber(2)
  $2.Moniker get moniker => $_getN(1);
  @$pb.TagNumber(2)
  set moniker($2.Moniker value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasMoniker() => $_has(1);
  @$pb.TagNumber(2)
  void clearMoniker() => $_clearField(2);
  @$pb.TagNumber(2)
  $2.Moniker ensureMoniker() => $_ensure(1);
}

class BeginReadBinaryI16Request extends $pb.GeneratedMessage {
  factory BeginReadBinaryI16Request({
    $1.Session? task,
    $core.int? numSampsPerChan,
    $core.double? timeout,
    $core.int? fillModeRaw,
    $core.int? arraySizeInSamps,
  }) {
    final result = create();
    if (task != null) result.task = task;
    if (numSampsPerChan != null) result.numSampsPerChan = numSampsPerChan;
    if (timeout != null) result.timeout = timeout;
    if (fillModeRaw != null) result.fillModeRaw = fillModeRaw;
    if (arraySizeInSamps != null) result.arraySizeInSamps = arraySizeInSamps;
    return result;
  }

  BeginReadBinaryI16Request._();

  factory BeginReadBinaryI16Request.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory BeginReadBinaryI16Request.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'BeginReadBinaryI16Request',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'nidaqmx_grpc'), createEmptyInstance: create)
    ..aOM<$1.Session>(1, _omitFieldNames ? '' : 'task', subBuilder: $1.Session.create)
    ..aI(2, _omitFieldNames ? '' : 'numSampsPerChan')
    ..aD(3, _omitFieldNames ? '' : 'timeout')
    ..aI(5, _omitFieldNames ? '' : 'fillModeRaw')
    ..aI(6, _omitFieldNames ? '' : 'arraySizeInSamps', fieldType: $pb.PbFieldType.OU3)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  BeginReadBinaryI16Request clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  BeginReadBinaryI16Request copyWith(void Function(BeginReadBinaryI16Request) updates) =>
      super.copyWith((message) => updates(message as BeginReadBinaryI16Request)) as BeginReadBinaryI16Request;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static BeginReadBinaryI16Request create() => BeginReadBinaryI16Request._();
  @$core.override
  BeginReadBinaryI16Request createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static BeginReadBinaryI16Request getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<BeginReadBinaryI16Request>(create);
  static BeginReadBinaryI16Request? _defaultInstance;

  @$pb.TagNumber(1)
  $1.Session get task => $_getN(0);
  @$pb.TagNumber(1)
  set task($1.Session value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasTask() => $_has(0);
  @$pb.TagNumber(1)
  void clearTask() => $_clearField(1);
  @$pb.TagNumber(1)
  $1.Session ensureTask() => $_ensure(0);

  @$pb.TagNumber(2)
  $core.int get numSampsPerChan => $_getIZ(1);
  @$pb.TagNumber(2)
  set numSampsPerChan($core.int value) => $_setSignedInt32(1, value);
  @$pb.TagNumber(2)
  $core.bool hasNumSampsPerChan() => $_has(1);
  @$pb.TagNumber(2)
  void clearNumSampsPerChan() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.double get timeout => $_getN(2);
  @$pb.TagNumber(3)
  set timeout($core.double value) => $_setDouble(2, value);
  @$pb.TagNumber(3)
  $core.bool hasTimeout() => $_has(2);
  @$pb.TagNumber(3)
  void clearTimeout() => $_clearField(3);

  @$pb.TagNumber(5)
  $core.int get fillModeRaw => $_getIZ(3);
  @$pb.TagNumber(5)
  set fillModeRaw($core.int value) => $_setSignedInt32(3, value);
  @$pb.TagNumber(5)
  $core.bool hasFillModeRaw() => $_has(3);
  @$pb.TagNumber(5)
  void clearFillModeRaw() => $_clearField(5);

  @$pb.TagNumber(6)
  $core.int get arraySizeInSamps => $_getIZ(4);
  @$pb.TagNumber(6)
  set arraySizeInSamps($core.int value) => $_setUnsignedInt32(4, value);
  @$pb.TagNumber(6)
  $core.bool hasArraySizeInSamps() => $_has(4);
  @$pb.TagNumber(6)
  void clearArraySizeInSamps() => $_clearField(6);
}

class BeginReadBinaryI16Response extends $pb.GeneratedMessage {
  factory BeginReadBinaryI16Response({
    $core.int? status,
    $2.Moniker? moniker,
  }) {
    final result = create();
    if (status != null) result.status = status;
    if (moniker != null) result.moniker = moniker;
    return result;
  }

  BeginReadBinaryI16Response._();

  factory BeginReadBinaryI16Response.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory BeginReadBinaryI16Response.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'BeginReadBinaryI16Response',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'nidaqmx_grpc'), createEmptyInstance: create)
    ..aI(1, _omitFieldNames ? '' : 'status')
    ..aOM<$2.Moniker>(2, _omitFieldNames ? '' : 'moniker', subBuilder: $2.Moniker.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  BeginReadBinaryI16Response clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  BeginReadBinaryI16Response copyWith(void Function(BeginReadBinaryI16Response) updates) =>
      super.copyWith((message) => updates(message as BeginReadBinaryI16Response)) as BeginReadBinaryI16Response;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static BeginReadBinaryI16Response create() => BeginReadBinaryI16Response._();
  @$core.override
  BeginReadBinaryI16Response createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static BeginReadBinaryI16Response getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<BeginReadBinaryI16Response>(create);
  static BeginReadBinaryI16Response? _defaultInstance;

  @$pb.TagNumber(1)
  $core.int get status => $_getIZ(0);
  @$pb.TagNumber(1)
  set status($core.int value) => $_setSignedInt32(0, value);
  @$pb.TagNumber(1)
  $core.bool hasStatus() => $_has(0);
  @$pb.TagNumber(1)
  void clearStatus() => $_clearField(1);

  @$pb.TagNumber(2)
  $2.Moniker get moniker => $_getN(1);
  @$pb.TagNumber(2)
  set moniker($2.Moniker value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasMoniker() => $_has(1);
  @$pb.TagNumber(2)
  void clearMoniker() => $_clearField(2);
  @$pb.TagNumber(2)
  $2.Moniker ensureMoniker() => $_ensure(1);
}

class BeginReadBinaryI32Request extends $pb.GeneratedMessage {
  factory BeginReadBinaryI32Request({
    $1.Session? task,
    $core.int? numSampsPerChan,
    $core.double? timeout,
    $core.int? fillModeRaw,
    $core.int? arraySizeInSamps,
  }) {
    final result = create();
    if (task != null) result.task = task;
    if (numSampsPerChan != null) result.numSampsPerChan = numSampsPerChan;
    if (timeout != null) result.timeout = timeout;
    if (fillModeRaw != null) result.fillModeRaw = fillModeRaw;
    if (arraySizeInSamps != null) result.arraySizeInSamps = arraySizeInSamps;
    return result;
  }

  BeginReadBinaryI32Request._();

  factory BeginReadBinaryI32Request.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory BeginReadBinaryI32Request.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'BeginReadBinaryI32Request',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'nidaqmx_grpc'), createEmptyInstance: create)
    ..aOM<$1.Session>(1, _omitFieldNames ? '' : 'task', subBuilder: $1.Session.create)
    ..aI(2, _omitFieldNames ? '' : 'numSampsPerChan')
    ..aD(3, _omitFieldNames ? '' : 'timeout')
    ..aI(5, _omitFieldNames ? '' : 'fillModeRaw')
    ..aI(6, _omitFieldNames ? '' : 'arraySizeInSamps', fieldType: $pb.PbFieldType.OU3)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  BeginReadBinaryI32Request clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  BeginReadBinaryI32Request copyWith(void Function(BeginReadBinaryI32Request) updates) =>
      super.copyWith((message) => updates(message as BeginReadBinaryI32Request)) as BeginReadBinaryI32Request;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static BeginReadBinaryI32Request create() => BeginReadBinaryI32Request._();
  @$core.override
  BeginReadBinaryI32Request createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static BeginReadBinaryI32Request getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<BeginReadBinaryI32Request>(create);
  static BeginReadBinaryI32Request? _defaultInstance;

  @$pb.TagNumber(1)
  $1.Session get task => $_getN(0);
  @$pb.TagNumber(1)
  set task($1.Session value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasTask() => $_has(0);
  @$pb.TagNumber(1)
  void clearTask() => $_clearField(1);
  @$pb.TagNumber(1)
  $1.Session ensureTask() => $_ensure(0);

  @$pb.TagNumber(2)
  $core.int get numSampsPerChan => $_getIZ(1);
  @$pb.TagNumber(2)
  set numSampsPerChan($core.int value) => $_setSignedInt32(1, value);
  @$pb.TagNumber(2)
  $core.bool hasNumSampsPerChan() => $_has(1);
  @$pb.TagNumber(2)
  void clearNumSampsPerChan() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.double get timeout => $_getN(2);
  @$pb.TagNumber(3)
  set timeout($core.double value) => $_setDouble(2, value);
  @$pb.TagNumber(3)
  $core.bool hasTimeout() => $_has(2);
  @$pb.TagNumber(3)
  void clearTimeout() => $_clearField(3);

  @$pb.TagNumber(5)
  $core.int get fillModeRaw => $_getIZ(3);
  @$pb.TagNumber(5)
  set fillModeRaw($core.int value) => $_setSignedInt32(3, value);
  @$pb.TagNumber(5)
  $core.bool hasFillModeRaw() => $_has(3);
  @$pb.TagNumber(5)
  void clearFillModeRaw() => $_clearField(5);

  @$pb.TagNumber(6)
  $core.int get arraySizeInSamps => $_getIZ(4);
  @$pb.TagNumber(6)
  set arraySizeInSamps($core.int value) => $_setUnsignedInt32(4, value);
  @$pb.TagNumber(6)
  $core.bool hasArraySizeInSamps() => $_has(4);
  @$pb.TagNumber(6)
  void clearArraySizeInSamps() => $_clearField(6);
}

class BeginReadBinaryI32Response extends $pb.GeneratedMessage {
  factory BeginReadBinaryI32Response({
    $core.int? status,
    $2.Moniker? moniker,
  }) {
    final result = create();
    if (status != null) result.status = status;
    if (moniker != null) result.moniker = moniker;
    return result;
  }

  BeginReadBinaryI32Response._();

  factory BeginReadBinaryI32Response.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory BeginReadBinaryI32Response.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'BeginReadBinaryI32Response',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'nidaqmx_grpc'), createEmptyInstance: create)
    ..aI(1, _omitFieldNames ? '' : 'status')
    ..aOM<$2.Moniker>(2, _omitFieldNames ? '' : 'moniker', subBuilder: $2.Moniker.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  BeginReadBinaryI32Response clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  BeginReadBinaryI32Response copyWith(void Function(BeginReadBinaryI32Response) updates) =>
      super.copyWith((message) => updates(message as BeginReadBinaryI32Response)) as BeginReadBinaryI32Response;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static BeginReadBinaryI32Response create() => BeginReadBinaryI32Response._();
  @$core.override
  BeginReadBinaryI32Response createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static BeginReadBinaryI32Response getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<BeginReadBinaryI32Response>(create);
  static BeginReadBinaryI32Response? _defaultInstance;

  @$pb.TagNumber(1)
  $core.int get status => $_getIZ(0);
  @$pb.TagNumber(1)
  set status($core.int value) => $_setSignedInt32(0, value);
  @$pb.TagNumber(1)
  $core.bool hasStatus() => $_has(0);
  @$pb.TagNumber(1)
  void clearStatus() => $_clearField(1);

  @$pb.TagNumber(2)
  $2.Moniker get moniker => $_getN(1);
  @$pb.TagNumber(2)
  set moniker($2.Moniker value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasMoniker() => $_has(1);
  @$pb.TagNumber(2)
  void clearMoniker() => $_clearField(2);
  @$pb.TagNumber(2)
  $2.Moniker ensureMoniker() => $_ensure(1);
}

/// Per-frame payloads carried in MonikerReadResponse's Any values. (protobuf has no
/// int16, so raw 16-bit codes arrive as int32 and are narrowed client-side.)
class MonikerReadAnalogF64Response extends $pb.GeneratedMessage {
  factory MonikerReadAnalogF64Response({
    $core.int? status,
    $core.Iterable<$core.double>? readArray,
    $core.int? sampsPerChanRead,
  }) {
    final result = create();
    if (status != null) result.status = status;
    if (readArray != null) result.readArray.addAll(readArray);
    if (sampsPerChanRead != null) result.sampsPerChanRead = sampsPerChanRead;
    return result;
  }

  MonikerReadAnalogF64Response._();

  factory MonikerReadAnalogF64Response.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory MonikerReadAnalogF64Response.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'MonikerReadAnalogF64Response',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'nidaqmx_grpc'), createEmptyInstance: create)
    ..aI(1, _omitFieldNames ? '' : 'status')
    ..p<$core.double>(2, _omitFieldNames ? '' : 'readArray', $pb.PbFieldType.KD)
    ..aI(3, _omitFieldNames ? '' : 'sampsPerChanRead')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  MonikerReadAnalogF64Response clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  MonikerReadAnalogF64Response copyWith(void Function(MonikerReadAnalogF64Response) updates) =>
      super.copyWith((message) => updates(message as MonikerReadAnalogF64Response)) as MonikerReadAnalogF64Response;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static MonikerReadAnalogF64Response create() => MonikerReadAnalogF64Response._();
  @$core.override
  MonikerReadAnalogF64Response createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static MonikerReadAnalogF64Response getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<MonikerReadAnalogF64Response>(create);
  static MonikerReadAnalogF64Response? _defaultInstance;

  @$pb.TagNumber(1)
  $core.int get status => $_getIZ(0);
  @$pb.TagNumber(1)
  set status($core.int value) => $_setSignedInt32(0, value);
  @$pb.TagNumber(1)
  $core.bool hasStatus() => $_has(0);
  @$pb.TagNumber(1)
  void clearStatus() => $_clearField(1);

  @$pb.TagNumber(2)
  $pb.PbList<$core.double> get readArray => $_getList(1);

  @$pb.TagNumber(3)
  $core.int get sampsPerChanRead => $_getIZ(2);
  @$pb.TagNumber(3)
  set sampsPerChanRead($core.int value) => $_setSignedInt32(2, value);
  @$pb.TagNumber(3)
  $core.bool hasSampsPerChanRead() => $_has(2);
  @$pb.TagNumber(3)
  void clearSampsPerChanRead() => $_clearField(3);
}

class MonikerReadBinaryI16Response extends $pb.GeneratedMessage {
  factory MonikerReadBinaryI16Response({
    $core.int? status,
    $core.Iterable<$core.int>? readArray,
    $core.int? sampsPerChanRead,
  }) {
    final result = create();
    if (status != null) result.status = status;
    if (readArray != null) result.readArray.addAll(readArray);
    if (sampsPerChanRead != null) result.sampsPerChanRead = sampsPerChanRead;
    return result;
  }

  MonikerReadBinaryI16Response._();

  factory MonikerReadBinaryI16Response.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory MonikerReadBinaryI16Response.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'MonikerReadBinaryI16Response',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'nidaqmx_grpc'), createEmptyInstance: create)
    ..aI(1, _omitFieldNames ? '' : 'status')
    ..p<$core.int>(2, _omitFieldNames ? '' : 'readArray', $pb.PbFieldType.K3)
    ..aI(3, _omitFieldNames ? '' : 'sampsPerChanRead')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  MonikerReadBinaryI16Response clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  MonikerReadBinaryI16Response copyWith(void Function(MonikerReadBinaryI16Response) updates) =>
      super.copyWith((message) => updates(message as MonikerReadBinaryI16Response)) as MonikerReadBinaryI16Response;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static MonikerReadBinaryI16Response create() => MonikerReadBinaryI16Response._();
  @$core.override
  MonikerReadBinaryI16Response createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static MonikerReadBinaryI16Response getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<MonikerReadBinaryI16Response>(create);
  static MonikerReadBinaryI16Response? _defaultInstance;

  @$pb.TagNumber(1)
  $core.int get status => $_getIZ(0);
  @$pb.TagNumber(1)
  set status($core.int value) => $_setSignedInt32(0, value);
  @$pb.TagNumber(1)
  $core.bool hasStatus() => $_has(0);
  @$pb.TagNumber(1)
  void clearStatus() => $_clearField(1);

  @$pb.TagNumber(2)
  $pb.PbList<$core.int> get readArray => $_getList(1);

  @$pb.TagNumber(3)
  $core.int get sampsPerChanRead => $_getIZ(2);
  @$pb.TagNumber(3)
  set sampsPerChanRead($core.int value) => $_setSignedInt32(2, value);
  @$pb.TagNumber(3)
  $core.bool hasSampsPerChanRead() => $_has(2);
  @$pb.TagNumber(3)
  void clearSampsPerChanRead() => $_clearField(3);
}

class MonikerReadBinaryI32Response extends $pb.GeneratedMessage {
  factory MonikerReadBinaryI32Response({
    $core.int? status,
    $core.Iterable<$core.int>? readArray,
    $core.int? sampsPerChanRead,
  }) {
    final result = create();
    if (status != null) result.status = status;
    if (readArray != null) result.readArray.addAll(readArray);
    if (sampsPerChanRead != null) result.sampsPerChanRead = sampsPerChanRead;
    return result;
  }

  MonikerReadBinaryI32Response._();

  factory MonikerReadBinaryI32Response.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory MonikerReadBinaryI32Response.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'MonikerReadBinaryI32Response',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'nidaqmx_grpc'), createEmptyInstance: create)
    ..aI(1, _omitFieldNames ? '' : 'status')
    ..p<$core.int>(2, _omitFieldNames ? '' : 'readArray', $pb.PbFieldType.K3)
    ..aI(3, _omitFieldNames ? '' : 'sampsPerChanRead')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  MonikerReadBinaryI32Response clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  MonikerReadBinaryI32Response copyWith(void Function(MonikerReadBinaryI32Response) updates) =>
      super.copyWith((message) => updates(message as MonikerReadBinaryI32Response)) as MonikerReadBinaryI32Response;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static MonikerReadBinaryI32Response create() => MonikerReadBinaryI32Response._();
  @$core.override
  MonikerReadBinaryI32Response createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static MonikerReadBinaryI32Response getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<MonikerReadBinaryI32Response>(create);
  static MonikerReadBinaryI32Response? _defaultInstance;

  @$pb.TagNumber(1)
  $core.int get status => $_getIZ(0);
  @$pb.TagNumber(1)
  set status($core.int value) => $_setSignedInt32(0, value);
  @$pb.TagNumber(1)
  $core.bool hasStatus() => $_has(0);
  @$pb.TagNumber(1)
  void clearStatus() => $_clearField(1);

  @$pb.TagNumber(2)
  $pb.PbList<$core.int> get readArray => $_getList(1);

  @$pb.TagNumber(3)
  $core.int get sampsPerChanRead => $_getIZ(2);
  @$pb.TagNumber(3)
  set sampsPerChanRead($core.int value) => $_setSignedInt32(2, value);
  @$pb.TagNumber(3)
  $core.bool hasSampsPerChanRead() => $_has(2);
  @$pb.TagNumber(3)
  void clearSampsPerChanRead() => $_clearField(3);
}

const $core.bool _omitFieldNames = $core.bool.fromEnvironment('protobuf.omit_field_names');
const $core.bool _omitMessageNames = $core.bool.fromEnvironment('protobuf.omit_message_names');
