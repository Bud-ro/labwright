// Exercises the FFI backend against the compiled C shim (test/native/fake_daqmx.c).
// This is the real dart:ffi marshalling path end-to-end — a wrong width/sign/pointer
// in the bindings would surface here — without needing NI-DAQmx installed. The shim
// returns magic/echo values and captures arguments, so we assert both directions.

@TestOn('!windows')
library;

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

    test('readVoltage marshals AI config (int32 term, doubles, units) and returns the value',
        () async {
      final daq = open();
      final v = await daq.readVoltage('Dev1/ai0', min: -3, max: 7, terminalConfig: DaqmxVal.diff);
      expect(v, 4.2); // shim's magic scalar
      expect(probe.lastAiMin, -3);
      expect(probe.lastAiMax, 7);
      expect(probe.lastAiTerm, DaqmxVal.diff);
      expect(probe.lastAiUnits, DaqmxVal.volts);
      expect(probe.lastChannel, 'Dev1/ai0');
      await daq.close();
    });

    test('writeVoltage marshals value/autostart/timeout', () async {
      final daq = open();
      await daq.writeVoltage('Dev1/ao0', 2.5, timeout: 3);
      expect(probe.lastWriteValue, 2.5);
      expect(probe.lastWriteAutoStart, DaqmxVal.boolTrue);
      expect(probe.lastWriteTimeout, 3);
      expect(probe.lastChannel, 'Dev1/ao0');
      await daq.close();
    });

    test('a negative status becomes a DaqmxException with the extended error text', () async {
      final daq = open();
      // The shim returns -200279 for any channel containing "fail".
      await expectLater(
        daq.readVoltage('Dev1/aifail0'),
        throwsA(isA<DaqmxException>()
            .having((e) => e.status, 'status', -200279)
            .having((e) => e.message, 'message', contains('FAKE-DAQmx'))
            .having((e) => e.operation, 'op', 'DAQmxCreateAIVoltageChan')),
      );
      await daq.close();
    });
  });

  group('streaming through real FFI + an isolate', () {
    test('finite f64 stream yields a continuous ramp of the right length', () async {
      final daq = open();
      final chunks =
          await daq.readVoltageStream('Dev1/ai0', rateHz: 10000, samplesPerChunk: 100, totalSamples: 250)
              .toList();
      final all = chunks.expand((c) => c).toList();
      expect(all.length, 250);
      expect(all, List.generate(250, (i) => i.toDouble())); // shim ramp 0..249
      expect(chunks.map((c) => c.length), [100, 100, 50]); // last chunk shorter
      expect(probe.lastRate, 10000); // sample rate set from Dart reached CfgSampClkTiming
      expect(probe.lastSampleMode, DaqmxVal.finiteSamps);
      await daq.close();
    });

    test('raw i16 stream yields Int16List chunks (half the bytes of f64)', () async {
      final daq = open();
      final chunks = await daq
          .readRawI16Stream('Dev1/ai0', rateHz: 1000, samplesPerChunk: 50, totalSamples: 100)
          .toList();
      expect(chunks, everyElement(isA<Int16List>()));
      final all = chunks.expand((c) => c).toList();
      expect(all.length, 100);
      expect(all, List.generate(100, (i) => i));
      await daq.close();
    });

    test('raw i32 stream yields Int32List chunks', () async {
      final daq = open();
      final chunks = await daq
          .readRawI32Stream('Dev1/ai0', rateHz: 1000, samplesPerChunk: 64, totalSamples: 64)
          .toList();
      expect(chunks.single, isA<Int32List>());
      expect(chunks.single, List.generate(64, (i) => i));
      await daq.close();
    });

    test('continuous stream sets contSamps and stops cleanly on cancel', () async {
      final daq = open();
      final got = await daq
          .readStream('Dev1/ai0', rateHz: 100000, samplesPerChunk: 32, format: DaqSampleFormat.rawI16)
          .take(3)
          .toList(); // take(3) cancels the subscription -> worker tears down
      expect(got, hasLength(3));
      expect(probe.lastSampleMode, DaqmxVal.contSamps);
      expect(probe.lastInputBuffer, greaterThanOrEqualTo(100000)); // DMA headroom for high rate
      await daq.close();
    });
  });
}
