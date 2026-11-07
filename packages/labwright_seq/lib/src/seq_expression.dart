/// A binary operator of the sequence expression language, with its binding strength.
enum SeqBinaryOp {
  /// Logical or.
  or('||', 3),

  /// Logical and.
  and('&&', 4),

  /// Bitwise or.
  bitOr('|', 5),

  /// Bitwise exclusive or.
  bitXor('^', 6),

  /// Bitwise and.
  bitAnd('&', 7),

  /// Equality.
  equal('==', 8),

  /// Inequality.
  notEqual('!=', 8),

  /// Less than.
  less('<', 9),

  /// Less than or equal.
  lessEqual('<=', 9),

  /// Greater than.
  greater('>', 9),

  /// Greater than or equal.
  greaterEqual('>=', 9),

  /// Left shift.
  shiftLeft('<<', 10),

  /// Right shift.
  shiftRight('>>', 10),

  /// Addition, or string concatenation.
  add('+', 11),

  /// Subtraction.
  subtract('-', 11),

  /// Multiplication.
  multiply('*', 12),

  /// Division.
  divide('/', 12),

  /// Remainder, signed like the dividend.
  modulo('%', 12);

  const SeqBinaryOp(this.token, this.precedence);
  final String token;
  final int precedence;
  static final Map<String, SeqBinaryOp> byToken = {for (final op in values) op.token: op};
}

/// An assignment operator: plain, or compound with the binary operator it applies.
enum SeqAssignOp {
  assign('=', null),
  add('+=', SeqBinaryOp.add),
  subtract('-=', SeqBinaryOp.subtract),
  multiply('*=', SeqBinaryOp.multiply),
  divide('/=', SeqBinaryOp.divide),
  modulo('%=', SeqBinaryOp.modulo),
  bitAnd('&=', SeqBinaryOp.bitAnd),
  bitOr('|=', SeqBinaryOp.bitOr),
  bitXor('^=', SeqBinaryOp.bitXor);

  const SeqAssignOp(this.token, this.binary);
  final String token;
  final SeqBinaryOp? binary;
  static final Map<String, SeqAssignOp> byToken = {for (final op in values) op.token: op};
}

/// A prefix operator.
enum SeqUnaryOp {
  not('!'),
  negate('-'),
  plus('+'),
  bitNot('~');

  const SeqUnaryOp(this.token);
  final String token;
  static final Map<String, SeqUnaryOp> byToken = {for (final op in values) op.token: op};
}

sealed class SeqExpr {
  const SeqExpr();
}

final class SeqNumber extends SeqExpr {
  const SeqNumber(this.value, {required this.integral});
  final num value;
  final bool integral;
}

final class SeqString extends SeqExpr {
  const SeqString(this.value);
  final String value;
}

final class SeqBool extends SeqExpr {
  const SeqBool(this.value);
  final bool value;
}

final class SeqNothing extends SeqExpr {
  const SeqNothing();
}

final class SeqName extends SeqExpr {
  const SeqName(this.name);
  final String name;
}

final class SeqMember extends SeqExpr {
  const SeqMember(this.target, this.name);
  final SeqExpr target;
  final String name;
}

final class SeqIndex extends SeqExpr {
  const SeqIndex(this.target, this.index);
  final SeqExpr target;
  final SeqExpr index;
}

final class SeqCall extends SeqExpr {
  const SeqCall(this.callee, this.arguments);
  final SeqExpr callee;
  final List<SeqExpr> arguments;
}

final class SeqUnary extends SeqExpr {
  const SeqUnary(this.op, this.operand);
  final SeqUnaryOp op;
  final SeqExpr operand;
}

final class SeqStep extends SeqExpr {
  const SeqStep(this.target, {required this.increment, required this.prefix});
  final SeqExpr target;
  final bool increment;
  final bool prefix;
}

final class SeqBinary extends SeqExpr {
  const SeqBinary(this.op, this.left, this.right);
  final SeqBinaryOp op;
  final SeqExpr left;
  final SeqExpr right;
}

final class SeqConditional extends SeqExpr {
  const SeqConditional(this.condition, this.whenTrue, this.whenFalse);
  final SeqExpr condition;
  final SeqExpr whenTrue;
  final SeqExpr whenFalse;
}

final class SeqAssign extends SeqExpr {
  const SeqAssign(this.op, this.target, this.value);
  final SeqAssignOp op;
  final SeqExpr target;
  final SeqExpr value;
}

final class SeqArray extends SeqExpr {
  const SeqArray(this.elements);
  final List<SeqExpr> elements;
}

final class SeqSequence extends SeqExpr {
  const SeqSequence(this.items);
  final List<SeqExpr> items;
}

/// Parses one expression, null when [text] uses a construct the grammar does not cover.
SeqExpr? parseSeqExpression(String text) {
  final tokens = _lex(_withoutValidationMarkers(text));
  if (tokens == null || tokens.isEmpty) return null;
  final parser = _Parser(tokens);
  try {
    final expr = parser.sequence();
    return parser.atEnd ? expr : null;
  } on _ParseFailure {
    return null;
  }
}

enum _Kind { number, string, name, symbol }

typedef _Token = ({_Kind kind, String text, Object? value});

const _symbols = [
  '<<=', '>>=', '==', '!=', '<=', '>=', '&&', '||', '<<', '>>', '++', '--', //
  '+=', '-=', '*=', '/=', '%=', '&=', '|=', '^=', //
  '+', '-', '*', '/', '%', '<', '>', '=', '!', '~', '&', '|', '^', '?', ':', ',', '.', '(', ')', '[', ']', '{', '}',
];

final _numberPattern = RegExp(r'(0[xX][0-9a-fA-F]+|0[bB][01]+|(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?)(u?i64)?');
final _integralDigits = RegExp(r'^(?:[0-9]+|0[xXbB].*)$');
final _namePattern = RegExp(r'[A-Za-z_][A-Za-z0-9_]*');

String _withoutValidationMarkers(String text) {
  const marker = '#NoValidation(';
  var result = text;
  for (var at = result.indexOf(marker); at >= 0; at = result.indexOf(marker)) {
    var depth = 1;
    var i = at + marker.length;
    for (; i < result.length && depth > 0; i++) {
      if (result[i] == '(') depth++;
      if (result[i] == ')') depth--;
    }
    if (depth != 0) return text;
    result = result.substring(0, at) + result.substring(at + marker.length, i - 1) + result.substring(i);
  }
  return result;
}

List<_Token>? _lex(String text) {
  final tokens = <_Token>[];
  var i = 0;
  while (i < text.length) {
    final c = text.codeUnitAt(i);
    if (c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D) {
      i++;
      continue;
    }
    if (text.startsWith('//', i)) {
      final end = text.indexOf('\n', i);
      i = end < 0 ? text.length : end;
      continue;
    }
    if (text.startsWith('/*', i)) {
      final end = text.indexOf('*/', i + 2);
      if (end < 0) return null;
      i = end + 2;
      continue;
    }
    if (c == 0x22 || (c == 0x40 && text.startsWith('@"', i))) {
      final verbatim = c == 0x40;
      final value = StringBuffer();
      var j = verbatim ? i + 2 : i + 1;
      for (; ; j++) {
        if (j >= text.length) return null;
        final d = text[j];
        if (d == '"') {
          if (verbatim && j + 1 < text.length && text[j + 1] == '"') return null;
          break;
        }
        if (d == '\n' || d == '\r') return null;
        if (d == r'\' && !verbatim) {
          if (j + 1 >= text.length) return null;
          final escaped = switch (text[++j]) {
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            '"' => '"',
            "'" => "'",
            r'\' => r'\',
            _ => null,
          };
          if (escaped == null) return null;
          value.write(escaped);
        } else {
          value.write(d);
        }
      }
      tokens.add((kind: _Kind.string, text: text.substring(i, j + 1), value: value.toString()));
      i = j + 1;
      continue;
    }
    final number = c >= 0x30 && c <= 0x39 || (c == 0x2E && i + 1 < text.length && _isDigit(text.codeUnitAt(i + 1)))
        ? _numberPattern.matchAsPrefix(text, i)
        : null;
    if (number != null) {
      final digits = number.group(1)!;
      final value = digits.startsWith(RegExp('0[bB]'))
          ? int.tryParse(digits.substring(2), radix: 2)
          : num.tryParse(digits);
      if (value == null) return null;
      final integral = number.group(2) != null || _integralDigits.hasMatch(digits);
      tokens.add((kind: _Kind.number, text: digits, value: (value, integral && value % 1 == 0)));
      i = number.end;
      if (i < text.length && _namePattern.matchAsPrefix(text, i) != null) return null;
      continue;
    }
    final name = _namePattern.matchAsPrefix(text, i);
    if (name != null) {
      tokens.add((kind: _Kind.name, text: name.group(0)!, value: null));
      i = name.end;
      continue;
    }
    final symbol = _symbols.where((s) => text.startsWith(s, i)).firstOrNull;
    if (symbol == null || symbol == '<<=' || symbol == '>>=') return null;
    tokens.add((kind: _Kind.symbol, text: symbol, value: null));
    i += symbol.length;
  }
  return tokens;
}

bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

final class _ParseFailure implements Exception {
  const _ParseFailure();
}

class _Parser {
  _Parser(this.tokens);
  final List<_Token> tokens;
  int at = 0;
  bool get atEnd => at >= tokens.length;
  _Token? get peek => atEnd ? null : tokens[at];
  bool isSymbol(String s) => peek?.kind == _Kind.symbol && peek!.text == s;
  bool accept(String s) {
    if (!isSymbol(s)) return false;
    at++;
    return true;
  }

  void expect(String s) {
    if (!accept(s)) throw const _ParseFailure();
  }

  SeqExpr sequence() {
    final items = [assignment()];
    while (accept(',')) {
      if (atEnd) break;
      items.add(assignment());
    }
    return items.length == 1 ? items.single : SeqSequence(items);
  }

  SeqExpr assignment() {
    final target = conditional();
    final token = peek;
    final op = token?.kind == _Kind.symbol ? SeqAssignOp.byToken[token!.text] : null;
    if (op == null) return target;
    at++;
    return SeqAssign(op, target, assignment());
  }

  SeqExpr conditional() {
    final condition = binary(SeqBinaryOp.or.precedence);
    if (!accept('?')) return condition;
    final whenTrue = assignment();
    expect(':');
    return SeqConditional(condition, whenTrue, assignment());
  }

  SeqExpr binary(int minPrecedence) {
    var left = unary();
    while (true) {
      final token = peek;
      final op = token?.kind == _Kind.symbol ? SeqBinaryOp.byToken[token!.text] : null;
      if (op == null || op.precedence < minPrecedence) return left;
      at++;
      left = SeqBinary(op, left, binary(op.precedence + 1));
    }
  }

  SeqExpr unary() {
    if (isSymbol('++') || isSymbol('--')) {
      final increment = tokens[at++].text == '++';
      return SeqStep(unary(), increment: increment, prefix: true);
    }
    final token = peek;
    final op = token?.kind == _Kind.symbol ? SeqUnaryOp.byToken[token!.text] : null;
    if (op != null) {
      at++;
      return SeqUnary(op, unary());
    }
    return postfix(primary());
  }

  SeqExpr postfix(SeqExpr base) {
    var expr = base;
    while (true) {
      if (accept('.')) {
        final name = peek;
        if (name?.kind != _Kind.name) throw const _ParseFailure();
        at++;
        expr = SeqMember(expr, name!.text);
      } else if (accept('[')) {
        final index = sequence();
        expect(']');
        expr = SeqIndex(expr, index);
      } else if (accept('(')) {
        expr = SeqCall(expr, arguments(')'));
      } else if (isSymbol('++') || isSymbol('--')) {
        final increment = peek!.text == '++';
        at++;
        expr = SeqStep(expr, increment: increment, prefix: false);
      } else {
        return expr;
      }
    }
  }

  List<SeqExpr> arguments(String close) {
    final args = <SeqExpr>[];
    if (accept(close)) return args;
    do {
      args.add(assignment());
    } while (accept(','));
    expect(close);
    return args;
  }

  SeqExpr primary() {
    final token = peek;
    if (token == null) throw const _ParseFailure();
    at++;
    switch (token.kind) {
      case _Kind.number:
        final (num value, bool integral) = token.value! as (num, bool);
        return SeqNumber(integral ? value.toInt() : value.toDouble(), integral: integral);
      case _Kind.string:
        return SeqString(token.value! as String);
      case _Kind.name:
        return switch (token.text.toLowerCase()) {
          'true' => const SeqBool(true),
          'false' => const SeqBool(false),
          'nothing' => const SeqNothing(),
          _ => SeqName(token.text),
        };
      case _Kind.symbol:
        if (token.text == '(') {
          final inner = sequence();
          expect(')');
          return inner;
        }
        if (token.text == '{') return SeqArray(arguments('}'));
        throw const _ParseFailure();
    }
  }
}
