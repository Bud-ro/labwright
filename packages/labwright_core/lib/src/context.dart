import 'measurement.dart';
import 'peripheral.dart';
import 'requirement.dart';
import 'validators.dart';

/// Handed to each phase as its single argument. Scoped to one phase run: the
/// measurements and logs it collects belong to that phase's record.
///
/// Constructed by the test executor; authors receive it, they don't build it.
class PhaseContext {
  /// Built by the test executor for one phase run; authors receive it.
  PhaseContext({
    required this.dutId,
    required Map<String, Peripheral> peripherals,
  }) : _peripherals = peripherals;

  /// Identifier of the device under test for this run.
  final String dutId;

  final Map<String, Peripheral> _peripherals;
  final List<Measurement<dynamic>> _measurements = [];
  final List<String> _logs = [];

  /// Measurements declared so far in this phase (executor reads these).
  List<Measurement<dynamic>> get measurements => List.unmodifiable(_measurements);

  /// Log lines emitted so far in this phase.
  List<String> get logs => List.unmodifiable(_logs);

  /// Declare a measurement, optionally with [units], [validators], and the
  /// [requirements] it verifies (for traceability), and get a handle to set its
  /// [Measurement.value].
  Measurement<T> measure<T>(
    String name, {
    String? units,
    List<Validator<T>> validators = const [],
    List<RequirementRef> requirements = const [],
  }) {
    final m = Measurement<T>(name, units: units, validators: validators, requirements: requirements);
    _measurements.add(m);
    return m;
  }

  /// Look up an injected peripheral by type (and optionally [name]).
  P peripheral<P extends Peripheral>([String? name]) {
    for (final p in _peripherals.values) {
      if (p is P && (name == null || p.name == name)) return p;
    }
    throw StateError(
      'No peripheral of type $P${name != null ? ' named "$name"' : ''} is registered',
    );
  }

  /// Append a line to this phase's log.
  void log(String message) => _logs.add(message);
}
