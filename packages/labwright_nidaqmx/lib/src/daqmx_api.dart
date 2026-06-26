// The single, backend-agnostic DAQmx API. Callers program against [DaqmxApi] and
// never against a concrete backend, so the same code runs whether DAQmx is reached
// locally (in-process FFI on Windows/Linux) or remotely (NI gRPC Device Server,
// the only option on macOS). Construct one via the `Daqmx` factory (daqmx.dart).
//
// The API is async on purpose: the gRPC backend is inherently asynchronous, and the
// FFI backend's synchronous calls wrap trivially in a `Future`. One async surface is
// what lets the two implementations stay truly interchangeable.

import 'daqmx_constants.dart';

/// A DAQmx operation returned an error status. Carries NI's own extended error text
/// (the offending channel/value, etc.). Thrown by either backend so callers handle
/// failures identically regardless of transport. Status convention matches NI:
/// `0` = ok, `< 0` = error, `> 0` = warning.
class DaqmxException implements Exception {
  DaqmxException(this.status, this.message, {this.operation});
  final int status;
  final String message;
  final String? operation;
  @override
  String toString() => 'DaqmxException(${operation ?? 'DAQmx'} status $status): $message';
}

/// The DAQmx transport could not be reached: the NI-DAQmx runtime is absent (FFI
/// backend) or the gRPC Device Server is unreachable (gRPC backend). Distinct from
/// [DaqmxException], which signals a call that reached DAQmx and came back failed.
class DaqmxUnavailable implements Exception {
  DaqmxUnavailable(this.message);
  final String message;
  @override
  String toString() => 'DaqmxUnavailable: $message';
}

/// The portable DAQmx surface. Both the FFI and gRPC backends implement this exact
/// interface; nothing above it knows which transport it holds.
abstract interface class DaqmxApi {
  /// Names of the devices DAQmx currently sees (e.g. `cDAQ1`, `cDAQ1Mod1`); empty
  /// when none are present.
  Future<List<String>> deviceNames();

  /// One immediate analog-input voltage reading from [physicalChannel]
  /// (e.g. `cDAQ1Mod1/ai0`), via a one-shot task. [timeout] is in seconds
  /// (`-1` = wait indefinitely), matching DAQmx semantics.
  Future<double> readVoltage(
    String physicalChannel, {
    double min = -10,
    double max = 10,
    int terminalConfig = DaqmxVal.cfgDefault,
    double timeout = 10,
  });

  /// Drive [physicalChannel] (e.g. `cDAQ1Mod2/ao0`) to [volts] via a one-shot,
  /// auto-started task.
  Future<void> writeVoltage(
    String physicalChannel,
    double volts, {
    double min = -10,
    double max = 10,
    double timeout = 10,
  });

  /// NI's most recent extended error text for this transport.
  Future<String> errorInfo();

  /// Release the transport (free FFI handles / shut the gRPC channel). Idempotent.
  Future<void> close();
}
