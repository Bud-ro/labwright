import 'package:labwright_core/labwright_core.dart';
import 'package:test/test.dart';

/// A fake peripheral that records its lifecycle, for asserting open/close order.
class _RecordingPeripheral extends Peripheral {
  _RecordingPeripheral(this.name, this.events);
  @override
  final String name;
  final List<String> events;
  bool failOnOpen = false;

  @override
  Future<void> open() async {
    if (failOnOpen) throw StateError('boom');
    events.add('open:$name');
  }

  @override
  Future<void> close() async => events.add('close:$name');
}

void main() {
  test('ABI version is the documented baseline', () {
    expect(labwrightAbiVersion, 0);
  });

  group('Validators', () {
    test('inRange inclusive vs exclusive', () {
      expect(Validators.inRange(0, 5)(5).passed, isTrue);
      expect(Validators.inRange(0, 5, inclusive: false)(5).passed, isFalse);
    });
    test('approx tolerance', () {
      expect(Validators.approx(3.3, 0.1)(3.39).passed, isTrue);
      expect(Validators.approx(3.3, 0.1)(3.5).passed, isFalse);
    });
    test('limit text is recorded', () {
      expect(Validators.lessThan(10)(3).limit, '< 10');
    });
    test('notEquals', () {
      expect(Validators.notEquals(0)(0).passed, isFalse);
      expect(Validators.notEquals(0)(1).passed, isTrue);
      expect(Validators.notEquals('x')('y').limit, '!= x');
    });
    test('isOneOf accepts allow-listed values and records the set', () {
      final v = Validators.isOneOf(['A', 'B', 'C']);
      expect(v('B').passed, isTrue);
      expect(v('Z').passed, isFalse);
      expect(v('Z').limit, 'one of {A, B, C}');
      // tolerates a one-shot iterable
      final w = Validators.isOneOf([1, 2, 3].where((n) => n.isOdd));
      expect(w(3).passed, isTrue);
      expect(w(2).passed, isFalse);
    });
    test('outsideRange inclusive vs exclusive', () {
      expect(Validators.outsideRange(0, 5)(6).passed, isTrue);
      expect(Validators.outsideRange(0, 5)(3).passed, isFalse);
      expect(Validators.outsideRange(0, 5)(5).passed, isFalse); // boundary inside the band
      expect(Validators.outsideRange(0, 5, inclusive: false)(5).passed, isTrue); // boundary excluded from band
      expect(Validators.outsideRange(0, 5)(6).limit, 'outside [0, 5]');
    });
  });

  group('Measurement', () {
    test('passes when all validators pass', () {
      final m = Measurement<num>('v', units: 'V', validators: [Validators.inRange(0, 5)]);
      m.value = 3.3;
      final r = m.toRecord();
      expect(r.outcome, Outcome.pass);
      expect(r.value, 3.3);
      expect(r.failedLimits, isEmpty);
    });
    test('fails and reports the violated limit', () {
      final m = Measurement<num>('v', validators: [Validators.atMost(5), Validators.atLeast(1)]);
      m.value = 9;
      final r = m.toRecord();
      expect(r.outcome, Outcome.fail);
      expect(r.failedLimits, ['<= 5']);
    });
    test('unset measurement is an error, not a pass', () {
      final r = Measurement<num>('v').toRecord();
      expect(r.outcome, Outcome.error);
      expect(r.isSet, isFalse);
    });
    test('reading an unset value throws', () {
      expect(() => Measurement<num>('v').value, throwsStateError);
    });
  });

  group('Outcome combination', () {
    test('worst wins', () {
      expect(combineOutcomes([Outcome.pass, Outcome.fail, Outcome.skip]), Outcome.fail);
      expect(combineOutcomes([Outcome.pass, Outcome.error]), Outcome.error);
      expect(combineOutcomes([Outcome.pass, Outcome.skip]), Outcome.pass);
    });
    test('empty fallback', () {
      expect(combineOutcomes([], empty: Outcome.pass), Outcome.pass);
    });
    test('fromName parses every name and round-trips', () {
      for (final o in Outcome.values) {
        expect(Outcome.fromName(o.name), o);
      }
      expect(Outcome.fromName('bogus'), Outcome.error); // default fallback
      expect(Outcome.fromName(null), Outcome.error);
      expect(Outcome.fromName(42), Outcome.error); // non-string
      expect(Outcome.fromName('nope', fallback: Outcome.skip), Outcome.skip);
    });
  });

  group('Test executor', () {
    test('all phases pass -> test passes', () async {
      final test = Test('demo', [
        Phase('measure', (ctx) async {
          ctx.measure<num>('v', validators: [Validators.inRange(0, 5)]).value = 3.3;
        }),
      ]);
      final rec = await test.run(dutId: 'DUT-1');
      expect(rec.outcome, Outcome.pass);
      expect(rec.dutId, 'DUT-1');
      expect(rec.phases.single.measurements.single.value, 3.3);
    });

    test('a failing measurement fails the phase and test', () async {
      final test = Test('demo', [
        Phase('measure', (ctx) async {
          ctx.measure<num>('v', validators: [Validators.atMost(5)]).value = 9;
        }),
      ]);
      final rec = await test.run(dutId: 'DUT-1');
      expect(rec.outcome, Outcome.fail);
    });

    test('a thrown exception is an error outcome', () async {
      final test = Test('demo', [
        Phase('boom', (ctx) async => throw StateError('nope')),
      ]);
      final rec = await test.run(dutId: 'DUT-1');
      expect(rec.outcome, Outcome.error);
      expect(rec.phases.single.error, contains('nope'));
    });

    test('continueOnFailure:false aborts and skips the rest', () async {
      var ranSecond = false;
      final test = Test('demo', [
        Phase('gate', (ctx) async {
          ctx.measure<num>('v', validators: [Validators.atMost(5)]).value = 9;
        }, continueOnFailure: false),
        Phase('after', (ctx) async => ranSecond = true),
      ]);
      final rec = await test.run(dutId: 'DUT-1');
      expect(ranSecond, isFalse);
      expect(rec.phases[1].outcome, Outcome.skip);
      expect(rec.outcome, Outcome.fail);
    });

    test('peripherals open before phases and close after, in reverse', () async {
      final events = <String>[];
      final test = Test(
        'demo',
        [
          Phase('use', (ctx) async {
            ctx.peripheral<_RecordingPeripheral>('a');
            events.add('phase');
          }),
        ],
        peripherals: {
          'a': _RecordingPeripheral('a', events),
          'b': _RecordingPeripheral('b', events),
        },
      );
      await test.run(dutId: 'DUT-1');
      expect(events, ['open:a', 'open:b', 'phase', 'close:b', 'close:a']);
    });

    test('peripheral open failure is a setup error', () async {
      final events = <String>[];
      final bad = _RecordingPeripheral('a', events)..failOnOpen = true;
      final test = Test('demo', [Phase('noop', (ctx) async {})], peripherals: {'a': bad});
      final rec = await test.run(dutId: 'DUT-1');
      expect(rec.outcome, Outcome.error);
      expect(rec.error, contains('peripheral open failed'));
    });

    test('record serializes to JSON', () async {
      final test = Test('demo', [
        Phase('m', (ctx) async {
          ctx.measure<num>('v', units: 'V', validators: [Validators.inRange(0, 5)]).value = 3.3;
        }),
      ]);
      final json = (await test.run(dutId: 'DUT-1')).toJson();
      expect(json['outcome'], 'pass');
      expect(json['dutId'], 'DUT-1');
      final phases = json['phases'] as List;
      expect(phases, hasLength(1));
    });
  });

  group('Station', () {
    test('emits lifecycle events in order and tracks live state', () async {
      final station = Station();
      final seen = <String>[];
      final sub = station.events.listen((e) => seen.add(e.runtimeType.toString()));

      final test = Test('demo', [
        Phase('a', (ctx) async {
          ctx.measure<num>('v', validators: [Validators.inRange(0, 5)]).value = 1;
        }),
        Phase('b', (ctx) async {}),
      ]);

      expect(station.state.status, StationStatus.idle);
      final rec = await station.run(test, dutId: 'DUT-9');
      await Future<void>.delayed(Duration.zero); // flush broadcast microtasks
      await sub.cancel();

      expect(seen, [
        'TestStarted',
        'PhaseStarted',
        'PhaseFinished',
        'PhaseStarted',
        'PhaseFinished',
        'TestFinished',
      ]);
      expect(rec.outcome, Outcome.pass);
      expect(station.state.status, StationStatus.finished);
      expect(station.state.outcome, Outcome.pass);
      expect(station.state.completed, hasLength(2));
      expect(station.state.currentPhase, isNull);
      await station.close();
    });

    test('state exposes the running phase mid-run', () async {
      final station = Station();
      String? phaseDuringRun;
      int? indexDuringRun;
      final test = Test('demo', [
        Phase('only', (ctx) async {
          phaseDuringRun = station.state.currentPhase;
          indexDuringRun = station.state.currentPhaseIndex;
        }),
      ]);
      await station.run(test, dutId: 'DUT-1');
      expect(phaseDuringRun, 'only');
      expect(indexDuringRun, 0);
      await station.close();
    });

    test('events serialize to JSON with an event tag', () async {
      final station = Station();
      final jsons = <Map<String, Object?>>[];
      final sub = station.events.listen((e) => jsons.add(e.toJson()));
      await station.run(Test('demo', [Phase('p', (ctx) async {})]), dutId: 'D');
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect(jsons.first['event'], 'testStarted');
      expect(jsons.last['event'], 'testFinished');
      await station.close();
    });
  });
}
