import 'dart:convert';
import 'dart:math';

import 'package:labwright_core/labwright_core.dart';
import 'package:test/test.dart';

/// Randomized invariants for the engine and validators (seeded for determinism).
void main() {
  final rng = Random(20260623);

  int severity(Outcome o) => switch (o) {
        Outcome.skip => 0,
        Outcome.pass => 1,
        Outcome.fail => 2,
        Outcome.error => 3,
      };

  test('a range measurement passes iff the value is within the range', () {
    for (var i = 0; i < 500; i++) {
      final lo = rng.nextDouble() * 10 - 5;
      final hi = lo + rng.nextDouble() * 5;
      final v = rng.nextDouble() * 16 - 8;
      final rec = (Measurement<num>('v', validators: [Validators.inRange(lo, hi)])..value = v).toRecord();
      expect(rec.outcome, (v >= lo && v <= hi) ? Outcome.pass : Outcome.fail, reason: 'v=$v in [$lo,$hi]');
    }
  });

  test('a measurement passes iff every validator passes', () {
    for (var i = 0; i < 500; i++) {
      final a = rng.nextDouble() * 10;
      final b = rng.nextDouble() * 10;
      final v = rng.nextDouble() * 10;
      final rec = (Measurement<num>('v', validators: [Validators.atMost(a), Validators.atLeast(b)])..value = v)
          .toRecord();
      expect(rec.outcome, (v <= a && v >= b) ? Outcome.pass : Outcome.fail);
    }
  });

  test('combineOutcomes is worst-wins', () {
    const all = Outcome.values;
    for (var i = 0; i < 1000; i++) {
      final list = [for (var k = 0; k < rng.nextInt(6); k++) all[rng.nextInt(all.length)]];
      final got = combineOutcomes(list, empty: Outcome.pass);
      if (list.isEmpty) {
        expect(got, Outcome.pass);
      } else {
        expect(severity(got), list.map(severity).reduce(max));
      }
    }
  });

  test('phase/test outcome equals the worst of its measurement outcomes', () async {
    for (var i = 0; i < 300; i++) {
      final specs = [
        for (var j = 0; j < rng.nextInt(4); j++)
          (v: rng.nextDouble() * 8, lo: rng.nextDouble() * 4, hi: 0.0),
      ].map((s) => (v: s.v, lo: s.lo, hi: s.lo + rng.nextDouble() * 4)).toList();

      final test = Test('t', [
        Phase('p', (ctx) async {
          for (final s in specs) {
            ctx.measure<num>('m', validators: [Validators.inRange(s.lo, s.hi)]).value = s.v;
          }
        }),
      ]);
      final rec = await test.run(dutId: 'D');
      final expected = specs.isEmpty
          ? Outcome.pass
          : (specs.any((s) => !(s.v >= s.lo && s.v <= s.hi)) ? Outcome.fail : Outcome.pass);
      expect(rec.phases.single.outcome, expected);
      expect(rec.outcome, expected);
    }
  });

  test('TestRecord.toJson is stable and JSON-encodable', () async {
    for (var i = 0; i < 100; i++) {
      final v = rng.nextDouble() * 5;
      final test = Test('t', [
        Phase('p', (ctx) async {
          ctx.measure<num>('v', units: 'V', validators: [Validators.inRange(0, 3)]).value = v;
        }),
      ]);
      final rec = await test.run(dutId: 'D-$i');
      final once = jsonEncode(rec.toJson());
      expect(once, jsonEncode(rec.toJson())); // stable
      expect(jsonDecode(once), isA<Map<String, dynamic>>());
    }
  });
}
