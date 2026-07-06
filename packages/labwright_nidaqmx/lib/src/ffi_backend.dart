// The local, in-process [DaqmxApi] backend: pure `dart:ffi` calls straight into
// NI's own NI-DAQmx runtime (`nicaiu.dll` on Windows, `libnidaqmx.so` on Linux).
// No method channels, no helper process — the Dart VM calls the C ABI directly.
//
// The runtime is loaded lazily on first use so that merely constructing the backend
// (e.g. via `Daqmx.local()`) never throws; the [DaqmxUnavailable] surfaces only when
// a call actually needs the driver. macOS never reaches here — `Daqmx.local()` gates
// it out — but if forced, [loadNidaqmx] still throws [DaqmxUnavailable] with the
// gRPC pointer.
//
// NOTE: NI-DAQmx is a synchronous C API. These methods are `async` to satisfy the
// shared [DaqmxApi] contract, but each call runs to completion on the calling isolate
// and BLOCKS it for up to the DAQmx `timeout` (so avoid `timeout: -1` / infinite on
// the UI/event isolate; offload to an isolate if you need true concurrency). The gRPC
// backend, being genuinely async, does not block.

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'daqmx_api.dart';
import 'daqmx_constants.dart';
import 'ffi.dart';
import 'ffi_stream.dart';
import 'logging.dart';
import 'streaming.dart';

/// [DaqmxApi] implemented over the local NI-DAQmx C library via FFI.
class FfiDaqmxBackend implements DaqmxApi {
  FfiDaqmxBackend({this.libraryPath});

  /// Optional explicit path to the NI-DAQmx shared library; when null the platform
  /// default name is resolved (`nicaiu.dll` / `libnidaqmx.so`).
  final String? libraryPath;

  NidaqmxBindings? _cached;
  bool _closed = false;

  /// Resolve (and cache) the DAQmx entry points, loading the library on first touch.
  /// Throws [DaqmxUnavailable] if the runtime is absent, the platform unsupported, or
  /// a required symbol is missing (version mismatch) — never a raw FFI error.
  NidaqmxBindings get _bindings {
    final cached = _cached;
    if (cached != null) return cached;
    DaqLoggers.ffi.fine('loading NI-DAQmx runtime (${libraryPath ?? 'platform default'})');
    try {
      return _cached = NidaqmxBindings(loadNidaqmx(path: libraryPath));
    } on DaqmxUnavailable {
      rethrow;
    } catch (e) {
      // loadNidaqmx succeeded but a lookupFunction failed (missing/renamed symbol).
      throw DaqmxUnavailable('NI-DAQmx loaded but a required symbol is unavailable: $e');
    }
  }

  void _ensureOpen() {
    if (_closed) throw StateError('FfiDaqmxBackend used after close().');
  }

  /// Throws [DaqmxException] (enriched with [errorInfo]) when [status] < 0; logs and
  /// passes through positive warnings.
  int _check(int status, String op) {
    if (status > 0) {
      DaqLoggers.ffi.warning('$op -> warning status $status');
      return status;
    }
    if (status == 0) return 0;
    final info = _errorInfoSync();
    DaqLoggers.ffi.warning('$op -> status $status: $info');
    throw DaqmxException(status, info, operation: op);
  }

  String _errorInfoSync() => using((arena) {
    const cap = 2048;
    final buf = arena<Uint8>(cap);
    buf[0] = 0; // defensive: never read an uninitialized buffer if the call no-ops
    final str = buf.cast<Utf8>();
    _bindings.getExtendedErrorInfo(str, cap);
    return str.toDartString();
  });

  @override
  Future<String> errorInfo() async {
    _ensureOpen();
    return _errorInfoSync();
  }

  @override
  Future<List<String>> deviceNames() async {
    _ensureOpen();
    return using((arena) {
      // A size-0 probe returns the required buffer length (NI Get*String convention),
      // so a system with many devices isn't truncated; fall back to 4096 if unknown.
      final needed = _bindings.getSysDevNames(nullptr, 0);
      final cap = needed > 0 ? needed : 4096;
      final buf = arena<Uint8>(cap);
      buf[0] = 0;
      final str = buf.cast<Utf8>();
      _check(_bindings.getSysDevNames(str, cap), 'DAQmxGetSysDevNames');
      final s = str.toDartString().trim();
      final names = s.isEmpty ? const <String>[] : s.split(',').map((e) => e.trim()).toList();
      DaqLoggers.ffi.fine('deviceNames -> $names');
      return names;
    });
  }

  @override
  Future<double> readVoltage(
    String physicalChannel, {
    double min = -10,
    double max = 10,
    int terminalConfig = DaqmxVal.cfgDefault,
    double timeout = 10,
  }) async {
    _ensureOpen();
    return using((arena) {
      final task = arena<TaskHandle>();
      // Empty task name -> DAQmx assigns a unique one (no cross-call name collisions).
      _check(_bindings.createTask(''.toNativeUtf8(allocator: arena), task), 'DAQmxCreateTask');
      DaqLoggers.task.fine('CreateTask (ai)');
      try {
        _check(
          _bindings.createAIVoltageChan(
            task.value,
            physicalChannel.toNativeUtf8(allocator: arena),
            nullptr,
            terminalConfig,
            min,
            max,
            DaqmxVal.volts,
            nullptr,
          ),
          'DAQmxCreateAIVoltageChan',
        );
        final value = arena<Double>();
        _check(_bindings.readAnalogScalarF64(task.value, timeout, value, nullptr), 'DAQmxReadAnalogScalarF64');
        DaqLoggers.io.fine('readVoltage($physicalChannel) -> ${value.value}');
        return value.value;
      } finally {
        _bindings.clearTask(task.value);
        DaqLoggers.task.fine('ClearTask (ai)');
      }
    });
  }

  @override
  Future<void> writeVoltage(
    String physicalChannel,
    double volts, {
    double min = -10,
    double max = 10,
    double timeout = 10,
  }) async {
    _ensureOpen();
    return using((arena) {
      final task = arena<TaskHandle>();
      _check(_bindings.createTask(''.toNativeUtf8(allocator: arena), task), 'DAQmxCreateTask');
      DaqLoggers.task.fine('CreateTask (ao)');
      try {
        _check(
          _bindings.createAOVoltageChan(
            task.value,
            physicalChannel.toNativeUtf8(allocator: arena),
            nullptr,
            min,
            max,
            DaqmxVal.volts,
            nullptr,
          ),
          'DAQmxCreateAOVoltageChan',
        );
        _check(
          _bindings.writeAnalogScalarF64(task.value, DaqmxVal.boolTrue, timeout, volts, nullptr),
          'DAQmxWriteAnalogScalarF64',
        );
        DaqLoggers.io.fine('writeVoltage($physicalChannel, $volts)');
      } finally {
        _bindings.clearTask(task.value);
        DaqLoggers.task.fine('ClearTask (ao)');
      }
    });
  }

  @override
  Stream<TypedData> readStream(
    String physicalChannel, {
    required double rateHz,
    int samplesPerChunk = 1000,
    int? totalSamples,
    DaqSampleFormat format = DaqSampleFormat.volts,
    double min = -10,
    double max = 10,
    int terminalConfig = DaqmxVal.cfgDefault,
  }) {
    _ensureOpen();
    DaqLoggers.io.fine(
      'readStream($physicalChannel, ${rateHz}Hz, $format, '
      '${totalSamples == null ? 'continuous' : '$totalSamples samps'})',
    );
    return ffiReadStream(
      libraryPath: libraryPath,
      channel: physicalChannel,
      rateHz: rateHz,
      samplesPerChunk: samplesPerChunk,
      totalSamples: totalSamples,
      format: format,
      min: min,
      max: max,
      terminalConfig: terminalConfig,
    );
  }

  /// The resolved entry points — an escape hatch for operations the portable API
  /// has not wrapped yet (FFI backend only; loads the runtime on access).
  NidaqmxBindings get bindings => _bindings;

  @override
  Future<void> close() async {
    // dart:ffi has no DynamicLibrary close; dropping the bindings releases our
    // reference. The backend is single-use after close() (calls throw StateError).
    _closed = true;
    _cached = null;
    DaqLoggers.ffi.fine('closed FFI backend');
  }
}
