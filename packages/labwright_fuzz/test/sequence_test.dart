import 'dart:math';

import 'package:labwright_fuzz/labwright_fuzz.dart';
import 'package:test/test.dart';

void main() {
  test('finds and minimizes a single bad command in a sequence', () async {
    final campaign = FuzzCampaign<List<double>>(
      generator: FuzzGenerators.listOf(FuzzGenerators.doubleInRange(0, 1), minLength: 1, maxLength: 12),
      safety: SafetyEnvelope((seq) => seq.every((v) => v >= 0 && v <= 1)),
      probe: (seq) async => seq.any((v) => v > 0.9) ? const OracleResult.fail('bad command') : const OracleResult.ok(),
      iterations: 500,
      seed: 1,
    );
    final r = await campaign.run();
    expect(r.foundFailure, isTrue);
    expect(r.failingCase!.length, 1); // shrank away every element but the offending one
    expect(r.failingCase!.single, greaterThan(0.9));
  });

  test('grammar: oneOf(just...) builds command tokens; bad command is found and isolated', () async {
    // A command alphabet via just + oneOf, sequenced via listOf.
    final commands = FuzzGenerators.oneOf([
      FuzzGenerators.just('READ'),
      FuzzGenerators.just('WRITE'),
      FuzzGenerators.just('RESET'),
      FuzzGenerators.just('DANGER'), // the offending command
    ]);
    final campaign = FuzzCampaign<List<String>>(
      generator: FuzzGenerators.listOf(commands, minLength: 1, maxLength: 12),
      safety: SafetyEnvelope((_) => true),
      probe: (seq) async => seq.contains('DANGER') ? const OracleResult.fail('issued DANGER') : const OracleResult.ok(),
      iterations: 800,
      seed: 7,
    );
    final r = await campaign.run();
    expect(r.foundFailure, isTrue);
    // listOf shrinks the sequence down to just the offending command.
    expect(r.failingCase, ['DANGER']);
  });

  test('oneOf requires at least one choice', () {
    expect(() => FuzzGenerators.oneOf<int>(const []), throwsArgumentError);
  });

  test('just always yields its value and never shrinks', () {
    final g = FuzzGenerators.just(42);
    expect(g.generate(Random(0)), 42);
    expect(g.generate(Random(999)), 42);
    expect(g.shrink(42), isEmpty);
  });

  test('finds a stateful cumulative-overflow sequence; minimized case still overflows', () async {
    const limit = 5.0;
    final campaign = FuzzCampaign<List<double>>(
      generator: FuzzGenerators.listOf(FuzzGenerators.doubleInRange(0, 1), maxLength: 20),
      safety: SafetyEnvelope((seq) => seq.every((v) => v >= 0 && v <= 1)),
      probe: (seq) async {
        var sum = 0.0;
        for (final v in seq) {
          sum += v;
          if (sum > limit) return const OracleResult.fail('overflow');
        }
        return const OracleResult.ok();
      },
      iterations: 800,
      seed: 3,
    );
    final r = await campaign.run();
    expect(r.foundFailure, isTrue);
    expect(r.failingCase!.fold<double>(0, (a, b) => a + b), greaterThan(limit));
  });
}
