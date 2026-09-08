part of 'dart_export.dart';

const _dartReserved = {
  'if',
  'else',
  'for',
  'while',
  'do',
  'switch',
  'case',
  'default',
  'break',
  'continue',
  'return',
  'var',
  'final',
  'const',
  'void',
  'main',
  'class',
  'new',
  'this',
  'super',
  'true',
  'false',
  'null',
  'is',
  'in',
  'try',
  'catch',
  'finally',
  'throw',
  'rethrow',
  'assert',
  'await',
  'async',
  'enum',
  'extends',
  'with',
  'implements',
  'abstract',
  'static',
  'late',
  'required',
  'dynamic',
  'yield',
  'export',
  'import',
  'library',
  'part',
  'fileGlobals',
  'stationGlobals',
  'runState',
  'step',
  'ts',
  'params',
  'locals',
  's',
  'ctx',
  'lw',
};

String dartIdentifier(String name, {bool capitalize = false}) {
  final words = <String>[
    for (final chunk in name.split(RegExp(r'[^A-Za-z0-9]+')))
      if (chunk.isNotEmpty)
        ...chunk
            .replaceAllMapped(RegExp(r'([a-z0-9])([A-Z])'), (match) => '${match.group(1)} ${match.group(2)}')
            .replaceAllMapped(RegExp(r'([A-Z]+)([A-Z][a-z])'), (match) => '${match.group(1)} ${match.group(2)}')
            .split(' ')
            .where((piece) => piece.isNotEmpty),
  ];
  if (words.isEmpty) return capitalize ? 'Unnamed' : 'unnamed';
  final buffer = StringBuffer();
  for (var wordIndex = 0; wordIndex < words.length; wordIndex++) {
    final word = words[wordIndex].toLowerCase();
    if (wordIndex == 0 && !capitalize) {
      buffer.write(word);
    } else {
      buffer.write(word[0].toUpperCase() + word.substring(1));
    }
  }
  var identifier = buffer.toString();
  if (RegExp(r'^[0-9]').hasMatch(identifier)) identifier = 'v$identifier';
  if (_dartReserved.contains(identifier)) identifier = '$identifier\$';
  return identifier;
}

String _uniqueName(String base, Set<String> taken) {
  var name = base;
  var suffix = 2;
  while (!taken.add(name)) {
    name = '$base${suffix++}';
  }
  return name;
}

Set<String> _reservedTopLevelNames({required bool asTest, String? registerName}) => {
  'ts',
  'fileGlobals',
  'stationGlobals',
  'runState',
  'step',
  'FileGlobals',
  'StationGlobals',
  if (asTest) ...const {'lw', 'main'},
  if (registerName != null) registerName,
};

Map<String, String> _sequenceFnTable(SeqFile file, Set<String> taken) {
  final table = <String, String>{};
  for (final sequence in file.sequences) {
    if (table.containsKey(sequence.name)) continue;
    table[sequence.name] = _uniqueName(dartIdentifier(sequence.name), taken);
  }
  return table;
}

List<(String, bool)> _segments(String text) {
  final out = <(String, bool)>[];
  var start = 0;
  var cursor = 0;
  while (cursor < text.length) {
    final char = text[cursor];
    if (char == '"' || char == "'") {
      if (cursor > start) out.add((text.substring(start, cursor), false));
      final quote = char;
      var quoteEnd = cursor + 1;
      while (quoteEnd < text.length) {
        if (text[quoteEnd] == r'\') {
          quoteEnd += 2;
          continue;
        }
        if (text[quoteEnd] == quote) break;
        quoteEnd++;
      }
      quoteEnd = quoteEnd < text.length ? quoteEnd + 1 : text.length;
      out.add((text.substring(cursor, quoteEnd), true));
      start = quoteEnd;
      cursor = quoteEnd;
    } else {
      cursor++;
    }
  }
  if (start < text.length) out.add((text.substring(start), false));
  return out;
}

String _stripComments(String text) {
  final out = StringBuffer();
  var cursor = 0;
  while (cursor < text.length) {
    final char = text[cursor];
    if (char == '"' || char == "'") {
      out.write(char);
      cursor++;
      while (cursor < text.length) {
        out.write(text[cursor]);
        if (text[cursor] == r'\') {
          if (cursor + 1 < text.length) out.write(text[cursor + 1]);
          cursor += 2;
          continue;
        }
        final closed = text[cursor] == char;
        cursor++;
        if (closed) break;
      }
      continue;
    }
    if (char == '/' && cursor + 1 < text.length && text[cursor + 1] == '/') {
      while (cursor < text.length && text[cursor] != '\n' && text[cursor] != '\r') {
        cursor++;
      }
      continue;
    }
    if (char == '/' && cursor + 1 < text.length && text[cursor + 1] == '*') {
      final end = text.indexOf('*/', cursor + 2);
      out.write(' ');
      cursor = end < 0 ? text.length : end + 2;
      continue;
    }
    out.write(char);
    cursor++;
  }
  return out.toString();
}

String _stripNoValidation(String text) {
  const marker = '#NoValidation(';
  var result = text;
  var markerAt = result.indexOf(marker);
  while (markerAt >= 0) {
    var depth = 1;
    var cursor = markerAt + marker.length;
    while (cursor < result.length && depth > 0) {
      if (result[cursor] == '(') depth++;
      if (result[cursor] == ')') depth--;
      cursor++;
    }
    if (depth != 0) return text;
    result =
        result.substring(0, markerAt) +
        result.substring(markerAt + marker.length, cursor - 1) +
        result.substring(cursor);
    markerAt = result.indexOf(marker);
  }
  return result;
}

List<String> _splitTopLevelCommas(String text) {
  final parts = <String>[];
  var depth = 0;
  var start = 0;
  var consumed = 0;
  for (final (segment, isString) in _segments(text)) {
    if (!isString) {
      for (var charIndex = 0; charIndex < segment.length; charIndex++) {
        switch (segment[charIndex]) {
          case '(' || '[' || '{':
            depth++;
          case ')' || ']' || '}':
            depth--;
          case ',':
            if (depth <= 0) {
              parts.add(text.substring(start, consumed + charIndex));
              start = consumed + charIndex + 1;
            }
        }
      }
    }
    consumed += segment.length;
  }
  parts.add(text.substring(start));
  return parts;
}

List<String>? _rawStmtPieces(String raw) {
  final cleaned = _stripNoValidation(_stripComments(raw));
  final parts = _splitTopLevelCommas(cleaned);
  bool balanced(String piece) {
    var depth = 0;
    for (final (segment, isString) in _segments(piece)) {
      if (isString) continue;
      for (var charIndex = 0; charIndex < segment.length; charIndex++) {
        if (segment[charIndex] == '(' || segment[charIndex] == '[' || segment[charIndex] == '{') depth++;
        if (segment[charIndex] == ')' || segment[charIndex] == ']' || segment[charIndex] == '}') depth--;
        if (depth < 0) return false;
      }
    }
    return depth == 0 && '"'.allMatches(piece.replaceAll(r'\"', '')).length.isEven;
  }

  if (parts.length > 1 && !parts.every(balanced)) {
    return null;
  }
  return parts;
}

String _escape(String text) => text
    .replaceAll(r'\', r'\\')
    .replaceAll("'", r"\'")
    .replaceAll(r'$', r'\$')
    .replaceAll('\n', r'\n')
    .replaceAll('\r', r'\r');

String _withoutUnusedImport(String source, String importLine, RegExp usage) {
  final stripped = source.replaceFirst(importLine, '');
  return usage.hasMatch(_withoutLineComments(stripped)) ? source : stripped;
}

String _withoutLineComments(String source) {
  final buffer = StringBuffer();
  for (final line in source.split('\n')) {
    var inString = false;
    var cut = line.length;
    for (var charIndex = 0; charIndex < line.length; charIndex++) {
      final codeUnit = line.codeUnitAt(charIndex);
      if (inString && codeUnit == 0x5C /* \ */ ) {
        charIndex++;
      } else if (codeUnit == 0x27 /* ' */ ) {
        inString = !inString;
      } else if (!inString &&
          codeUnit == 0x2F /* / */ &&
          charIndex + 1 < line.length &&
          line.codeUnitAt(charIndex + 1) == 0x2F) {
        cut = charIndex;
        break;
      }
    }
    buffer.writeln(line.substring(0, cut));
  }
  return buffer.toString();
}

/// 2^53, above which a double no longer represents every integer exactly.
const int _maxExactIntDouble = 9007199254740992;

String _numLiteral(num value) =>
    value is int && value.abs() < _maxExactIntDouble ? value.toString() : value.toDouble().toString();

final RegExp _i64SuffixLiteral = RegExp(r'(?<![\w.$])(\d+|0[xX][0-9a-fA-F]+)u?i64\b');

num? _parseTsNum(String text) {
  final trimmed = text.trim();
  final direct = num.tryParse(trimmed);
  if (direct != null) return direct;
  final match = RegExp(r'^-?(\d+|0[xX][0-9a-fA-F]+)u?i64$').firstMatch(trimmed);
  if (match == null) return null;
  final digits = num.tryParse(match.group(1)!);
  return digits == null ? null : (trimmed.startsWith('-') ? -digits : digits);
}

String _comment(String text) => text.replaceAll(RegExp(r'[\r\n]+'), ' | ').trim();

String _unportableFieldLine(String name) =>
    '// not a Dart field name — reachable only by porting its uses: ${_comment(name)}';

bool _validGlobalFieldName(String name) =>
    RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(name) &&
    !_dartReserved.contains(name) &&
    !const {
      'toString',
      'hashCode',
      'runtimeType',
      'noSuchMethod',
      'FileGlobals',
      'StationGlobals',
      'ts',
      'lw',
    }.contains(name);

const _variableRoots = {
  'FileGlobals': 'fileGlobals',
  'StationGlobals': 'stationGlobals',
  'RunState': 'runState',
  'Step': 'step',
};

/// `%` is absent: TestStand modulo keeps the sign of the dividend, Dart does not.
final _dartSafeExpression = RegExp(r"^[A-Za-z0-9_.\s+\-*/!<>=&|(),'\x22\[\]]+$");

const _builtinCalls = {
  'Len': 'ts.len',
  'GetNumElements': 'ts.getNumElements',
  'SetNumElements': 'ts.setNumElements',
  'Str': 'ts.str',
  'Left': 'ts.left',
  'Right': 'ts.right',
  'Mid': 'ts.mid',
  'Find': 'ts.find',
};

final _testStandOnly = RegExp(r'(?<!\.)\b[A-Za-z][A-Za-z0-9_]*\s*\(|#|->');
