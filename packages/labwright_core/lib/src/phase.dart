import 'context.dart';
import 'requirement.dart';

/// The body of a [Phase]: an async function given the phase's [PhaseContext].
typedef PhaseBody = Future<void> Function(PhaseContext ctx);

/// One unit of a test — the smallest thing that produces an outcome.
///
/// A phase acquires measurements through its context; the executor derives the
/// phase outcome from those measurements (or [Outcome.error] if the body throws).
class Phase {
  /// Creates a phase named [name] that runs [body]; set
  /// [continueOnFailure] to false to abort the test when this phase fails, and
  /// list the [requirements] it verifies.
  const Phase(
    this.name,
    this.body, {
    this.continueOnFailure = true,
    this.requirements = const [],
  });

  /// The phase's name (becomes the group/testcase name in records).
  final String name;

  /// The async function that runs the phase against its [PhaseContext].
  final PhaseBody body;

  /// When false, a [Outcome.fail]/[Outcome.error] in this phase aborts the test
  /// and remaining phases are recorded as skipped.
  final bool continueOnFailure;

  /// Requirements this phase verifies (for traceability).
  final List<RequirementRef> requirements;
}
