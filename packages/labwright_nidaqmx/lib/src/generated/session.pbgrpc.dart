// This is a generated file - do not edit.
//
// Generated from session.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:async' as $async;
import 'dart:core' as $core;

import 'package:grpc/service_api.dart' as $grpc;
import 'package:protobuf/protobuf.dart' as $pb;

import 'session.pb.dart' as $0;

export 'session.pb.dart';

/// Cross-driver utilities exposed by the server (device discovery, reservation, ...).
/// Only EnumerateDevices is transcribed here.
@$pb.GrpcServiceName('nidevice_grpc.SessionUtilities')
class SessionUtilitiesClient extends $grpc.Client {
  /// The hostname for this service.
  static const $core.String defaultHost = '';

  /// OAuth scopes needed for the client.
  static const $core.List<$core.String> oauthScopes = [
    '',
  ];

  SessionUtilitiesClient(super.channel, {super.options, super.interceptors});

  $grpc.ResponseFuture<$0.EnumerateDevicesResponse> enumerateDevices(
    $0.EnumerateDevicesRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$enumerateDevices, request, options: options);
  }

  // method descriptors

  static final _$enumerateDevices = $grpc.ClientMethod<$0.EnumerateDevicesRequest, $0.EnumerateDevicesResponse>(
      '/nidevice_grpc.SessionUtilities/EnumerateDevices',
      ($0.EnumerateDevicesRequest value) => value.writeToBuffer(),
      $0.EnumerateDevicesResponse.fromBuffer);
}

@$pb.GrpcServiceName('nidevice_grpc.SessionUtilities')
abstract class SessionUtilitiesServiceBase extends $grpc.Service {
  $core.String get $name => 'nidevice_grpc.SessionUtilities';

  SessionUtilitiesServiceBase() {
    $addMethod($grpc.ServiceMethod<$0.EnumerateDevicesRequest, $0.EnumerateDevicesResponse>(
        'EnumerateDevices',
        enumerateDevices_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.EnumerateDevicesRequest.fromBuffer(value),
        ($0.EnumerateDevicesResponse value) => value.writeToBuffer()));
  }

  $async.Future<$0.EnumerateDevicesResponse> enumerateDevices_Pre(
      $grpc.ServiceCall $call, $async.Future<$0.EnumerateDevicesRequest> $request) async {
    return enumerateDevices($call, await $request);
  }

  $async.Future<$0.EnumerateDevicesResponse> enumerateDevices(
      $grpc.ServiceCall call, $0.EnumerateDevicesRequest request);
}
