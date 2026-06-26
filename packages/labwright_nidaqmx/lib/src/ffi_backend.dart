// The local, in-process [DaqmxApi] backend: pure `dart:ffi` calls straight into
// NI's own NI-DAQmx runtime (`nicaiu.dll` on Windows, `libnidaqmx.so` on Linux).
// No method channels, no helper process — the Dart VM calls the C ABI directly.
//
// The runtime is loaded lazily on first use so that merely constructing the backend
// (e.g. via `Daqmx.local()`) never throws; the [DaqmxUnavailable] surfaces only when
// a call actually needs the driver. macOS never reaches here — `Daqmx.local()` gates
// it out — but if forced, [loadNidaqmx] still throws [DaqmxUnavailable] with the
// gRPC pointer.

import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'daqmx_api.dart';
import 'daqmx_constants.dart';
import 'ffi.dart';

/// [DaqmxApi] implemented over the local NI-DAQmx C library via FFI.
class FfiDaqmxBackend implements DaqmxApi {
  FfiDaqmxBackend({this.libraryPath});

  /// Optional explicit path to the NI-DAQmx shared library; when null the platform
  /// default name is resolved (`nicaiu.dll` / `libnidaqmx.so`).
  final String? libraryPath;

  NidaqmxBindings? _cached;

  /// Resolve (and cache) the DAQmx entry points, loading the library on first touch.
  /// Throws [DaqmxUnavailable] if the runtime is absent or the platform unsupported.
  NidaqmxBindings get _bindings => _cached ??= NidaqmxBindings(loadNidaqmx(path: libraryPath));

  /// Throws [DaqmxException] (enriched with [errorInfo]) when [status] < 0; positive
  /// warnings are returned for the caller to handle.
  int _check(int status, String op) {
    if (status < 0) throw DaqmxException(status, _errorInfoSync(), operation: op);
    return status;
  }

  String _errorInfoSync() => using((arena) {
        const cap = 2048;
        final buf = arena<Uint8>(cap).cast<Utf8>();
        _bindings.getExtendedErrorInfo(buf, cap);
        return buf.toDartString();
      });

  @override
  Future<String> errorInfo() async => _errorInfoSync();

  @override
  Future<List<String>> deviceNames() async => using((arena) {
        const cap = 4096;
        final buf = arena<Uint8>(cap).cast<Utf8>();
        _check(_bindings.getSysDevNames(buf, cap), 'DAQmxGetSysDevNames');
        final s = buf.toDartString().trim();
        return s.isEmpty ? const <String>[] : s.split(',').map((e) => e.trim()).toList();
      });

  @override
  Future<double> readVoltage(
    String physicalChannel, {
    double min = -10,
    double max = 10,
    int terminalConfig = DaqmxVal.cfgDefault,
    double timeout = 10,
  }) async =>
      using((arena) {
        final task = arena<TaskHandle>();
        _check(_bindings.createTask('lw-ai'.toNativeUtf8(allocator: arena), task), 'DAQmxCreateTask');
        try {
          _check(
            _bindings.createAIVoltageChan(task.value, physicalChannel.toNativeUtf8(allocator: arena),
                nullptr, terminalConfig, min, max, DaqmxVal.volts, nullptr),
            'DAQmxCreateAIVoltageChan',
          );
          final value = arena<Double>();
          _check(_bindings.readAnalogScalarF64(task.value, timeout, value, nullptr),
              'DAQmxReadAnalogScalarF64');
          return value.value;
        } finally {
          _bindings.clearTask(task.value);
        }
      });

  @override
  Future<void> writeVoltage(
    String physicalChannel,
    double volts, {
    double min = -10,
    double max = 10,
    double timeout = 10,
  }) async =>
      using((arena) {
        final task = arena<TaskHandle>();
        _check(_bindings.createTask('lw-ao'.toNativeUtf8(allocator: arena), task), 'DAQmxCreateTask');
        try {
          _check(
            _bindings.createAOVoltageChan(task.value, physicalChannel.toNativeUtf8(allocator: arena),
                nullptr, min, max, DaqmxVal.volts, nullptr),
            'DAQmxCreateAOVoltageChan',
          );
          _check(_bindings.writeAnalogScalarF64(task.value, DaqmxVal.boolTrue, timeout, volts, nullptr),
              'DAQmxWriteAnalogScalarF64');
        } finally {
          _bindings.clearTask(task.value);
        }
      });

  /// The resolved entry points — an escape hatch for operations the portable API
  /// has not wrapped yet (FFI backend only; loads the runtime on access).
  NidaqmxBindings get bindings => _bindings;

  @override
  Future<void> close() async {
    // dart:ffi has no DynamicLibrary close; dropping the bindings lets the next call
    // re-resolve. Outstanding tasks are one-shot and cleared inline above.
    _cached = null;
  }
}
