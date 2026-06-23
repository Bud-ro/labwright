import 'dart:async';
import 'dart:math';

/// The verdict of probing the DUT with one stimulus.
class OracleResult {
  const OracleResult({required this.failed, this.detail});

  /// The DUT behaved correctly for this stimulus.
  const OracleResult.ok()
      : failed = false,
        detail = null;

  /// The DUT misbehaved; [detail] explains how.
  const OracleResult.fail(this.detail) : failed = true;

  /// Whether the stimulus revealed a failure.
  final bool failed;

  /// Human-readable explanation of a failure, if any.
  final String? detail;
}

/// Applies a stimulus to the DUT and reports whether it misbehaved (out-of-spec
/// measurement, error response, …). Returning normally with `ok()` means healthy;
/// throwing, or exceeding the campaign watchdog, also counts as a failure.
typedef FuzzProbe<S> = Future<OracleResult> Function(S stimulus);

/// The safe operating area for stimulus. A campaign **requires** one and never
/// applies stimulus for which [within] is false — fuzzing must not damage the DUT.
class SafetyEnvelope<S> {
  const SafetyEnvelope(this.within, {this.description = 'safety envelope'});

  /// Returns true if [stimulus] is safe to apply to the DUT.
  final bool Function(S stimulus) within;

  /// Label for this envelope, used in error messages.
  final String description;
}

/// Produces stimulus from a seeded RNG and proposes smaller variants of a
/// failing case for shrinking.
class FuzzGenerator<S> {
  const FuzzGenerator({required this.generate, this.shrink = _none});

  /// Produces one stimulus from the seeded [rng].
  final S Function(Random rng) generate;

  /// Candidates "smaller" than [failing]; greedy shrinking adopts the smallest
  /// that still fails. Default: no shrinking.
  final Iterable<S> Function(S failing) shrink;

  static Iterable<Never> _none(Object? _) => const [];
}

/// Built-in [FuzzGenerator]s.
abstract final class FuzzGenerators {
  /// Uniform doubles in `[min, max]`; shrinks toward [shrinkTarget] by trying
  /// progressively-closer-to-failing fractions (so the minimal failing value is
  /// found, not just any smaller value).
  static FuzzGenerator<double> doubleInRange(double min, double max, {double shrinkTarget = 0}) =>
      FuzzGenerator<double>(
        generate: (rng) => min + rng.nextDouble() * (max - min),
        shrink: (failing) {
          final span = failing - shrinkTarget;
          if (span == 0) return const <double>[];
          return [
            for (final frac in const [0.25, 0.5, 0.625, 0.75, 0.8125, 0.875, 0.9375])
              shrinkTarget + span * frac,
          ];
        },
      );

  /// Sequences of [element] (for command/protocol fuzzing). Generates lengths in
  /// `[minLength, maxLength]`; shrinks by dropping halves, then single elements,
  /// then shrinking each element in place — so the minimal failing subsequence is
  /// found.
  static FuzzGenerator<List<S>> listOf<S>(
    FuzzGenerator<S> element, {
    int minLength = 0,
    int maxLength = 16,
  }) =>
      FuzzGenerator<List<S>>(
        generate: (rng) {
          final n = minLength + rng.nextInt(maxLength - minLength + 1);
          return [for (var i = 0; i < n; i++) element.generate(rng)];
        },
        shrink: (failing) sync* {
          if (failing.isEmpty) return;
          final half = failing.length ~/ 2;
          if (half > 0) {
            yield failing.sublist(0, half); // drop second half
            yield failing.sublist(failing.length - half); // drop first half
          }
          for (var i = 0; i < failing.length; i++) {
            yield [...failing.sublist(0, i), ...failing.sublist(i + 1)]; // drop element i
          }
          for (var i = 0; i < failing.length; i++) {
            for (final smaller in element.shrink(failing[i])) {
              yield [...failing.sublist(0, i), smaller, ...failing.sublist(i + 1)];
            }
          }
        },
      );

  /// A constant generator that always yields [value] and never shrinks. Compose
  /// with [oneOf]/[listOf] to build grammar-style stimulus (e.g. command tokens
  /// like `oneOf([just(Cmd.read), just(Cmd.write)])`).
  static FuzzGenerator<S> just<S>(S value) => FuzzGenerator<S>(generate: (_) => value);

  /// Grammar alternation: each draw picks one of [choices] uniformly. Shrinking
  /// offers the union of the choices' own shrink candidates for the failing
  /// value (constant choices contribute none, so a sequence still minimizes by
  /// dropping elements). Throws if [choices] is empty.
  static FuzzGenerator<S> oneOf<S>(List<FuzzGenerator<S>> choices) {
    if (choices.isEmpty) {
      throw ArgumentError.value(choices, 'choices', 'must not be empty');
    }
    return FuzzGenerator<S>(
      generate: (rng) => choices[rng.nextInt(choices.length)].generate(rng),
      shrink: (failing) => [for (final c in choices) ...c.shrink(failing)],
    );
  }

  /// Uniform ints in `[min, max]`; shrinks toward [shrinkTarget] by bisection.
  static FuzzGenerator<int> intInRange(int min, int max, {int shrinkTarget = 0}) =>
      FuzzGenerator<int>(
        generate: (rng) => min + rng.nextInt(max - min + 1),
        shrink: (failing) {
          final out = <int>[];
          var v = failing;
          while (v != shrinkTarget && out.length < 32) {
            v = shrinkTarget + (v - shrinkTarget) ~/ 2;
            out.add(v);
          }
          return out.reversed; // largest-but-smaller first so greedy minimizes
        },
      );
}

/// The outcome of a fuzzing campaign.
class FuzzReport<S> {
  FuzzReport({
    required this.foundFailure,
    required this.iterationsRun,
    required this.seed,
    this.failingCase,
    this.originalFailingCase,
    this.detail,
    this.shrinkSteps = 0,
  });

  /// Whether the campaign hit a failure.
  final bool foundFailure;

  /// How many stimulus iterations ran before stopping.
  final int iterationsRun;

  /// The RNG seed (re-run with the same seed to reproduce).
  final int seed;

  /// Minimized failing stimulus (the replayable case).
  final S? failingCase;

  /// Failing stimulus before shrinking.
  final S? originalFailingCase;

  /// Failure explanation from the probe/watchdog, if any.
  final String? detail;

  /// Number of shrink steps applied to minimize the case.
  final int shrinkSteps;

  /// One-line human-readable summary of the campaign result.
  String summary() => foundFailure
      ? 'FAIL after $iterationsRun iters (seed $seed): $detail; '
          'case=$failingCase (from $originalFailingCase, $shrinkSteps shrink steps)'
      : 'ok: $iterationsRun iters, no failure (seed $seed)';
}

/// Fuzzes a DUT: generates safe stimulus, probes under a watchdog, and on the
/// first failure shrinks it to a minimal, replayable case.
class FuzzCampaign<S> {
  FuzzCampaign({
    required this.generator,
    required this.probe,
    required this.safety,
    this.iterations = 100,
    this.seed = 0,
    this.watchdog = const Duration(seconds: 5),
    this.maxShrinkSteps = 100,
    this.maxSafetyRejections = 100000,
  });

  /// Generates (and shrinks) stimulus.
  final FuzzGenerator<S> generator;

  /// Applies stimulus to the DUT and reports health.
  final FuzzProbe<S> probe;

  /// Mandatory — a campaign cannot be constructed without a safety envelope.
  final SafetyEnvelope<S> safety;

  /// How many stimulus iterations to try before giving up.
  final int iterations;

  /// RNG seed; the run is deterministic for a given seed.
  final int seed;

  /// Per-probe time limit; exceeding it counts as a (hang) failure.
  final Duration watchdog;

  /// Cap on shrink steps when minimizing a failing case.
  final int maxShrinkSteps;

  /// Cap on consecutive safety rejections before erroring (envelope too tight).
  final int maxSafetyRejections;

  /// Runs the campaign: safe stimulus → probe under watchdog → shrink on the
  /// first failure. Returns a [FuzzReport].
  Future<FuzzReport<S>> run() async {
    final rng = Random(seed);
    var rejections = 0;

    for (var i = 0; i < iterations; i++) {
      S stimulus = generator.generate(rng);
      while (!safety.within(stimulus)) {
        rejections++;
        if (rejections > maxSafetyRejections) {
          throw StateError('safety envelope "${safety.description}" rejected all generated stimulus');
        }
        stimulus = generator.generate(rng);
      }

      final result = await _probe(stimulus);
      if (result.failed) {
        final (minimized, steps) = await _shrink(stimulus);
        return FuzzReport(
          foundFailure: true,
          iterationsRun: i + 1,
          seed: seed,
          originalFailingCase: stimulus,
          failingCase: minimized,
          detail: result.detail,
          shrinkSteps: steps,
        );
      }
    }
    return FuzzReport(foundFailure: false, iterationsRun: iterations, seed: seed);
  }

  /// Re-run a (minimized) failing case deterministically.
  Future<OracleResult> replay(S stimulus) => _probe(stimulus);

  Future<OracleResult> _probe(S stimulus) async {
    try {
      return await probe(stimulus).timeout(watchdog);
    } on TimeoutException {
      return OracleResult.fail('watchdog: probe exceeded ${watchdog.inMilliseconds}ms (possible hang)');
    } catch (e) {
      return OracleResult.fail('probe threw: $e');
    }
  }

  Future<bool> _fails(S stimulus) async => (await _probe(stimulus)).failed;

  Future<(S, int)> _shrink(S failing) async {
    var current = failing;
    var steps = 0;
    var improved = true;
    while (improved && steps < maxShrinkSteps) {
      improved = false;
      for (final candidate in generator.shrink(current)) {
        if (!safety.within(candidate)) continue;
        steps++;
        if (steps > maxShrinkSteps) break;
        if (await _fails(candidate)) {
          current = candidate;
          improved = true;
          break;
        }
      }
    }
    return (current, steps);
  }
}
