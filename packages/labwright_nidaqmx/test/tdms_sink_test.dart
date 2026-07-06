// Verifies the DAQ-stream -> TDMS bridge: chunks become segments, raw integer
// formats are stored as their compact TdsType, and the bytes round-trip through the
// TDMS reader. The synthetic test needs no native toolchain; the end-to-end test
// drives a real FFI i16 stream from the C shim into TDMS.

@TestOn('!windows')
library;

import 'dart:typed_data';

import 'package:labwright_nidaqmx/labwright_nidaqmx.dart';
import 'package:labwright_tdms/labwright_tdms.dart';
import 'package:test/test.dart';

import 'fake_daqmx_lib.dart';

void main() {
  test('records an i16 stream as compact i16 TDMS segments that round-trip', () async {
    // Three chunks of a continuous ramp 0..249.
    final chunks = <Int16List>[
      Int16List.fromList(List.generate(100, (i) => i)),
      Int16List.fromList(List.generate(100, (i) => 100 + i)),
      Int16List.fromList(List.generate(50, (i) => 200 + i)),
    ];
    final bytes = await recordStreamToTdms(
      Stream<TypedData>.fromIterable(chunks),
      format: DaqSampleFormat.rawI16,
      group: 'AI',
      channel: 'Dev1/ai0',
      rateHz: 1000,
    );

    final file = TdmsReader.read(bytes);
    final ch = file.group('AI')!.channel('Dev1/ai0')!;
    expect(ch.data, List.generate(250, (i) => i.toDouble())); // segments concatenated
    expect(ch.properties['wf_increment'], closeTo(0.001, 1e-12)); // 1/rate
  });

  test('maps every format to its compact on-disk TdsType', () {
    expect(tdsTypeFor(DaqSampleFormat.volts), TdsType.doubleFloat);
    expect(tdsTypeFor(DaqSampleFormat.rawI16), TdsType.i16);
    expect(tdsTypeFor(DaqSampleFormat.rawI32), TdsType.i32);
    expect(tdsTypeFor(DaqSampleFormat.rawU16), TdsType.u16);
    expect(tdsTypeFor(DaqSampleFormat.rawU32), TdsType.u32);
  });

  group('end-to-end: FFI shim stream -> TDMS', () {
    final lib = buildFakeDaqmxLib();

    test('a real i16 acquisition lands in TDMS as a ramp', () async {
      final daq = FfiDaqmxBackend(libraryPath: lib!);
      final stream = daq.readRawI16Stream('Dev1/ai0', rateHz: 5000, samplesPerChunk: 64, totalSamples: 200);
      final bytes = await recordStreamToTdms(
        stream,
        format: DaqSampleFormat.rawI16,
        group: 'AI',
        channel: 'ai0',
        rateHz: 5000,
      );
      await daq.close();

      final ch = TdmsReader.read(bytes).group('AI')!.channel('ai0')!;
      expect(ch.data, List.generate(200, (i) => i.toDouble()));
      expect(ch.properties['wf_increment'], closeTo(1 / 5000, 1e-12));
    }, skip: lib == null ? 'no C compiler available' : false);
  });
}
