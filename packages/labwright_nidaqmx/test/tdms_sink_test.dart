// DAQ-stream -> TDMS bridge: chunks become segments, raw integer formats keep
// their compact TdsType, and the bytes round-trip through the TDMS reader.

@TestOn('!windows')
library;

import 'dart:typed_data';

import 'package:labwright_nidaqmx/labwright_nidaqmx.dart';
import 'package:labwright_tdms/labwright_tdms.dart';
import 'package:test/test.dart';

import 'fake_daqmx_lib.dart';

void main() {
  test('records an i16 stream as compact i16 TDMS segments that round-trip', () async {
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
    final ch = TdmsReader.read(bytes).group('AI')!.channel('Dev1/ai0')!;
    expect(ch.data, List.generate(250, (i) => i.toDouble()), reason: 'segments concatenate');
    expect(ch.properties['wf_increment'], closeTo(0.001, 1e-12), reason: '1/rate');
  });

  test('maps every format to its compact on-disk TdsType', () {
    const want = {
      DaqSampleFormat.volts: TdsType.doubleFloat,
      DaqSampleFormat.rawI16: TdsType.i16,
      DaqSampleFormat.rawI32: TdsType.i32,
      DaqSampleFormat.rawU16: TdsType.u16,
      DaqSampleFormat.rawU32: TdsType.u32,
    };
    expect(want.keys.toSet(), DaqSampleFormat.values.toSet(), reason: 'every format has a row');
    want.forEach((format, type) => expect(tdsTypeFor(format), type, reason: '$format'));
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
