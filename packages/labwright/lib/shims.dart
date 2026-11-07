import 'dart:math' as math;

dynamic eval(String expression) => throw UnimplementedError('expression not translated: $expression');

bool cond(String expression) => throw UnimplementedError('condition not translated: $expression');

bool truthy(Object? v) => switch (v) {
  final bool b => b,
  final num n => n != 0,
  _ => throw UnimplementedError('truthiness of ${v.runtimeType}'),
};

double len(Object? v) => switch (v) {
  final String s => s.length.toDouble(),
  final Iterable<Object?> i => i.length.toDouble(),
  final Map<Object?, Object?> m => m.length.toDouble(),
  final PropObj p => p.entries.length.toDouble(),
  _ => throw UnimplementedError('Len of ${v.runtimeType}'),
};

double getNumElements(Object? v, [Object? a]) =>
    a == null ? len(v) : throw UnimplementedError('GetNumElements with options');

Object? setNumElements(Object? v, Object? n, [Object? a]) {
  if (v is! List || n is! num || a != null) {
    throw UnimplementedError('SetNumElements on ${v.runtimeType}');
  }
  final target = n.toInt();
  while (v.length > target) {
    v.removeLast();
  }
  while (v.length < target) {
    v.add(null);
  }
  return v;
}

String str(Object? v, [Object? f1, Object? f2, Object? f3]) {
  if (f1 != null || f2 != null || f3 != null) {
    throw UnimplementedError('Str with format options');
  }
  if (v is! num) return v.toString();
  if ((v is int || v == v.roundToDouble()) && v.abs() < 9007199254740992) {
    return v.toInt().toString();
  }
  var text = v.toStringAsPrecision(13);
  if (text.contains('.') && !text.contains('e')) {
    text = text.replaceAll(RegExp(r'0+$'), '');
    if (text.endsWith('.')) text = text.substring(0, text.length - 1);
  }
  return text;
}

String left(Object? s, Object? n) => _clip(s, n, fromLeft: true);
String right(Object? s, Object? n) => _clip(s, n, fromLeft: false);

String mid(Object? s, Object? offset, [Object? count]) {
  final text = s is String ? s : throw UnimplementedError('Mid of ${s.runtimeType}');
  final start = (offset is num ? offset.toInt() : 0).clamp(0, text.length);
  final end = count is num ? (start + count.toInt()).clamp(start, text.length) : text.length;
  return text.substring(start, end);
}

double find(Object? s, Object? sub, [Object? start]) {
  if (s is! String || sub is! String) {
    throw UnimplementedError('Find of ${s.runtimeType}');
  }
  return s.indexOf(sub, (start is num ? start.toInt() : 0).clamp(0, s.length)).toDouble();
}

String _clip(Object? s, Object? n, {required bool fromLeft}) {
  final text = s is String ? s : throw UnimplementedError('Left/Right of ${s.runtimeType}');
  final count = (n is num ? n.toInt() : 0).clamp(0, text.length);
  return fromLeft ? text.substring(0, count) : text.substring(text.length - count);
}

math.Random? _rng;

double rand([Object? min, Object? max]) {
  final r = (_rng ??= math.Random()).nextDouble();
  if (min is num && max is num) return min + r * (max - min);
  if (min == null && max == null) return r;
  throw UnimplementedError('Random with non-numeric bounds');
}

/// A sequence parameter passed by reference that the callee writes: the caller reads [value] back after the call.
class Ref<T> {
  Ref(this.value);
  T value;
}

/// A deep copy of a value passed to a by-value container parameter.
T copy<T>(T value) => switch (value) {
  final List<Object?> list => <Object?>[for (final element in list) copy(element)] as T,
  final PropObj object =>
    (PropObj.named(object._name)
          .._canonical.addAll(object._canonical)
          .._values.addAll({for (final e in object._values.entries) e.key: copy(e.value)}))
        as T,
  _ => value,
};

/// A Numeric Limit Test comparison: the first pair of letters applies to the low limit and the second to the high
/// limit; a single pair compares against the low limit.
enum LimitComparison {
  /// Equal to low.
  eq('EQ'),

  /// Not equal to low.
  ne('NE'),

  /// Greater than low.
  gt('GT'),

  /// Less than low.
  lt('LT'),

  /// Greater than or equal to low.
  ge('GE'),

  /// Less than or equal to low.
  le('LE'),

  /// Above low and below high.
  gtlt('GTLT'),

  /// At or above low and at or below high.
  gele('GELE'),

  /// At or above low and below high.
  gelt('GELT'),

  /// Above low and at or below high.
  gtle('GTLE'),

  /// Below low or above high.
  ltgt('LTGT'),

  /// At or below low or at or above high.
  lege('LEGE'),

  /// Below low or at or above high.
  ltge('LTGE'),

  /// At or below low or above high.
  legt('LEGT'),

  /// Records the value without judging it.
  log('LOG');

  const LimitComparison(this.code);
  final String code;
  static final Map<String, LimitComparison> byCode = {for (final c in values) c.code: c};
  bool passes(num value, num low, num high) => switch (this) {
    eq => value == low,
    ne => value != low,
    gt => value > low,
    lt => value < low,
    ge => value >= low,
    le => value <= low,
    gtlt => value > low && value < high,
    gele => value >= low && value <= high,
    gelt => value >= low && value < high,
    gtle => value > low && value <= high,
    ltgt => value < low || value > high,
    lege => value <= low || value >= high,
    ltge => value < low || value >= high,
    legt => value <= low || value > high,
    log => true,
  };
}

/// A String Value Test comparison.
enum StringComparison {
  /// Equal ignoring case.
  ignoreCase('IgnoreCase'),

  /// Equal including case.
  caseSensitive('CaseSensitive'),

  /// Records the value without judging it.
  log('LOG');

  const StringComparison(this.code);
  final String code;
  static final Map<String, StringComparison> byCode = {for (final c in values) c.code: c};
}

/// The step status a passing judgement sets.
const statusPassed = 'Passed';

/// The step status a failing judgement sets.
const statusFailed = 'Failed';

String checkLimits(
  Object? value,
  Object? high,
  Object? low,
  Object? comparison, [
  Object? doNotCopyToResults,
  Object? nominal,
  Object? thresholdType,
]) {
  final judged = LimitComparison.byCode[comparison];
  if (judged == null) throw UnimplementedError('CheckLimits comparison $comparison');
  if (judged == LimitComparison.log) return statusPassed;
  if (value is! num || low is! num || high is! num) {
    throw UnimplementedError('CheckLimits of ${value.runtimeType} against ${low.runtimeType}..${high.runtimeType}');
  }
  return judged.passes(value, low, high) ? statusPassed : statusFailed;
}

String checkStrLimit(Object? value, Object? limit, Object? comparison, [Object? maxChars]) {
  final judged = StringComparison.byCode[comparison];
  if (judged == null || (maxChars != null && maxChars != -1)) {
    throw UnimplementedError('CheckStrLimit comparison $comparison${maxChars == null ? '' : ' over $maxChars chars'}');
  }
  if (judged == StringComparison.log) return statusPassed;
  if (value is! String || limit is! String) {
    throw UnimplementedError('CheckStrLimit of ${value.runtimeType} against ${limit.runtimeType}');
  }
  final equal = judged == StringComparison.ignoreCase ? value.toLowerCase() == limit.toLowerCase() : value == limit;
  return equal ? statusPassed : statusFailed;
}

/// Raised by a Terminate post action: the execution stops after each sequence on the way out runs its cleanup.
final class SequenceTermination implements Exception {
  const SequenceTermination();
  @override
  String toString() => 'execution terminated by a post action';
}

Never terminate() => throw const SequenceTermination();

/// What the host answers for a message popup step: the 1-based button pressed and the text entered.
typedef PopupResponse = ({double buttonHit, String response});

/// The operations an exported sequence can only perform through its host: dialogs and the step types whose
/// substeps the engine or a vendor implements. The default, [UnavailableStepHost], raises [StepHostUnavailable] naming the
/// operation; a host installs its own by assigning [stepHost].
abstract class StepHost {
  const StepHost();
  Future<PopupResponse> messagePopup({
    required Object? title,
    required Object? message,
    required List<Object?> buttons,
    bool showResponse = false,
    Object? defaultResponse,
  });
  Future<void> runStepType(String stepType, StepPhase phase, Object? step, Object? result);
}

/// When a step type acts: its Pre substeps run before the step's code module, its Post substeps after it.
enum StepPhase { pre, post }

/// Raised by [UnavailableStepHost]: the program needs a host for [operation].
final class StepHostUnavailable extends Error {
  StepHostUnavailable(this.operation);
  final String operation;
  @override
  String toString() => 'step operation "$operation" needs a StepHost, and none is installed';
}

/// The host a program runs with until one is installed: every operation raises.
final class UnavailableStepHost extends StepHost {
  const UnavailableStepHost();
  @override
  Future<PopupResponse> messagePopup({
    required Object? title,
    required Object? message,
    required List<Object?> buttons,
    bool showResponse = false,
    Object? defaultResponse,
  }) => throw StepHostUnavailable('MessagePopup');
  @override
  Future<void> runStepType(String stepType, StepPhase phase, Object? step, Object? result) =>
      throw StepHostUnavailable('$stepType ${phase.name}');
}

StepHost stepHost = const UnavailableStepHost();

/// The status a sequence reports: failed once a step whose failure fails the sequence records a failed status.
class SequenceRun {
  bool failed = false;
  String get status => failed ? statusFailed : statusPassed;
  void record(Object? stepStatus) {
    if (stepStatus == statusFailed) failed = true;
  }
}

/// The looping state of a step that repeats: the RunState.LoopIndex and loop counters its expressions read.
class StepLoop {
  double index = 0;
  double numIterations = 0;
  double numPassed = 0;
  double numFailed = 0;
  void count(Object? status) {
    numIterations++;
    if (status == statusPassed) numPassed++;
    if (status == statusFailed) numFailed++;
  }
}

/// Start, Start + Step, … while the value has not passed Stop.
List<double> sweepSteps(Object? start, Object? stop, Object? step) {
  if (start is! num || stop is! num || step is! num || step == 0) {
    throw UnimplementedError('sweep from $start to $stop by $step');
  }
  final tolerance = step.abs() * 1e-9;
  final values = <double>[];
  for (
    var v = start.toDouble();
    step > 0 ? v <= stop + tolerance : v >= stop - tolerance;
    v = (start + values.length * step).toDouble()
  ) {
    values.add(v);
  }
  return values;
}

/// [count] points from [start] to [stop], both included, spaced evenly or by a constant ratio.
List<double> sweepPoints(Object? start, Object? stop, Object? count, {bool logarithmic = false}) {
  if (start is! num || stop is! num || count is! num || count < 1 || (logarithmic && start * stop <= 0)) {
    throw UnimplementedError('sweep of $count points from $start to $stop');
  }
  final n = count.toInt();
  if (n == 1) return [start.toDouble()];
  return [
    for (var i = 0; i < n; i++)
      logarithmic ? start * math.pow(stop / start, i / (n - 1)).toDouble() : start + (stop - start) * i / (n - 1),
  ];
}

/// Rows of the values that parallel sweep parameters take together; every column must have the same length.
Iterable<List<Object?>> parallel(List<Iterable<Object?>> columns) sync* {
  final lists = [for (final c in columns) c.toList()];
  final length = lists.first.length;
  if (lists.any((l) => l.length != length)) throw ArgumentError('parallel sweep parameters differ in length');
  for (var i = 0; i < length; i++) {
    yield [for (final l in lists) l[i]];
  }
}

Iterable<Object?> iterate(Object? v) => switch (v) {
  final Iterable<Object?> i => i,
  final Map<Object?, Object?> m => m.values,
  final PropObj p => p.entries,
  _ => throw UnimplementedError('iterate over ${v.runtimeType}'),
};

class PropObj {
  PropObj([Map<String, Object?> init = const {}]) : this.named('', init);

  PropObj.named(this._name, [Map<String, Object?> init = const {}]) {
    init.forEach((k, v) => this[k] = v);
  }

  String get name => _name;
  String _name;

  final Map<String, String> _canonical = {};
  final Map<String, Object?> _values = {};

  Object? operator [](String key) {
    final canon = _canonical[key.toLowerCase()];
    if (canon == null) {
      throw StateError("property '$key' is not set on ${name.isEmpty ? 'this object' : name}");
    }
    return _values[canon];
  }

  void operator []=(String key, Object? value) {
    final canon = _canonical.putIfAbsent(key.toLowerCase(), () => key);
    if (value is PropObj && value._name.isEmpty) value._name = canon;
    _values[canon] = value;
  }

  bool has(String key) => _canonical.containsKey(key.toLowerCase());

  List<PropObj> get entries => [
    for (final key in _values.keys)
      switch (_values[key]) {
        final PropObj p => p,
        final v => PropObj.named(key, {'Value': v}),
      },
  ];

  @override
  String toString() => 'PropObj(${name.isEmpty ? '' : '$name: '}${_values.keys.join(', ')})';

  @override
  dynamic noSuchMethod(Invocation invocation) {
    var member = invocation.memberName.toString();
    member = member.substring(8, member.length - 2);
    if (invocation.isSetter) {
      this[member.substring(0, member.length - 1)] = invocation.positionalArguments.single;
      return null;
    }
    if (invocation.isGetter) {
      return switch (member) {
        'AsPropertyObject' => this,
        'Name' => name,
        _ => this[member],
      };
    }
    return switch (member) {
      'GetSubProperties' => entries,
      'Exists' => has('${invocation.positionalArguments.first}'),
      _ => throw UnimplementedError('engine method not shimmed: PropObj.$member'),
    };
  }
}
