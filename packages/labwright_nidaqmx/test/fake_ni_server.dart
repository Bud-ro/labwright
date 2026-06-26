// An in-process fake of the NI gRPC Device Server, just complete enough to exercise
// GrpcDaqmxBackend over a real loopback gRPC channel. It implements the same two
// services the backend talks to (NiDAQmx + SessionUtilities), models the task
// session lifecycle, captures calls for assertions, and can inject DAQmx error
// statuses. This validates the actual wire path and session model — not a mock of
// our own client.

import 'dart:io' show InternetAddress;

import 'package:grpc/grpc.dart';

import 'package:labwright_nidaqmx/src/generated/nidaqmx.pbgrpc.dart';
import 'package:labwright_nidaqmx/src/generated/session.pbgrpc.dart';

/// Fake `NiDAQmx` service with an in-memory task model + call capture.
class FakeDaqmxService extends NiDAQmxServiceBase {
  FakeDaqmxService({this.defaultReadValue = 1.2345});

  /// Value returned by ReadAnalogScalarF64 when a channel has no explicit value.
  double defaultReadValue;

  /// Per-physical-channel read values (keyed by the channel configured on the task).
  final Map<String, double> channelValues = {};

  /// Inject a negative DAQmx status on the next CreateAIVoltageChan (null = succeed).
  int? failAiChanStatus;

  // --- captured calls (for assertions) ---
  final List<String> createdAiChannels = [];
  final List<String> createdAoChannels = [];
  final List<({String channel, double value})> writes = [];
  final List<String> clearedTasks = [];
  int createTaskCount = 0;

  int _seq = 0;
  final Map<String, String> _taskChannel = {}; // task name -> last configured channel

  @override
  Future<CreateTaskResponse> createTask(ServiceCall call, CreateTaskRequest request) async {
    createTaskCount++;
    final name = 'task${++_seq}';
    return CreateTaskResponse(status: 0, task: Session(name: name), newSessionInitialized: true);
  }

  @override
  Future<CreateAIVoltageChanResponse> createAIVoltageChan(
      ServiceCall call, CreateAIVoltageChanRequest request) async {
    if (failAiChanStatus != null) {
      return CreateAIVoltageChanResponse(status: failAiChanStatus);
    }
    createdAiChannels.add(request.physicalChannel);
    _taskChannel[request.task.name] = request.physicalChannel;
    return CreateAIVoltageChanResponse(status: 0);
  }

  @override
  Future<CreateAOVoltageChanResponse> createAOVoltageChan(
      ServiceCall call, CreateAOVoltageChanRequest request) async {
    createdAoChannels.add(request.physicalChannel);
    _taskChannel[request.task.name] = request.physicalChannel;
    return CreateAOVoltageChanResponse(status: 0);
  }

  @override
  Future<ReadAnalogScalarF64Response> readAnalogScalarF64(
      ServiceCall call, ReadAnalogScalarF64Request request) async {
    final channel = _taskChannel[request.task.name];
    final value = channelValues[channel] ?? defaultReadValue;
    return ReadAnalogScalarF64Response(status: 0, value: value);
  }

  @override
  Future<WriteAnalogScalarF64Response> writeAnalogScalarF64(
      ServiceCall call, WriteAnalogScalarF64Request request) async {
    final channel = _taskChannel[request.task.name] ?? '';
    writes.add((channel: channel, value: request.value));
    return WriteAnalogScalarF64Response(status: 0);
  }

  @override
  Future<StartTaskResponse> startTask(ServiceCall call, StartTaskRequest request) async =>
      StartTaskResponse(status: 0);

  @override
  Future<StopTaskResponse> stopTask(ServiceCall call, StopTaskRequest request) async =>
      StopTaskResponse(status: 0);

  @override
  Future<ClearTaskResponse> clearTask(ServiceCall call, ClearTaskRequest request) async {
    clearedTasks.add(request.task.name);
    return ClearTaskResponse(status: 0);
  }

  @override
  Future<GetErrorStringResponse> getErrorString(
      ServiceCall call, GetErrorStringRequest request) async {
    if (request.errorCode == 0) return GetErrorStringResponse(status: 0, errorString: '');
    return GetErrorStringResponse(
        status: 0, errorString: 'Simulated DAQmx error (code ${request.errorCode}).');
  }
}

/// Fake `SessionUtilities` service returning a fixed device list.
class FakeUtilitiesService extends SessionUtilitiesServiceBase {
  FakeUtilitiesService({this.devices = const ['cDAQ1', 'cDAQ1Mod1']});

  /// Device names EnumerateDevices reports.
  List<String> devices;

  @override
  Future<EnumerateDevicesResponse> enumerateDevices(
      ServiceCall call, EnumerateDevicesRequest request) async {
    return EnumerateDevicesResponse(
      devices: devices.map((n) => DeviceProperties(name: n)).toList(),
    );
  }
}

/// A running fake server bound to an ephemeral loopback port.
class FakeNiServer {
  FakeNiServer._(this._server, this.daqmx, this.utilities);

  final Server _server;
  final FakeDaqmxService daqmx;
  final FakeUtilitiesService utilities;

  int get port => _server.port!;
  bool _stopped = false;

  static Future<FakeNiServer> start({
    FakeDaqmxService? daqmx,
    FakeUtilitiesService? utilities,
  }) async {
    final d = daqmx ?? FakeDaqmxService();
    final u = utilities ?? FakeUtilitiesService();
    final server = Server.create(services: [d, u]);
    await server.serve(address: InternetAddress.loopbackIPv4, port: 0);
    return FakeNiServer._(server, d, u);
  }

  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    await _server.shutdown();
  }
}
