import 'dart:math';

import 'package:labwright_core/labwright_core.dart';
import 'package:labwright_runner/labwright_runner.dart';
import 'package:labwright_tdms/labwright_tdms.dart';
import 'package:test/test.dart';

/// Property test: for many varied records, a record → TDMS → record-JSON round
/// trip preserves the structure the self-describing-TDMS guarantee depends on
/// (phase names/outcomes, measurement names/outcomes, requirement refs). This
/// generalizes the single hand-written round-trip case to a seeded variety of
/// shapes, including mixed pass/fail.
void main() {
  test('recordToTdms -> tdmsToRecordJson preserves phases/outcomes/requirements', () async {
    final rng = Random(1234);

    Test buildTest(int idx) {
      final phaseCount = 1 + rng.nextInt(4);
      final phases = <Phase>[
        for (var p = 0; p < phaseCount; p++)
          Phase('phase${idx}_$p', (ctx) async {
            final measCount = 1 + rng.nextInt(3);
            for (var m = 0; m < measCount; m++) {
              final reqs = [
                for (var r = 0; r < rng.nextInt(3); r++) RequirementRef('REQ-$p-$m-$r', hash: 'h$r'),
              ];
              // Values in [-5, 15] against [0,10] → a mix of pass and fail.
              ctx
                  .measure<num>(
                    'm$m',
                    units: 'V',
                    validators: [Validators.inRange(0, 10)],
                    requirements: reqs,
                  )
                  .value = rng.nextDouble() * 20 - 5;
            }
          }),
      ];
      return Test('t$idx', phases);
    }

    for (var i = 0; i < 40; i++) {
      final rec = await buildTest(i).run(dutId: 'DUT-$i');
      final orig = rec.toJson();
      final recon = tdmsToRecordJson(TdmsReader.read(recordToTdms(rec)));

      final origPhases = orig['phases']! as List;
      final reconPhases = recon['phases']! as List;
      expect(reconPhases.length, origPhases.length, reason: 'phase count (rec $i)');

      for (var p = 0; p < origPhases.length; p++) {
        final op = origPhases[p] as Map<String, Object?>;
        final rp = reconPhases[p] as Map<String, Object?>;
        expect(rp['name'], op['name'], reason: 'phase name (rec $i, phase $p)');
        expect(rp['outcome'], op['outcome'], reason: 'phase outcome (rec $i, phase $p)');

        final om = op['measurements']! as List;
        final rm = rp['measurements']! as List;
        expect(rm.length, om.length, reason: 'measurement count (rec $i, phase $p)');

        for (var m = 0; m < om.length; m++) {
          final omm = om[m] as Map<String, Object?>;
          final rmm = rm[m] as Map<String, Object?>;
          expect(rmm['name'], omm['name'], reason: 'meas name (rec $i, phase $p, meas $m)');
          expect(rmm['outcome'], omm['outcome'], reason: 'meas outcome (rec $i, phase $p, meas $m)');
          // toJson omits requirements when empty; reconstruction emits []. Normalize.
          final origReqs = (omm['requirements'] as List?) ?? const [];
          final reconReqs = (rmm['requirements'] as List?) ?? const [];
          expect(reconReqs, origReqs, reason: 'meas requirements (rec $i, phase $p, meas $m)');
        }
      }
    }
  });
}
