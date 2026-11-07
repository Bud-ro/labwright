const int _kAsciiUpperA = 0x41;
const int _kAsciiUpperZ = 0x5A;
const int _kAsciiCaseDistance = 0x20;
const int _kAsciiLimit = 0x80;
String lvToLowerCase(String text) {
  final units = text.codeUnits;
  final mapped = List<int>.filled(units.length, 0);
  for (var index = 0; index < units.length; index++) {
    final unit = units[index];
    if (unit >= _kAsciiLimit) {
      throw UnsupportedError(
        'To Lower Case over code unit 0x${unit.toRadixString(16)} at $index: '
        "LabVIEW's case mapping above 0x7F is not decoded",
      );
    }
    mapped[index] = unit >= _kAsciiUpperA && unit <= _kAsciiUpperZ ? unit + _kAsciiCaseDistance : unit;
  }
  return String.fromCharCodes(mapped);
}

// TODO(lv-string-subset-range): LabVIEW's result for an out-of-range offset or length is not decoded; these throw.
String lvStringSubset(String text, int offset, [int? length]) {
  if (offset < 0 || offset > text.length) {
    throw RangeError.range(
      offset,
      0,
      text.length,
      'offset',
      "LabVIEW's String Subset out-of-range rule is not decoded",
    );
  }
  if (length == null) return text.substring(offset);
  if (length < 0 || offset + length > text.length) {
    throw RangeError.range(
      length,
      0,
      text.length - offset,
      'length',
      "LabVIEW's String Subset out-of-range rule is not decoded",
    );
  }
  return text.substring(offset, offset + length);
}

const String _kHexDigits = '0123456789ABCDEF';
// TODO(lv-hex-string-overflow): LabVIEW's output for a value wider than [width] digits is not decoded; this throws.
String lvHexString(int value, int width, int bits) {
  final mask = bits >= 64 ? -1 : (1 << bits) - 1;
  var remaining = value & mask;
  final digits = <int>[];
  do {
    digits.add(_kHexDigits.codeUnitAt(remaining & 0xF));
    remaining = remaining >>> 4;
  } while (remaining != 0);
  if (digits.length > width) {
    throw RangeError.value(width, 'width', "LabVIEW's rule for a value wider than the field is not decoded");
  }
  while (digits.length < width) {
    digits.add(_kHexDigits.codeUnitAt(0));
  }
  return String.fromCharCodes(digits.reversed);
}

List<T> lvInitializeArray<T>(int size, T element) {
  if (size < 0) {
    throw RangeError.value(size, 'size', "LabVIEW's Initialize Array rule for a negative size is not decoded");
  }
  return List<T>.filled(size, element);
}

/// To Upper Case, over the ASCII letters; code units above 0x7F are not decoded and throw.
String lvToUpperCase(String text) {
  final units = text.codeUnits;
  final mapped = List<int>.filled(units.length, 0);
  for (var index = 0; index < units.length; index++) {
    final unit = units[index];
    if (unit >= _kAsciiLimit) {
      throw UnsupportedError(
        'To Upper Case over code unit 0x${unit.toRadixString(16)} at $index: '
        "LabVIEW's case mapping above 0x7F is not decoded",
      );
    }
    mapped[index] = unit >= _kAsciiLowerA && unit <= _kAsciiLowerZ ? unit - _kAsciiCaseDistance : unit;
  }
  return String.fromCharCodes(mapped);
}

const int _kAsciiLowerA = 0x61;
const int _kAsciiLowerZ = 0x7A;

/// Reverse String.
String lvReverseString(String text) => String.fromCharCodes(text.codeUnits.reversed);

/// Number To Decimal String: [number] in decimal, padded on the left with spaces to [width]
/// when it is narrower; a null width pads nothing.
String lvNumberToDecimalString(int number, [int? width]) {
  final digits = number.toString();
  return width == null || digits.length >= width ? digits : digits.padLeft(width);
}

/// Number To Decimal String of an unsigned 64-bit pattern.
String lvNumberToDecimalStringU64(int number, [int? width]) {
  final digits = BigInt.from(number).toUnsigned(64).toString();
  return width == null || digits.length >= width ? digits : digits.padLeft(width);
}

/// Decimal String To Number: the optionally signed decimal digits at [offset] (negative reads
/// as zero), skipping leading white space; no digits give [defaultValue], and a value outside
/// a [bits]-wide [signed] integer saturates. `offsetPastNumber` is the index after the digits
/// read, or the offset when none were.
({int offsetPastNumber, int number}) lvDecimalStringToNumber(
  String string,
  int offset, {
  int defaultValue = 0,
  int bits = 32,
  bool signed = true,
}) {
  var at = offset < 0 ? 0 : offset;
  while (at < string.length && _isSpace(string.codeUnitAt(at))) {
    at++;
  }
  var negative = false;
  var cursor = at;
  if (cursor < string.length && (string.codeUnitAt(cursor) == 0x2d || string.codeUnitAt(cursor) == 0x2b)) {
    negative = string.codeUnitAt(cursor) == 0x2d;
    cursor++;
  }
  final start = cursor;
  var magnitude = BigInt.zero;
  while (cursor < string.length && _isDigit(string.codeUnitAt(cursor))) {
    magnitude = magnitude * BigInt.from(10) + BigInt.from(string.codeUnitAt(cursor) - 0x30);
    cursor++;
  }
  if (cursor == start) return (offsetPastNumber: offset < 0 ? 0 : offset, number: defaultValue);
  final value = negative ? -magnitude : magnitude;
  return (offsetPastNumber: cursor, number: _saturate(value, bits, signed: signed));
}

/// Hexadecimal String To Number, as [lvDecimalStringToNumber] over the digits `0-9a-fA-F`.
({int offsetPastNumber, int number}) lvHexadecimalStringToNumber(
  String string,
  int offset, {
  int defaultValue = 0,
  int bits = 32,
  bool signed = false,
}) => _radixStringToNumber(string, offset, 16, defaultValue: defaultValue, bits: bits, signed: signed);

/// Octal String To Number.
({int offsetPastNumber, int number}) lvOctalStringToNumber(
  String string,
  int offset, {
  int defaultValue = 0,
  int bits = 32,
  bool signed = false,
}) => _radixStringToNumber(string, offset, 8, defaultValue: defaultValue, bits: bits, signed: signed);

({int offsetPastNumber, int number}) _radixStringToNumber(
  String string,
  int offset,
  int radix, {
  required int defaultValue,
  required int bits,
  required bool signed,
}) {
  var at = offset < 0 ? 0 : offset;
  while (at < string.length && _isSpace(string.codeUnitAt(at))) {
    at++;
  }
  final start = at;
  var value = BigInt.zero;
  while (at < string.length) {
    final digit = _digitValue(string.codeUnitAt(at));
    if (digit == null || digit >= radix) break;
    value = value * BigInt.from(radix) + BigInt.from(digit);
    at++;
  }
  if (at == start) return (offsetPastNumber: offset < 0 ? 0 : offset, number: defaultValue);
  return (offsetPastNumber: at, number: _saturate(value, bits, signed: signed));
}

/// Fract/Exp String To Number: a floating-point literal at [offset] with an optional sign,
/// fraction and exponent; no digits give [defaultValue].
({int offsetPastNumber, double number}) lvFractExpStringToNumber(
  String string,
  int offset, {
  double defaultValue = 0.0,
}) {
  var at = offset < 0 ? 0 : offset;
  while (at < string.length && _isSpace(string.codeUnitAt(at))) {
    at++;
  }
  final match = RegExp(r'^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?').firstMatch(string.substring(at));
  if (match == null) return (offsetPastNumber: offset < 0 ? 0 : offset, number: defaultValue);
  return (offsetPastNumber: at + match.end, number: double.parse(match.group(0)!));
}

int _saturate(BigInt value, int bits, {required bool signed}) {
  final low = signed ? -(BigInt.one << (bits - 1)) : BigInt.zero;
  final high = signed ? (BigInt.one << (bits - 1)) - BigInt.one : (BigInt.one << bits) - BigInt.one;
  final clamped = value < low
      ? low
      : value > high
      ? high
      : value;
  return clamped.toSigned(64).toInt();
}

bool _isSpace(int unit) => unit == 0x20 || unit == 0x09 || unit == 0x0a || unit == 0x0d;

bool _isDigit(int unit) => unit >= 0x30 && unit <= 0x39;

int? _digitValue(int unit) {
  if (_isDigit(unit)) return unit - 0x30;
  if (unit >= 0x41 && unit <= 0x46) return unit - 0x41 + 10;
  if (unit >= 0x61 && unit <= 0x66) return unit - 0x61 + 10;
  return null;
}

/// Pick Line: [string] with line [lineIndex] of [multiLineString] appended, the lines split at
/// line feeds; an index outside the lines appends nothing.
String lvPickLine(String string, String multiLineString, int lineIndex) {
  if (lineIndex < 0) return string;
  final lines = multiLineString.split('\n');
  if (lineIndex >= lines.length) return string;
  final line = lines[lineIndex];
  return string + (line.endsWith('\r') ? line.substring(0, line.length - 1) : line);
}

/// Search/Split String: [string] split at the first [searchString] at or after [offset] (a
/// negative offset reads as zero), or at [offset] itself when the search string is empty.
/// Without a match the whole string is `before` and `offsetOfMatch` is -1.
({String before, String matchAndRest, int offsetOfMatch}) lvSearchSplitString(
  String string,
  String searchString, [
  int offset = 0,
]) {
  final start = offset < 0 ? 0 : (offset > string.length ? string.length : offset);
  if (searchString.isEmpty) {
    return (before: string.substring(0, start), matchAndRest: string.substring(start), offsetOfMatch: start);
  }
  final at = string.indexOf(searchString, start);
  if (at < 0) return (before: string, matchAndRest: '', offsetOfMatch: -1);
  return (before: string.substring(0, at), matchAndRest: string.substring(at), offsetOfMatch: at);
}

/// Search and Replace String: the first, or every ([replaceAll]), [searchString] at or after
/// [offset] in [inputString] replaced by [replaceString]; with [regularExpression] the search
/// string is a regular expression and the replacement may hold `\1`..`\9` backreferences.
/// An empty search string inserts the replacement at the offset, or when replacing all, at the
/// offset, between every character and at the end. `offsetPastReplacement` is the index in the
/// result after the last replacement, or -1 without a match.
({String result, int replacements, int offsetPastReplacement}) lvSearchAndReplaceString(
  String inputString,
  String searchString,
  String replaceString, {
  int offset = 0,
  bool replaceAll = false,
  bool ignoreCase = false,
  bool multiline = false,
  bool regularExpression = false,
}) {
  final start = offset < 0 ? 0 : (offset > inputString.length ? inputString.length : offset);
  final head = inputString.substring(0, start);
  final tail = inputString.substring(start);
  final out = StringBuffer(head);
  var replacements = 0;
  var pastLast = -1;
  if (searchString.isEmpty) {
    if (!replaceAll) {
      out.write(replaceString);
      out.write(tail);
      return (result: out.toString(), replacements: 1, offsetPastReplacement: start + replaceString.length);
    }
    for (var i = 0; i < tail.length; i++) {
      out.write(replaceString);
      out.writeCharCode(tail.codeUnitAt(i));
    }
    out.write(replaceString);
    return (result: out.toString(), replacements: tail.length + 1, offsetPastReplacement: out.length);
  }
  final Pattern pattern = regularExpression
      ? RegExp(searchString, caseSensitive: !ignoreCase, multiLine: multiline)
      : (ignoreCase ? RegExp(RegExp.escape(searchString), caseSensitive: false) : searchString);
  var cursor = 0;
  for (final match in pattern.allMatches(tail)) {
    if (match.end == match.start && match.start < cursor) continue;
    out.write(tail.substring(cursor, match.start));
    out.write(regularExpression ? _expandBackreferences(replaceString, match) : replaceString);
    replacements++;
    pastLast = out.length;
    cursor = match.end;
    if (!replaceAll) break;
    if (match.end == match.start) {
      if (match.start < tail.length) out.writeCharCode(tail.codeUnitAt(match.start));
      cursor = match.start + 1;
      if (cursor > tail.length) break;
    }
  }
  if (cursor <= tail.length) out.write(tail.substring(cursor));
  return (result: out.toString(), replacements: replacements, offsetPastReplacement: pastLast);
}

String _expandBackreferences(String replacement, Match match) {
  final out = StringBuffer();
  for (var i = 0; i < replacement.length; i++) {
    final unit = replacement.codeUnitAt(i);
    if (unit == 0x5c && i + 1 < replacement.length) {
      final next = replacement.codeUnitAt(i + 1);
      if (next >= 0x30 && next <= 0x39) {
        final group = next - 0x30;
        if (group <= match.groupCount) out.write(match.group(group) ?? '');
        i++;
        continue;
      }
      if (next == 0x5c) {
        out.write(r'\');
        i++;
        continue;
      }
    }
    out.writeCharCode(unit);
  }
  return out.toString();
}

/// The conversion a spreadsheet format string selects: `%s` text, `%d` integers, `%f`, `%e`
/// and `%g` floating point.
enum LvSpreadsheetFormat {
  text,
  integer,
  float;

  /// The conversion of [format]; null when it holds no conversion this runtime spells.
  static LvSpreadsheetFormat? of(String format) {
    final match = RegExp(r'%[-+#0 ]*\d*(?:\.\d+)?([sdfeg])').firstMatch(format);
    return switch (match?.group(1)) {
      's' => text,
      'd' => integer,
      'f' || 'e' || 'g' => float,
      _ => null,
    };
  }
}

/// Spreadsheet String To Array for a 1-D or 2-D array type: rows split at line endings (CR LF,
/// LF or CR), fields at any of [delimiters] (one tab when none). A 2-D result is rectangular,
/// short rows padded with the element's default; a 1-D result is the first row. Each field is
/// converted as [format] says: text as itself, an integer as Decimal String To Number reads it,
/// a float as Fract/Exp String To Number does.
({List<List<Object>> rows, int columns}) lvSpreadsheetStringToRows(
  String spreadsheetString,
  LvSpreadsheetFormat format, {
  List<String> delimiters = const ['\t'],
}) {
  final splitters = delimiters.where((delimiter) => delimiter.isNotEmpty).toList();
  if (splitters.isEmpty) splitters.add('\t');
  final lines = spreadsheetString.split(RegExp('\r\n|\n|\r'));
  if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
  final rows = <List<Object>>[];
  var columns = 0;
  final separator = RegExp(splitters.map(RegExp.escape).join('|'));
  for (final line in lines) {
    final fields = line.split(separator);
    final row = <Object>[
      for (final field in fields)
        switch (format) {
          LvSpreadsheetFormat.text => field,
          LvSpreadsheetFormat.integer => lvDecimalStringToNumber(field, 0, bits: 64).number,
          LvSpreadsheetFormat.float => lvFractExpStringToNumber(field, 0).number,
        },
    ];
    if (row.length > columns) columns = row.length;
    rows.add(row);
  }
  return (rows: rows, columns: columns);
}

/// Array To Spreadsheet String: each element spelled by [spell], fields joined by [delimiter],
/// rows ended by [lineEnd]; a 1-D array is one row.
String lvArrayToSpreadsheetString(
  List<List<Object?>> rows,
  String Function(Object?) spell, {
  String delimiter = '\t',
  String lineEnd = '\n',
}) {
  final out = StringBuffer();
  for (final row in rows) {
    out.write(row.map(spell).join(delimiter));
    out.write(lineEnd);
  }
  return out.toString();
}

/// LabVIEW's string ordering, which compares code units from the first character.
int lvCompareStrings(String a, String b) {
  final length = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < length; i++) {
    final difference = a.codeUnitAt(i) - b.codeUnitAt(i);
    if (difference != 0) return difference;
  }
  return a.length - b.length;
}
