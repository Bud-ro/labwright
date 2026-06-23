import 'package:labwright_fuzz/labwright_fuzz.dart';
import 'package:test/test.dart';

// A toy DUT: healthy until driven above an overvoltage threshold.
const _overvoltage = 4.2;

void main() {
  test('finds a threshold failure and shrinks it toward the boundary', () async {
    final campaign = FuzzCampaign<double>(
      generator: FuzzGenerators.doubleInRange(0, 5),
      safety: const SafetyEnvelope(_safe0to5, description: '0..5 V SOA'),
      probe: (v) async => v > _overvoltage ? const OracleResult.fail('overvoltage') : const OracleResult.ok(),
      iterations: 500,
      seed: 1,
    );
    final r = await campaign.run();
    expect(r.foundFailure, isTrue);
    expect(r.detail, 'overvoltage');
    expect(r.failingCase!, greaterThan(_overvoltage));
    expect(r.failingCase!, lessThanOrEqualTo(r.originalFailingCase!)); // shrunk, not enlarged
  });

  test('never applies stimulus outside the safety envelope', () async {
    final applied = <double>[];
    final campaign = FuzzCampaign<double>(
      generator: FuzzGenerators.doubleInRange(0, 10), // can generate up to 10 V
      safety: const SafetyEnvelope(_safe0to5, description: '0..5 V SOA'),
      probe: (v) async {
        applied.add(v);
        return const OracleResult.ok();
      },
      iterations: 300,
      seed: 7,
    );
    final r = await campaign.run();
    expect(r.foundFailure, isFalse);
    expect(applied, isNotEmpty);
    expect(applied.every((v) => v >= 0 && v <= 5), isTrue); // unsafe stimulus filtered out
  });

  test('the watchdog catches a hang', () async {
    final campaign = FuzzCampaign<double>(
      generator: const FuzzGenerator(generate: _constantOne),
      safety: const SafetyEnvelope(_always),
      probe: (v) async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        return const OracleResult.ok();
      },
      iterations: 3,
      watchdog: const Duration(milliseconds: 30),
    );
    final r = await campaign.run();
    expect(r.foundFailure, isTrue);
    expect(r.detail, contains('watchdog'));
  });

  test('a probe exception is a failure', () async {
    final campaign = FuzzCampaign<double>(
      generator: FuzzGenerators.doubleInRange(0, 5),
      safety: const SafetyEnvelope(_safe0to5),
      probe: (v) async {
        if (v > 4) throw StateError('latch-up');
        return const OracleResult.ok();
      },
      iterations: 500,
      seed: 2,
    );
    final r = await campaign.run();
    expect(r.foundFailure, isTrue);
    expect(r.detail, contains('latch-up'));
  });

  test('throws if the safety envelope rejects all stimulus', () async {
    final campaign = FuzzCampaign<double>(
      generator: FuzzGenerators.doubleInRange(0, 10),
      safety: const SafetyEnvelope(_never, description: 'rejects all'),
      probe: (v) async => const OracleResult.ok(),
      iterations: 5,
      maxSafetyRejections: 50,
    );
    await expectLater(campaign.run(), throwsA(isA<StateError>()));
  });

  test('the minimized failing case replays deterministically', () async {
    final campaign = FuzzCampaign<double>(
      generator: FuzzGenerators.doubleInRange(0, 5),
      safety: const SafetyEnvelope(_safe0to5),
      probe: (v) async => v > _overvoltage ? const OracleResult.fail('overvoltage') : const OracleResult.ok(),
      iterations: 500,
      seed: 3,
    );
    final r = await campaign.run();
    expect(r.foundFailure, isTrue);
    expect((await campaign.replay(r.failingCase!)).failed, isTrue);
    expect((await campaign.replay(r.failingCase!)).failed, isTrue); // stable
  });
}

bool _safe0to5(double v) => v >= 0 && v <= 5;
bool _always(double v) => true;
bool _never(double v) => false;
double _constantOne(Object? rng) => 1.0;
