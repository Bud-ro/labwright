/// The result of applying one [Validator] to a measured value.
class ValidationResult {
  const ValidationResult({required this.passed, required this.limit});

  /// Whether the value satisfied the limit.
  final bool passed;

  /// Human-readable description of the limit, e.g. `in [0.0, 5.0]` or `== 42`.
  /// Recorded verbatim so a TestRecord shows exactly what was checked.
  final String limit;
}

/// Checks a measured value against a limit. Pure and side-effect free.
typedef Validator<T> = ValidationResult Function(T value);

/// Built-in [Validator] constructors. Authors compose these (or [predicate])
/// when declaring a measurement; custom validators are just functions.
abstract final class Validators {
  /// Closed interval `[min, max]` (or open `(min, max)` when [inclusive] is false).
  static Validator<num> inRange(num min, num max, {bool inclusive = true}) => (v) =>
      ValidationResult(
        passed: inclusive ? (v >= min && v <= max) : (v > min && v < max),
        limit: '${inclusive ? 'in' : 'strictly in'} [$min, $max]',
      );

  static Validator<num> lessThan(num bound) =>
      (v) => ValidationResult(passed: v < bound, limit: '< $bound');

  static Validator<num> atMost(num bound) =>
      (v) => ValidationResult(passed: v <= bound, limit: '<= $bound');

  static Validator<num> greaterThan(num bound) =>
      (v) => ValidationResult(passed: v > bound, limit: '> $bound');

  static Validator<num> atLeast(num bound) =>
      (v) => ValidationResult(passed: v >= bound, limit: '>= $bound');

  /// Within [tolerance] of [target] (inclusive).
  static Validator<num> approx(num target, num tolerance) => (v) => ValidationResult(
        passed: (v - target).abs() <= tolerance,
        limit: '$target +/- $tolerance',
      );

  static Validator<T> equals<T>(T expected) =>
      (v) => ValidationResult(passed: v == expected, limit: '== $expected');

  static Validator<T> notEquals<T>(T forbidden) =>
      (v) => ValidationResult(passed: v != forbidden, limit: '!= $forbidden');

  /// Value must be one of [allowed] (a fixed allow-list / enum-like check).
  static Validator<T> isOneOf<T>(Iterable<T> allowed) {
    final options = allowed.toList(); // materialize: callers may pass a one-shot iterable
    return (v) => ValidationResult(passed: options.contains(v), limit: 'one of {${options.join(', ')}}');
  }

  /// Complement of [inRange]: the value must lie *outside* `[min, max]` (or the
  /// open band `(min, max)` when [inclusive] is false).
  static Validator<num> outsideRange(num min, num max, {bool inclusive = true}) => (v) => ValidationResult(
        passed: inclusive ? (v < min || v > max) : (v <= min || v >= max),
        limit: '${inclusive ? 'outside' : 'strictly outside'} [$min, $max]',
      );

  static Validator<String> matches(Pattern pattern) =>
      (v) => ValidationResult(passed: pattern.allMatches(v).isNotEmpty, limit: 'matches $pattern');

  /// Arbitrary predicate with a caller-supplied [description] for the record.
  static Validator<T> predicate<T>(bool Function(T value) test, String description) =>
      (v) => ValidationResult(passed: test(v), limit: description);
}
