// FfiDaqmxBackend against the compiled C shim (test/native/fake_daqmx.c): the
// real dart:ffi marshalling path end-to-end, no NI-DAQmx needed. The shim
// returns magic/echo values and captures arguments, so both directions assert.

@TestOn('!windows')
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:labwright_nidaqmx/labwright_nidaqmx.dart';
import 'package:test/test.dart';

import 'fake_daqmx_lib.dart';

void main() {
  final lib = buildFakeDaqmxLib();
  if (lib == null) {
    test('FFI shim tests skipped (no C toolchain)', () {}, skip: 'no C compiler available');
    return;
  }
  final probe = FakeDaqmxProbe(lib);
  FfiDaqmxBackend open() => FfiDaqmxBackend(libraryPath: lib);

  group('scalar path through real FFI', () {
    test('deviceNames parses GetSysDevNames (incl. the size-0 probe)', () async {
      final daq = open();
      expect(await daq.deviceNames(), ['FakeDev1', 'FakeDev1Mod1']);
      await daq.close();
    });

    test('readVoltage marshals AI config (int32 term, doubles, units) and returns the value', () async {
      final daq = open();
      expect(await daq.readVoltage('Dev1/ai0', min: -3, max: 7, terminalConfig: DaqmxVal.diff), 4.2);
      expect(
        (probe.lastAiMin, probe.lastAiMax, probe.lastAiTerm, probe.lastAiUnits, probe.lastChannel),
        (-3.0, 7.0, DaqmxVal.diff, DaqmxVal.volts, 'Dev1/ai0'),
      );
      await daq.close();
    });

    test('writeVoltage marshals value/autostart/timeout', () async {
      final daq = open();
      await daq.writeVoltage('Dev1/ao0', 2.5, timeout: 3);
      expect(
        (probe.lastWriteValue, probe.lastWriteAutoStart, probe.lastWriteTimeout, probe.lastChannel),
        (2.5, DaqmxVal.boolTrue, 3.0, 'Dev1/ao0'),
      );
      await daq.close();
    });

    test('a negative status becomes a DaqmxException with the extended error text', () async {
      final daq = open();
      // The shim returns -200279 for any channel containing "fail".
      await expectLater(
        daq.readVoltage('Dev1/aifail0'),
        throwsA(
          isA<DaqmxException>()
              .having((e) => e.status, 'status', -200279)
              .having((e) => e.message, 'message', contains('FAKE-DAQmx'))
              .having((e) => e.operation, 'op', 'DAQmxCreateAIVoltageChan'),
        ),
      );
      await daq.close();
    });
  });

  group('streaming through real FFI + an isolate', () {
    test('finite f64 stream yields the shim ramp with a short final chunk', () async {
      final daq = open();
      final chunks = await daq
          .readVoltageStream('Dev1/ai0', rateHz: 10000, samplesPerChunk: 100, totalSamples: 250)
          .toList();
      expect(chunks.expand((c) => c).toList(), List.generate(250, (i) => i.toDouble()));
      expect(chunks.map((c) => c.length), [100, 100, 50]);
      expect(probe.lastRate, 10000, reason: 'the Dart rate reached CfgSampClkTiming');
      expect(probe.lastSampleMode, DaqmxVal.finiteSamps);
      await daq.close();
    });

    // (name, open the stream, per-chunk type, total samples)
    // dart format off
    final rawRows = <(String, Stream<List<int>> Function(FfiDaqmxBackend), Matcher, int)>[
      ('raw i16 stream yields Int16List chunks (half the bytes of f64)',
          (d) => d.readRawI16Stream('Dev1/ai0', rateHz: 1000, samplesPerChunk: 50, totalSamples: 100), isA<Int16List>(), 100),
      ('raw i32 stream yields Int32List chunks',
          (d) => d.readRawI32Stream('Dev1/ai0', rateHz: 1000, samplesPerChunk: 64, totalSamples: 64), isA<Int32List>(), 64),
    ];
    // dart format on
    for (final (name, stream, chunkType, total) in rawRows) {
      test(name, () async {
        final daq = open();
        final chunks = await stream(daq).toList();
        expect(chunks, everyElement(chunkType));
        expect(chunks.expand((c) => c).toList(), List.generate(total, (i) => i));
        await daq.close();
      });
    }

    test('pausing then resuming the subscription keeps the worker delivering', () async {
      final daq = open();
      final chunks = <TypedData>[];
      var arrived = Completer<void>();
      final samples = daq.readStream('Dev1/ai0', rateHz: 1000, samplesPerChunk: 16, format: DaqSampleFormat.rawI16);
      final sub = samples.listen((chunk) {
        chunks.add(chunk);
        if (!arrived.isCompleted) arrived.complete();
      });
      await arrived.future;
      sub.pause();
      arrived = Completer<void>();
      sub.resume();
      await arrived.future.timeout(const Duration(seconds: 10));
      expect(chunks.length, greaterThan(1));
      await sub.cancel();
      await daq.close();
    });

    test('continuous stream sets contSamps and stops cleanly on cancel', () async {
      final daq = open();
      final got = await daq
          .readStream('Dev1/ai0', rateHz: 100000, samplesPerChunk: 32, format: DaqSampleFormat.rawI16)
          .take(3) // cancel -> worker tears down
          .toList();
      expect(got, hasLength(3));
      expect(probe.lastSampleMode, DaqmxVal.contSamps);
      expect(probe.lastInputBuffer, greaterThanOrEqualTo(100000), reason: 'DMA headroom for the high rate');
      await daq.close();
    });
  });
}
