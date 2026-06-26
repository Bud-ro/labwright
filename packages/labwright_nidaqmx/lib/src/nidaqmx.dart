// Thin typed facade over the NI-DAQmx C API. Mirrors the ergonomics of the
// clean-room `qdaq` Dart facade so callers/tests look the same against either
// backend. Status convention (identical to qdaq, by design): 0 = ok, <0 = error,
// >0 = warning.

import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'daqmx_constants.dart';
import 'ffi.dart';

export 'daqmx_constants.dart';
export 'ffi.dart' show NidaqmxUnavailable, TaskHandle;

/// A DAQmx call returned an error status. Carries NI's own extended error text.
class NidaqmxException implements Exception {
  NidaqmxException(this.status, this.message, {this.operation});
  final int status;
  final String message;
  final String? operation;
  @override
  String toString() =>
      'NidaqmxException(${operation ?? 'DAQmx'} status $status): $message';
}

/// An open handle to the host's NI-DAQmx runtime (Windows/Linux only).
class Nidaqmx {
  Nidaqmx._(this.bindings);

  /// The resolved entry points (escape hatch for operations the facade has not
  /// wrapped yet).
  final NidaqmxBindings bindings;

  /// Load the NI-DAQmx runtime. Throws [NidaqmxUnavailable] if it is absent or
  /// the platform is macOS (unsupported by NI — use the qdaq backend there).
  factory Nidaqmx.open({String? path}) => Nidaqmx._(NidaqmxBindings(loadNidaqmx(path: path)));

  /// NI's most recent extended error text (the offending channel/value, etc.).
  String errorInfo() => using((arena) {
        const cap = 2048;
        final buf = arena<Uint8>(cap).cast<Utf8>();
        bindings.getExtendedErrorInfo(buf, cap);
        return buf.toDartString();
      });

  /// Throws [NidaqmxException] (enriched with [errorInfo]) when [status] < 0.
  /// Positive warnings are returned to the caller to handle.
  int _check(int status, String op) {
    if (status < 0) throw NidaqmxException(status, errorInfo(), operation: op);
    return status;
  }

  /// Comma-separated names of the devices NI-DAQmx currently sees (e.g. `cDAQ1`,
  /// `cDAQ1Mod1`). Empty when none are present.
  List<String> deviceNames() => using((arena) {
        const cap = 4096;
        final buf = arena<Uint8>(cap).cast<Utf8>();
        _check(bindings.getSysDevNames(buf, cap), 'DAQmxGetSysDevNames');
        final s = buf.toDartString().trim();
        return s.isEmpty ? const [] : s.split(',').map((e) => e.trim()).toList();
      });

  /// One immediate analog-input voltage reading from [physicalChannel]
  /// (e.g. `cDAQ1Mod1/ai0`), via a one-shot task.
  double readVoltage(
    String physicalChannel, {
    double min = -10,
    double max = 10,
    int terminalConfig = DaqmxVal.cfgDefault,
    double timeout = 10,
  }) =>
      using((arena) {
        final task = arena<TaskHandle>();
        _check(bindings.createTask('lw-ai'.toNativeUtf8(allocator: arena), task), 'DAQmxCreateTask');
        try {
          _check(
            bindings.createAIVoltageChan(task.value, physicalChannel.toNativeUtf8(allocator: arena),
                nullptr, terminalConfig, min, max, DaqmxVal.volts, nullptr),
            'DAQmxCreateAIVoltageChan',
          );
          final value = arena<Double>();
          _check(bindings.readAnalogScalarF64(task.value, timeout, value, nullptr),
              'DAQmxReadAnalogScalarF64');
          return value.value;
        } finally {
          bindings.clearTask(task.value);
        }
      });

  /// Drive [physicalChannel] (e.g. `cDAQ1Mod2/ao0`) to [volts], via a one-shot
  /// auto-started task.
  void writeVoltage(
    String physicalChannel,
    double volts, {
    double min = -10,
    double max = 10,
    double timeout = 10,
  }) =>
      using((arena) {
        final task = arena<TaskHandle>();
        _check(bindings.createTask('lw-ao'.toNativeUtf8(allocator: arena), task), 'DAQmxCreateTask');
        try {
          _check(
            bindings.createAOVoltageChan(task.value, physicalChannel.toNativeUtf8(allocator: arena),
                nullptr, min, max, DaqmxVal.volts, nullptr),
            'DAQmxCreateAOVoltageChan',
          );
          _check(bindings.writeAnalogScalarF64(task.value, DaqmxVal.boolTrue, timeout, volts, nullptr),
              'DAQmxWriteAnalogScalarF64');
        } finally {
          bindings.clearTask(task.value);
        }
      });
}
