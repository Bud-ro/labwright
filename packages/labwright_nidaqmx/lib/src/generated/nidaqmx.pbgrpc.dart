// This is a generated file - do not edit.
//
// Generated from nidaqmx.proto.

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

import 'nidaqmx.pb.dart' as $0;

export 'nidaqmx.pb.dart';

@$pb.GrpcServiceName('nidaqmx_grpc.NiDAQmx')
class NiDAQmxClient extends $grpc.Client {
  /// The hostname for this service.
  static const $core.String defaultHost = '';

  /// OAuth scopes needed for the client.
  static const $core.List<$core.String> oauthScopes = [
    '',
  ];

  NiDAQmxClient(super.channel, {super.options, super.interceptors});

  $grpc.ResponseFuture<$0.CreateTaskResponse> createTask(
    $0.CreateTaskRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$createTask, request, options: options);
  }

  $grpc.ResponseFuture<$0.CreateAIVoltageChanResponse> createAIVoltageChan(
    $0.CreateAIVoltageChanRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$createAIVoltageChan, request, options: options);
  }

  $grpc.ResponseFuture<$0.CreateAOVoltageChanResponse> createAOVoltageChan(
    $0.CreateAOVoltageChanRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$createAOVoltageChan, request, options: options);
  }

  $grpc.ResponseFuture<$0.StartTaskResponse> startTask(
    $0.StartTaskRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$startTask, request, options: options);
  }

  $grpc.ResponseFuture<$0.StopTaskResponse> stopTask(
    $0.StopTaskRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$stopTask, request, options: options);
  }

  $grpc.ResponseFuture<$0.ClearTaskResponse> clearTask(
    $0.ClearTaskRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$clearTask, request, options: options);
  }

  $grpc.ResponseFuture<$0.ReadAnalogScalarF64Response> readAnalogScalarF64(
    $0.ReadAnalogScalarF64Request request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$readAnalogScalarF64, request, options: options);
  }

  $grpc.ResponseFuture<$0.WriteAnalogScalarF64Response> writeAnalogScalarF64(
    $0.WriteAnalogScalarF64Request request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$writeAnalogScalarF64, request, options: options);
  }

  $grpc.ResponseFuture<$0.GetErrorStringResponse> getErrorString(
    $0.GetErrorStringRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$getErrorString, request, options: options);
  }

  $grpc.ResponseFuture<$0.CfgSampClkTimingResponse> cfgSampClkTiming(
    $0.CfgSampClkTimingRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$cfgSampClkTiming, request, options: options);
  }

  /// Buffered streaming: a Begin*Read returns a Moniker, then DataMoniker.StreamRead
  /// pushes the samples. (Subset of NI's full set of Begin*Read variants.)
  $grpc.ResponseFuture<$0.BeginReadAnalogF64Response> beginReadAnalogF64(
    $0.BeginReadAnalogF64Request request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$beginReadAnalogF64, request, options: options);
  }

  $grpc.ResponseFuture<$0.BeginReadBinaryI16Response> beginReadBinaryI16(
    $0.BeginReadBinaryI16Request request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$beginReadBinaryI16, request, options: options);
  }

  $grpc.ResponseFuture<$0.BeginReadBinaryI32Response> beginReadBinaryI32(
    $0.BeginReadBinaryI32Request request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$beginReadBinaryI32, request, options: options);
  }

  // method descriptors

  static final _$createTask = $grpc.ClientMethod<$0.CreateTaskRequest, $0.CreateTaskResponse>(
      '/nidaqmx_grpc.NiDAQmx/CreateTask',
      ($0.CreateTaskRequest value) => value.writeToBuffer(),
      $0.CreateTaskResponse.fromBuffer);
  static final _$createAIVoltageChan =
      $grpc.ClientMethod<$0.CreateAIVoltageChanRequest, $0.CreateAIVoltageChanResponse>(
          '/nidaqmx_grpc.NiDAQmx/CreateAIVoltageChan',
          ($0.CreateAIVoltageChanRequest value) => value.writeToBuffer(),
          $0.CreateAIVoltageChanResponse.fromBuffer);
  static final _$createAOVoltageChan =
      $grpc.ClientMethod<$0.CreateAOVoltageChanRequest, $0.CreateAOVoltageChanResponse>(
          '/nidaqmx_grpc.NiDAQmx/CreateAOVoltageChan',
          ($0.CreateAOVoltageChanRequest value) => value.writeToBuffer(),
          $0.CreateAOVoltageChanResponse.fromBuffer);
  static final _$startTask = $grpc.ClientMethod<$0.StartTaskRequest, $0.StartTaskResponse>(
      '/nidaqmx_grpc.NiDAQmx/StartTask',
      ($0.StartTaskRequest value) => value.writeToBuffer(),
      $0.StartTaskResponse.fromBuffer);
  static final _$stopTask = $grpc.ClientMethod<$0.StopTaskRequest, $0.StopTaskResponse>(
      '/nidaqmx_grpc.NiDAQmx/StopTask',
      ($0.StopTaskRequest value) => value.writeToBuffer(),
      $0.StopTaskResponse.fromBuffer);
  static final _$clearTask = $grpc.ClientMethod<$0.ClearTaskRequest, $0.ClearTaskResponse>(
      '/nidaqmx_grpc.NiDAQmx/ClearTask',
      ($0.ClearTaskRequest value) => value.writeToBuffer(),
      $0.ClearTaskResponse.fromBuffer);
  static final _$readAnalogScalarF64 =
      $grpc.ClientMethod<$0.ReadAnalogScalarF64Request, $0.ReadAnalogScalarF64Response>(
          '/nidaqmx_grpc.NiDAQmx/ReadAnalogScalarF64',
          ($0.ReadAnalogScalarF64Request value) => value.writeToBuffer(),
          $0.ReadAnalogScalarF64Response.fromBuffer);
  static final _$writeAnalogScalarF64 =
      $grpc.ClientMethod<$0.WriteAnalogScalarF64Request, $0.WriteAnalogScalarF64Response>(
          '/nidaqmx_grpc.NiDAQmx/WriteAnalogScalarF64',
          ($0.WriteAnalogScalarF64Request value) => value.writeToBuffer(),
          $0.WriteAnalogScalarF64Response.fromBuffer);
  static final _$getErrorString = $grpc.ClientMethod<$0.GetErrorStringRequest, $0.GetErrorStringResponse>(
      '/nidaqmx_grpc.NiDAQmx/GetErrorString',
      ($0.GetErrorStringRequest value) => value.writeToBuffer(),
      $0.GetErrorStringResponse.fromBuffer);
  static final _$cfgSampClkTiming = $grpc.ClientMethod<$0.CfgSampClkTimingRequest, $0.CfgSampClkTimingResponse>(
      '/nidaqmx_grpc.NiDAQmx/CfgSampClkTiming',
      ($0.CfgSampClkTimingRequest value) => value.writeToBuffer(),
      $0.CfgSampClkTimingResponse.fromBuffer);
  static final _$beginReadAnalogF64 = $grpc.ClientMethod<$0.BeginReadAnalogF64Request, $0.BeginReadAnalogF64Response>(
      '/nidaqmx_grpc.NiDAQmx/BeginReadAnalogF64',
      ($0.BeginReadAnalogF64Request value) => value.writeToBuffer(),
      $0.BeginReadAnalogF64Response.fromBuffer);
  static final _$beginReadBinaryI16 = $grpc.ClientMethod<$0.BeginReadBinaryI16Request, $0.BeginReadBinaryI16Response>(
      '/nidaqmx_grpc.NiDAQmx/BeginReadBinaryI16',
      ($0.BeginReadBinaryI16Request value) => value.writeToBuffer(),
      $0.BeginReadBinaryI16Response.fromBuffer);
  static final _$beginReadBinaryI32 = $grpc.ClientMethod<$0.BeginReadBinaryI32Request, $0.BeginReadBinaryI32Response>(
      '/nidaqmx_grpc.NiDAQmx/BeginReadBinaryI32',
      ($0.BeginReadBinaryI32Request value) => value.writeToBuffer(),
      $0.BeginReadBinaryI32Response.fromBuffer);
}

@$pb.GrpcServiceName('nidaqmx_grpc.NiDAQmx')
abstract class NiDAQmxServiceBase extends $grpc.Service {
  $core.String get $name => 'nidaqmx_grpc.NiDAQmx';

  NiDAQmxServiceBase() {
    $addMethod($grpc.ServiceMethod<$0.CreateTaskRequest, $0.CreateTaskResponse>(
        'CreateTask',
        createTask_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.CreateTaskRequest.fromBuffer(value),
        ($0.CreateTaskResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.CreateAIVoltageChanRequest, $0.CreateAIVoltageChanResponse>(
        'CreateAIVoltageChan',
        createAIVoltageChan_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.CreateAIVoltageChanRequest.fromBuffer(value),
        ($0.CreateAIVoltageChanResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.CreateAOVoltageChanRequest, $0.CreateAOVoltageChanResponse>(
        'CreateAOVoltageChan',
        createAOVoltageChan_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.CreateAOVoltageChanRequest.fromBuffer(value),
        ($0.CreateAOVoltageChanResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.StartTaskRequest, $0.StartTaskResponse>(
        'StartTask',
        startTask_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.StartTaskRequest.fromBuffer(value),
        ($0.StartTaskResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.StopTaskRequest, $0.StopTaskResponse>(
        'StopTask',
        stopTask_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.StopTaskRequest.fromBuffer(value),
        ($0.StopTaskResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.ClearTaskRequest, $0.ClearTaskResponse>(
        'ClearTask',
        clearTask_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.ClearTaskRequest.fromBuffer(value),
        ($0.ClearTaskResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.ReadAnalogScalarF64Request, $0.ReadAnalogScalarF64Response>(
        'ReadAnalogScalarF64',
        readAnalogScalarF64_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.ReadAnalogScalarF64Request.fromBuffer(value),
        ($0.ReadAnalogScalarF64Response value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.WriteAnalogScalarF64Request, $0.WriteAnalogScalarF64Response>(
        'WriteAnalogScalarF64',
        writeAnalogScalarF64_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.WriteAnalogScalarF64Request.fromBuffer(value),
        ($0.WriteAnalogScalarF64Response value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.GetErrorStringRequest, $0.GetErrorStringResponse>(
        'GetErrorString',
        getErrorString_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.GetErrorStringRequest.fromBuffer(value),
        ($0.GetErrorStringResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.CfgSampClkTimingRequest, $0.CfgSampClkTimingResponse>(
        'CfgSampClkTiming',
        cfgSampClkTiming_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.CfgSampClkTimingRequest.fromBuffer(value),
        ($0.CfgSampClkTimingResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.BeginReadAnalogF64Request, $0.BeginReadAnalogF64Response>(
        'BeginReadAnalogF64',
        beginReadAnalogF64_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.BeginReadAnalogF64Request.fromBuffer(value),
        ($0.BeginReadAnalogF64Response value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.BeginReadBinaryI16Request, $0.BeginReadBinaryI16Response>(
        'BeginReadBinaryI16',
        beginReadBinaryI16_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.BeginReadBinaryI16Request.fromBuffer(value),
        ($0.BeginReadBinaryI16Response value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.BeginReadBinaryI32Request, $0.BeginReadBinaryI32Response>(
        'BeginReadBinaryI32',
        beginReadBinaryI32_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.BeginReadBinaryI32Request.fromBuffer(value),
        ($0.BeginReadBinaryI32Response value) => value.writeToBuffer()));
  }

  $async.Future<$0.CreateTaskResponse> createTask_Pre(
      $grpc.ServiceCall $call, $async.Future<$0.CreateTaskRequest> $request) async {
    return createTask($call, await $request);
  }

  $async.Future<$0.CreateTaskResponse> createTask($grpc.ServiceCall call, $0.CreateTaskRequest request);

  $async.Future<$0.CreateAIVoltageChanResponse> createAIVoltageChan_Pre(
      $grpc.ServiceCall $call, $async.Future<$0.CreateAIVoltageChanRequest> $request) async {
    return createAIVoltageChan($call, await $request);
  }

  $async.Future<$0.CreateAIVoltageChanResponse> createAIVoltageChan(
      $grpc.ServiceCall call, $0.CreateAIVoltageChanRequest request);

  $async.Future<$0.CreateAOVoltageChanResponse> createAOVoltageChan_Pre(
      $grpc.ServiceCall $call, $async.Future<$0.CreateAOVoltageChanRequest> $request) async {
    return createAOVoltageChan($call, await $request);
  }

  $async.Future<$0.CreateAOVoltageChanResponse> createAOVoltageChan(
      $grpc.ServiceCall call, $0.CreateAOVoltageChanRequest request);

  $async.Future<$0.StartTaskResponse> startTask_Pre(
      $grpc.ServiceCall $call, $async.Future<$0.StartTaskRequest> $request) async {
    return startTask($call, await $request);
  }

  $async.Future<$0.StartTaskResponse> startTask($grpc.ServiceCall call, $0.StartTaskRequest request);

  $async.Future<$0.StopTaskResponse> stopTask_Pre(
      $grpc.ServiceCall $call, $async.Future<$0.StopTaskRequest> $request) async {
    return stopTask($call, await $request);
  }

  $async.Future<$0.StopTaskResponse> stopTask($grpc.ServiceCall call, $0.StopTaskRequest request);

  $async.Future<$0.ClearTaskResponse> clearTask_Pre(
      $grpc.ServiceCall $call, $async.Future<$0.ClearTaskRequest> $request) async {
    return clearTask($call, await $request);
  }

  $async.Future<$0.ClearTaskResponse> clearTask($grpc.ServiceCall call, $0.ClearTaskRequest request);

  $async.Future<$0.ReadAnalogScalarF64Response> readAnalogScalarF64_Pre(
      $grpc.ServiceCall $call, $async.Future<$0.ReadAnalogScalarF64Request> $request) async {
    return readAnalogScalarF64($call, await $request);
  }

  $async.Future<$0.ReadAnalogScalarF64Response> readAnalogScalarF64(
      $grpc.ServiceCall call, $0.ReadAnalogScalarF64Request request);

  $async.Future<$0.WriteAnalogScalarF64Response> writeAnalogScalarF64_Pre(
      $grpc.ServiceCall $call, $async.Future<$0.WriteAnalogScalarF64Request> $request) async {
    return writeAnalogScalarF64($call, await $request);
  }

  $async.Future<$0.WriteAnalogScalarF64Response> writeAnalogScalarF64(
      $grpc.ServiceCall call, $0.WriteAnalogScalarF64Request request);

  $async.Future<$0.GetErrorStringResponse> getErrorString_Pre(
      $grpc.ServiceCall $call, $async.Future<$0.GetErrorStringRequest> $request) async {
    return getErrorString($call, await $request);
  }

  $async.Future<$0.GetErrorStringResponse> getErrorString($grpc.ServiceCall call, $0.GetErrorStringRequest request);

  $async.Future<$0.CfgSampClkTimingResponse> cfgSampClkTiming_Pre(
      $grpc.ServiceCall $call, $async.Future<$0.CfgSampClkTimingRequest> $request) async {
    return cfgSampClkTiming($call, await $request);
  }

  $async.Future<$0.CfgSampClkTimingResponse> cfgSampClkTiming(
      $grpc.ServiceCall call, $0.CfgSampClkTimingRequest request);

  $async.Future<$0.BeginReadAnalogF64Response> beginReadAnalogF64_Pre(
      $grpc.ServiceCall $call, $async.Future<$0.BeginReadAnalogF64Request> $request) async {
    return beginReadAnalogF64($call, await $request);
  }

  $async.Future<$0.BeginReadAnalogF64Response> beginReadAnalogF64(
      $grpc.ServiceCall call, $0.BeginReadAnalogF64Request request);

  $async.Future<$0.BeginReadBinaryI16Response> beginReadBinaryI16_Pre(
      $grpc.ServiceCall $call, $async.Future<$0.BeginReadBinaryI16Request> $request) async {
    return beginReadBinaryI16($call, await $request);
  }

  $async.Future<$0.BeginReadBinaryI16Response> beginReadBinaryI16(
      $grpc.ServiceCall call, $0.BeginReadBinaryI16Request request);

  $async.Future<$0.BeginReadBinaryI32Response> beginReadBinaryI32_Pre(
      $grpc.ServiceCall $call, $async.Future<$0.BeginReadBinaryI32Request> $request) async {
    return beginReadBinaryI32($call, await $request);
  }

  $async.Future<$0.BeginReadBinaryI32Response> beginReadBinaryI32(
      $grpc.ServiceCall call, $0.BeginReadBinaryI32Request request);
}
