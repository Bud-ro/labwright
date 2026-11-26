import 'dart:math' as math;

dynamic eval(String expression) => throw UnimplementedError('expression not translated: $expression');

bool cond(String expression) => throw UnimplementedError('condition not translated: $expression');

void notExported(String action) => throw UnimplementedError(action);

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
  if (f2 != null || f3 != null) throw UnimplementedError('Str with localization or escaping options');
  if (f1 != null) {
    if (f1 is! String) throw UnimplementedError('Str with a ${f1.runtimeType} format');
    return printf(f1, v);
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

final _conversion = RegExp(r'%([-+ 0#]*)(\d+)?(?:\.(\d+))?([diufeExXos%])');

/// [format] with each C printf conversion replaced by [value]; a conversion outside d, i, u, f, e, E, x, X, o, s
/// and %% raises.
String printf(String format, Object? value) {
  if (format.replaceAll(_conversion, '').contains('%')) throw UnimplementedError('printf format $format');
  return format.replaceAllMapped(_conversion, (m) {
    final flags = m[1]!;
    final width = int.tryParse(m[2] ?? '') ?? 0;
    final precision = int.tryParse(m[3] ?? '');
    final conversion = m[4]!;
    if (conversion == '%') return '%';
    String body;
    var sign = '';
    num number() => value is num ? value : throw UnimplementedError('printf %$conversion of ${value.runtimeType}');
    switch (conversion) {
      case 'd' || 'i' || 'u':
        final n = number().truncate();
        if (conversion == 'u' && n < 0) throw UnimplementedError('printf %u of a negative number');
        body = n.abs().toString().padLeft(precision ?? 1, '0');
        if (n < 0) sign = '-';
      case 'x' || 'X' || 'o':
        final n = number().truncate();
        if (n < 0) throw UnimplementedError('printf %$conversion of a negative number');
        body = n.toRadixString(conversion == 'o' ? 8 : 16).padLeft(precision ?? 1, '0');
        if (conversion == 'X') body = body.toUpperCase();
        if (flags.contains('#') && n != 0) body = conversion == 'o' ? '0$body' : '0$conversion$body';
      case 'f':
        final n = number();
        body = n.abs().toStringAsFixed(precision ?? 6);
        if (n < 0) sign = '-';
      case 'e' || 'E':
        final n = number();
        final text = n.abs().toStringAsExponential(precision ?? 6);
        final cut = text.indexOf('e');
        final exponent = text.substring(cut + 2).padLeft(2, '0');
        body = '${text.substring(0, cut)}e${text[cut + 1]}$exponent';
        if (conversion == 'E') body = body.toUpperCase();
        if (n < 0) sign = '-';
      default:
        body = value is String ? value : str(value);
        if (precision != null && body.length > precision) body = body.substring(0, precision);
    }
    if (sign.isEmpty && 'difeE'.contains(conversion)) {
      if (flags.contains('+')) {
        sign = '+';
      } else if (flags.contains(' ')) {
        sign = ' ';
      }
    }
    final padding = width - sign.length - body.length;
    if (padding <= 0) return '$sign$body';
    if (flags.contains('-')) return '$sign$body${' ' * padding}';
    final zeroPad = flags.contains('0') && conversion != 's' && !(precision != null && 'diuxXo'.contains(conversion));
    return zeroPad ? '$sign${'0' * padding}$body' : '${' ' * padding}$sign$body';
  });
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

/// The sequence calls a sequence started in new threads: waited for by step name, and at the end of the calling
/// sequence when the call asked for it.
class AsyncCalls {
  final Map<String, Future<Object?>> _byStep = {};
  final List<Future<Object?>> _atEnd = [];
  void start(String step, Future<Object?> call, {required bool waitAtEnd}) {
    call.ignore();
    _byStep[step] = call;
    if (waitAtEnd) _atEnd.add(call);
  }

  Future<Object?> wait(String step) => _byStep[step] ?? (throw StateError('no thread was started by step "$step"'));
  Future<void> waitAtEnd() => Future.wait(_atEnd);
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

/// A step status: the text TestStand records in `Step.Result.Status`. The constants are the values TestStand and its
/// built-in step types set; a code module may set any other text.
extension type const Status(String text) implements String {
  /// [passed] when a judgement holds, [failed] when it does not.
  const Status.passFail(bool holds) : this(holds ? 'Passed' : 'Failed');

  /// The step judged its measurement and it passed, or its run mode is Force Pass.
  static const passed = Status('Passed');

  /// The step judged its measurement and it failed, or its run mode is Force Fail.
  static const failed = Status('Failed');

  /// The step finished without judging anything.
  static const done = Status('Done');

  /// A run-time error occurred in the step.
  static const error = Status('Error');

  /// The step did not run: its run mode is Skip or its precondition was false.
  static const skipped = Status('Skipped');

  /// The execution was terminated while the step ran.
  static const terminated = Status('Terminated');
}

/// Judges [value] against [low] and [high] as [comparison], a [LimitComparison] code, says: a comparison named by
/// one pair of letters uses [low] alone, and `LOG` uses neither.
///
/// `CheckLimits` translation, which a Numeric Limit Test's status expression calls. The `EQT` comparison, whose
/// limits are [nominal] widened by [low] and [high] as [thresholdType] says, is not implemented.
Status checkLimits(
  Object? value,
  Object? comparison, {
  Object? low,
  Object? high,
  Object? nominal,
  Object? thresholdType,
}) {
  final judged = LimitComparison.byCode[comparison];
  if (judged == null) throw UnimplementedError('CheckLimits comparison $comparison');
  if (judged == LimitComparison.log) return Status.passed;
  final upper = high ?? low;
  if (value is! num || low is! num || upper is! num) {
    throw UnimplementedError('CheckLimits of ${value.runtimeType} against ${low.runtimeType}..${high.runtimeType}');
  }
  return judged.passes(value, low, upper) ? Status.passed : Status.failed;
}

Status checkStrLimit(Object? value, Object? limit, Object? comparison, [Object? maxChars]) {
  final judged = StringComparison.byCode[comparison];
  if (judged == null || (maxChars != null && maxChars != -1)) {
    throw UnimplementedError('CheckStrLimit comparison $comparison${maxChars == null ? '' : ' over $maxChars chars'}');
  }
  if (judged == StringComparison.log) return Status.passed;
  if (value is! String || limit is! String) {
    throw UnimplementedError('CheckStrLimit of ${value.runtimeType} against ${limit.runtimeType}');
  }
  final equal = judged == StringComparison.ignoreCase ? value.toLowerCase() == limit.toLowerCase() : value == limit;
  return equal ? Status.passed : Status.failed;
}

/// A run-time error in a step: a problem with the testing process itself, not a test failure. It unwinds through each
/// sequence's cleanup to the caller unless the step ignores run-time errors.
final class RunTimeError implements Exception {
  const RunTimeError(this.code, this.message);
  final Object? code;
  final Object? message;
  @override
  String toString() => 'run-time error $code: $message';
}

/// Raised by a Terminate post action: the execution stops after each sequence on the way out runs its cleanup.
final class SequenceTermination implements Exception {
  const SequenceTermination();
  @override
  String toString() => 'execution terminated by a post action';
}

Never terminate() => throw const SequenceTermination();

/// What the operator answered a [messagePopup] with: the 1-based index of the button pressed and the text entered.
typedef PopupResponse = ({int buttonHit, String response});

/// Shows [message] in a dialog titled [title] and waits for the operator to press one of [buttons].
///
/// `MessagePopup` translation. With [showResponse] the dialog also has a text box, starting as [defaultResponse],
/// whose text the answer carries. With a [timeout] the dialog presses button [timeoutButton] itself once it elapses.
Future<PopupResponse> messagePopup(
  String title,
  String message, {
  List<String> buttons = const ['OK'],
  bool showResponse = false,
  String defaultResponse = '',
  Duration? timeout,
  int timeoutButton = 1,
}) => throw UnimplementedError('MessagePopup "$title"');

/// Starts the program at [path] with the command line [arguments] and, with [waitForExit], waits for it to exit.
///
/// `CallExecutable` translation. The answer carries the program's exit code, which is 0 when it was not waited for,
/// and the text it wrote to standard error.
Future<({int exitCode, String standardError})> callExecutable(
  String path, {
  String arguments = '',
  bool waitForExit = false,
}) => throw UnimplementedError('CallExecutable $path');

/// A measurement a [multipleNumericLimitTest] judges: [value] compared by [comparison] against [low] and [high].
typedef LimitMeasurement = ({Object? value, String comparison, Object? low, Object? high});

/// Judges each of [measurements] against its own limits, as [checkLimits] does: passes when every one passes.
///
/// `NI_MultipleNumericLimitTest` translation.
Status multipleNumericLimitTest(List<LimitMeasurement> measurements) =>
    measurements.every((m) => checkLimits(m.value, m.comparison, low: m.low, high: m.high) == Status.passed)
    ? Status.passed
    : Status.failed;

/// Runs the measurement plug-in service [service] with [inputs], by parameter name, and answers its outputs by
/// parameter name.
///
/// `NI_Measurement` translation.
Future<Map<String, Object?>> measurement(String service, [Map<String, Object?> inputs = const {}]) =>
    throw UnimplementedError('measurement $service');

/// Makes the pin map at [path] the one measurement plug-in services resolve pin names with.
///
/// `NI_UpdatePinMap` translation.
Future<void> updatePinMap(String path) => throw UnimplementedError('update pin map $path');

/// A lock a thread holds until it calls [release].
abstract interface class LockHold {
  void release();
}

/// Waits until no other thread holds the lock [nameOrReference] names, then takes it.
///
/// Translation of a step's setting to use a lock so that only one thread at a time executes it.
Future<LockHold> acquireLock(Object? nameOrReference) => throw UnimplementedError('lock $nameOrReference');

/// What a code module answers: its outputs by parameter name, with a cluster or struct member as `parameter.member`.
typedef ModuleOutputs = Map<String, Object?>;

/// The value a code module call answers as `Return Value`.
extension ModuleReturn on Future<ModuleOutputs> {
  Future<Object?> get returnValue async => (await this)['Return Value'];
}

/// Runs the LabVIEW VI at [path] with [inputs] wired to its controls by label.
///
/// LabVIEW adapter translation. A VI that [passesContext] receives the calling sequence's context and can read and
/// write its variables. An error on the VI's error out raises [RunTimeError].
Future<ModuleOutputs> callVi(String path, {Map<String, Object?> inputs = const {}, bool passesContext = false}) =>
    throw UnimplementedError('VI $path');

/// Calls [function] exported by the DLL at [library] with [inputs] by parameter name.
///
/// C/C++ DLL adapter translation. The function's return value answers as `Return Value`.
Future<ModuleOutputs> callDll(
  String library,
  String function, {
  Map<String, Object?> inputs = const {},
  bool passesContext = false,
}) => throw UnimplementedError('DLL $library:$function');

/// Uses [member], a constructor, method or property named with its class, of the .NET [assembly] with [inputs] by
/// parameter name. After the first call of a step, each call acts on the object the previous one answered.
///
/// .NET adapter translation. The member's value answers as `Return Value`.
Future<ModuleOutputs> callDotNet(
  String assembly,
  String member, {
  Map<String, Object?> inputs = const {},
  bool passesContext = false,
}) => throw UnimplementedError('.NET $member');

/// Calls [function] of the Python module at [module] with [inputs] by parameter name; with an [instance], calls it
/// as a method of that object.
///
/// Python adapter translation. The function's value answers as `Return Value`.
Future<ModuleOutputs> callPython(
  String module,
  String function, {
  Map<String, Object?> inputs = const {},
  Object? instance,
  bool passesContext = false,
}) => throw UnimplementedError('Python $module:$function');

/// Uses [member], a method or property named with its interface, of the COM [object] with [inputs] by parameter name.
///
/// ActiveX/COM adapter translation. The member's value answers as `Return Value`.
Future<ModuleOutputs> callActiveX(Object? object, String member, {Map<String, Object?> inputs = const {}}) =>
    throw UnimplementedError('ActiveX $member');

/// The text of [tag] in [category] of the station's localized resource strings.
///
/// `ResStr` and `GetResourceString` translation.
String resourceString(Object? category, Object? tag) => throw UnimplementedError('resource string $category/$tag');

/// Stands for [length] characters of serialized data the export does not decode.
final class Undecoded {
  const Undecoded(this.length);
  final int length;
}

/// Runs a step of [type], a step type this export does not translate, configured with [properties]: the values the
/// step sets that differ from its type's defaults. A [result] receives what the step type records.
Future<void> stepType(String type, [Map<String, Object?> properties = const {}, Object? result]) =>
    throw UnimplementedError('step type $type');

/// What a step records: its status, its run-time error, its report text, and the members its type adds as [extra].
class StepResult extends PropObj {
  StepResult([Map<String, Object?> extra = const {}])
    : super({
        'Error': PropObj({'Code': 0, 'Msg': '', 'Occurred': false}),
        'Status': '',
        'ReportText': '',
        'Common': PropObj(),
        ...extra,
      });
}

/// The status of a sequence whose steps can fail: failed once a step whose failure fails the sequence records
/// [Status.failed].
class SequenceRun {
  bool failed = false;
  Status get status => failed ? Status.failed : Status.passed;
  void record(Object? stepStatus) {
    if (stepStatus == Status.failed) failed = true;
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
    if (status == Status.passed) numPassed++;
    if (status == Status.failed) numFailed++;
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
