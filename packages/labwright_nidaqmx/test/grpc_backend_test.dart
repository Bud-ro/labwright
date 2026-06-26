// End-to-end tests for the gRPC backend against an in-process fake NI gRPC Device
// Server over a real loopback channel — they exercise the actual wire path and the
// CreateTask -> ConfigureChannel -> Read/Write -> ClearTask session model.

import 'package:labwright_nidaqmx/labwright_nidaqmx.dart';
import 'package:test/test.dart';

import 'fake_ni_server.dart';

void main() {
  late FakeNiServer server;
  late DaqmxApi daq;

  Future<void> startWith({FakeDaqmxService? daqmx, FakeUtilitiesService? utilities}) async {
    server = await FakeNiServer.start(daqmx: daqmx, utilities: utilities);
    daq = Daqmx.remote(host: '127.0.0.1', port: server.port);
  }

  tearDown(() async {
    await daq.close();
    await server.stop();
  });

  test('deviceNames() returns the server\'s enumerated devices', () async {
    await startWith(utilities: FakeUtilitiesService(devices: ['cDAQ9', 'cDAQ9Mod3']));
    expect(await daq.deviceNames(), ['cDAQ9', 'cDAQ9Mod3']);
  });

  test('deviceNames() drops empty names', () async {
    await startWith(utilities: FakeUtilitiesService(devices: ['cDAQ1', '', 'cDAQ1Mod1']));
    expect(await daq.deviceNames(), ['cDAQ1', 'cDAQ1Mod1']);
  });

  test('readVoltage() drives the full session model and returns the value', () async {
    final fake = FakeDaqmxService()..channelValues['cDAQ1Mod1/ai0'] = 3.14;
    await startWith(daqmx: fake);

    final v = await daq.readVoltage('cDAQ1Mod1/ai0');

    expect(v, 3.14);
    expect(fake.createTaskCount, 1);
    expect(fake.createdAiChannels, ['cDAQ1Mod1/ai0']);
    expect(fake.clearedTasks, hasLength(1)); // task always cleared
  });

  test('writeVoltage() configures AO, writes, and clears the task', () async {
    final fake = FakeDaqmxService();
    await startWith(daqmx: fake);

    await daq.writeVoltage('cDAQ1Mod2/ao0', 2.5);

    expect(fake.createdAoChannels, ['cDAQ1Mod2/ao0']);
    expect(fake.writes, hasLength(1));
    expect(fake.writes.single.channel, 'cDAQ1Mod2/ao0');
    expect(fake.writes.single.value, 2.5);
    expect(fake.clearedTasks, hasLength(1));
  });

  test('a negative DAQmx status becomes a DaqmxException with the server error text', () async {
    final fake = FakeDaqmxService()..failAiChanStatus = -200279;
    await startWith(daqmx: fake);

    await expectLater(
      daq.readVoltage('cDAQ1Mod1/ai0'),
      throwsA(isA<DaqmxException>()
          .having((e) => e.status, 'status', -200279)
          .having((e) => e.message, 'message', contains('Simulated DAQmx error'))
          .having((e) => e.operation, 'operation', 'DAQmxCreateAIVoltageChan')),
    );
    // Even on failure the task is cleared (finally block).
    expect(fake.clearedTasks, hasLength(1));
  });

  test('errorInfo() resolves text for the success code (empty when healthy)', () async {
    await startWith();
    expect(await daq.errorInfo(), isEmpty);
  });

  test('an unreachable server surfaces DaqmxUnavailable, not a raw GrpcError', () async {
    // Connect to the server, then stop it so the RPC fails at the transport layer.
    await startWith();
    await server.stop();
    await expectLater(daq.deviceNames(), throwsA(isA<DaqmxUnavailable>()));
  });
}
