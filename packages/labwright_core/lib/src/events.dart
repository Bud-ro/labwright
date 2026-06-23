import 'record.dart';

/// A live event emitted by the executor as a test runs. Consumed by [Station]
/// (and, through it, the UI) to show progress in real time. Pure data — no I/O —
/// so it is safe on every platform including Flutter web.
sealed class TestEvent {
  TestEvent({required this.at});

  /// When the event occurred (UTC-serializable).
  final DateTime at;

  Map<String, Object?> toJson();
}

/// The test has begun (emitted before peripherals open).
class TestStarted extends TestEvent {
  TestStarted({required this.testName, required this.dutId, required this.phaseCount, required super.at});
  final String testName;
  final String dutId;
  final int phaseCount;

  @override
  Map<String, Object?> toJson() => {
        'event': 'testStarted',
        'at': at.toUtc().toIso8601String(),
        'testName': testName,
        'dutId': dutId,
        'phaseCount': phaseCount,
      };
}

/// A phase is about to run. [index] is 0-based; [total] is the phase count.
class PhaseStarted extends TestEvent {
  PhaseStarted({required this.phaseName, required this.index, required this.total, required super.at});
  final String phaseName;
  final int index;
  final int total;

  @override
  Map<String, Object?> toJson() => {
        'event': 'phaseStarted',
        'at': at.toUtc().toIso8601String(),
        'phaseName': phaseName,
        'index': index,
        'total': total,
      };
}

/// A phase finished (also emitted for skipped phases after an abort).
class PhaseFinished extends TestEvent {
  PhaseFinished({required this.record, required this.index, required this.total, required super.at});
  final PhaseRecord record;
  final int index;
  final int total;

  @override
  Map<String, Object?> toJson() => {
        'event': 'phaseFinished',
        'at': at.toUtc().toIso8601String(),
        'index': index,
        'total': total,
        'phase': record.toJson(),
      };
}

/// The test has finished; carries the canonical [TestRecord].
class TestFinished extends TestEvent {
  TestFinished({required this.record, required super.at});
  final TestRecord record;

  @override
  Map<String, Object?> toJson() => {
        'event': 'testFinished',
        'at': at.toUtc().toIso8601String(),
        'record': record.toJson(),
      };
}
