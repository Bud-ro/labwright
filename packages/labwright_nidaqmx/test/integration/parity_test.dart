// Cross-backend parity: the headline promise is "same API, two transports." When BOTH
// a real NI-DAQmx runtime (DAQMX_AI_CHANNEL) and a real NI gRPC Device Server
// (NI_GRPC_HOST) point at the same device, assert FFI and gRPC agree. Self-skips unless
// both are configured.
//
//   DAQMX_AI_CHANNEL=Dev1/ai0 NI_GRPC_HOST=localhost NI_GRPC_AI_CHANNEL=Dev1/ai0 \
//   dart test -t hardware packages/labwright_nidaqmx/test/integration/parity_test.dart

@Tags(['hardware'])
@TestOn('!browser')
library;

import 'dart:io';

import 'package:labwright_nidaqmx/labwright_nidaqmx.dart';
import 'package:test/test.dart';

void main() {
  final ai = Platform.environment['DAQMX_AI_CHANNEL'];
  final host = Platform.environment['NI_GRPC_HOST'];
  final port = int.tryParse(Platform.environment['NI_GRPC_PORT'] ?? '') ?? 31763;
  final grpcAi = Platform.environment['NI_GRPC_AI_CHANNEL'] ?? ai;
  final skip = (ai == null || host == null)
      ? 'set DAQMX_AI_CHANNEL and NI_GRPC_HOST (same device) to run FFI<->gRPC parity'
      : null;

  group('FFI vs gRPC parity on the same device', () {
    late DaqmxApi local;
    late DaqmxApi remote;
    setUp(() {
      local = Daqmx.local(libraryPath: Platform.environment['DAQMX_LIB']);
      remote = Daqmx.remote(host: host!, port: port);
    });
    tearDown(() async {
      await local.close();
      await remote.close();
    });

    test('both enumerate the same devices', () async {
      expect((await local.deviceNames()).toSet(), (await remote.deviceNames()).toSet());
    });

    test('both return a finite voltage for the same channel', () async {
      expect((await local.readVoltage(ai!)).isFinite, isTrue);
      expect((await remote.readVoltage(grpcAi!)).isFinite, isTrue);
    });
  }, skip: skip);
}
