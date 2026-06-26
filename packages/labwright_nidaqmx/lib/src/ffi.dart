// ignore_for_file: library_private_types_in_public_api
// Hand-written dart:ffi bindings to the PUBLIC NI-DAQmx C API (nicaiu.dll on
// Windows, libnidaqmx.so on Linux). This wraps NI's own trusted driver — it does
// NOT reimplement it — so on Windows/Linux there is no reverse-engineering: the
// signatures below are transcribed from NI's published C reference.
//
// Deliberately the same shape as the clean-room `labwright_qdaq` bindings (qdaq
// conforms to this exact ABI), so the binding shape is reusable. macOS is NOT
// supported by NI-DAQmx — use the gRPC backend there; see [loadNidaqmx].

import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'daqmx_api.dart';

/// Opaque DAQmx task handle (`TaskHandle` in the C API).
typedef TaskHandle = Pointer<Void>;

/// Opens the NI-DAQmx shared library for the host platform, or throws
/// [DaqmxUnavailable] with guidance. macOS is rejected explicitly: NI ships no
/// modern DAQmx for macOS (only the long-dead NI-DAQmx Base ≤ macOS 10.14), so on
/// macOS the only path is the gRPC backend talking to a Windows/Linux host server.
DynamicLibrary loadNidaqmx({String? path}) {
  if (path != null) return DynamicLibrary.open(path);
  if (Abi.current() == Abi.macosArm64 || Abi.current() == Abi.macosX64) {
    throw DaqmxUnavailable(
        'NI-DAQmx has no local runtime on macOS; connect to an NI gRPC Device Server '
        'instead (Daqmx.remote(host: ...)).');
  }
  final candidates = Abi.current() == Abi.windowsX64 || Abi.current() == Abi.windowsArm64
      ? const ['nicaiu.dll']
      : const ['libnidaqmx.so', 'libnidaqmx.so.1'];
  Object? last;
  for (final c in candidates) {
    try {
      return DynamicLibrary.open(c);
    } catch (e) {
      last = e;
    }
  }
  throw DaqmxUnavailable(
      'Could not load the NI-DAQmx runtime (tried: ${candidates.join(', ')}). '
      'Install NI-DAQmx (free) on Windows/Linux. Last error: $last');
}

// --- native (C) signatures: the public NI-DAQmx C API ---
typedef _CreateTaskC = Int32 Function(Pointer<Utf8>, Pointer<TaskHandle>);
typedef _TaskOnlyC = Int32 Function(TaskHandle);
typedef _CreateAiVoltageC =
    Int32 Function(TaskHandle, Pointer<Utf8>, Pointer<Utf8>, Int32, Double, Double, Int32, Pointer<Utf8>);
typedef _CreateAoVoltageC =
    Int32 Function(TaskHandle, Pointer<Utf8>, Pointer<Utf8>, Double, Double, Int32, Pointer<Utf8>);
typedef _CfgSampClkTimingC =
    Int32 Function(TaskHandle, Pointer<Utf8>, Double, Int32, Int32, Uint64);
typedef _ReadAnalogF64C = Int32 Function(
    TaskHandle, Int32, Double, Uint32, Pointer<Double>, Uint32, Pointer<Int32>, Pointer<Uint32>);
// Binary (raw ADC-code) block reads. Identical shape to ReadAnalogF64 but with the
// device's native element width — the practical high-speed formats (half/quarter the
// bytes of f64, no per-sample scaling).
typedef _ReadBinaryI16C = Int32 Function(
    TaskHandle, Int32, Double, Uint32, Pointer<Int16>, Uint32, Pointer<Int32>, Pointer<Uint32>);
typedef _ReadBinaryI32C = Int32 Function(
    TaskHandle, Int32, Double, Uint32, Pointer<Int32>, Uint32, Pointer<Int32>, Pointer<Uint32>);
typedef _ReadBinaryU16C = Int32 Function(
    TaskHandle, Int32, Double, Uint32, Pointer<Uint16>, Uint32, Pointer<Int32>, Pointer<Uint32>);
typedef _ReadBinaryU32C = Int32 Function(
    TaskHandle, Int32, Double, Uint32, Pointer<Uint32>, Uint32, Pointer<Int32>, Pointer<Uint32>);
typedef _ReadAnalogScalarF64C = Int32 Function(TaskHandle, Double, Pointer<Double>, Pointer<Uint32>);
typedef _WriteAnalogScalarF64C = Int32 Function(TaskHandle, Uint32, Double, Double, Pointer<Uint32>);
typedef _GetStringC = Int32 Function(Pointer<Utf8>, Uint32);

/// One resolved set of NI-DAQmx entry points, looked up once from an open library.
/// Dart-side signatures use `int`/`double` (the FFI marshals the C widths declared
/// in the `*C` typedefs above).
class NidaqmxBindings {
  NidaqmxBindings(DynamicLibrary lib)
      : createTask = lib.lookupFunction<_CreateTaskC, _CreateTaskDart>('DAQmxCreateTask'),
        startTask = lib.lookupFunction<_TaskOnlyC, _TaskOnlyDart>('DAQmxStartTask'),
        stopTask = lib.lookupFunction<_TaskOnlyC, _TaskOnlyDart>('DAQmxStopTask'),
        clearTask = lib.lookupFunction<_TaskOnlyC, _TaskOnlyDart>('DAQmxClearTask'),
        createAIVoltageChan =
            lib.lookupFunction<_CreateAiVoltageC, _CreateAiVoltageDart>('DAQmxCreateAIVoltageChan'),
        createAOVoltageChan =
            lib.lookupFunction<_CreateAoVoltageC, _CreateAoVoltageDart>('DAQmxCreateAOVoltageChan'),
        cfgSampClkTiming =
            lib.lookupFunction<_CfgSampClkTimingC, _CfgSampClkTimingDart>('DAQmxCfgSampClkTiming'),
        readAnalogF64 = lib.lookupFunction<_ReadAnalogF64C, _ReadAnalogF64Dart>('DAQmxReadAnalogF64'),
        readBinaryI16 = lib.lookupFunction<_ReadBinaryI16C, _ReadBinaryI16Dart>('DAQmxReadBinaryI16'),
        readBinaryI32 = lib.lookupFunction<_ReadBinaryI32C, _ReadBinaryI32Dart>('DAQmxReadBinaryI32'),
        readBinaryU16 = lib.lookupFunction<_ReadBinaryU16C, _ReadBinaryU16Dart>('DAQmxReadBinaryU16'),
        readBinaryU32 = lib.lookupFunction<_ReadBinaryU32C, _ReadBinaryU32Dart>('DAQmxReadBinaryU32'),
        readAnalogScalarF64 = lib
            .lookupFunction<_ReadAnalogScalarF64C, _ReadAnalogScalarF64Dart>('DAQmxReadAnalogScalarF64'),
        writeAnalogScalarF64 = lib
            .lookupFunction<_WriteAnalogScalarF64C, _WriteAnalogScalarF64Dart>('DAQmxWriteAnalogScalarF64'),
        getExtendedErrorInfo =
            lib.lookupFunction<_GetStringC, _GetStringDart>('DAQmxGetExtendedErrorInfo'),
        getSysDevNames = lib.lookupFunction<_GetStringC, _GetStringDart>('DAQmxGetSysDevNames');

  final int Function(Pointer<Utf8>, Pointer<TaskHandle>) createTask;
  final int Function(TaskHandle) startTask;
  final int Function(TaskHandle) stopTask;
  final int Function(TaskHandle) clearTask;
  final int Function(TaskHandle, Pointer<Utf8>, Pointer<Utf8>, int, double, double, int, Pointer<Utf8>)
      createAIVoltageChan;
  final int Function(TaskHandle, Pointer<Utf8>, Pointer<Utf8>, double, double, int, Pointer<Utf8>)
      createAOVoltageChan;
  final int Function(TaskHandle, Pointer<Utf8>, double, int, int, int) cfgSampClkTiming;
  final int Function(
          TaskHandle, int, double, int, Pointer<Double>, int, Pointer<Int32>, Pointer<Uint32>)
      readAnalogF64;
  final int Function(
          TaskHandle, int, double, int, Pointer<Int16>, int, Pointer<Int32>, Pointer<Uint32>)
      readBinaryI16;
  final int Function(
          TaskHandle, int, double, int, Pointer<Int32>, int, Pointer<Int32>, Pointer<Uint32>)
      readBinaryI32;
  final int Function(
          TaskHandle, int, double, int, Pointer<Uint16>, int, Pointer<Int32>, Pointer<Uint32>)
      readBinaryU16;
  final int Function(
          TaskHandle, int, double, int, Pointer<Uint32>, int, Pointer<Int32>, Pointer<Uint32>)
      readBinaryU32;
  final int Function(TaskHandle, double, Pointer<Double>, Pointer<Uint32>) readAnalogScalarF64;
  final int Function(TaskHandle, int, double, double, Pointer<Uint32>) writeAnalogScalarF64;
  final int Function(Pointer<Utf8>, int) getExtendedErrorInfo;
  final int Function(Pointer<Utf8>, int) getSysDevNames;
}

// Dart-side function signatures (C widths -> Dart int/double).
typedef _CreateTaskDart = int Function(Pointer<Utf8>, Pointer<TaskHandle>);
typedef _TaskOnlyDart = int Function(TaskHandle);
typedef _CreateAiVoltageDart =
    int Function(TaskHandle, Pointer<Utf8>, Pointer<Utf8>, int, double, double, int, Pointer<Utf8>);
typedef _CreateAoVoltageDart =
    int Function(TaskHandle, Pointer<Utf8>, Pointer<Utf8>, double, double, int, Pointer<Utf8>);
typedef _CfgSampClkTimingDart = int Function(TaskHandle, Pointer<Utf8>, double, int, int, int);
typedef _ReadAnalogF64Dart = int Function(
    TaskHandle, int, double, int, Pointer<Double>, int, Pointer<Int32>, Pointer<Uint32>);
typedef _ReadBinaryI16Dart = int Function(
    TaskHandle, int, double, int, Pointer<Int16>, int, Pointer<Int32>, Pointer<Uint32>);
typedef _ReadBinaryI32Dart = int Function(
    TaskHandle, int, double, int, Pointer<Int32>, int, Pointer<Int32>, Pointer<Uint32>);
typedef _ReadBinaryU16Dart = int Function(
    TaskHandle, int, double, int, Pointer<Uint16>, int, Pointer<Int32>, Pointer<Uint32>);
typedef _ReadBinaryU32Dart = int Function(
    TaskHandle, int, double, int, Pointer<Uint32>, int, Pointer<Int32>, Pointer<Uint32>);
typedef _ReadAnalogScalarF64Dart = int Function(TaskHandle, double, Pointer<Double>, Pointer<Uint32>);
typedef _WriteAnalogScalarF64Dart = int Function(TaskHandle, int, double, double, Pointer<Uint32>);
typedef _GetStringDart = int Function(Pointer<Utf8>, int);
