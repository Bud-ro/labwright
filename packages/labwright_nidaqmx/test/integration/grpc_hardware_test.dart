// Integration tests for the gRPC backend against a REAL NI gRPC Device Server (which
// itself can sit on top of NI MAX simulated devices). Self-skips unless NI_GRPC_HOST is
// set. Start the server on a Windows/Linux host with NI-DAQmx, then:
//
//   NI_GRPC_HOST=192.168.1.50 [NI_GRPC_PORT=31763] NI_GRPC_AI_CHANNEL=Dev1/ai0 \
//   dart test -t hardware packages/labwright_nidaqmx/test/integration/grpc_hardware_test.dart
//
// These exercise the moniker streaming path (Begin*Read -> StreamRead -> Any decode)
// against the real server — the assumption the fake-server tests stand in for.

@Tags(['hardware'])
@TestOn('!browser')
library;

import 'dart:io';

import 'package:labwright_nidaqmx/labwright_nidaqmx.dart';
import 'package:test/test.dart';

void main() {
  final host = Platform.environment['NI_GRPC_HOST'];
  final port = int.tryParse(Platform.environment['NI_GRPC_PORT'] ?? '') ?? 31763;
  final ai = Platform.environment['NI_GRPC_AI_CHANNEL'] ?? Platform.environment['DAQMX_AI_CHANNEL'];
  final skip = (host == null || ai == null)
      ? 'set NI_GRPC_HOST and NI_GRPC_AI_CHANNEL to run gRPC integration against a real server'
      : null;

  group('gRPC backend against a live NI gRPC Device Server', () {
    late DaqmxApi daq;
    setUp(() => daq = Daqmx.remote(host: host!, port: port));
    tearDown(() => daq.close());

    test('enumerates at least one device', () async {
      expect(await daq.deviceNames(), isNotEmpty);
    });

    test('scalar AI read returns a finite voltage', () async {
      expect((await daq.readVoltage(ai!)).isFinite, isTrue);
    });

    test('moniker streaming returns the requested samples', () async {
      // gRPC finite is whole-chunk granular; assert we reached at least totalSamples.
      final chunks = await daq
          .readVoltageStream(ai!, rateHz: 1000, samplesPerChunk: 100, totalSamples: 500)
          .toList();
      expect(chunks.expand((c) => c).length, greaterThanOrEqualTo(500));
    });

    test('continuous moniker stream yields then cancels cleanly', () async {
      final got =
          await daq.readVoltageStream(ai!, rateHz: 1000, samplesPerChunk: 100).take(3).toList();
      expect(got, hasLength(3));
    });

    test('a nonexistent channel raises DaqmxException', () async {
      await expectLater(
        daq.readVoltage('NoSuchDevice42/ai0'),
        throwsA(isA<DaqmxException>()),
      );
    });
  }, skip: skip);
}
