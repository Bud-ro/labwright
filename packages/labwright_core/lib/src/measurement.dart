import 'outcome.dart';
import 'record.dart';
import 'requirement.dart';
import 'validators.dart';

/// A named value a phase acquires and (optionally) checks against limits.
///
/// Declared via `ctx.measure(...)`, set with [value], then collected by the
/// executor into a [MeasurementRecord] at the end of the phase. A measurement
/// that is declared but never set resolves to [Outcome.error] — that means the
/// test could not acquire it, which is a fault, not a pass.
class Measurement<T> {
  /// Declares a measurement named [name], with optional [units], [validators]
  /// (limits that decide pass/fail), and [requirements] it verifies. Usually
  /// created via `ctx.measure(...)` rather than directly.
  Measurement(
    this.name, {
    this.units,
    List<Validator<T>> validators = const [],
    List<RequirementRef> requirements = const [],
  })  : _validators = List.unmodifiable(validators),
        requirements = List.unmodifiable(requirements);

  /// The measurement's name (becomes the channel/record key).
  final String name;

  /// Engineering units (e.g. `V`, `mA`), or null if dimensionless.
  final String? units;
  final List<Validator<T>> _validators;

  /// Requirements this measurement verifies (for traceability).
  final List<RequirementRef> requirements;

  bool _isSet = false;
  late T _value;

  /// Whether a value has been recorded.
  bool get isSet => _isSet;

  /// The recorded value. Throws [StateError] if read before being set.
  T get value {
    if (!_isSet) throw StateError('Measurement "$name" was read before it was set');
    return _value;
  }

  /// Records the measured [v] and marks the measurement set.
  set value(T v) {
    _value = v;
    _isSet = true;
  }

  /// Snapshots the current state into an immutable record.
  MeasurementRecord toRecord() {
    if (!_isSet) {
      return MeasurementRecord(
        name: name,
        units: units,
        value: null,
        isSet: false,
        outcome: Outcome.error,
        checkedLimits: const [],
        failedLimits: const [],
        requirements: requirements,
      );
    }
    final results = [for (final validate in _validators) validate(_value)];
    final failed = [for (final r in results) if (!r.passed) r.limit];
    return MeasurementRecord(
      name: name,
      units: units,
      value: _value,
      isSet: true,
      outcome: failed.isEmpty ? Outcome.pass : Outcome.fail,
      checkedLimits: [for (final r in results) r.limit],
      failedLimits: failed,
      requirements: requirements,
    );
  }
}
