// Integration tests for the FFI backend against a REAL NI-DAQmx runtime (including NI
// MAX *simulated devices* — no physical hardware required). They self-skip unless the
// relevant env vars are set, so the default `dart test` run stays green with no NI
// software installed. Run on a Windows/Linux box with NI-DAQmx:
//
//   DAQMX_AI_CHANNEL=Dev1/ai0 \
//   [DAQMX_AO_CHANNEL=Dev1/ao0] [DAQMX_LIB=/path/to/libnidaqmx.so] \
//   dart test -t hardware packages/labwright_nidaqmx/test/integration/ffi_hardware_test.dart
//
// This is the validation that the C-shim tests stand in for: same operations, real
// driver. See README "Validating against real hardware".

@Tags(['hardware'])
@TestOn('!browser')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_nidaqmx/labwright_nidaqmx.dart';
import 'package:test/test.dart';

void main() {
  final ai = Platform.environment['DAQMX_AI_CHANNEL'];
  final ao = Platform.environment['DAQMX_AO_CHANNEL'];
  final lib = Platform.environment['DAQMX_LIB'];
  final skip = ai == null ? 'set DAQMX_AI_CHANNEL (e.g. Dev1/ai0) to run FFI integration against real NI-DAQmx' : null;

  group('FFI backend against a live NI-DAQmx runtime', () {
    late DaqmxApi daq;
    setUp(() => daq = Daqmx.local(libraryPath: lib));
    tearDown(() => daq.close());

    test('enumerates at least one device', () async {
      expect(await daq.deviceNames(), isNotEmpty);
    });

    test('scalar AI read returns a finite voltage', () async {
      expect((await daq.readVoltage(ai!)).isFinite, isTrue);
    });

    test('finite f64 stream returns exactly totalSamples', () async {
      final chunks = await daq.readVoltageStream(ai!, rateHz: 1000, samplesPerChunk: 100, totalSamples: 500).toList();
      expect(chunks.expand((c) => c).length, 500);
    });

    test('raw i16 stream yields Int16List chunks', () async {
      final chunks = await daq.readRawI16Stream(ai!, rateHz: 1000, samplesPerChunk: 100, totalSamples: 300).toList();
      expect(chunks, everyElement(isA<Int16List>()));
      expect(chunks.expand((c) => c).length, greaterThanOrEqualTo(300));
    });

    test('continuous stream yields then cancels cleanly', () async {
      final got = await daq.readVoltageStream(ai!, rateHz: 1000, samplesPerChunk: 100).take(3).toList();
      expect(got, hasLength(3));
    });

    test('a nonexistent channel raises DaqmxException with NI error text', () async {
      await expectLater(
        daq.readVoltage('NoSuchDevice42/ai0'),
        throwsA(isA<DaqmxException>().having((e) => e.message, 'message', isNotEmpty)),
      );
    });

    test(
      'AO write round-trips (set DAQMX_AO_CHANNEL)',
      () async {
        await daq.writeVoltage(ao!, 1.0);
      },
      skip: ao == null ? 'set DAQMX_AO_CHANNEL to exercise analog output' : null,
    );
  }, skip: skip);
}
