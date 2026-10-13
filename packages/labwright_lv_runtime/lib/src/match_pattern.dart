/// LabVIEW's Match Pattern: the leftmost match of [pattern] in [string] at or after [offset],
/// with the string split around it. Without a match, `before` is the whole string, `match` and
/// `after` are empty and `offsetPastMatch` is −1. An offset below zero reads as zero.
({String before, String match, String after, int offsetPastMatch}) lvMatchPattern(
  String string,
  String pattern, [
  int offset = 0,
]) {
  final start = offset < 0 ? 0 : offset;
  final compiled = _LvPattern.parse(pattern);
  if (start <= string.length) {
    final last = compiled.anchoredAtOffset ? start : string.length;
    for (var at = start; at <= last; at++) {
      final end = compiled.matchAt(string, at);
      if (end != null) {
        return (
          before: string.substring(0, at),
          match: string.substring(at, end),
          after: string.substring(end),
          offsetPastMatch: end,
        );
      }
    }
  }
  return (before: string, match: '', after: '', offsetPastMatch: -1);
}

enum _Repeat { once, optional, star, plus }

class _Atom {
  const _Atom(this.matches, this.repeat);

  final bool Function(int unit) matches;

  final _Repeat repeat;
}

const int _kNewline = 0x0a;
const int _kSpace = 0x20;
const int _kTilde = 0x7e;
const int _kAsciiLimit = 0x80;

bool _isDisplayable(int unit) {
  if (unit >= _kAsciiLimit) {
    throw UnsupportedError(
      'Match Pattern over code unit 0x${unit.toRadixString(16)}: '
      "which characters above 0x7F LabVIEW's [^…] class counts as displayable is not decoded",
    );
  }
  return unit >= _kSpace && unit <= _kTilde;
}

class _LvPattern {
  _LvPattern(this.atoms, {required this.anchoredAtOffset, required this.anchoredAtEnd});

  final List<_Atom> atoms;

  final bool anchoredAtOffset;

  final bool anchoredAtEnd;

  static _LvPattern parse(String pattern) {
    final units = pattern.codeUnits;
    var at = 0;
    var end = units.length;
    final anchoredAtOffset = units.isNotEmpty && units[0] == 0x5e;
    if (anchoredAtOffset) at = 1;
    final anchoredAtEnd = end > at && units[end - 1] == 0x24 && !(end >= 2 && units[end - 2] == 0x5c);
    if (anchoredAtEnd) end--;
    final atoms = <_Atom>[];
    while (at < end) {
      final bool Function(int) matches;
      switch (units[at]) {
        case 0x2e:
          matches = (unit) => unit != _kNewline;
          at++;
        case 0x5b:
          final (set, next) = _parseClass(units, at + 1, end);
          matches = set;
          at = next;
        case 0x5c:
          final (literal, next) = _parseEscape(units, at + 1, end);
          matches = (unit) => unit == literal;
          at = next;
        case 0x2a || 0x2b || 0x3f:
          throw UnsupportedError(
            'Match Pattern pattern "$pattern": a quantifier at index $at follows no character, '
            "and LabVIEW's reading of it is not decoded",
          );
        case final literal:
          matches = (unit) => unit == literal;
          at++;
      }
      var repeat = _Repeat.once;
      if (at < end) {
        switch (units[at]) {
          case 0x2a:
            repeat = _Repeat.star;
            at++;
          case 0x2b:
            repeat = _Repeat.plus;
            at++;
          case 0x3f:
            repeat = _Repeat.optional;
            at++;
        }
      }
      atoms.add(_Atom(matches, repeat));
    }
    return _LvPattern(atoms, anchoredAtOffset: anchoredAtOffset, anchoredAtEnd: anchoredAtEnd);
  }

  /// A character class from after its `[` to its `]`: the set and the index past `]`.
  static (bool Function(int), int) _parseClass(List<int> units, int at, int end) {
    var negated = false, displayableOnly = false;
    if (at < end && units[at] == _kTilde) {
      negated = true;
      at++;
    } else if (at < end && units[at] == 0x5e) {
      negated = true;
      displayableOnly = true;
      at++;
    }
    final members = <int>[];
    final ranges = <(int, int)>[];
    var closed = false;
    while (at < end) {
      if (units[at] == 0x5d) {
        closed = true;
        at++;
        break;
      }
      final int literal;
      if (units[at] == 0x5c) {
        (literal, at) = _parseEscape(units, at + 1, end);
      } else {
        literal = units[at++];
      }
      if (at + 1 < end && units[at] == 0x2d && units[at + 1] != 0x5d && _ranges(literal, units[at + 1])) {
        ranges.add((literal, units[at + 1]));
        at += 2;
      } else {
        members.add(literal);
      }
    }
    if (!closed) {
      throw UnsupportedError('Match Pattern: a character class opened at index ${at - 1} is never closed');
    }
    if (members.isEmpty && ranges.isEmpty) {
      throw UnsupportedError("Match Pattern: an empty character class, whose reading in LabVIEW is not decoded");
    }
    bool listed(int unit) => members.contains(unit) || ranges.any((range) => unit >= range.$1 && unit <= range.$2);
    if (!negated) return (listed, at);
    if (!displayableOnly) return ((unit) => !listed(unit), at);
    return ((unit) => _isDisplayable(unit) && !listed(unit), at);
  }

  /// Whether `-` between [low] and [high] spans a range: both digits, both lowercase or both
  /// uppercase letters, in order.
  static bool _ranges(int low, int high) {
    bool digit(int c) => c >= 0x30 && c <= 0x39;
    bool lower(int c) => c >= 0x61 && c <= 0x7a;
    bool upper(int c) => c >= 0x41 && c <= 0x5a;
    return low <= high && ((digit(low) && digit(high)) || (lower(low) && lower(high)) || (upper(low) && upper(high)));
  }

  /// The character an escape from after its `\` denotes, and the index past the escape: two
  /// upper-case hex digits name a code, `b f n s r t` name controls, anything else is itself.
  static (int, int) _parseEscape(List<int> units, int at, int end) {
    if (at >= end) {
      throw UnsupportedError("Match Pattern: a pattern ending in '\\', whose reading in LabVIEW is not decoded");
    }
    if (at + 1 < end && _hexDigit(units[at]) != null && _hexDigit(units[at + 1]) != null) {
      return (_hexDigit(units[at])! << 4 | _hexDigit(units[at + 1])!, at + 2);
    }
    return switch (units[at]) {
      0x62 => (0x08, at + 1),
      0x66 => (0x0c, at + 1),
      0x6e => (0x0a, at + 1),
      0x73 => (0x20, at + 1),
      0x72 => (0x0d, at + 1),
      0x74 => (0x09, at + 1),
      final literal => (literal, at + 1),
    };
  }

  static int? _hexDigit(int unit) {
    if (unit >= 0x30 && unit <= 0x39) return unit - 0x30;
    if (unit >= 0x41 && unit <= 0x46) return unit - 0x41 + 10;
    return null;
  }

  /// Where a match starting at [at] ends, or null; each quantifier takes as much as it can and
  /// gives back only as much as the rest of the pattern needs.
  int? matchAt(String string, int at) => _matchFrom(string.codeUnits, at, 0);

  int? _matchFrom(List<int> units, int at, int atom) {
    if (atom == atoms.length) return !anchoredAtEnd || at == units.length ? at : null;
    final current = atoms[atom];
    final most = switch (current.repeat) {
      _Repeat.once || _Repeat.plus => current.repeat == _Repeat.plus ? units.length - at : 1,
      _Repeat.optional => 1,
      _Repeat.star => units.length - at,
    };
    final least = current.repeat == _Repeat.once || current.repeat == _Repeat.plus ? 1 : 0;
    var taken = 0;
    while (taken < most && at + taken < units.length && current.matches(units[at + taken])) {
      taken++;
    }
    for (var count = taken; count >= least; count--) {
      final end = _matchFrom(units, at + count, atom + 1);
      if (end != null) return end;
    }
    return null;
  }
}
