/// DUT fuzzing for Labwright.
///
/// Build a [FuzzCampaign] with a [FuzzGenerator], a [FuzzProbe] that applies
/// stimulus to the device and reports health, and a **mandatory** [SafetyEnvelope]
/// (unsafe stimulus is never applied). A failure is the probe returning
/// `OracleResult.fail`, throwing, or exceeding the watchdog (liveness). The first
/// failure is shrunk to a minimal, deterministically-replayable case.
library;

export 'src/fuzz.dart';
export 'src/regression.dart';
