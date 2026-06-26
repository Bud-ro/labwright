// The remote [DaqmxApi] backend: a pure-Dart gRPC client for the **NI gRPC Device
// Server** (https://github.com/ni/grpc-device, MIT-licensed). The server runs on a
// Windows/Linux host that has NI-DAQmx + the hardware; any platform — crucially
// macOS, which has no local NI-DAQmx — drives that hardware over gRPC.
//
// Same [DaqmxApi] as the FFI backend: callers can't tell local from remote. The wire
// implementation is generated from NI's `nidaqmx.proto` / `session.proto`; that
// codegen + a live server to validate against is the remaining work (see the README
// "gRPC backend" section). Until those stubs are wired, the data-path methods throw
// [UnimplementedError] rather than pretend to talk to a server.

import 'daqmx_api.dart';
import 'daqmx_constants.dart';

/// [DaqmxApi] over the NI gRPC Device Server. Construct via `Daqmx.remote(...)`.
class GrpcDaqmxBackend implements DaqmxApi {
  GrpcDaqmxBackend({
    required this.host,
    this.port = defaultPort,
    this.secure = false,
  });

  /// NI gRPC Device Server's default listen port.
  static const int defaultPort = 31763;

  /// Host running the NI gRPC Device Server (the box with NI-DAQmx + hardware).
  final String host;

  /// Server port (defaults to [defaultPort]).
  final int port;

  /// Whether to use TLS. The server supports an insecure mode for trusted LANs and
  /// a certificate-secured mode; pick per deployment.
  final bool secure;

  Never _pending(String op) => throw UnimplementedError(
        'GrpcDaqmxBackend.$op is not wired yet. The remote backend needs the Dart '
        'gRPC stubs generated from NI\'s nidaqmx.proto/session.proto (see the README '
        '"gRPC backend" section) and validation against a running NI gRPC Device '
        'Server at $host:$port.',
      );

  @override
  Future<List<String>> deviceNames() async => _pending('deviceNames');

  @override
  Future<double> readVoltage(
    String physicalChannel, {
    double min = -10,
    double max = 10,
    int terminalConfig = DaqmxVal.cfgDefault,
    double timeout = 10,
  }) async =>
      _pending('readVoltage');

  @override
  Future<void> writeVoltage(
    String physicalChannel,
    double volts, {
    double min = -10,
    double max = 10,
    double timeout = 10,
  }) async =>
      _pending('writeVoltage');

  @override
  Future<String> errorInfo() async => _pending('errorInfo');

  @override
  Future<void> close() async {
    // No channel is opened yet; nothing to tear down. Once the gRPC ClientChannel is
    // introduced this shuts it down.
  }
}
