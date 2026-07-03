// This is a generated file - do not edit.
//
// Generated from data_moniker.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:core' as $core;

import 'package:fixnum/fixnum.dart' as $fixnum;
import 'package:protobuf/protobuf.dart' as $pb;
import 'package:protobuf/well_known_types/google/protobuf/any.pb.dart' as $1;

import 'data_moniker.pbenum.dart';

export 'package:protobuf/protobuf.dart' show GeneratedMessageGenericExtensions;

export 'data_moniker.pbenum.dart';

/// A handle to a server-side data endpoint (which server / data source / instance).
class Moniker extends $pb.GeneratedMessage {
  factory Moniker({
    $core.String? serviceLocation,
    $core.String? dataSource,
    $fixnum.Int64? dataInstance,
  }) {
    final result = create();
    if (serviceLocation != null) result.serviceLocation = serviceLocation;
    if (dataSource != null) result.dataSource = dataSource;
    if (dataInstance != null) result.dataInstance = dataInstance;
    return result;
  }

  Moniker._();

  factory Moniker.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory Moniker.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Moniker',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'ni.data_monikers'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'serviceLocation')
    ..aOS(2, _omitFieldNames ? '' : 'dataSource')
    ..aInt64(3, _omitFieldNames ? '' : 'dataInstance')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Moniker clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Moniker copyWith(void Function(Moniker) updates) =>
      super.copyWith((message) => updates(message as Moniker)) as Moniker;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static Moniker create() => Moniker._();
  @$core.override
  Moniker createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static Moniker getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<Moniker>(create);
  static Moniker? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get serviceLocation => $_getSZ(0);
  @$pb.TagNumber(1)
  set serviceLocation($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasServiceLocation() => $_has(0);
  @$pb.TagNumber(1)
  void clearServiceLocation() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get dataSource => $_getSZ(1);
  @$pb.TagNumber(2)
  set dataSource($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasDataSource() => $_has(1);
  @$pb.TagNumber(2)
  void clearDataSource() => $_clearField(2);

  @$pb.TagNumber(3)
  $fixnum.Int64 get dataInstance => $_getI64(2);
  @$pb.TagNumber(3)
  set dataInstance($fixnum.Int64 value) => $_setInt64(2, value);
  @$pb.TagNumber(3)
  $core.bool hasDataInstance() => $_has(2);
  @$pb.TagNumber(3)
  void clearDataInstance() => $_clearField(3);
}

class MonikerList extends $pb.GeneratedMessage {
  factory MonikerList({
    $core.Iterable<Moniker>? readMonikers,
    $core.Iterable<Moniker>? writeMonikers,
  }) {
    final result = create();
    if (readMonikers != null) result.readMonikers.addAll(readMonikers);
    if (writeMonikers != null) result.writeMonikers.addAll(writeMonikers);
    return result;
  }

  MonikerList._();

  factory MonikerList.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory MonikerList.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'MonikerList',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'ni.data_monikers'),
      createEmptyInstance: create)
    ..pPM<Moniker>(2, _omitFieldNames ? '' : 'readMonikers',
        subBuilder: Moniker.create)
    ..pPM<Moniker>(3, _omitFieldNames ? '' : 'writeMonikers',
        subBuilder: Moniker.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  MonikerList clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  MonikerList copyWith(void Function(MonikerList) updates) =>
      super.copyWith((message) => updates(message as MonikerList))
          as MonikerList;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static MonikerList create() => MonikerList._();
  @$core.override
  MonikerList createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static MonikerList getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<MonikerList>(create);
  static MonikerList? _defaultInstance;

  @$pb.TagNumber(2)
  $pb.PbList<Moniker> get readMonikers => $_getList(0);

  @$pb.TagNumber(3)
  $pb.PbList<Moniker> get writeMonikers => $_getList(1);
}

/// One frame's payload: each value is a type-specific message (e.g. a
/// MonikerReadAnalogF64Response) packed into an Any.
class MonikerValues extends $pb.GeneratedMessage {
  factory MonikerValues({
    $core.Iterable<$1.Any>? values,
  }) {
    final result = create();
    if (values != null) result.values.addAll(values);
    return result;
  }

  MonikerValues._();

  factory MonikerValues.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory MonikerValues.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'MonikerValues',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'ni.data_monikers'),
      createEmptyInstance: create)
    ..pPM<$1.Any>(1, _omitFieldNames ? '' : 'values', subBuilder: $1.Any.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  MonikerValues clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  MonikerValues copyWith(void Function(MonikerValues) updates) =>
      super.copyWith((message) => updates(message as MonikerValues))
          as MonikerValues;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static MonikerValues create() => MonikerValues._();
  @$core.override
  MonikerValues createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static MonikerValues getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<MonikerValues>(create);
  static MonikerValues? _defaultInstance;

  @$pb.TagNumber(1)
  $pb.PbList<$1.Any> get values => $_getList(0);
}

class MonikerReadResponse extends $pb.GeneratedMessage {
  factory MonikerReadResponse({
    MonikerValues? data,
  }) {
    final result = create();
    if (data != null) result.data = data;
    return result;
  }

  MonikerReadResponse._();

  factory MonikerReadResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory MonikerReadResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'MonikerReadResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'ni.data_monikers'),
      createEmptyInstance: create)
    ..aOM<MonikerValues>(1, _omitFieldNames ? '' : 'data',
        subBuilder: MonikerValues.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  MonikerReadResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  MonikerReadResponse copyWith(void Function(MonikerReadResponse) updates) =>
      super.copyWith((message) => updates(message as MonikerReadResponse))
          as MonikerReadResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static MonikerReadResponse create() => MonikerReadResponse._();
  @$core.override
  MonikerReadResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static MonikerReadResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<MonikerReadResponse>(create);
  static MonikerReadResponse? _defaultInstance;

  @$pb.TagNumber(1)
  MonikerValues get data => $_getN(0);
  @$pb.TagNumber(1)
  set data(MonikerValues value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasData() => $_has(0);
  @$pb.TagNumber(1)
  void clearData() => $_clearField(1);
  @$pb.TagNumber(1)
  MonikerValues ensureData() => $_ensure(0);
}

class BeginMonikerSidebandStreamRequest extends $pb.GeneratedMessage {
  factory BeginMonikerSidebandStreamRequest({
    SidebandStrategy? strategy,
    MonikerList? monikers,
  }) {
    final result = create();
    if (strategy != null) result.strategy = strategy;
    if (monikers != null) result.monikers = monikers;
    return result;
  }

  BeginMonikerSidebandStreamRequest._();

  factory BeginMonikerSidebandStreamRequest.fromBuffer(
          $core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory BeginMonikerSidebandStreamRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'BeginMonikerSidebandStreamRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'ni.data_monikers'),
      createEmptyInstance: create)
    ..aE<SidebandStrategy>(1, _omitFieldNames ? '' : 'strategy',
        enumValues: SidebandStrategy.values)
    ..aOM<MonikerList>(2, _omitFieldNames ? '' : 'monikers',
        subBuilder: MonikerList.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  BeginMonikerSidebandStreamRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  BeginMonikerSidebandStreamRequest copyWith(
          void Function(BeginMonikerSidebandStreamRequest) updates) =>
      super.copyWith((message) =>
              updates(message as BeginMonikerSidebandStreamRequest))
          as BeginMonikerSidebandStreamRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static BeginMonikerSidebandStreamRequest create() =>
      BeginMonikerSidebandStreamRequest._();
  @$core.override
  BeginMonikerSidebandStreamRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static BeginMonikerSidebandStreamRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<BeginMonikerSidebandStreamRequest>(
          create);
  static BeginMonikerSidebandStreamRequest? _defaultInstance;

  @$pb.TagNumber(1)
  SidebandStrategy get strategy => $_getN(0);
  @$pb.TagNumber(1)
  set strategy(SidebandStrategy value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasStrategy() => $_has(0);
  @$pb.TagNumber(1)
  void clearStrategy() => $_clearField(1);

  @$pb.TagNumber(2)
  MonikerList get monikers => $_getN(1);
  @$pb.TagNumber(2)
  set monikers(MonikerList value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasMonikers() => $_has(1);
  @$pb.TagNumber(2)
  void clearMonikers() => $_clearField(2);
  @$pb.TagNumber(2)
  MonikerList ensureMonikers() => $_ensure(1);
}

class BeginMonikerSidebandStreamResponse extends $pb.GeneratedMessage {
  factory BeginMonikerSidebandStreamResponse({
    SidebandStrategy? strategy,
    $core.String? connectionUrl,
    $core.String? sidebandIdentifier,
    $fixnum.Int64? bufferSize,
  }) {
    final result = create();
    if (strategy != null) result.strategy = strategy;
    if (connectionUrl != null) result.connectionUrl = connectionUrl;
    if (sidebandIdentifier != null)
      result.sidebandIdentifier = sidebandIdentifier;
    if (bufferSize != null) result.bufferSize = bufferSize;
    return result;
  }

  BeginMonikerSidebandStreamResponse._();

  factory BeginMonikerSidebandStreamResponse.fromBuffer(
          $core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory BeginMonikerSidebandStreamResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'BeginMonikerSidebandStreamResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'ni.data_monikers'),
      createEmptyInstance: create)
    ..aE<SidebandStrategy>(1, _omitFieldNames ? '' : 'strategy',
        enumValues: SidebandStrategy.values)
    ..aOS(2, _omitFieldNames ? '' : 'connectionUrl')
    ..aOS(3, _omitFieldNames ? '' : 'sidebandIdentifier')
    ..a<$fixnum.Int64>(
        4, _omitFieldNames ? '' : 'bufferSize', $pb.PbFieldType.OS6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  BeginMonikerSidebandStreamResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  BeginMonikerSidebandStreamResponse copyWith(
          void Function(BeginMonikerSidebandStreamResponse) updates) =>
      super.copyWith((message) =>
              updates(message as BeginMonikerSidebandStreamResponse))
          as BeginMonikerSidebandStreamResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static BeginMonikerSidebandStreamResponse create() =>
      BeginMonikerSidebandStreamResponse._();
  @$core.override
  BeginMonikerSidebandStreamResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static BeginMonikerSidebandStreamResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<BeginMonikerSidebandStreamResponse>(
          create);
  static BeginMonikerSidebandStreamResponse? _defaultInstance;

  @$pb.TagNumber(1)
  SidebandStrategy get strategy => $_getN(0);
  @$pb.TagNumber(1)
  set strategy(SidebandStrategy value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasStrategy() => $_has(0);
  @$pb.TagNumber(1)
  void clearStrategy() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get connectionUrl => $_getSZ(1);
  @$pb.TagNumber(2)
  set connectionUrl($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasConnectionUrl() => $_has(1);
  @$pb.TagNumber(2)
  void clearConnectionUrl() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.String get sidebandIdentifier => $_getSZ(2);
  @$pb.TagNumber(3)
  set sidebandIdentifier($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasSidebandIdentifier() => $_has(2);
  @$pb.TagNumber(3)
  void clearSidebandIdentifier() => $_clearField(3);

  @$pb.TagNumber(4)
  $fixnum.Int64 get bufferSize => $_getI64(3);
  @$pb.TagNumber(4)
  set bufferSize($fixnum.Int64 value) => $_setInt64(3, value);
  @$pb.TagNumber(4)
  $core.bool hasBufferSize() => $_has(3);
  @$pb.TagNumber(4)
  void clearBufferSize() => $_clearField(4);
}

const $core.bool _omitFieldNames =
    $core.bool.fromEnvironment('protobuf.omit_field_names');
const $core.bool _omitMessageNames =
    $core.bool.fromEnvironment('protobuf.omit_message_names');
