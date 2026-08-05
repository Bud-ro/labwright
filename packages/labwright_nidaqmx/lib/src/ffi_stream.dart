// FFI buffered streaming. NI-DAQmx reads block the calling thread, so a continuous
// acquisition would freeze the caller's isolate. Instead we run the whole task — load,
// configure the sample clock, loop the buffered read — on a DEDICATED isolate, and
// ship each chunk back over a port as a [Stream]. The Dart stream's pause/resume/cancel
// drive the worker (pause the read loop, stop+clear the task), so backpressure and
// teardown work the way callers expect.
//
// Commands reach the worker between reads. A pause or a cancel issued while a buffered
// read is in flight therefore takes effect only once that read returns, which is bounded
// by the DAQmx read timeout. Cancel deliberately waits for that instead of killing the
// isolate: a killed worker would skip DAQmxStopTask/DAQmxClearTask and leave the task
// alive inside the driver.

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
    required this.format,
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
  final DaqSampleFormat format;
  final double min;
  final double max;
  final int terminalConfig;
  final double readTimeout;
}

/// Command the stream owner sends the worker over the worker's control port.
enum _StreamCommand {
  /// Leave the read loop, then stop and clear the task.
  stop,

  /// Hold the read loop before its next read.
  pause,

  /// Release a held read loop.
  resume,
}

/// Worker-to-owner message. Sample chunks are not part of this set: they cross the
/// port bare as [TransferableTypedData], so delivering one allocates no wrapper. Two
/// further messages reach the same port from the VM rather than the worker: the
/// `[description, stackTrace]` pair of an uncaught worker error, and `null` when the
/// isolate exits (see [Isolate.spawn]'s `onError`/`onExit`).
sealed class _WorkerReply {
  const _WorkerReply();
}

/// First reply of every run: the port that accepts [_StreamCommand]s.
final class _WorkerReady extends _WorkerReply {
  const _WorkerReady(this.commands);

  final SendPort commands;
}

/// A failed library load, DAQmx call, or Dart error inside the worker. A [_WorkerDone]
/// always follows, and it — not this reply — closes the stream, so an error and the
/// close that follows it cannot race.
final class _WorkerFailed extends _WorkerReply {
  const _WorkerFailed({required this.status, required this.operation, required this.message});

  /// Negative DAQmx status, or a [DaqmxLocalStatus] value when the failure never
  /// reached the driver.
  final int status;

  /// The DAQmx entry point that failed, or `load` for the library itself.
  final String operation;

  final String message;
}

/// The read loop has ended and the task is cleared; no further replies follow.
final class _WorkerDone extends _WorkerReply {
  const _WorkerDone();
}

/// How long a cancel waits for the worker's command port before giving up on a graceful
/// stop. The worker sends it as its first act, so only an isolate that never runs at all
/// reaches this bound.
const _readyGrace = Duration(seconds: 2);

/// Slack beyond the read timeout for the worker to leave the read loop, stop and clear
/// the task, and report done.
const _stopMargin = Duration(seconds: 1);

/// Graceful-stop window for a run whose read timeout is infinite (DAQmx `-1`): the read
/// in flight has no bound of its own, so the wait gets a fixed one.
const _indefiniteStopGrace = Duration(seconds: 30);

/// Deadline for a worker to finish its own teardown after being told to stop.
Duration _stopGrace(double readTimeout) => readTimeout > 0
    ? Duration(microseconds: (readTimeout * Duration.microsecondsPerSecond).round()) + _stopMargin
    : _indefiniteStopGrace;

/// Consecutive empty reads tolerated at full speed before the loop starts backing off.
const _emptyReadsBeforeBackoff = 4;

/// Pause inserted between reads once a device keeps returning nothing, so a silent
/// input cannot spin the worker's core.
const _emptyReadBackoff = Duration(milliseconds: 2);

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

  /// The worker's command port, or null if the worker never reported ready.
  final ready = Completer<SendPort?>();

  /// Completed once the worker has cleared the task or its isolate has exited.
  final finished = Completer<void>();
  Isolate? isolate;
  SendPort? control;

  /// Set when cancellation starts. Replies that arrive while the worker winds down are
  /// dropped instead of being pushed at a subscription that is already gone; a failure
  /// the worker reports after the caller cancelled has nowhere to go by definition.
  var closing = false;
  StreamSubscription<dynamic>? sub;
  late StreamController<TypedData> controller;

  Future<void> teardown() async {
    closing = true;
    final commands = await ready.future.timeout(_readyGrace, onTimeout: () => null);
    if (commands != null) {
      commands.send(_StreamCommand.stop);
      // The worker sees the stop only after its in-flight read returns; let it run its
      // own stop/clear rather than killing it and leaking the task in the driver.
      await finished.future.timeout(_stopGrace(readTimeout), onTimeout: () {});
    }
    await sub?.cancel();
    fromWorker.close();
    // A worker that met its deadline is already gone and this is a no-op; one that hung
    // past it is unreachable anyway.
    isolate?.kill(priority: Isolate.immediate);
    isolate = null;
  }

  controller = StreamController<TypedData>(
    onListen: () async {
      sub = fromWorker.listen((reply) {
        switch (reply) {
          case final TransferableTypedData chunk:
            if (!closing) controller.add(_view(chunk.materialize(), format));
          case _WorkerReady(:final commands):
            control = commands;
            if (!ready.isCompleted) ready.complete(commands);
            // Honor a stop or pause that arrived before the worker was ready.
            if (closing) {
              commands.send(_StreamCommand.stop);
            } else if (controller.isPaused) {
              commands.send(_StreamCommand.pause);
            }
          case _WorkerFailed(:final status, :final message, :final operation):
            if (!closing) controller.addError(_streamError(status, operation, message));
          case _WorkerDone():
            if (!finished.isCompleted) finished.complete();
            if (!closing) controller.close();
          // An uncaught worker error, delivered by the VM as [description, stackTrace].
          // The worker reports its own failures as [_WorkerFailed], so this covers only
          // errors raised outside its body, such as in a port callback.
          case [final description, final trace]:
            if (!closing) {
              controller.addError(
                DaqmxException(
                  DaqmxLocalStatus.streamWorkerFailed.status,
                  '$description\n$trace',
                  operation: 'stream worker',
                ),
              );
            }
          // The worker isolate has exited (Isolate.spawn's onExit posts null). It is
          // sent after any uncaught error, so an error is always delivered first.
          case null:
            if (!ready.isCompleted) ready.complete(control);
            if (!finished.isCompleted) finished.complete();
            if (!closing) controller.close();
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
            format: format,
            min: min,
            max: max,
            terminalConfig: terminalConfig,
            readTimeout: readTimeout,
          ),
          onError: fromWorker.sendPort,
          onExit: fromWorker.sendPort,
        );
      } catch (error) {
        if (!ready.isCompleted) ready.complete(null);
        if (!finished.isCompleted) finished.complete();
        controller.addError(DaqmxUnavailable('failed to start stream worker: $error'));
        await controller.close();
      }
    },
    onPause: () => control?.send(_StreamCommand.pause),
    onResume: () => control?.send(_StreamCommand.resume),
    onCancel: teardown,
  );

  return controller.stream;
}

/// The exception a [_WorkerFailed] surfaces as. A load failure means the runtime was
/// never reached, which is what [DaqmxUnavailable] states everywhere else in the
/// package; anything else carries a status and is a [DaqmxException].
Object _streamError(int status, String operation, String message) => status == DaqmxLocalStatus.libraryLoadFailed.status
    ? DaqmxUnavailable(message)
    : DaqmxException(status, message, operation: operation);

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
  req.toMain.send(_WorkerReady(control.sendPort));

  var stop = false;
  var paused = false;
  Completer<void>? resumeSignal;
  control.listen((message) {
    switch (message as _StreamCommand) {
      case _StreamCommand.stop:
        stop = true;
        resumeSignal?.complete();
        resumeSignal = null;
      case _StreamCommand.pause:
        paused = true;
      case _StreamCommand.resume:
        paused = false;
        resumeSignal?.complete();
        resumeSignal = null;
    }
  });

  final format = req.format;
  NidaqmxBindings bindings;
  try {
    bindings = NidaqmxBindings(loadNidaqmx(path: req.libraryPath));
  } catch (error) {
    req.toMain.send(
      _WorkerFailed(
        status: DaqmxLocalStatus.libraryLoadFailed.status,
        operation: 'load',
        message: 'NI-DAQmx unavailable: $error',
      ),
    );
    req.toMain.send(const _WorkerDone());
    control.close();
    return;
  }

  final arena = Arena();
  final taskPtr = arena<TaskHandle>();
  String? errorText(int status) {
    if (status >= 0) return null;
    const cap = 2048;
    final buf = arena<Uint8>(cap);
    buf[0] = 0;
    bindings.getExtendedErrorInfo(buf.cast<Utf8>(), cap);
    return buf.cast<Utf8>().toDartString();
  }

  void fail(int status, String operation, String fallback) {
    req.toMain.send(
      _WorkerFailed(status: status, operation: operation, message: errorText(status) ?? fallback),
    );
  }

  var task = nullptr.cast<Void>();
  try {
    var status = bindings.createTask(''.toNativeUtf8(allocator: arena), taskPtr);
    if (status < 0) return fail(status, 'DAQmxCreateTask', 'create failed');
    task = taskPtr.value;

    status = bindings.createAIVoltageChan(
      task,
      req.channel.toNativeUtf8(allocator: arena),
      nullptr,
      req.terminalConfig,
      req.min,
      req.max,
      DaqmxVal.volts,
      nullptr,
    );
    if (status < 0) return fail(status, 'DAQmxCreateAIVoltageChan', 'channel failed');

    final continuous = req.totalSamples == null;
    final mode = continuous ? DaqmxVal.contSamps : DaqmxVal.finiteSamps;
    // Buffer hint: total for finite, a few chunks for continuous.
    final sampsHint = req.totalSamples ?? (req.samplesPerChunk * 4);
    status = bindings.cfgSampClkTiming(
      task,
      ''.toNativeUtf8(allocator: arena),
      req.rateHz,
      DaqmxVal.rising,
      mode,
      sampsHint,
    );
    if (status < 0) return fail(status, 'DAQmxCfgSampClkTiming', 'timing failed');

    // For continuous high-rate acquisition, give the driver DMA headroom well beyond a
    // single chunk so it doesn't overrun between our reads. (Finite uses the default.)
    if (continuous) {
      final bufSamps = req.samplesPerChunk * 8 < 100000 ? 100000 : req.samplesPerChunk * 8;
      status = bindings.cfgInputBuffer(task, bufSamps);
      if (status < 0) return fail(status, 'DAQmxCfgInputBuffer', 'buffer failed');
    }

    status = bindings.startTask(task);
    if (status < 0) return fail(status, 'DAQmxStartTask', 'start failed');

    final sampsRead = arena<Int32>();
    final reserved = nullptr.cast<Uint32>();
    final chunk = req.samplesPerChunk;
    // One destination buffer for the whole run: an arena allocation per read would grow
    // the worker's footprint for as long as the acquisition lasts.
    final buffer = arena<Uint8>(chunk * format.bytesPerSample);
    var delivered = 0;
    var emptyReads = 0;

    while (!stop) {
      if (paused) {
        resumeSignal = Completer<void>();
        await resumeSignal!.future;
        if (stop) break;
      }

      final want = continuous ? chunk : (req.totalSamples! - delivered).clamp(0, chunk);
      if (want == 0) break;

      final read = _readChunk(bindings, format, task, want, req.readTimeout, buffer, sampsRead, reserved);
      final samples = read.samples;
      if (samples == null) return fail(read.status, _readOp(format), 'read failed');
      final got = sampsRead.value;
      if (got <= 0) {
        emptyReads++;
        await Future<void>.delayed(emptyReads > _emptyReadsBeforeBackoff ? _emptyReadBackoff : Duration.zero);
        continue;
      }
      emptyReads = 0;
      req.toMain.send(samples);
      delivered += got;
      if (!continuous && delivered >= req.totalSamples!) break;
      await Future<void>.delayed(Duration.zero); // let control messages land
    }
  } catch (error, stackTrace) {
    // A Dart error in the loop (a driver reporting an impossible sample count, say)
    // reaches the owner as a stream error like any DAQmx failure, and the task is still
    // stopped and cleared below. Without this the error would escape to the isolate's
    // error port instead, out of order with the replies on the main port.
    req.toMain.send(
      _WorkerFailed(
        status: DaqmxLocalStatus.streamWorkerFailed.status,
        operation: 'stream worker',
        message: '$error\n$stackTrace',
      ),
    );
  } finally {
    if (task != nullptr) {
      bindings.stopTask(task);
      bindings.clearTask(task);
    }
    arena.releaseAll();
    req.toMain.send(const _WorkerDone());
    control.close();
  }
}

String _readOp(DaqSampleFormat format) => switch (format) {
  DaqSampleFormat.volts => 'DAQmxReadAnalogF64',
  DaqSampleFormat.rawI16 => 'DAQmxReadBinaryI16',
  DaqSampleFormat.rawI32 => 'DAQmxReadBinaryI32',
  DaqSampleFormat.rawU16 => 'DAQmxReadBinaryU16',
  DaqSampleFormat.rawU32 => 'DAQmxReadBinaryU32',
};

/// One buffered read: the block as transferable bytes plus the DAQmx status.
/// [samples] is null exactly when [status] is negative.
typedef _ChunkRead = ({TransferableTypedData? samples, int status});

/// Read one block in [format] into [buffer] and package it as transferable bytes.
/// [buffer] holds `samplesPerChunk * format.bytesPerSample` bytes and is reused for
/// every read of a run.
_ChunkRead _readChunk(
  NidaqmxBindings bindings,
  DaqSampleFormat format,
  TaskHandle task,
  int want,
  double timeout,
  Pointer<Uint8> buffer,
  Pointer<Int32> sampsRead,
  Pointer<Uint32> reserved,
) {
  const fill = DaqmxVal.groupByChannel;
  switch (format) {
    case DaqSampleFormat.volts:
      final buf = buffer.cast<Double>();
      final status = bindings.readAnalogF64(task, want, timeout, fill, buf, want, sampsRead, reserved);
      if (status < 0) return (samples: null, status: status);
      return (samples: _transfer(Float64List.fromList(buf.asTypedList(sampsRead.value))), status: status);
    case DaqSampleFormat.rawI16:
      final buf = buffer.cast<Int16>();
      final status = bindings.readBinaryI16(task, want, timeout, fill, buf, want, sampsRead, reserved);
      if (status < 0) return (samples: null, status: status);
      return (samples: _transfer(Int16List.fromList(buf.asTypedList(sampsRead.value))), status: status);
    case DaqSampleFormat.rawI32:
      final buf = buffer.cast<Int32>();
      final status = bindings.readBinaryI32(task, want, timeout, fill, buf, want, sampsRead, reserved);
      if (status < 0) return (samples: null, status: status);
      return (samples: _transfer(Int32List.fromList(buf.asTypedList(sampsRead.value))), status: status);
    case DaqSampleFormat.rawU16:
      final buf = buffer.cast<Uint16>();
      final status = bindings.readBinaryU16(task, want, timeout, fill, buf, want, sampsRead, reserved);
      if (status < 0) return (samples: null, status: status);
      return (samples: _transfer(Uint16List.fromList(buf.asTypedList(sampsRead.value))), status: status);
    case DaqSampleFormat.rawU32:
      final buf = buffer.cast<Uint32>();
      final status = bindings.readBinaryU32(task, want, timeout, fill, buf, want, sampsRead, reserved);
      if (status < 0) return (samples: null, status: status);
      return (samples: _transfer(Uint32List.fromList(buf.asTypedList(sampsRead.value))), status: status);
  }
}

TransferableTypedData _transfer(TypedData samples) => TransferableTypedData.fromList([samples]);
