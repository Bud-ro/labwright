/// Result classification for a measurement, a phase, or a whole test.
///
/// Ordered by increasing severity: [skip] < [pass] < [fail] < [error].
/// - [skip]  — not executed (e.g. a phase after the test aborted).
/// - [pass]  — executed and all checks passed.
/// - [fail]  — executed but a limit/validator was violated (a real DUT failure).
/// - [error] — could not be evaluated (exception, or a declared value never set).
enum Outcome {
  skip,
  pass,
  fail,
  error;

  /// Parses an outcome from its [name] (the value written to JSON/TDMS), falling
  /// back to [fallback] (default [error]) for null or unrecognized strings. The
  /// inverse of [Outcome.name]; the single place outcome strings are decoded.
  static Outcome fromName(Object? name, {Outcome fallback = Outcome.error}) {
    if (name is String) {
      for (final o in values) {
        if (o.name == name) return o;
      }
    }
    return fallback;
  }
}

/// Combines child outcomes by worst-wins severity (error > fail > pass > skip).
///
/// Relies on [Outcome] being declared in increasing-severity order, so
/// `Outcome.index` *is* the severity. Returns [empty] only when [outcomes] is empty.
Outcome combineOutcomes(Iterable<Outcome> outcomes, {Outcome empty = Outcome.skip}) {
  var seen = false;
  var worst = Outcome.skip;
  for (final o in outcomes) {
    seen = true;
    if (o.index > worst.index) worst = o;
  }
  return seen ? worst : empty;
}
