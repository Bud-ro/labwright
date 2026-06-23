import 'dart:convert';

import 'package:labwright_core/labwright_core.dart';
import 'package:labwright_daq/labwright_daq.dart';
import 'package:test/test.dart';

void main() {
  group('SimulatedDaq analog input', () {
    test('read returns the configured signal value; unconfigured reads 0', () async {
      final daq = SimulatedDaq(analogInputs: {0: Signals.constant(3.3)});
      expect(await daq.analogIn(0).read(), 3.3);
      expect(await daq.analogIn(1).read(), 0.0);
    });

    test('stream emits count samples with virtual timestamps and signal values', () async {
      final daq = SimulatedDaq(analogInputs: {0: Signals.ramp(voltsPerSecond: 10)});
      final samples = await daq.analogIn(0).stream(rateHz: 1000, count: 3).toList();
      expect(samples, hasLength(3));
      expect(samples[0].elapsed, Duration.zero);
      expect(samples[1].elapsed, const Duration(microseconds: 1000));
      expect(samples[0].value, closeTo(0.0, 1e-9));
      expect(samples[1].value, closeTo(0.01, 1e-9)); // 10 V/s * 1 ms
      expect(samples[2].value, closeTo(0.02, 1e-9));
    });

    test('setInput swaps the signal', () async {
      final daq = SimulatedDaq();
      expect(await daq.analogIn(0).read(), 0.0);
      daq.setInput(0, Signals.constant(5));
      expect(await daq.analogIn(0).read(), 5.0);
    });
  });

  group('SimulatedDaq output / digital / counter', () {
    test('analog out records the last value and full history', () async {
      final daq = SimulatedDaq();
      await daq.analogOut(2).write(1.5);
      await daq.analogOut(2).write(2.5);
      expect(daq.writtenAnalog[2], 2.5);
      expect(daq.analogWrites, hasLength(2));
      expect(daq.analogWrites.first.channel, 2);
    });

    test('digital line read/write', () async {
      final daq = SimulatedDaq();
      expect(await daq.digital.read(0), isFalse);
      await daq.digital.write(0, high: true);
      expect(await daq.digital.read(0), isTrue);
    });

    test('counter read/reset', () async {
      final daq = SimulatedDaq()..counters[0] = 42;
      expect(await daq.counter(0).read(), 42);
      await daq.counter(0).reset();
      expect(await daq.counter(0).read(), 0);
    });
  });

  test('plugs into a Test as a peripheral and gets opened/closed by the executor', () async {
    final daq = SimulatedDaq(analogInputs: {0: Signals.constant(3.3)});
    final test = Test(
      '3v3 rail',
      [
        Phase('measure rail', (ctx) async {
          final v = await ctx.peripheral<SimulatedDaq>().analogIn(0).read();
          ctx.measure<num>('rail', units: 'V', validators: [Validators.approx(3.3, 0.1)]).value = v;
        }),
      ],
      peripherals: {'daq': daq},
    );
    final rec = await test.run(dutId: 'DUT-1');
    expect(rec.outcome, Outcome.pass);
    expect(rec.phases.single.measurements.single.value, 3.3);
    expect(daq.isOpen, isFalse); // executor opened it, then closed it
  });

  group('record / replay', () {
    Test buildTest(Map<String, Peripheral> peripherals) => Test(
          'rec',
          [
            Phase('acquire', (ctx) async {
              final daq = ctx.peripheral<DaqDevice>();
              final samples = await daq.analogIn(0).stream(rateHz: 1000, count: 3).toList();
              final fixed = await daq.analogIn(1).read();
              ctx.measure<num>('last', validators: [Validators.inRange(-1, 1)]).value = samples.last.value;
              ctx.measure<num>('fixed').value = fixed;
            }),
          ],
          peripherals: peripherals,
        );

    test('replay reproduces recorded reads without the original device', () async {
      final sim = SimulatedDaq(analogInputs: {0: Signals.ramp(voltsPerSecond: 1), 1: Signals.constant(5)});
      final recording = RecordingDaq(sim);
      final r1 = await buildTest({'daq': recording}).run(dutId: 'D');

      final replay = ReplayDaq(recording.trace);
      final r2 = await buildTest({'daq': replay}).run(dutId: 'D');

      expect(r2.outcome, r1.outcome);
      expect(
        r2.phases.single.measurements.map((m) => m.value).toList(),
        r1.phases.single.measurements.map((m) => m.value).toList(),
      );
    });

    test('trace round-trips through JSON and still replays', () async {
      final sim = SimulatedDaq(analogInputs: {0: Signals.ramp(voltsPerSecond: 1), 1: Signals.constant(5)});
      final recording = RecordingDaq(sim);
      await buildTest({'daq': recording}).run(dutId: 'D');

      final json = jsonDecode(jsonEncode(recording.trace.toJson())) as Map<String, Object?>;
      final replay = ReplayDaq(DaqTrace.fromJson(json));
      final r = await buildTest({'daq': replay}).run(dutId: 'D');
      expect(r.outcome, Outcome.pass);
    });

    test('replay errors out if the test asks for an unrecorded read', () async {
      final replay = ReplayDaq(DaqTrace());
      final test = Test(
        'diverged',
        [Phase('p', (ctx) async => ctx.peripheral<DaqDevice>().analogIn(0).read())],
        peripherals: {'daq': replay},
      );
      final rec = await test.run(dutId: 'D');
      expect(rec.outcome, Outcome.error);
      expect(rec.phases.single.error, contains('replay'));
    });
  });
}
