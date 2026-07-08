// GrpcDaqmxBackend end-to-end against an in-process fake NI gRPC Device Server
// over a real loopback channel: the actual wire path and the
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
    // dart format off
    const rows = <(String, List<String>, List<String>)>[
      ('returns the server\'s enumerated devices', ['cDAQ9', 'cDAQ9Mod3'], ['cDAQ9', 'cDAQ9Mod3']),
      ('drops empty names', ['cDAQ1', '', 'cDAQ1Mod1'], ['cDAQ1', 'cDAQ1Mod1']),
      ('returns [] when the server reports no devices', [], []),
      ('returns [] when every name is empty', ['', ''], []),
    ];
    // dart format on
    for (final (name, devices, want) in rows) {
      test(name, () async {
        await startWith(utilities: FakeUtilitiesService(devices: devices));
        expect(await daq.deviceNames(), want);
      });
    }
  });

  test('readVoltage drives the full session model and returns the value', () async {
    final fake = FakeDaqmxService()..channelValues['cDAQ1Mod1/ai0'] = 3.14;
    await startWith(daqmx: fake);
    expect(await daq.readVoltage('cDAQ1Mod1/ai0'), 3.14);
    expect(fake.createTaskCount, 1);
    expect(fake.createdAiChannels, ['cDAQ1Mod1/ai0']);
    expect(fake.clearedTasks, hasLength(1), reason: 'the task is always cleared');
  });

  test('readVoltage wire config: documented defaults, then custom values forwarded', () async {
    final fake = FakeDaqmxService();
    await startWith(daqmx: fake);
    await daq.readVoltage('cDAQ1Mod1/ai0');
    await daq.readVoltage('cDAQ1Mod1/ai0', min: -5, max: 5, terminalConfig: DaqmxVal.diff, timeout: 2.5);
    expect(fake.aiConfigs, [
      (min: -10.0, max: 10.0, termCfg: DaqmxVal.cfgDefault, units: DaqmxVal.volts),
      (min: -5.0, max: 5.0, termCfg: DaqmxVal.diff, units: DaqmxVal.volts),
    ]);
    expect(fake.readTimeouts, [10.0, 2.5]);
  });

  test('a positive DAQmx warning does not throw and the reading is returned', () async {
    final fake = FakeDaqmxService()
      ..failAiChanStatus = 200015
      ..channelValues['cDAQ1Mod1/ai0'] = 7.0;
    await startWith(daqmx: fake);
    expect(await daq.readVoltage('cDAQ1Mod1/ai0'), 7.0);
  });

  test('writeVoltage configures AO, writes with autoStart, and clears the task', () async {
    final fake = FakeDaqmxService();
    await startWith(daqmx: fake);
    await daq.writeVoltage('cDAQ1Mod2/ao0', 2.5, timeout: 4);
    expect(fake.createdAoChannels, ['cDAQ1Mod2/ao0']);
    expect(fake.writes, [(channel: 'cDAQ1Mod2/ao0', value: 2.5, autoStart: true, timeout: 4.0)]);
    expect(fake.clearedTasks, hasLength(1));
  });

  group('DAQmx error statuses map to DaqmxException naming the operation', () {
    // (name, inject, failing op, call is a write, tasks cleared afterwards)
    // dart format off
    final rows = <(String, void Function(FakeDaqmxService), String, bool, int)>[
      ('read status error still clears the task', (f) => f.failReadStatus = -200279, 'DAQmxReadAnalogScalarF64', false, 1),
      ('CreateTask failure has no task to clear', (f) => f.failCreateTaskStatus = -50103, 'DAQmxCreateTask', false, 0),
      ('AI-channel error still clears the task', (f) => f.failAiChanStatus = -200279, 'DAQmxCreateAIVoltageChan', false, 1),
      ('AO-channel error still clears the task', (f) => f.failAoChanStatus = -200170, 'DAQmxCreateAOVoltageChan', true, 1),
      ('write error still clears the task', (f) => f.failWriteStatus = -200279, 'DAQmxWriteAnalogScalarF64', true, 1),
    ];
    // dart format on
    for (final (name, inject, op, viaWrite, cleared) in rows) {
      test(name, () async {
        final fake = FakeDaqmxService();
        inject(fake);
        await startWith(daqmx: fake);
        await expectLater(
          viaWrite ? daq.writeVoltage('cDAQ1Mod2/ao0', 1.0) : daq.readVoltage('cDAQ1Mod1/ai0'),
          throwsA(isA<DaqmxException>().having((e) => e.operation, 'op', op)),
        );
        expect(fake.clearedTasks, hasLength(cleared));
        if (op == 'DAQmxCreateTask') expect(fake.createdAiChannels, isEmpty);
      });
    }
  });

  group('error text', () {
    // dart format off
    final rows = <(String, void Function(FakeDaqmxService), Matcher)>[
      ('negative status carries the server error string', (_) {}, contains('Simulated DAQmx error')),
      ('empty server error string falls back to the status code', (f) => f.emptyErrorString = true, equals('DAQmx status -200279')),
      ('a failed error-string lookup falls back to "unavailable"', (f) => f.throwOnGetErrorString = true, contains('error text unavailable')),
    ];
    // dart format on
    for (final (name, mutate, message) in rows) {
      test(name, () async {
        final fake = FakeDaqmxService()..failAiChanStatus = -200279;
        mutate(fake);
        await startWith(daqmx: fake);
        await expectLater(
          daq.readVoltage('cDAQ1Mod1/ai0'),
          throwsA(
            isA<DaqmxException>()
                .having((e) => e.status, 'status', -200279)
                .having((e) => e.message, 'message', message)
                .having((e) => e.operation, 'op', 'DAQmxCreateAIVoltageChan'),
          ),
        );
      });
    }

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
        await startWith(utilities: FakeUtilitiesService(hang: true), callTimeout: const Duration(milliseconds: 300));
        await expectLater(daq.deviceNames(), throwsA(isA<DaqmxUnavailable>()));
      },
      timeout: const Timeout(Duration(seconds: 10)),
    );

    test('close() is idempotent; use after close() throws StateError', () async {
      await startWith();
      await daq.deviceNames();
      await daq.close();
      await daq.close(); // must not throw
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
      expect(await Future.wait([daq.readVoltage('ai0'), daq.readVoltage('ai1')]), containsAll([1.0, 2.0]));
      expect(fake.createTaskCount, 2, reason: 'a distinct task per concurrent call');
    });
  });

  group('moniker streaming (in-band gRPC)', () {
    test('finite f64 stream: Begin -> StreamRead -> unpack Any -> ramp', () async {
      await startWith();
      final chunks = await daq
          .readVoltageStream('cDAQ1Mod1/ai0', rateHz: 1000, samplesPerChunk: 50, totalSamples: 200)
          .toList();
      expect(chunks.expand((c) => c).toList(), List.generate(200, (i) => i.toDouble()));
      expect(server.daqmx.lastStreamRate, 1000, reason: 'the Dart rate reached CfgSampClkTiming');
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
          .take(3) // cancels -> server stream torn down, task cleared
          .toList();
      expect(got, hasLength(3));
      expect((got.first as Int16List).toList(), List.generate(10, (i) => i));
    });

    test('a non-gRPC sideband strategy throws UnsupportedError', () {
      final remote = Daqmx.remote(host: '127.0.0.1', port: 1, sideband: SidebandStrategy.sockets);
      expect(() => remote.readStream('ai0', rateHz: 1000), throwsA(isA<UnsupportedError>()));
    });
  });
}
