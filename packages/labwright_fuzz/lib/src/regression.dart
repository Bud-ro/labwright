import 'dart:async';

import 'package:labwright_core/labwright_core.dart';

import 'fuzz.dart';

Future<OracleResult> _safeProbe<S>(FuzzProbe<S> probe, S stimulus, Duration watchdog) async {
  try {
    return await probe(stimulus).timeout(watchdog);
  } on TimeoutException {
    return OracleResult.fail('watchdog: probe exceeded ${watchdog.inMilliseconds}ms');
  } catch (e) {
    return OracleResult.fail('probe threw: $e');
  }
}

/// Wraps a failing fuzz [stimulus] as a single-phase [Test] so it joins the
/// regular suite as a deterministic regression (and records via the runner —
/// JSON + TDMS). The phase records a `dut_healthy` measurement that must be true;
/// it fails if the probe reports a failure, throws, or exceeds [watchdog].
Test fuzzRegressionTest<S>({
  required String name,
  required S stimulus,
  required FuzzProbe<S> probe,
  Duration watchdog = const Duration(seconds: 5),
}) {
  return Test(name, [
    Phase('replay fuzz case', (ctx) async {
      final result = await _safeProbe(probe, stimulus, watchdog);
      if (result.detail != null) ctx.log(result.detail!);
      ctx.measure<bool>('dut_healthy', validators: [Validators.equals(true)]).value = !result.failed;
    }),
  ]);
}

/// Convenience: build a regression [Test] for a failing case using a campaign's
/// own probe and watchdog.
extension FuzzCampaignRegression<S> on FuzzCampaign<S> {
  Test regression(S stimulus, {String name = 'fuzz regression'}) =>
      fuzzRegressionTest(name: name, stimulus: stimulus, probe: probe, watchdog: watchdog);
}
