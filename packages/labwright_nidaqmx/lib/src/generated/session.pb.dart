// This is a generated file - do not edit.
//
// Generated from session.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:core' as $core;

import 'package:protobuf/protobuf.dart' as $pb;

export 'package:protobuf/protobuf.dart' show GeneratedMessageGenericExtensions;

export 'session.pbenum.dart';

/// A server-side session handle. For NI-DAQmx, `name` is the DAQmx task handle the
/// server returns from CreateTask and that subsequent calls pass back.
class Session extends $pb.GeneratedMessage {
  factory Session({
    $core.String? name,
  }) {
    final result = create();
    if (name != null) result.name = name;
    return result;
  }

  Session._();

  factory Session.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory Session.fromJson($core.String json, [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'Session',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'nidevice_grpc'), createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'name')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Session clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Session copyWith(void Function(Session) updates) =>
      super.copyWith((message) => updates(message as Session)) as Session;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static Session create() => Session._();
  @$core.override
  Session createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static Session getDefault() => _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<Session>(create);
  static Session? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get name => $_getSZ(0);
  @$pb.TagNumber(1)
  set name($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasName() => $_has(0);
  @$pb.TagNumber(1)
  void clearName() => $_clearField(1);
}

class EnumerateDevicesRequest extends $pb.GeneratedMessage {
  factory EnumerateDevicesRequest() => create();

  EnumerateDevicesRequest._();

  factory EnumerateDevicesRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory EnumerateDevicesRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'EnumerateDevicesRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'nidevice_grpc'), createEmptyInstance: create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  EnumerateDevicesRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  EnumerateDevicesRequest copyWith(void Function(EnumerateDevicesRequest) updates) =>
      super.copyWith((message) => updates(message as EnumerateDevicesRequest)) as EnumerateDevicesRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static EnumerateDevicesRequest create() => EnumerateDevicesRequest._();
  @$core.override
  EnumerateDevicesRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static EnumerateDevicesRequest getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<EnumerateDevicesRequest>(create);
  static EnumerateDevicesRequest? _defaultInstance;
}

class EnumerateDevicesResponse extends $pb.GeneratedMessage {
  factory EnumerateDevicesResponse({
    $core.Iterable<DeviceProperties>? devices,
  }) {
    final result = create();
    if (devices != null) result.devices.addAll(devices);
    return result;
  }

  EnumerateDevicesResponse._();

  factory EnumerateDevicesResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory EnumerateDevicesResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'EnumerateDevicesResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'nidevice_grpc'), createEmptyInstance: create)
    ..pPM<DeviceProperties>(1, _omitFieldNames ? '' : 'devices', subBuilder: DeviceProperties.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  EnumerateDevicesResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  EnumerateDevicesResponse copyWith(void Function(EnumerateDevicesResponse) updates) =>
      super.copyWith((message) => updates(message as EnumerateDevicesResponse)) as EnumerateDevicesResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static EnumerateDevicesResponse create() => EnumerateDevicesResponse._();
  @$core.override
  EnumerateDevicesResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static EnumerateDevicesResponse getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<EnumerateDevicesResponse>(create);
  static EnumerateDevicesResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $pb.PbList<DeviceProperties> get devices => $_getList(0);
}

class DeviceProperties extends $pb.GeneratedMessage {
  factory DeviceProperties({
    $core.String? name,
    $core.String? model,
    $core.String? vendor,
    $core.String? serialNumber,
    $core.int? productId,
  }) {
    final result = create();
    if (name != null) result.name = name;
    if (model != null) result.model = model;
    if (vendor != null) result.vendor = vendor;
    if (serialNumber != null) result.serialNumber = serialNumber;
    if (productId != null) result.productId = productId;
    return result;
  }

  DeviceProperties._();

  factory DeviceProperties.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory DeviceProperties.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'DeviceProperties',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'nidevice_grpc'), createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'name')
    ..aOS(2, _omitFieldNames ? '' : 'model')
    ..aOS(3, _omitFieldNames ? '' : 'vendor')
    ..aOS(4, _omitFieldNames ? '' : 'serialNumber')
    ..aI(5, _omitFieldNames ? '' : 'productId', fieldType: $pb.PbFieldType.OU3)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DeviceProperties clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DeviceProperties copyWith(void Function(DeviceProperties) updates) =>
      super.copyWith((message) => updates(message as DeviceProperties)) as DeviceProperties;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static DeviceProperties create() => DeviceProperties._();
  @$core.override
  DeviceProperties createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static DeviceProperties getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<DeviceProperties>(create);
  static DeviceProperties? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get name => $_getSZ(0);
  @$pb.TagNumber(1)
  set name($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasName() => $_has(0);
  @$pb.TagNumber(1)
  void clearName() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get model => $_getSZ(1);
  @$pb.TagNumber(2)
  set model($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasModel() => $_has(1);
  @$pb.TagNumber(2)
  void clearModel() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.String get vendor => $_getSZ(2);
  @$pb.TagNumber(3)
  set vendor($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasVendor() => $_has(2);
  @$pb.TagNumber(3)
  void clearVendor() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.String get serialNumber => $_getSZ(3);
  @$pb.TagNumber(4)
  set serialNumber($core.String value) => $_setString(3, value);
  @$pb.TagNumber(4)
  $core.bool hasSerialNumber() => $_has(3);
  @$pb.TagNumber(4)
  void clearSerialNumber() => $_clearField(4);

  @$pb.TagNumber(5)
  $core.int get productId => $_getIZ(4);
  @$pb.TagNumber(5)
  set productId($core.int value) => $_setUnsignedInt32(4, value);
  @$pb.TagNumber(5)
  $core.bool hasProductId() => $_has(4);
  @$pb.TagNumber(5)
  void clearProductId() => $_clearField(5);
}

const $core.bool _omitFieldNames = $core.bool.fromEnvironment('protobuf.omit_field_names');
const $core.bool _omitMessageNames = $core.bool.fromEnvironment('protobuf.omit_message_names');
