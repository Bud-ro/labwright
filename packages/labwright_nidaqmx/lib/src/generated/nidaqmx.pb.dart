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

import 'package:protobuf/protobuf.dart' as $pb;

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
    if (initializationBehavior != null)
      result.initializationBehavior = initializationBehavior;
    return result;
  }

  CreateTaskRequest._();

  factory CreateTaskRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory CreateTaskRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'CreateTaskRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'nidaqmx_grpc'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'sessionName')
    ..aE<$1.SessionInitializationBehavior>(
        2, _omitFieldNames ? '' : 'initializationBehavior',
        enumValues: $1.SessionInitializationBehavior.values)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CreateTaskRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CreateTaskRequest copyWith(void Function(CreateTaskRequest) updates) =>
      super.copyWith((message) => updates(message as CreateTaskRequest))
          as CreateTaskRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static CreateTaskRequest create() => CreateTaskRequest._();
  @$core.override
  CreateTaskRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static CreateTaskRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<CreateTaskRequest>(create);
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
  set initializationBehavior($1.SessionInitializationBehavior value) =>
      $_setField(2, value);
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
    if (newSessionInitialized != null)
      result.newSessionInitialized = newSessionInitialized;
    return result;
  }

  CreateTaskResponse._();

  factory CreateTaskResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory CreateTaskResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'CreateTaskResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'nidaqmx_grpc'),
      createEmptyInstance: create)
    ..aI(1, _omitFieldNames ? '' : 'status')
    ..aOM<$1.Session>(2, _omitFieldNames ? '' : 'task',
        subBuilder: $1.Session.create)
    ..aOB(3, _omitFieldNames ? '' : 'newSessionInitialized')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CreateTaskResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CreateTaskResponse copyWith(void Function(CreateTaskResponse) updates) =>
      super.copyWith((message) => updates(message as CreateTaskResponse))
          as CreateTaskResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static CreateTaskResponse create() => CreateTaskResponse._();
  @$core.override
  CreateTaskResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static CreateTaskResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<CreateTaskResponse>(create);
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

enum CreateAIVoltageChanRequest_TerminalConfigEnum {
  terminalConfig,
  terminalConfigRaw,
  notSet
}

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
    if (nameToAssignToChannel != null)
      result.nameToAssignToChannel = nameToAssignToChannel;
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

  static const $core
      .Map<$core.int, CreateAIVoltageChanRequest_TerminalConfigEnum>
      _CreateAIVoltageChanRequest_TerminalConfigEnumByTag = {
    4: CreateAIVoltageChanRequest_TerminalConfigEnum.terminalConfig,
    5: CreateAIVoltageChanRequest_TerminalConfigEnum.terminalConfigRaw,
    0: CreateAIVoltageChanRequest_TerminalConfigEnum.notSet
  };
  static const $core.Map<$core.int, CreateAIVoltageChanRequest_UnitsEnum>
      _CreateAIVoltageChanRequest_UnitsEnumByTag = {
    8: CreateAIVoltageChanRequest_UnitsEnum.units,
    9: CreateAIVoltageChanRequest_UnitsEnum.unitsRaw,
    0: CreateAIVoltageChanRequest_UnitsEnum.notSet
  };
  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'CreateAIVoltageChanRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'nidaqmx_grpc'),
      createEmptyInstance: create)
    ..oo(0, [4, 5])
    ..oo(1, [8, 9])
    ..aOM<$1.Session>(1, _omitFieldNames ? '' : 'task',
        subBuilder: $1.Session.create)
    ..aOS(2, _omitFieldNames ? '' : 'physicalChannel')
    ..aOS(3, _omitFieldNames ? '' : 'nameToAssignToChannel')
    ..aE<InputTermCfgWithDefault>(4, _omitFieldNames ? '' : 'terminalConfig',
        enumValues: InputTermCfgWithDefault.values)
    ..aI(5, _omitFieldNames ? '' : 'terminalConfigRaw')
    ..aD(6, _omitFieldNames ? '' : 'minVal')
    ..aD(7, _omitFieldNames ? '' : 'maxVal')
    ..aE<VoltageUnits2>(8, _omitFieldNames ? '' : 'units',
        enumValues: VoltageUnits2.values)
    ..aI(9, _omitFieldNames ? '' : 'unitsRaw')
    ..aOS(10, _omitFieldNames ? '' : 'customScaleName')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CreateAIVoltageChanRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CreateAIVoltageChanRequest copyWith(
          void Function(CreateAIVoltageChanRequest) updates) =>
      super.copyWith(
              (message) => updates(message as CreateAIVoltageChanRequest))
          as CreateAIVoltageChanRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static CreateAIVoltageChanRequest create() => CreateAIVoltageChanRequest._();
  @$core.override
  CreateAIVoltageChanRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static CreateAIVoltageChanRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<CreateAIVoltageChanRequest>(create);
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
  CreateAIVoltageChanRequest_UnitsEnum whichUnitsEnum() =>
      _CreateAIVoltageChanRequest_UnitsEnumByTag[$_whichOneof(1)]!;
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

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'CreateAIVoltageChanResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'nidaqmx_grpc'),
      createEmptyInstance: create)
    ..aI(1, _omitFieldNames ? '' : 'status')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CreateAIVoltageChanResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CreateAIVoltageChanResponse copyWith(
          void Function(CreateAIVoltageChanResponse) updates) =>
      super.copyWith(
              (message) => updates(message as CreateAIVoltageChanResponse))
          as CreateAIVoltageChanResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static CreateAIVoltageChanResponse create() =>
      CreateAIVoltageChanResponse._();
  @$core.override
  CreateAIVoltageChanResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static CreateAIVoltageChanResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<CreateAIVoltageChanResponse>(create);
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
    if (nameToAssignToChannel != null)
      result.nameToAssignToChannel = nameToAssignToChannel;
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

  static const $core.Map<$core.int, CreateAOVoltageChanRequest_UnitsEnum>
      _CreateAOVoltageChanRequest_UnitsEnumByTag = {
    6: CreateAOVoltageChanRequest_UnitsEnum.units,
    7: CreateAOVoltageChanRequest_UnitsEnum.unitsRaw,
    0: CreateAOVoltageChanRequest_UnitsEnum.notSet
  };
  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'CreateAOVoltageChanRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'nidaqmx_grpc'),
      createEmptyInstance: create)
    ..oo(0, [6, 7])
    ..aOM<$1.Session>(1, _omitFieldNames ? '' : 'task',
        subBuilder: $1.Session.create)
    ..aOS(2, _omitFieldNames ? '' : 'physicalChannel')
    ..aOS(3, _omitFieldNames ? '' : 'nameToAssignToChannel')
    ..aD(4, _omitFieldNames ? '' : 'minVal')
    ..aD(5, _omitFieldNames ? '' : 'maxVal')
    ..aE<VoltageUnits2>(6, _omitFieldNames ? '' : 'units',
        enumValues: VoltageUnits2.values)
    ..aI(7, _omitFieldNames ? '' : 'unitsRaw')
    ..aOS(8, _omitFieldNames ? '' : 'customScaleName')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CreateAOVoltageChanRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CreateAOVoltageChanRequest copyWith(
          void Function(CreateAOVoltageChanRequest) updates) =>
      super.copyWith(
              (message) => updates(message as CreateAOVoltageChanRequest))
          as CreateAOVoltageChanRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static CreateAOVoltageChanRequest create() => CreateAOVoltageChanRequest._();
  @$core.override
  CreateAOVoltageChanRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static CreateAOVoltageChanRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<CreateAOVoltageChanRequest>(create);
  static CreateAOVoltageChanRequest? _defaultInstance;

  @$pb.TagNumber(6)
  @$pb.TagNumber(7)
  CreateAOVoltageChanRequest_UnitsEnum whichUnitsEnum() =>
      _CreateAOVoltageChanRequest_UnitsEnumByTag[$_whichOneof(0)]!;
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

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'CreateAOVoltageChanResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'nidaqmx_grpc'),
      createEmptyInstance: create)
    ..aI(1, _omitFieldNames ? '' : 'status')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CreateAOVoltageChanResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CreateAOVoltageChanResponse copyWith(
          void Function(CreateAOVoltageChanResponse) updates) =>
      super.copyWith(
              (message) => updates(message as CreateAOVoltageChanResponse))
          as CreateAOVoltageChanResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static CreateAOVoltageChanResponse create() =>
      CreateAOVoltageChanResponse._();
  @$core.override
  CreateAOVoltageChanResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static CreateAOVoltageChanResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<CreateAOVoltageChanResponse>(create);
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

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'StartTaskRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'nidaqmx_grpc'),
      createEmptyInstance: create)
    ..aOM<$1.Session>(1, _omitFieldNames ? '' : 'task',
        subBuilder: $1.Session.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  StartTaskRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  StartTaskRequest copyWith(void Function(StartTaskRequest) updates) =>
      super.copyWith((message) => updates(message as StartTaskRequest))
          as StartTaskRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static StartTaskRequest create() => StartTaskRequest._();
  @$core.override
  StartTaskRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static StartTaskRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<StartTaskRequest>(create);
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

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'StartTaskResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'nidaqmx_grpc'),
      createEmptyInstance: create)
    ..aI(1, _omitFieldNames ? '' : 'status')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  StartTaskResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  StartTaskResponse copyWith(void Function(StartTaskResponse) updates) =>
      super.copyWith((message) => updates(message as StartTaskResponse))
          as StartTaskResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static StartTaskResponse create() => StartTaskResponse._();
  @$core.override
  StartTaskResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static StartTaskResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<StartTaskResponse>(create);
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
  factory StopTaskRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'StopTaskRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'nidaqmx_grpc'),
      createEmptyInstance: create)
    ..aOM<$1.Session>(1, _omitFieldNames ? '' : 'task',
        subBuilder: $1.Session.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  StopTaskRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  StopTaskRequest copyWith(void Function(StopTaskRequest) updates) =>
      super.copyWith((message) => updates(message as StopTaskRequest))
          as StopTaskRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static StopTaskRequest create() => StopTaskRequest._();
  @$core.override
  StopTaskRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static StopTaskRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<StopTaskRequest>(create);
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

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'StopTaskResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'nidaqmx_grpc'),
      createEmptyInstance: create)
    ..aI(1, _omitFieldNames ? '' : 'status')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  StopTaskResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  StopTaskResponse copyWith(void Function(StopTaskResponse) updates) =>
      super.copyWith((message) => updates(message as StopTaskResponse))
          as StopTaskResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static StopTaskResponse create() => StopTaskResponse._();
  @$core.override
  StopTaskResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static StopTaskResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<StopTaskResponse>(create);
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

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ClearTaskRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'nidaqmx_grpc'),
      createEmptyInstance: create)
    ..aOM<$1.Session>(1, _omitFieldNames ? '' : 'task',
        subBuilder: $1.Session.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ClearTaskRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ClearTaskRequest copyWith(void Function(ClearTaskRequest) updates) =>
      super.copyWith((message) => updates(message as ClearTaskRequest))
          as ClearTaskRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static ClearTaskRequest create() => ClearTaskRequest._();
  @$core.override
  ClearTaskRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static ClearTaskRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ClearTaskRequest>(create);
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

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ClearTaskResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'nidaqmx_grpc'),
      createEmptyInstance: create)
    ..aI(1, _omitFieldNames ? '' : 'status')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ClearTaskResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ClearTaskResponse copyWith(void Function(ClearTaskResponse) updates) =>
      super.copyWith((message) => updates(message as ClearTaskResponse))
          as ClearTaskResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static ClearTaskResponse create() => ClearTaskResponse._();
  @$core.override
  ClearTaskResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static ClearTaskResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ClearTaskResponse>(create);
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

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ReadAnalogScalarF64Request',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'nidaqmx_grpc'),
      createEmptyInstance: create)
    ..aOM<$1.Session>(1, _omitFieldNames ? '' : 'task',
        subBuilder: $1.Session.create)
    ..aD(2, _omitFieldNames ? '' : 'timeout')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ReadAnalogScalarF64Request clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ReadAnalogScalarF64Request copyWith(
          void Function(ReadAnalogScalarF64Request) updates) =>
      super.copyWith(
              (message) => updates(message as ReadAnalogScalarF64Request))
          as ReadAnalogScalarF64Request;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static ReadAnalogScalarF64Request create() => ReadAnalogScalarF64Request._();
  @$core.override
  ReadAnalogScalarF64Request createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static ReadAnalogScalarF64Request getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ReadAnalogScalarF64Request>(create);
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

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ReadAnalogScalarF64Response',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'nidaqmx_grpc'),
      createEmptyInstance: create)
    ..aI(1, _omitFieldNames ? '' : 'status')
    ..aD(2, _omitFieldNames ? '' : 'value')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ReadAnalogScalarF64Response clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ReadAnalogScalarF64Response copyWith(
          void Function(ReadAnalogScalarF64Response) updates) =>
      super.copyWith(
              (message) => updates(message as ReadAnalogScalarF64Response))
          as ReadAnalogScalarF64Response;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static ReadAnalogScalarF64Response create() =>
      ReadAnalogScalarF64Response._();
  @$core.override
  ReadAnalogScalarF64Response createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static ReadAnalogScalarF64Response getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ReadAnalogScalarF64Response>(create);
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

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'WriteAnalogScalarF64Request',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'nidaqmx_grpc'),
      createEmptyInstance: create)
    ..aOM<$1.Session>(1, _omitFieldNames ? '' : 'task',
        subBuilder: $1.Session.create)
    ..aOB(2, _omitFieldNames ? '' : 'autoStart')
    ..aD(3, _omitFieldNames ? '' : 'timeout')
    ..aD(4, _omitFieldNames ? '' : 'value')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  WriteAnalogScalarF64Request clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  WriteAnalogScalarF64Request copyWith(
          void Function(WriteAnalogScalarF64Request) updates) =>
      super.copyWith(
              (message) => updates(message as WriteAnalogScalarF64Request))
          as WriteAnalogScalarF64Request;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static WriteAnalogScalarF64Request create() =>
      WriteAnalogScalarF64Request._();
  @$core.override
  WriteAnalogScalarF64Request createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static WriteAnalogScalarF64Request getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<WriteAnalogScalarF64Request>(create);
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

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'WriteAnalogScalarF64Response',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'nidaqmx_grpc'),
      createEmptyInstance: create)
    ..aI(1, _omitFieldNames ? '' : 'status')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  WriteAnalogScalarF64Response clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  WriteAnalogScalarF64Response copyWith(
          void Function(WriteAnalogScalarF64Response) updates) =>
      super.copyWith(
              (message) => updates(message as WriteAnalogScalarF64Response))
          as WriteAnalogScalarF64Response;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static WriteAnalogScalarF64Response create() =>
      WriteAnalogScalarF64Response._();
  @$core.override
  WriteAnalogScalarF64Response createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static WriteAnalogScalarF64Response getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<WriteAnalogScalarF64Response>(create);
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

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'GetErrorStringRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'nidaqmx_grpc'),
      createEmptyInstance: create)
    ..aI(1, _omitFieldNames ? '' : 'errorCode')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetErrorStringRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetErrorStringRequest copyWith(
          void Function(GetErrorStringRequest) updates) =>
      super.copyWith((message) => updates(message as GetErrorStringRequest))
          as GetErrorStringRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static GetErrorStringRequest create() => GetErrorStringRequest._();
  @$core.override
  GetErrorStringRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static GetErrorStringRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<GetErrorStringRequest>(create);
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

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'GetErrorStringResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'nidaqmx_grpc'),
      createEmptyInstance: create)
    ..aI(1, _omitFieldNames ? '' : 'status')
    ..aOS(2, _omitFieldNames ? '' : 'errorString')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetErrorStringResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetErrorStringResponse copyWith(
          void Function(GetErrorStringResponse) updates) =>
      super.copyWith((message) => updates(message as GetErrorStringResponse))
          as GetErrorStringResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static GetErrorStringResponse create() => GetErrorStringResponse._();
  @$core.override
  GetErrorStringResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static GetErrorStringResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<GetErrorStringResponse>(create);
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

const $core.bool _omitFieldNames =
    $core.bool.fromEnvironment('protobuf.omit_field_names');
const $core.bool _omitMessageNames =
    $core.bool.fromEnvironment('protobuf.omit_message_names');
