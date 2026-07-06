// End-to-end tests for the gRPC backend against an in-process fake NI gRPC Device
// Server over a real loopback channel — they exercise the actual wire path and the
// CreateTask -> ConfigureChannel -> Read/Write -> ClearTask session model.

import 'dart:typed_data';

import 'package:grpc/grpc.dart';
import 'package:labwright_nidaqmx/labwright_nidaqmx.dart';
import 'package:test/test.dart';

import 'fake_ni_server.dart';

void main() {
  late FakeNiServer server;
  late DaqmxApi daq;

  Future<void> startWith({
    FakeDaqmxService? daqmx,
    FakeUtilitiesService? utilities,
    Duration callTimeout = const Duration(seconds: 30),
  }) async {
    server = await FakeNiServer.start(daqmx: daqmx, utilities: utilities);
    daq = Daqmx.remote(host: '127.0.0.1', port: server.port, callTimeout: callTimeout);
  }

  tearDown(() async {
    await daq.close();
    await server.stop();
  });

  group('deviceNames', () {
    test('returns the server\'s enumerated devices', () async {
      await startWith(utilities: FakeUtilitiesService(devices: ['cDAQ9', 'cDAQ9Mod3']));
      expect(await daq.deviceNames(), ['cDAQ9', 'cDAQ9Mod3']);
    });

    test('drops empty names', () async {
      await startWith(utilities: FakeUtilitiesService(devices: ['cDAQ1', '', 'cDAQ1Mod1']));
      expect(await daq.deviceNames(), ['cDAQ1', 'cDAQ1Mod1']);
    });

    test('returns [] when the server reports no devices', () async {
      await startWith(utilities: FakeUtilitiesService(devices: []));
      expect(await daq.deviceNames(), isEmpty);
    });
  });

  group('readVoltage', () {
    test('drives the full session model and returns the value', () async {
      final fake = FakeDaqmxService()..channelValues['cDAQ1Mod1/ai0'] = 3.14;
      await startWith(daqmx: fake);

      final v = await daq.readVoltage('cDAQ1Mod1/ai0');

      expect(v, 3.14);
      expect(fake.createTaskCount, 1);
      expect(fake.createdAiChannels, ['cDAQ1Mod1/ai0']);
      expect(fake.clearedTasks, hasLength(1)); // task always cleared
    });

    test('sends documented defaults on the wire', () async {
      final fake = FakeDaqmxService();
      await startWith(daqmx: fake);
      await daq.readVoltage('cDAQ1Mod1/ai0');
      expect(fake.aiConfigs.single.min, -10);
      expect(fake.aiConfigs.single.max, 10);
      expect(fake.aiConfigs.single.termCfg, DaqmxVal.cfgDefault);
      expect(fake.aiConfigs.single.units, DaqmxVal.volts);
      expect(fake.readTimeouts.single, 10);
    });

    test('forwards custom min/max/terminalConfig/timeout on the wire', () async {
      final fake = FakeDaqmxService();
      await startWith(daqmx: fake);
      await daq.readVoltage('cDAQ1Mod1/ai0', min: -5, max: 5, terminalConfig: DaqmxVal.diff, timeout: 2.5);
      expect(fake.aiConfigs.single.min, -5);
      expect(fake.aiConfigs.single.max, 5);
      expect(fake.aiConfigs.single.termCfg, DaqmxVal.diff);
      expect(fake.readTimeouts.single, 2.5);
    });

    test('a read-status error maps to DaqmxException and still clears the task', () async {
      final fake = FakeDaqmxService()..failReadStatus = -200279;
      await startWith(daqmx: fake);
      await expectLater(
        daq.readVoltage('cDAQ1Mod1/ai0'),
        throwsA(isA<DaqmxException>().having((e) => e.operation, 'op', 'DAQmxReadAnalogScalarF64')),
      );
      expect(fake.clearedTasks, hasLength(1));
    });

    test('a CreateTask failure maps to DaqmxException and configures no channel', () async {
      final fake = FakeDaqmxService()..failCreateTaskStatus = -50103;
      await startWith(daqmx: fake);
      await expectLater(
        daq.readVoltage('cDAQ1Mod1/ai0'),
        throwsA(isA<DaqmxException>().having((e) => e.operation, 'op', 'DAQmxCreateTask')),
      );
      expect(fake.createdAiChannels, isEmpty);
    });

    test('a positive DAQmx warning does not throw and the reading is returned', () async {
      final fake = FakeDaqmxService()
        ..failAiChanStatus =
            200015 // warning code (>0)
        ..channelValues['cDAQ1Mod1/ai0'] = 7.0;
      await startWith(daqmx: fake);
      expect(await daq.readVoltage('cDAQ1Mod1/ai0'), 7.0);
    });
  });

  group('writeVoltage', () {
    test('configures AO, writes (autoStart), and clears the task', () async {
      final fake = FakeDaqmxService();
      await startWith(daqmx: fake);

      await daq.writeVoltage('cDAQ1Mod2/ao0', 2.5, timeout: 4);

      expect(fake.createdAoChannels, ['cDAQ1Mod2/ao0']);
      expect(fake.writes, hasLength(1));
      expect(fake.writes.single.channel, 'cDAQ1Mod2/ao0');
      expect(fake.writes.single.value, 2.5);
      expect(fake.writes.single.autoStart, isTrue);
      expect(fake.writes.single.timeout, 4);
      expect(fake.clearedTasks, hasLength(1));
    });

    test('an AO-channel error maps to DaqmxException and clears the task', () async {
      final fake = FakeDaqmxService()..failAoChanStatus = -200170;
      await startWith(daqmx: fake);
      await expectLater(
        daq.writeVoltage('cDAQ1Mod2/ao0', 1.0),
        throwsA(isA<DaqmxException>().having((e) => e.operation, 'op', 'DAQmxCreateAOVoltageChan')),
      );
      expect(fake.clearedTasks, hasLength(1));
    });

    test('a write error maps to DaqmxException and clears the task', () async {
      final fake = FakeDaqmxService()..failWriteStatus = -200279;
      await startWith(daqmx: fake);
      await expectLater(
        daq.writeVoltage('cDAQ1Mod2/ao0', 1.0),
        throwsA(isA<DaqmxException>().having((e) => e.operation, 'op', 'DAQmxWriteAnalogScalarF64')),
      );
      expect(fake.clearedTasks, hasLength(1));
    });
  });

  group('error text', () {
    test('negative status carries the server error string', () async {
      final fake = FakeDaqmxService()..failAiChanStatus = -200279;
      await startWith(daqmx: fake);
      await expectLater(
        daq.readVoltage('cDAQ1Mod1/ai0'),
        throwsA(
          isA<DaqmxException>()
              .having((e) => e.status, 'status', -200279)
              .having((e) => e.message, 'message', contains('Simulated DAQmx error'))
              .having((e) => e.operation, 'op', 'DAQmxCreateAIVoltageChan'),
        ),
      );
    });

    test('empty server error string falls back to the status code', () async {
      final fake = FakeDaqmxService()
        ..failAiChanStatus = -200279
        ..emptyErrorString = true;
      await startWith(daqmx: fake);
      await expectLater(
        daq.readVoltage('cDAQ1Mod1/ai0'),
        throwsA(isA<DaqmxException>().having((e) => e.message, 'message', 'DAQmx status -200279')),
      );
    });

    test('a failed error-string lookup falls back to "unavailable"', () async {
      final fake = FakeDaqmxService()
        ..failAiChanStatus = -200279
        ..throwOnGetErrorString = true;
      await startWith(daqmx: fake);
      await expectLater(
        daq.readVoltage('cDAQ1Mod1/ai0'),
        throwsA(isA<DaqmxException>().having((e) => e.message, 'message', contains('error text unavailable'))),
      );
    });

    test('errorInfo() resolves text for the success code (empty when healthy)', () async {
      await startWith();
      expect(await daq.errorInfo(), isEmpty);
    });
  });

  group('transport & lifecycle', () {
    test('an unreachable server surfaces DaqmxUnavailable, not a raw GrpcError', () async {
      await startWith();
      await server.stop();
      await expectLater(daq.deviceNames(), throwsA(isA<DaqmxUnavailable>()));
    });

    test(
      'a hung server is bounded by callTimeout and surfaces DaqmxUnavailable',
      () async {
        await startWith(
          utilities: FakeUtilitiesService(hang: true),
          callTimeout: const Duration(milliseconds: 300),
        );
        await expectLater(daq.deviceNames(), throwsA(isA<DaqmxUnavailable>()));
      },
      timeout: const Timeout(Duration(seconds: 10)),
    );

    test('close() is idempotent', () async {
      await startWith();
      await daq.deviceNames();
      await daq.close();
      await daq.close(); // must not throw
    });

    test('using the backend after close() throws StateError', () async {
      await startWith();
      await daq.close();
      expect(daq.deviceNames(), throwsA(isA<StateError>()));
    });

    test('fromChannel uses the injected channel', () async {
      server = await FakeNiServer.start();
      final channel = ClientChannel(
        '127.0.0.1',
        port: server.port,
        options: const ChannelOptions(credentials: ChannelCredentials.insecure()),
      );
      daq = GrpcDaqmxBackend.fromChannel(channel);
      expect((daq as GrpcDaqmxBackend).host, '(injected)');
      expect(await daq.readVoltage('cDAQ1Mod1/ai0'), isA<double>());
    });

    test('concurrent reads on different channels do not cross-contaminate', () async {
      final fake = FakeDaqmxService()
        ..channelValues['ai0'] = 1.0
        ..channelValues['ai1'] = 2.0;
      await startWith(daqmx: fake);
      final results = await Future.wait([daq.readVoltage('ai0'), daq.readVoltage('ai1')]);
      expect(results, containsAll([1.0, 2.0]));
      expect(fake.createTaskCount, 2); // a distinct task per concurrent call
    });
  });

  group('moniker streaming (in-band gRPC)', () {
    test('finite f64 stream: Begin -> StreamRead -> unpack Any -> ramp', () async {
      await startWith();
      final chunks = await daq
          .readVoltageStream('cDAQ1Mod1/ai0', rateHz: 1000, samplesPerChunk: 50, totalSamples: 200)
          .toList();
      final all = chunks.expand((c) => c).toList();
      expect(all.length, 200);
      expect(all, List.generate(200, (i) => i.toDouble()));
      expect(server.daqmx.lastStreamRate, 1000); // rate set from Dart reached CfgSampClkTiming
      expect(server.daqmx.lastStreamModeRaw, DaqmxVal.finiteSamps);
    });

    test('raw i16 stream yields Int16List chunks over the wire', () async {
      await startWith();
      final chunks = await daq
          .readRawI16Stream('cDAQ1Mod1/ai0', rateHz: 2000, samplesPerChunk: 64, totalSamples: 256)
          .toList();
      expect(chunks, everyElement(isA<Int16List>()));
      expect(chunks.expand((c) => c).toList(), List.generate(256, (i) => i));
    });

    test('continuous stream stops cleanly when the subscription is cancelled', () async {
      await startWith();
      final got = await daq
          .readStream('cDAQ1Mod1/ai0', rateHz: 100000, samplesPerChunk: 10, format: DaqSampleFormat.rawI16)
          .take(3)
          .toList(); // take(3) cancels -> server stream torn down, task cleared
      expect(got, hasLength(3));
      expect((got.first as Int16List).toList(), List.generate(10, (i) => i));
    });

    test('a non-gRPC sideband strategy throws UnsupportedError', () {
      final remote = Daqmx.remote(host: '127.0.0.1', port: 1, sideband: SidebandStrategy.sockets);
      expect(
        () => remote.readStream('ai0', rateHz: 1000),
        throwsA(isA<UnsupportedError>()),
      );
    });
  });
}
