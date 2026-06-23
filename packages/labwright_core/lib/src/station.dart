import 'dart:async';

import 'events.dart';
import 'outcome.dart';
import 'record.dart';
import 'test.dart';

/// Lifecycle of a [Station]'s current run.
enum StationStatus { idle, running, finished }

/// An immutable snapshot of what a station is doing right now. Serializable so a
/// UI can render current progress without replaying the whole event stream.
class StationState {
  const StationState({
    required this.status,
    this.testName,
    this.dutId,
    this.phaseCount = 0,
    this.currentPhase,
    this.currentPhaseIndex,
    this.completed = const [],
    this.outcome,
  });

  final StationStatus status;
  final String? testName;
  final String? dutId;
  final int phaseCount;

  /// Name/index of the phase currently running, or null between phases.
  final String? currentPhase;
  final int? currentPhaseIndex;

  /// Phases that have finished so far.
  final List<PhaseRecord> completed;

  /// Final outcome, set once [status] is [StationStatus.finished].
  final Outcome? outcome;

  Map<String, Object?> toJson() => {
        'status': status.name,
        'testName': testName,
        'dutId': dutId,
        'phaseCount': phaseCount,
        'currentPhase': currentPhase,
        'currentPhaseIndex': currentPhaseIndex,
        'completed': [for (final p in completed) p.toJson()],
        'outcome': outcome?.name,
      };
}

/// Runs a [Test] while exposing its progress live: a broadcast [events] stream
/// plus an always-current [state] snapshot. This is the in-process "local-IPC
/// API"; the loopback socket transport that fronts it lives in `labwright_runner`.
class Station {
  final StreamController<TestEvent> _controller = StreamController<TestEvent>.broadcast();
  StationState _state = const StationState(status: StationStatus.idle);

  /// The latest snapshot.
  StationState get state => _state;

  /// Live event stream (broadcast; late subscribers receive future events only —
  /// pair with [state] for the current snapshot).
  Stream<TestEvent> get events => _controller.stream;

  /// Run [test], updating [state] and emitting [events] as it progresses.
  Future<TestRecord> run(Test test, {required String dutId}) =>
      test.run(dutId: dutId, onEvent: _handle);

  void _handle(TestEvent e) {
    switch (e) {
      case TestStarted():
        _state = StationState(
          status: StationStatus.running,
          testName: e.testName,
          dutId: e.dutId,
          phaseCount: e.phaseCount,
        );
      case PhaseStarted():
        _state = StationState(
          status: StationStatus.running,
          testName: _state.testName,
          dutId: _state.dutId,
          phaseCount: _state.phaseCount,
          currentPhase: e.phaseName,
          currentPhaseIndex: e.index,
          completed: _state.completed,
        );
      case PhaseFinished():
        _state = StationState(
          status: StationStatus.running,
          testName: _state.testName,
          dutId: _state.dutId,
          phaseCount: _state.phaseCount,
          completed: [..._state.completed, e.record],
        );
      case TestFinished():
        _state = StationState(
          status: StationStatus.finished,
          testName: _state.testName,
          dutId: _state.dutId,
          phaseCount: _state.phaseCount,
          completed: e.record.phases,
          outcome: e.record.outcome,
        );
    }
    _controller.add(e);
  }

  /// Releases the event stream. Call when the station is no longer needed.
  Future<void> close() => _controller.close();
}
