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
