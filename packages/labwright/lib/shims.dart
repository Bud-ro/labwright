/// Runtime compatibility shims for Dart programs exported from `.seq`
/// test-sequence files by `package:labwright_seq`.
///
/// The exported logic is plain Dart; these helpers cover the sequence
/// engine's expression built-ins (`Len`, `Str`, `Left`, …) and its
/// structured-variable model ([PropObj]) so generated code stays free of
/// per-file boilerplate. Import prefixed, conventionally `as ts`
/// ("test sequence"): `ts.len(x)`, `ts.truthy(v)`, `ts.eval('…')`.
///
/// The `.seq` format is produced by NI TestStand™; the name is used here
/// only to identify what these shims are compatible with — labwright is an
/// independent project, not affiliated with or endorsed by NI.
///
/// **Honesty contract.** [eval] and [cond] ALWAYS throw: an expression the
/// exporter could not translate mechanically arrives verbatim and must be
/// ported by hand — evaluating a guess would fabricate test behavior.
/// Everything else implements the engine semantics the corpus pins;
/// engine-specific forms (format strings, option arguments) throw
/// [UnimplementedError] loudly rather than approximating silently.
library;

import 'dart:math' as math;

/// An expression the exporter left untranslated, verbatim. Always throws:
/// port the expression to Dart by hand, then delete the call. Typed
/// `dynamic` (not `Never`) so the call composes anywhere the engine value
/// would have — arithmetic, arguments, assignment — without analyzer
/// noise about unreachable receivers.
dynamic eval(String expression) => throw UnimplementedError('expression not translated: $expression');

/// [eval] in condition position (`if (ts.cond('…'))`). Typed `bool` so the
/// generated `if` compiles; always throws, exactly like [eval].
bool cond(String expression) => throw UnimplementedError('condition not translated: $expression');

/// Engine truthiness for a value of unknown type: numbers are true when
/// non-zero, bools are themselves, strings/objects follow the engine's
/// boolean coercion where pinned.
bool truthy(Object? v) => switch (v) {
  final bool b => b,
  final num n => n != 0,
  _ => throw UnimplementedError('truthiness of ${v.runtimeType}'),
};

/// `Len`: string length or array element count.
double len(Object? v) => switch (v) {
  final String s => s.length.toDouble(),
  final Iterable<Object?> i => i.length.toDouble(),
  final Map<Object?, Object?> m => m.length.toDouble(),
  final PropObj p => p.entries.length.toDouble(),
  _ => throw UnimplementedError('Len of ${v.runtimeType}'),
};

/// `GetNumElements` (array size). The engine-specific forms (extra
/// arguments) are not implemented.
double getNumElements(Object? v, [Object? a]) =>
    a == null ? len(v) : throw UnimplementedError('GetNumElements with options');

/// `SetNumElements`: resizes a growable list, null-filling new slots (the
/// engine default-fills by element type — a null fill is the closest
/// core-Dart equivalent; replace in a real host if it matters).
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

/// `Str` (1-arg): number → string with the engine's default `%$.13g`
/// format, approximated with toStringAsPrecision(13) + cleanup. C-printf
/// `%g` edge cases may differ — replace in a real host if exactness
/// matters. Format-string forms are not implemented.
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

/// `Left`/`Right`/`Mid`/`Find` string helpers (counts clamped, as the
/// engine clamps).
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

/// `Random()` / `Random(min, max)` for PLAIN (non-suite) exports —
/// unseeded. Suite-mode exports use `lw.rand` instead, which draws from
/// the labwright seed so runs reproduce.
double rand([Object? min, Object? max]) {
  final r = (_rng ??= math.Random()).nextDouble();
  if (min is num && max is num) return min + r * (max - min);
  if (min == null && max == null) return r;
  throw UnimplementedError('Random with non-numeric bounds');
}

/// The value sequence a `For Each` step iterates: lists iterate their
/// elements, [PropObj]s their sub-properties (as [PropObj] views, matching
/// the engine's `GetSubProperties`).
Iterable<Object?> iterate(Object? v) => switch (v) {
  final Iterable<Object?> i => i,
  final Map<Object?, Object?> m => m.values,
  final PropObj p => p.entries,
  _ => throw UnimplementedError('iterate over ${v.runtimeType}'),
};

/// A structured sequence variable (an `Obj`/container), preserving the
/// declared default structure the source file carries — member names are
/// case-insensitive, like the engine.
///
/// Use through `dynamic` dispatch, exactly as exported code does:
/// `bag.Foo` reads, `bag.Foo = v` writes (creating the member), and the
/// engine-object surface (`AsPropertyObject`, `Name`, `GetSubProperties`,
/// `Exists`) is emulated via [noSuchMethod]. Reading a member that was
/// never set THROWS — the engine errors on unknown properties too, and
/// returning null would fabricate values. Engine methods beyond the ones
/// listed throw [UnimplementedError] naming the call.
class PropObj {
  PropObj([Map<String, Object?> init = const {}]) : this.named('', init);

  PropObj.named(this._name, [Map<String, Object?> init = const {}]) {
    init.forEach((k, v) => this[k] = v);
  }

  /// The property's name as its parent declares it ('' for a root bag).
  /// A bag stored into a parent slot takes that slot's name — properties
  /// are named by where they live, as in the engine.
  String get name => _name;
  String _name;

  final Map<String, String> _canonical = {}; // lowercased → declared casing
  final Map<String, Object?> _values = {}; // declared casing → value

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

  /// Whether [key] is set (case-insensitive).
  bool has(String key) => _canonical.containsKey(key.toLowerCase());

  /// The sub-properties, each as a [PropObj] view carrying its name —
  /// what the engine's `GetSubProperties("", 0)` returns. A scalar child
  /// is wrapped in a single-value [PropObj] (its value under `Value`).
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
    // Symbol has no public name accessor without dart:mirrors; its VM
    // toString ('Symbol("Foo")' / 'Symbol("Foo=")') is the stable idiom.
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
