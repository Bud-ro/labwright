// The one entry point callers use to obtain a [DaqmxApi]. It picks the transport;
// everything above it is transport-agnostic.
//
//   - `Daqmx.local()`   in-process FFI into NI-DAQmx. Windows/Linux only — on macOS
//                       it throws [UnsupportedError] (NI ships no macOS runtime),
//                       directing you to `Daqmx.remote(...)`.
//   - `Daqmx.remote()`  gRPC client to an NI gRPC Device Server. Works on every
//                       platform; on macOS it's the only option.
//
// Windows/Linux *can* also host the gRPC server and use `remote()`, but there's no
// need to — `local()` calls the driver directly under the hood.

import 'dart:io' show Platform;

import 'package:grpc/grpc.dart' show ChannelCredentials;

import 'daqmx_api.dart';
import 'ffi_backend.dart';
import 'grpc_backend.dart';
import 'streaming.dart' show SidebandStrategy;

/// Factory for [DaqmxApi] transports. Not instantiable — use the static methods.
abstract final class Daqmx {
  /// Local, in-process NI-DAQmx via FFI (Windows/Linux). The runtime is loaded
  /// lazily on first call, so this returns immediately even if NI-DAQmx is absent
  /// (the [DaqmxUnavailable] surfaces on first use instead).
  ///
  /// On macOS this throws [UnsupportedError]: there is no local NI-DAQmx runtime for
  /// macOS, so a local connection can never be supported — use [remote] against a
  /// host running the NI gRPC Device Server.
  static DaqmxApi local({String? libraryPath}) {
    if (Platform.isMacOS) {
      throw UnsupportedError(
        'Local NI-DAQmx is not supported on macOS — NI ships no macOS runtime. '
        'Run an NI gRPC Device Server on a Windows/Linux host and connect with '
        'Daqmx.remote(host: ...).',
      );
    }
    return FfiDaqmxBackend(libraryPath: libraryPath);
  }

  /// Remote NI-DAQmx over gRPC, talking to an NI gRPC Device Server on [host]
  /// (default port [GrpcDaqmxBackend.defaultPort]). Available on all platforms and
  /// required on macOS.
  ///
  /// [secure] selects TLS with system root CAs; for self-signed / private-CA / mTLS
  /// servers (typical on a lab LAN) pass [credentials] instead. [callTimeout] bounds
  /// every RPC so a hung server can't hang the caller.
  static DaqmxApi remote({
    required String host,
    int port = GrpcDaqmxBackend.defaultPort,
    bool secure = false,
    ChannelCredentials? credentials,
    Duration callTimeout = const Duration(seconds: 30),
    SidebandStrategy sideband = SidebandStrategy.inBandGrpc,
  }) =>
      GrpcDaqmxBackend(
        host: host,
        port: port,
        secure: secure,
        credentials: credentials,
        callTimeout: callTimeout,
        sideband: sideband,
      );
}
