enum DartType {
  dynamic,
  integer,
  double,
  number,
  string,
  boolean,
  list,
  nullValue,
  other;

  bool get isNumeric => this == integer || this == double || this == number;
}

const _shimReturns = {
  'eval': DartType.dynamic,
  'cond': DartType.boolean,
  'truthy': DartType.boolean,
  'len': DartType.double,
  'getNumElements': DartType.double,
  'str': DartType.string,
  'left': DartType.string,
  'right': DartType.string,
  'mid': DartType.string,
  'find': DartType.double,
  'rand': DartType.double,
};

const _precedence = {
  '=': 1, '+=': 1, '-=': 1, '*=': 1, '/=': 1, '??=': 1, //
  '?': 2, '||': 3, '&&': 4, '==': 5, '!=': 5, '<': 6, '<=': 6, '>': 6, '>=': 6,
  '+': 7, '-': 7, '*': 8, '/': 8, '%': 8,
};

final _token = RegExp(
  r'''\s*(0[xX][0-9A-Fa-f]+|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|'(?:[^'\\]|\\.)*'|"(?:[^"\\]|\\.)*"|[A-Za-z_$][\w$]*|\?\?=|[-+*/]=|\?(?![?.])|==|!=|<=|>=|&&|\|\||\+\+|--|[-+*/%<>!=()\[\],.:])''',
);

enum _Kind { literal, identifier, member, call, subscript, paren, unary, binary, conditional }

class _Node {
  _Node(this.kind, this.start, this.end, {this.children = const [], this.op});
  final _Kind kind;
  final int start;
  int end;
  final List<_Node> children;
  final String? op;
  DartType type = DartType.other;
  String? prefix, suffix;
  bool get isPrimary => kind.index <= _Kind.paren.index;
}

bool isPrimaryDartExpression(String source) {
  final tokens = _tokens(source);
  if (tokens == null) return false;
  final parser = _Parser(tokens);
  try {
    final root = parser.expression(0);
    return parser.at == tokens.length && root.isPrimary;
  } on FormatException {
    return false;
  }
}

List<(String, int, int)>? _tokens(String source) {
  final tokens = <(String, int, int)>[];
  var at = 0;
  while (at < source.length) {
    final m = _token.matchAsPrefix(source, at);
    if (m == null) return source.substring(at).trim().isEmpty ? tokens : null;
    tokens.add((m[1]!, m.end - m[1]!.length, m.end));
    at = m.end;
  }
  return tokens;
}

class DartExpressionTyper {
  DartExpressionTyper(this.typeOf, {this.isConstant = _never});
  final DartType Function(String identifier) typeOf;
  final bool Function(String identifier) isConstant;
  static bool _never(String identifier) => false;

  ({String text, DartType type, bool comparable})? coerce(String source, {DartType? want, bool bare = true}) {
    final tokens = _tokens(source);
    if (tokens == null) return null;
    final parser = _Parser(tokens);
    final _Node root;
    try {
      root = parser.expression(0);
      if (parser.at != tokens.length) return null;
    } on FormatException {
      return null;
    }
    final checker = _Checker(this, source);
    checker.type(root);
    if (want != null) checker.convert(root, want, bare: bare);
    return (text: checker.print(root), type: root.type, comparable: !checker.incomparable);
  }
}

class _Parser {
  _Parser(this.tokens);
  final List<(String, int, int)> tokens;
  int at = 0;
  String? get peek => at < tokens.length ? tokens[at].$1 : null;
  (String, int, int) take([String? expected]) {
    if (at >= tokens.length || (expected != null && tokens[at].$1 != expected)) throw const FormatException();
    return tokens[at++];
  }

  _Node expression(int minimum) {
    var left = prefix();
    while (true) {
      final op = peek;
      final p = _precedence[op];
      if (p == null || p < minimum) return left;
      take();
      if (op == '?') {
        final then = expression(1);
        take(':');
        final otherwise = expression(1);
        left = _Node(_Kind.conditional, left.start, otherwise.end, children: [left, then, otherwise]);
        continue;
      }
      final right = expression(p == 1 ? p : p + 1);
      left = _Node(_Kind.binary, left.start, right.end, children: [left, right], op: op);
    }
  }

  _Node prefix() {
    final (text, start, _) = take();
    if (text == '!' || text == '-' || text == '++' || text == '--') {
      final operand = prefix();
      return _Node(_Kind.unary, start, operand.end, children: [operand], op: text);
    }
    late _Node node;
    if (text == '(') {
      final inner = expression(0);
      node = _Node(_Kind.paren, start, take(')').$3, children: [inner]);
    } else if (RegExp(r'''^[\d'"]''').hasMatch(text)) {
      node = _Node(_Kind.literal, start, tokens[at - 1].$3, op: text);
    } else if (RegExp(r'^[A-Za-z_$]').hasMatch(text)) {
      node = _Node(_Kind.identifier, start, tokens[at - 1].$3, op: text);
    } else {
      throw const FormatException();
    }
    while (true) {
      switch (peek) {
        case '.':
          take();
          final name = take();
          node = _Node(_Kind.member, node.start, name.$3, children: [node], op: name.$1);
        case '(':
          take();
          final args = <_Node>[node];
          while (peek != ')') {
            if (at + 1 < tokens.length && tokens[at + 1].$1 == ':') at += 2;
            args.add(expression(1));
            if (peek == ',') take();
          }
          node = _Node(_Kind.call, node.start, take(')').$3, children: args);
        case '[':
          take();
          final index = expression(0);
          node = _Node(_Kind.subscript, node.start, take(']').$3, children: [node, index]);
        case '++' || '--':
          node = _Node(_Kind.unary, node.start, take().$3, children: [node], op: 'post');
        default:
          return node;
      }
    }
  }
}

class _Checker {
  _Checker(this.typer, this.source);
  final DartExpressionTyper typer;
  final String source;
  bool incomparable = false;

  DartType type(_Node node) => node.type = switch (node.kind) {
    _Kind.literal => switch (node.op!) {
      final t when t.startsWith("'") || t.startsWith('"') => DartType.string,
      final t when t.contains('.') || (t.contains(RegExp('[eE]')) && !t.startsWith('0x')) => DartType.double,
      _ => DartType.integer,
    },
    _Kind.identifier => switch (node.op!) {
      'true' || 'false' => DartType.boolean,
      'null' => DartType.nullValue,
      final id => typer.typeOf(id),
    },
    _Kind.member => _member(node),
    _Kind.call => _call(node),
    _Kind.subscript => _index(node),
    _Kind.paren => type(node.children.single),
    _Kind.unary => _unary(node),
    _Kind.binary => _binary(node),
    _Kind.conditional => _conditional(node),
  };

  DartType _conditional(_Node node) {
    final [condition, then, otherwise] = node.children;
    type(condition);
    convert(condition, DartType.boolean);
    final (t, o) = (type(then), type(otherwise));
    if (t == o) return t;
    if (t == DartType.dynamic || o == DartType.dynamic) return DartType.dynamic;
    return t.isNumeric && o.isNumeric ? DartType.number : DartType.other;
  }

  DartType _member(_Node node) {
    final receiver = node.children.single;
    if (receiver.kind == _Kind.identifier && receiver.op == 'station') return DartType.dynamic;
    if (receiver.kind == _Kind.identifier) {
      final known = typer.typeOf('${receiver.op}.${node.op}');
      if (known != DartType.other) {
        type(receiver);
        return known;
      }
    }
    return type(receiver) == DartType.dynamic ? DartType.dynamic : DartType.other;
  }

  DartType _call(_Node node) {
    final callee = node.children.first;
    for (final arg in node.children.skip(1)) {
      type(arg);
    }
    if (callee.kind == _Kind.member && callee.children.single.kind == _Kind.identifier) {
      final receiver = callee.children.single.op;
      if (receiver == 'ts') return _shimReturns[callee.op] ?? DartType.other;
    }
    return type(callee) == DartType.dynamic ? DartType.dynamic : DartType.other;
  }

  DartType _index(_Node node) {
    final receiver = type(node.children[0]);
    type(node.children[1]);
    if (receiver == DartType.list || receiver == DartType.string) convert(node.children[1], DartType.integer);
    return receiver == DartType.string
        ? DartType.string
        : (receiver == DartType.other ? DartType.other : DartType.dynamic);
  }

  DartType _unary(_Node node) {
    final operand = node.children.single;
    final t = type(operand);
    if (node.op == '!') {
      convert(operand, DartType.boolean);
      return DartType.boolean;
    }
    return t;
  }

  DartType _binary(_Node node) {
    final [left, right] = node.children;
    final op = node.op!;
    var l = type(left);
    final r = type(right);
    switch (_precedence[op]) {
      case 1:
        if (op == '??=') return l;
        if (op == '=') {
          convert(right, l, bare: true);
        } else if (l.isNumeric) {
          convert(right, DartType.number, bare: true);
        } else if (l == DartType.string) {
          convert(right, DartType.string, bare: true);
        }
        return l;
      case 3 || 4:
        convert(left, DartType.boolean);
        convert(right, DartType.boolean);
        return DartType.boolean;
      case 5:
        final known = {l, r}..removeAll(const {DartType.dynamic, DartType.other, DartType.nullValue});
        if (known.length == 2 && !known.every((t) => t.isNumeric)) incomparable = true;
        return DartType.boolean;
      case 6:
        if (l == DartType.dynamic) {
          convert(left, DartType.number);
          l = DartType.number;
        }
        if (l != DartType.string) convert(right, DartType.number);
        return DartType.boolean;
      default:
        if (l == DartType.dynamic || l == DartType.other) return l;
        if (l == DartType.string) {
          if (op == '+') convert(right, DartType.string);
          return DartType.string;
        }
        if (!l.isNumeric) return DartType.other;
        convert(right, DartType.number);
        final rt = right.type;
        if (op == '/' || l == DartType.double || rt == DartType.double) return DartType.double;
        return l == DartType.integer && rt == DartType.integer ? DartType.integer : DartType.number;
    }
  }

  void convert(_Node node, DartType want, {bool bare = false}) {
    final have = node.type;
    void wrap(String start, String end) => node
      ..prefix = '$start${node.prefix ?? ''}'
      ..suffix = '${node.suffix ?? ''}$end';

    void cast(String type) => bare ? wrap('', ' as $type') : wrap('(', ' as $type)');
    void method(String name) => node.isPrimary && node.prefix == null ? wrap('', '.$name()') : wrap('(', ').$name()');
    if (want == DartType.boolean && node.kind == _Kind.identifier && typer.isConstant(node.op!)) {
      wrap('ts.truthy(', ')');
      return;
    }
    switch (want) {
      case DartType.boolean when have == DartType.dynamic:
        cast('bool');
      case DartType.string when have == DartType.dynamic:
        cast('String');
      case DartType.list when have == DartType.dynamic:
        cast('List<dynamic>');
      case DartType.number when have == DartType.dynamic:
        cast('num');
      case DartType.integer when have == DartType.dynamic:
        wrap('(', ' as num).toInt()');
      case DartType.integer when have == DartType.double || have == DartType.number:
        method('toInt');
      case DartType.double when have == DartType.dynamic:
        wrap('(', ' as num).toDouble()');
      case DartType.double when have == DartType.number || (have == DartType.integer && node.kind != _Kind.literal):
        method('toDouble');
      default:
        return;
    }
    node.type = want == DartType.number ? DartType.number : want;
  }

  String print(_Node node) {
    final out = StringBuffer(node.prefix ?? '');
    var at = node.start;
    final children = [...node.children]..sort((a, b) => a.start.compareTo(b.start));
    for (final child in children) {
      out
        ..write(source.substring(at, child.start))
        ..write(print(child));
      at = child.end;
    }
    out
      ..write(source.substring(at, node.end))
      ..write(node.suffix ?? '');
    return out.toString();
  }
}
