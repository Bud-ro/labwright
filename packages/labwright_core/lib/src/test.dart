import 'context.dart';
import 'events.dart';
import 'outcome.dart';
import 'peripheral.dart';
import 'phase.dart';
import 'record.dart';

/// A test: an ordered list of [phases] plus the [peripherals] they need.
///
/// [run] opens the peripherals, executes phases in order, always closes the
/// peripherals afterward, and returns a [TestRecord]. Pass [onEvent] (or use a
/// [Station]) to observe progress live.
class Test {
  /// Creates a test named [name] from [phases], optionally injecting named
  /// [peripherals] (made unmodifiable) that phases look up via their context.
  Test(
    this.name,
    this.phases, {
    Map<String, Peripheral> peripherals = const {},
  }) : peripherals = Map.unmodifiable(peripherals);

  /// Human-readable test name (becomes the TestRecord/JUnit suite name).
  final String name;

  /// The phases to run, in order.
  final List<Phase> phases;

  /// Peripherals injected into each phase's context, keyed by name; opened
  /// before the first phase and closed after the last.
  final Map<String, Peripheral> peripherals;

  /// Runs the test against device [dutId]: opens peripherals, executes phases in
  /// order (a failing phase with `continueOnFailure: false` aborts the rest as
  /// skipped), always closes peripherals, and returns the [TestRecord]. Pass
  /// [onEvent] to observe progress live (e.g. via a Station).
  Future<TestRecord> run({
    required String dutId,
    void Function(TestEvent event)? onEvent,
  }) async {
    void emit(TestEvent event) => onEvent?.call(event);

    final start = DateTime.now();
    emit(TestStarted(testName: name, dutId: dutId, phaseCount: phases.length, at: start));

    final phaseRecords = <PhaseRecord>[];
    final opened = <Peripheral>[];
    String? setupError;

    try {
      for (final p in peripherals.values) {
        await p.open();
        opened.add(p);
      }
    } catch (e) {
      setupError = 'peripheral open failed: $e';
    }

    if (setupError == null) {
      final total = phases.length;
      var aborted = false;
      for (var i = 0; i < total; i++) {
        final phase = phases[i];
        if (aborted) {
          final skipped = PhaseRecord.skipped(phase.name);
          phaseRecords.add(skipped);
          emit(PhaseFinished(record: skipped, index: i, total: total, at: DateTime.now()));
          continue;
        }
        emit(PhaseStarted(phaseName: phase.name, index: i, total: total, at: DateTime.now()));
        final record = await _runPhase(phase, dutId);
        phaseRecords.add(record);
        emit(PhaseFinished(record: record, index: i, total: total, at: DateTime.now()));
        final bad = record.outcome == Outcome.fail || record.outcome == Outcome.error;
        if (bad && !phase.continueOnFailure) aborted = true;
      }
    }

    // Always release peripherals, in reverse order; never let cleanup throw.
    for (final p in opened.reversed) {
      try {
        await p.close();
      } catch (_) {
        // Swallowed deliberately — cleanup must not mask the test outcome.
      }
    }

    final end = DateTime.now();
    final outcome = setupError != null
        ? Outcome.error
        : combineOutcomes(phaseRecords.map((r) => r.outcome), empty: Outcome.pass);

    final testRecord = TestRecord(
      testName: name,
      dutId: dutId,
      outcome: outcome,
      phases: phaseRecords,
      start: start,
      end: end,
      error: setupError,
    );
    emit(TestFinished(record: testRecord, at: end));
    return testRecord;
  }

  Future<PhaseRecord> _runPhase(Phase phase, String dutId) async {
    final start = DateTime.now();
    final ctx = PhaseContext(dutId: dutId, peripherals: peripherals);
    String? error;
    try {
      await phase.body(ctx);
    } catch (e) {
      error = '$e';
    }
    final measurements = [for (final m in ctx.measurements) m.toRecord()];
    final outcome = error != null
        ? Outcome.error
        : combineOutcomes(measurements.map((m) => m.outcome), empty: Outcome.pass);
    return PhaseRecord(
      name: phase.name,
      outcome: outcome,
      measurements: measurements,
      logs: ctx.logs,
      start: start,
      end: DateTime.now(),
      error: error,
      requirements: phase.requirements,
    );
  }
}
