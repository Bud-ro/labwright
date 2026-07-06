// This is a generated file - do not edit.
//
// Generated from data_moniker.proto.

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

import 'data_moniker.pb.dart' as $0;

export 'data_moniker.pb.dart';

@$pb.GrpcServiceName('ni.data_monikers.DataMoniker')
class DataMonikerClient extends $grpc.Client {
  /// The hostname for this service.
  static const $core.String defaultHost = '';

  /// OAuth scopes needed for the client.
  static const $core.List<$core.String> oauthScopes = [
    '',
  ];

  DataMonikerClient(super.channel, {super.options, super.interceptors});

  /// Server-streams the data behind the given read monikers (in-band over gRPC).
  $grpc.ResponseStream<$0.MonikerReadResponse> streamRead(
    $0.MonikerList request, {
    $grpc.CallOptions? options,
  }) {
    return $createStreamingCall(_$streamRead, $async.Stream.fromIterable([request]), options: options);
  }

  /// Negotiates a faster sideband transport (shared memory / sockets / RDMA) for the
  /// same monikers; returns where to connect.
  $grpc.ResponseFuture<$0.BeginMonikerSidebandStreamResponse> beginSidebandStream(
    $0.BeginMonikerSidebandStreamRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$beginSidebandStream, request, options: options);
  }

  // method descriptors

  static final _$streamRead = $grpc.ClientMethod<$0.MonikerList, $0.MonikerReadResponse>(
      '/ni.data_monikers.DataMoniker/StreamRead',
      ($0.MonikerList value) => value.writeToBuffer(),
      $0.MonikerReadResponse.fromBuffer);
  static final _$beginSidebandStream =
      $grpc.ClientMethod<$0.BeginMonikerSidebandStreamRequest, $0.BeginMonikerSidebandStreamResponse>(
          '/ni.data_monikers.DataMoniker/BeginSidebandStream',
          ($0.BeginMonikerSidebandStreamRequest value) => value.writeToBuffer(),
          $0.BeginMonikerSidebandStreamResponse.fromBuffer);
}

@$pb.GrpcServiceName('ni.data_monikers.DataMoniker')
abstract class DataMonikerServiceBase extends $grpc.Service {
  $core.String get $name => 'ni.data_monikers.DataMoniker';

  DataMonikerServiceBase() {
    $addMethod($grpc.ServiceMethod<$0.MonikerList, $0.MonikerReadResponse>(
        'StreamRead',
        streamRead_Pre,
        false,
        true,
        ($core.List<$core.int> value) => $0.MonikerList.fromBuffer(value),
        ($0.MonikerReadResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.BeginMonikerSidebandStreamRequest, $0.BeginMonikerSidebandStreamResponse>(
        'BeginSidebandStream',
        beginSidebandStream_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.BeginMonikerSidebandStreamRequest.fromBuffer(value),
        ($0.BeginMonikerSidebandStreamResponse value) => value.writeToBuffer()));
  }

  $async.Stream<$0.MonikerReadResponse> streamRead_Pre(
      $grpc.ServiceCall $call, $async.Future<$0.MonikerList> $request) async* {
    yield* streamRead($call, await $request);
  }

  $async.Stream<$0.MonikerReadResponse> streamRead($grpc.ServiceCall call, $0.MonikerList request);

  $async.Future<$0.BeginMonikerSidebandStreamResponse> beginSidebandStream_Pre(
      $grpc.ServiceCall $call, $async.Future<$0.BeginMonikerSidebandStreamRequest> $request) async {
    return beginSidebandStream($call, await $request);
  }

  $async.Future<$0.BeginMonikerSidebandStreamResponse> beginSidebandStream(
      $grpc.ServiceCall call, $0.BeginMonikerSidebandStreamRequest request);
}
