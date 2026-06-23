import 'outcome.dart';
import 'requirement.dart';

/// Immutable snapshot of one measurement after a phase ran.
class MeasurementRecord {
  const MeasurementRecord({
    required this.name,
    required this.units,
    required this.value,
    required this.isSet,
    required this.outcome,
    required this.checkedLimits,
    required this.failedLimits,
    this.requirements = const [],
  });

  final String name;
  final String? units;
  final Object? value;
  final bool isSet;
  final Outcome outcome;
  final List<String> checkedLimits;
  final List<String> failedLimits;
  final List<RequirementRef> requirements;

  Map<String, Object?> toJson() => {
        'name': name,
        if (units != null) 'units': units,
        'value': value,
        'isSet': isSet,
        'outcome': outcome.name,
        'checkedLimits': checkedLimits,
        'failedLimits': failedLimits,
        if (requirements.isNotEmpty) 'requirements': [for (final r in requirements) r.toJson()],
      };
}

/// Immutable result of one phase.
class PhaseRecord {
  const PhaseRecord({
    required this.name,
    required this.outcome,
    required this.measurements,
    required this.logs,
    required this.start,
    required this.end,
    this.error,
    this.requirements = const [],
  });

  /// A phase that never ran because the test aborted earlier.
  factory PhaseRecord.skipped(String name) {
    final now = DateTime.now();
    return PhaseRecord(
      name: name,
      outcome: Outcome.skip,
      measurements: const [],
      logs: const [],
      start: now,
      end: now,
    );
  }

  final String name;
  final Outcome outcome;
  final List<MeasurementRecord> measurements;
  final List<String> logs;
  final DateTime start;
  final DateTime end;

  /// Present when the phase body threw.
  final String? error;

  /// Requirements declared on the phase itself (measurement-level refs live on
  /// each [MeasurementRecord]).
  final List<RequirementRef> requirements;

  int get durationMs => end.difference(start).inMilliseconds;

  Map<String, Object?> toJson() => {
        'name': name,
        'outcome': outcome.name,
        'durationMs': durationMs,
        'measurements': [for (final m in measurements) m.toJson()],
        'logs': logs,
        if (error != null) 'error': error,
        if (requirements.isNotEmpty) 'requirements': [for (final r in requirements) r.toJson()],
      };
}

/// Immutable result of a whole test run — the canonical artifact the runner
/// serializes (JSON now; TDMS in `labwright_tdms`).
class TestRecord {
  const TestRecord({
    required this.testName,
    required this.dutId,
    required this.outcome,
    required this.phases,
    required this.start,
    required this.end,
    this.error,
  });

  final String testName;
  final String dutId;
  final Outcome outcome;
  final List<PhaseRecord> phases;
  final DateTime start;
  final DateTime end;

  /// Present on setup failure (e.g. a peripheral failed to open).
  final String? error;

  int get durationMs => end.difference(start).inMilliseconds;

  Map<String, Object?> toJson() => {
        'testName': testName,
        'dutId': dutId,
        'outcome': outcome.name,
        'durationMs': durationMs,
        'start': start.toUtc().toIso8601String(),
        'end': end.toUtc().toIso8601String(),
        if (error != null) 'error': error,
        'phases': [for (final p in phases) p.toJson()],
      };
}
