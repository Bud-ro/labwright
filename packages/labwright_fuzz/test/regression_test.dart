import 'package:labwright_core/labwright_core.dart';
import 'package:labwright_fuzz/labwright_fuzz.dart';
import 'package:test/test.dart';

void main() {
  test('a failing fuzz case becomes a failing regression Test', () async {
    final campaign = FuzzCampaign<double>(
      generator: FuzzGenerators.doubleInRange(0, 5),
      safety: const SafetyEnvelope(_safe),
      probe: (v) async => v > 4.2 ? const OracleResult.fail('overvoltage') : const OracleResult.ok(),
      iterations: 500,
      seed: 1,
    );
    final r = await campaign.run();
    expect(r.foundFailure, isTrue);

    final regression = campaign.regression(r.failingCase!, name: 'overvoltage-regression');
    final rec = await regression.run(dutId: 'DUT-1');

    expect(rec.testName, 'overvoltage-regression');
    expect(rec.outcome, Outcome.fail);
    final m = rec.phases.single.measurements.single;
    expect(m.name, 'dut_healthy');
    expect(m.value, false);
  });

  test('a healthy case becomes a passing regression Test', () async {
    final t = fuzzRegressionTest<double>(
      name: 'ok',
      stimulus: 1,
      probe: (v) async => const OracleResult.ok(),
    );
    final rec = await t.run(dutId: 'D');
    expect(rec.outcome, Outcome.pass);
    expect(rec.phases.single.measurements.single.value, true);
  });

  test('a hanging probe regression fails via the watchdog', () async {
    final t = fuzzRegressionTest<double>(
      name: 'hang',
      stimulus: 1,
      watchdog: const Duration(milliseconds: 30),
      probe: (v) async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        return const OracleResult.ok();
      },
    );
    final rec = await t.run(dutId: 'D');
    expect(rec.outcome, Outcome.fail);
    expect(rec.phases.single.logs.any((l) => l.contains('watchdog')), isTrue);
  });
}

bool _safe(double v) => v >= 0 && v <= 5;
