// The single, backend-agnostic DAQmx API. Callers program against [DaqmxApi] and
// never against a concrete backend, so the same code runs whether DAQmx is reached
// locally (in-process FFI on Windows/Linux) or remotely (NI gRPC Device Server,
// the only option on macOS). Construct one via the `Daqmx` factory (daqmx.dart).
//
// The API is async on purpose: the gRPC backend is inherently asynchronous, and the
// FFI backend's synchronous calls wrap trivially in a `Future`. One async surface is
// what lets the two implementations stay truly interchangeable.

import 'dart:typed_data';

import 'daqmx_constants.dart';
import 'streaming.dart';

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

/// Statuses labwright itself reports on [DaqmxException.status] for failures that never
/// reached NI's driver, so no DAQmx status exists to carry. NI's error codes are small
/// negatives (its documented range stops well short of -1,000,000) and its warnings are
/// positive, so these values cannot be mistaken for one.
enum DaqmxLocalStatus {
  /// The NI-DAQmx runtime could not be loaded; surfaces as [DaqmxUnavailable].
  libraryLoadFailed(-1000001),

  /// The FFI streaming worker raised a Dart error rather than a DAQmx status.
  streamWorkerFailed(-1000002)
  ;

  const DaqmxLocalStatus(this.status);

  /// The value carried on [DaqmxException.status].
  final int status;
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

  /// Best-effort access to NI's most recent extended error text. Transport-specific:
  /// the FFI backend returns `DAQmxGetExtendedErrorInfo` (the genuine last-error text);
  /// the gRPC backend has no server-side last-error channel and returns `''` when
  /// healthy. Either way, the authoritative error text for a failed call is carried on
  /// the [DaqmxException] that call throws — prefer that over polling [errorInfo].
  Future<String> errorInfo();

  /// Buffered, hardware-clocked acquisition from [physicalChannel] at [rateHz]. Yields
  /// chunks of up to [samplesPerChunk] samples in [format]'s native typed list
  /// (`Float64List` for [DaqSampleFormat.volts], `Int16List` for
  /// [DaqSampleFormat.rawI16], …). Continuous until the subscription is cancelled,
  /// unless [totalSamples] is set (finite acquisition that then completes).
  ///
  /// The hardware sample clock paces delivery; cancelling the subscription stops and
  /// clears the task. The FFI backend runs the blocking read loop on a dedicated
  /// isolate so it never stalls the caller's event loop; see [DaqmxStreams] for typed
  /// convenience wrappers (`readVoltageStream`, `readRawI16Stream`, …).
  ///
  /// Under the FFI backend the driver read blocks, so pause and cancel are honoured
  /// between reads, not during one: a paused subscription can still receive the chunk
  /// already being read, and `cancel()`'s future can take up to one read to resolve
  /// while the task is stopped and cleared properly. [readTimeout] is the DAQmx timeout
  /// every buffered read is issued with, in seconds (`-1` = wait indefinitely), so it is
  /// what bounds that worst case: a lower value shortens cancel latency, and makes a read
  /// the device cannot satisfy within it come back as a DAQmx timeout error.
  ///
  /// [readTimeout] reaches the FFI backend only. The gRPC backend issues its server-side
  /// `Begin*Read` with an indefinite DAQmx timeout and cancels by closing the frame
  /// stream, without waiting on a read, so the value is ignored there.
  Stream<TypedData> readStream(
    String physicalChannel, {
    required double rateHz,
    int samplesPerChunk = 1000,
    int? totalSamples,
    DaqSampleFormat format = DaqSampleFormat.volts,
    double min = -10,
    double max = 10,
    int terminalConfig = DaqmxVal.cfgDefault,
    double readTimeout = 10,
  });

  /// Release the transport (free FFI handles / shut the gRPC channel). Idempotent.
  Future<void> close();
}
