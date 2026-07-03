// FFI buffered streaming. NI-DAQmx reads block the calling thread, so a continuous
// acquisition would freeze the caller's isolate. Instead we run the whole task — load,
// configure the sample clock, loop the buffered read — on a DEDICATED isolate, and
// ship each chunk back over a port as a [Stream]. The Dart stream's pause/resume/cancel
// drive the worker (pause the read loop, stop+clear the task), so backpressure and
// teardown work the way callers expect.

import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'daqmx_api.dart';
import 'daqmx_constants.dart';
import 'ffi.dart';
import 'streaming.dart';

/// Everything the worker isolate needs (all values are send-port-safe).
class _StreamRequest {
  _StreamRequest({
    required this.toMain,
    required this.libraryPath,
    required this.channel,
    required this.rateHz,
    required this.samplesPerChunk,
    required this.totalSamples,
    required this.formatIndex,
    required this.min,
    required this.max,
    required this.terminalConfig,
    required this.readTimeout,
  });

  final SendPort toMain;
  final String? libraryPath;
  final String channel;
  final double rateHz;
  final int samplesPerChunk;
  final int? totalSamples;
  final int formatIndex;
  final double min;
  final double max;
  final int terminalConfig;
  final double readTimeout;
}

const _doneTag = '__daq_stream_done__';

/// Buffered acquisition as a [Stream] of typed chunks, run on a worker isolate.
/// Mirrors the [DaqmxApi.readStream] contract for the FFI backend.
Stream<TypedData> ffiReadStream({
  required String? libraryPath,
  required String channel,
  required double rateHz,
  required int samplesPerChunk,
  required int? totalSamples,
  required DaqSampleFormat format,
  required double min,
  required double max,
  required int terminalConfig,
  double readTimeout = 10,
}) {
  final fromWorker = ReceivePort();
  Isolate? isolate;
  SendPort? control;
  StreamSubscription<dynamic>? sub;
  late StreamController<TypedData> controller;

  Future<void> teardown() async {
    control?.send('stop');
    await sub?.cancel();
    fromWorker.close();
    isolate?.kill();
    isolate = null;
  }

  controller = StreamController<TypedData>(
    onListen: () async {
      sub = fromWorker.listen((msg) {
        if (msg is SendPort) {
          control = msg;
          // Honor any pause that arrived before the worker was ready.
          if (controller.isPaused) control!.send('pause');
        } else if (msg is TransferableTypedData) {
          controller.add(_view(msg.materialize(), format));
        } else if (msg == _doneTag) {
          controller.close();
        } else if (msg is Map) {
          controller.addError(
              DaqmxException(msg['status'] as int? ?? -1, msg['error'] as String? ?? 'stream error',
                  operation: msg['op'] as String?));
          controller.close();
        }
      });
      try {
        isolate = await Isolate.spawn(
          _streamWorker,
          _StreamRequest(
            toMain: fromWorker.sendPort,
            libraryPath: libraryPath,
            channel: channel,
            rateHz: rateHz,
            samplesPerChunk: samplesPerChunk,
            totalSamples: totalSamples,
            formatIndex: format.index,
            min: min,
            max: max,
            terminalConfig: terminalConfig,
            readTimeout: readTimeout,
          ),
          onError: fromWorker.sendPort,
        );
      } catch (e) {
        controller.addError(DaqmxUnavailable('failed to start stream worker: $e'));
        await controller.close();
      }
    },
    onPause: () => control?.send('pause'),
    onResume: () => control?.send('resume'),
    onCancel: teardown,
  );

  return controller.stream;
}

/// View a transferred chunk's bytes as the format's typed list (no copy).
TypedData _view(ByteBuffer buf, DaqSampleFormat format) {
  switch (format) {
    case DaqSampleFormat.volts:
      return buf.asFloat64List();
    case DaqSampleFormat.rawI16:
      return buf.asInt16List();
    case DaqSampleFormat.rawI32:
      return buf.asInt32List();
    case DaqSampleFormat.rawU16:
      return buf.asUint16List();
    case DaqSampleFormat.rawU32:
      return buf.asUint32List();
  }
}

// --- worker isolate ---

Future<void> _streamWorker(_StreamRequest req) async {
  final control = ReceivePort();
  req.toMain.send(control.sendPort);

  var stop = false;
  var paused = false;
  Completer<void>? resumeSignal;
  control.listen((m) {
    if (m == 'stop') {
      stop = true;
      resumeSignal?.complete();
      resumeSignal = null;
    } else if (m == 'pause') {
      paused = true;
    } else if (m == 'resume') {
      paused = false;
      resumeSignal?.complete();
      resumeSignal = null;
    }
  });

  final format = DaqSampleFormat.values[req.formatIndex];
  NidaqmxBindings b;
  try {
    b = NidaqmxBindings(loadNidaqmx(path: req.libraryPath));
  } catch (e) {
    req.toMain.send({'error': 'NI-DAQmx unavailable: $e', 'op': 'load'});
    req.toMain.send(_doneTag);
    control.close();
    return;
  }

  final arena = Arena();
  final taskPtr = arena<TaskHandle>();
  String? errFor(int status, String op) {
    if (status >= 0) return null;
    const cap = 2048;
    final buf = arena<Uint8>(cap);
    buf[0] = 0;
    b.getExtendedErrorInfo(buf.cast<Utf8>(), cap);
    return buf.cast<Utf8>().toDartString();
  }

  void fail(int status, String op, String text) {
    req.toMain.send({'error': text, 'status': status, 'op': op});
  }

  var task = nullptr.cast<Void>();
  try {
    var s = b.createTask(''.toNativeUtf8(allocator: arena), taskPtr);
    if (s < 0) return fail(s, 'DAQmxCreateTask', errFor(s, 'DAQmxCreateTask') ?? 'create failed');
    task = taskPtr.value;

    s = b.createAIVoltageChan(task, req.channel.toNativeUtf8(allocator: arena), nullptr,
        req.terminalConfig, req.min, req.max, DaqmxVal.volts, nullptr);
    if (s < 0) {
      return fail(
          s, 'DAQmxCreateAIVoltageChan', errFor(s, 'DAQmxCreateAIVoltageChan') ?? 'channel failed');
    }

    final continuous = req.totalSamples == null;
    final mode = continuous ? DaqmxVal.contSamps : DaqmxVal.finiteSamps;
    // Buffer hint: total for finite, a few chunks for continuous.
    final sampsHint = req.totalSamples ?? (req.samplesPerChunk * 4);
    s = b.cfgSampClkTiming(
        task, ''.toNativeUtf8(allocator: arena), req.rateHz, DaqmxVal.rising, mode, sampsHint);
    if (s < 0) {
      return fail(s, 'DAQmxCfgSampClkTiming', errFor(s, 'DAQmxCfgSampClkTiming') ?? 'timing failed');
    }

    // For continuous high-rate acquisition, give the driver DMA headroom well beyond a
    // single chunk so it doesn't overrun between our reads. (Finite uses the default.)
    if (continuous) {
      final bufSamps = req.samplesPerChunk * 8 < 100000 ? 100000 : req.samplesPerChunk * 8;
      s = b.cfgInputBuffer(task, bufSamps);
      if (s < 0) {
        return fail(s, 'DAQmxCfgInputBuffer', errFor(s, 'DAQmxCfgInputBuffer') ?? 'buffer failed');
      }
    }

    s = b.startTask(task);
    if (s < 0) return fail(s, 'DAQmxStartTask', errFor(s, 'DAQmxStartTask') ?? 'start failed');

    final sampsRead = arena<Int32>();
    final reserved = nullptr.cast<Uint32>();
    final chunk = req.samplesPerChunk;
    var delivered = 0;

    while (!stop) {
      if (paused) {
        resumeSignal = Completer<void>();
        await resumeSignal!.future;
        if (stop) break;
      }

      final want =
          continuous ? chunk : (req.totalSamples! - delivered).clamp(0, chunk);
      if (want == 0) break;

      final transfer = _readChunk(b, format, task, want, req.readTimeout, sampsRead, reserved, arena);
      if (transfer == null) {
        final st = sampsRead.value; // unused for error; status captured below
        // _readChunk returns null only on a negative status, surfaced via _lastReadStatus
        final code = _lastReadStatus;
        return fail(code, _readOp(format), errFor(code, _readOp(format)) ?? 'read failed (st=$st)');
      }
      final got = sampsRead.value;
      if (got <= 0) {
        await Future<void>.delayed(Duration.zero);
        continue;
      }
      req.toMain.send(transfer);
      delivered += got;
      if (!continuous && delivered >= req.totalSamples!) break;
      await Future<void>.delayed(Duration.zero); // let control messages land
    }
  } finally {
    if (task != nullptr) {
      b.stopTask(task);
      b.clearTask(task);
    }
    arena.releaseAll();
    req.toMain.send(_doneTag);
    control.close();
  }
}

int _lastReadStatus = 0;

String _readOp(DaqSampleFormat f) => switch (f) {
      DaqSampleFormat.volts => 'DAQmxReadAnalogF64',
      DaqSampleFormat.rawI16 => 'DAQmxReadBinaryI16',
      DaqSampleFormat.rawI32 => 'DAQmxReadBinaryI32',
      DaqSampleFormat.rawU16 => 'DAQmxReadBinaryU16',
      DaqSampleFormat.rawU32 => 'DAQmxReadBinaryU32',
    };

/// Read one block in [format] and package it as transferable bytes, or null on a
/// negative DAQmx status (status stashed in [_lastReadStatus]).
TransferableTypedData? _readChunk(NidaqmxBindings b, DaqSampleFormat format, TaskHandle task,
    int want, double timeout, Pointer<Int32> sampsRead, Pointer<Uint32> reserved, Arena arena) {
  const fill = DaqmxVal.groupByChannel;
  switch (format) {
    case DaqSampleFormat.volts:
      final buf = arena<Double>(want);
      _lastReadStatus = b.readAnalogF64(task, want, timeout, fill, buf, want, sampsRead, reserved);
      if (_lastReadStatus < 0) return null;
      return TransferableTypedData.fromList([Float64List.fromList(buf.asTypedList(sampsRead.value))]);
    case DaqSampleFormat.rawI16:
      final buf = arena<Int16>(want);
      _lastReadStatus = b.readBinaryI16(task, want, timeout, fill, buf, want, sampsRead, reserved);
      if (_lastReadStatus < 0) return null;
      return TransferableTypedData.fromList([Int16List.fromList(buf.asTypedList(sampsRead.value))]);
    case DaqSampleFormat.rawI32:
      final buf = arena<Int32>(want);
      _lastReadStatus = b.readBinaryI32(task, want, timeout, fill, buf, want, sampsRead, reserved);
      if (_lastReadStatus < 0) return null;
      return TransferableTypedData.fromList([Int32List.fromList(buf.asTypedList(sampsRead.value))]);
    case DaqSampleFormat.rawU16:
      final buf = arena<Uint16>(want);
      _lastReadStatus = b.readBinaryU16(task, want, timeout, fill, buf, want, sampsRead, reserved);
      if (_lastReadStatus < 0) return null;
      return TransferableTypedData.fromList([Uint16List.fromList(buf.asTypedList(sampsRead.value))]);
    case DaqSampleFormat.rawU32:
      final buf = arena<Uint32>(want);
      _lastReadStatus = b.readBinaryU32(task, want, timeout, fill, buf, want, sampsRead, reserved);
      if (_lastReadStatus < 0) return null;
      return TransferableTypedData.fromList([Uint32List.fromList(buf.asTypedList(sampsRead.value))]);
  }
}
