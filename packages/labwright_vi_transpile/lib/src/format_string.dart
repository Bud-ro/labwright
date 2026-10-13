/// A Format Into String format string, read as the published specifier syntax reads it: literal
/// text with backslash codes, `%%`, and `%[n$][-][+][0][width][.precision]conversion`. Elements the
/// lowering does not spell (`^`, `#`, `_`, `{unit}`, `<time>`, localisation codes, and the e, g,
/// p, b, o, u, t and T conversions) make the whole format unreadable, so [lvFormatPieces] returns
/// null for them.
sealed class LvFormatPiece {
  const LvFormatPiece();
}

final class LvFormatLiteral extends LvFormatPiece {
  const LvFormatLiteral(this.text);

  final String text;
}

enum LvFormatConversion { text, decimal, hexadecimal, hexadecimalUpper, fixed }

final class LvFormatSpecifier extends LvFormatPiece {
  const LvFormatSpecifier({
    required this.conversion,
    this.argument,
    this.leftJustify = false,
    this.plusSign = false,
    this.zeroPad = false,
    this.width,
    this.precision,
  });

  final LvFormatConversion conversion;

  /// The zero-based argument `n$` names, or null for the next one.
  final int? argument;

  final bool leftJustify;

  final bool plusSign;

  final bool zeroPad;

  final int? width;

  final int? precision;
}

List<LvFormatPiece>? lvFormatPieces(String format) {
  final pieces = <LvFormatPiece>[];
  final literal = StringBuffer();
  final units = format.codeUnits;
  var at = 0;
  void flush() {
    if (literal.isEmpty) return;
    pieces.add(LvFormatLiteral(literal.toString()));
    literal.clear();
  }

  while (at < units.length) {
    final unit = units[at];
    if (unit == 0x5c) {
      final escaped = _escape(units, at + 1);
      if (escaped == null) return null;
      literal.writeCharCode(escaped.$1);
      at = escaped.$2;
      continue;
    }
    if (unit != 0x25) {
      literal.writeCharCode(unit);
      at++;
      continue;
    }
    at++;
    if (at < units.length && units[at] == 0x25) {
      literal.write('%');
      at++;
      continue;
    }
    flush();
    int? argument, width, precision;
    var leftJustify = false, plusSign = false, zeroPad = false;
    final digits = _digits(units, at);
    if (digits != null && digits.$2 < units.length && units[digits.$2] == 0x24) {
      argument = digits.$1 - 1;
      at = digits.$2 + 1;
    }
    flags:
    while (at < units.length) {
      switch (units[at]) {
        case 0x2d:
          leftJustify = true;
        case 0x2b:
          plusSign = true;
        case 0x30:
          zeroPad = true;
        case _:
          break flags;
      }
      at++;
    }
    if (_digits(units, at) case (final value, final next)) {
      width = value;
      at = next;
    }
    if (at < units.length && units[at] == 0x2e) {
      final scale = _digits(units, at + 1);
      if (scale == null) return null;
      precision = scale.$1;
      at = scale.$2;
    }
    if (at >= units.length) return null;
    final conversion = switch (units[at]) {
      0x73 => LvFormatConversion.text,
      0x64 => LvFormatConversion.decimal,
      0x78 => LvFormatConversion.hexadecimal,
      0x58 => LvFormatConversion.hexadecimalUpper,
      0x66 => LvFormatConversion.fixed,
      _ => null,
    };
    if (conversion == null) return null;
    at++;
    pieces.add(
      LvFormatSpecifier(
        conversion: conversion,
        argument: argument,
        leftJustify: leftJustify,
        plusSign: plusSign,
        zeroPad: zeroPad,
        width: width,
        precision: precision,
      ),
    );
  }
  flush();
  return pieces;
}

(int, int)? _digits(List<int> units, int at) {
  var value = 0, next = at;
  while (next < units.length && units[next] >= 0x30 && units[next] <= 0x39) {
    value = value * 10 + units[next] - 0x30;
    next++;
  }
  return next == at ? null : (value, next);
}

/// The character a backslash code from [at] denotes and the index past it: two upper-case hex
/// digits, or one of `b f n s r t \`.
(int, int)? _escape(List<int> units, int at) {
  if (at >= units.length) return null;
  int? hex(int unit) => unit >= 0x30 && unit <= 0x39
      ? unit - 0x30
      : unit >= 0x41 && unit <= 0x46
      ? unit - 0x41 + 10
      : null;
  if (at + 1 < units.length && hex(units[at]) != null && hex(units[at + 1]) != null) {
    return (hex(units[at])! << 4 | hex(units[at + 1])!, at + 2);
  }
  return switch (units[at]) {
    0x62 => (0x08, at + 1),
    0x66 => (0x0c, at + 1),
    0x6e => (0x0a, at + 1),
    0x73 => (0x20, at + 1),
    0x72 => (0x0d, at + 1),
    0x74 => (0x09, at + 1),
    0x5c => (0x5c, at + 1),
    _ => null,
  };
}

/// [text] as a single-quoted Dart string literal.
String lvDartStringLiteral(String text) {
  final out = StringBuffer("'");
  for (final code in text.codeUnits) {
    switch (code) {
      case 0x5c:
        out.write(r'\\');
      case 0x27:
        out.write(r"\'");
      case 0x24:
        out.write(r'\$');
      case 0x0a:
        out.write(r'\n');
      case 0x0d:
        out.write(r'\r');
      case 0x09:
        out.write(r'\t');
      default:
        if (code < 0x20 || code >= 0x7f) {
          out.write('\\u{${code.toRadixString(16)}}');
        } else {
          out.writeCharCode(code);
        }
    }
  }
  return (out..write("'")).toString();
}
