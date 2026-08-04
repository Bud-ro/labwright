/// LabVIEW's **string** operations.
///
/// A LabVIEW string is a byte sequence, carried here as a Dart `String` of
/// Latin-1 code units so that every byte value round-trips through one code
/// unit. Each operation below therefore reads code units, never Unicode
/// characters: Dart's own `toLowerCase` and `substring` are defined over
/// Unicode and would disagree with LabVIEW on exactly the bytes a digest or a
/// framed protocol depends on.
///
/// Where the file format does not establish what LabVIEW does with an operand
/// outside the operation's domain, these **throw** rather than invent a
/// result. A thrown call is a visible gap; a fabricated byte is not.
library;

const int _kAsciiUpperA = 0x41;
const int _kAsciiUpperZ = 0x5A;
const int _kAsciiCaseDistance = 0x20;

/// The first code unit outside the ASCII range.
const int _kAsciiLimit = 0x80;

/// LabVIEW's **To Lower Case** over the ASCII range: `A`..`Z` in [text] become
/// `a`..`z` and every other unit below 0x80 is returned unchanged. The proving
/// vectors exercise `A`..`F` alone; the rest of the range rests on the
/// published reference's own statement, that the function lower-cases every
/// alphabetic character of the string.
///
/// A code unit of 0x80 or above throws. LabVIEW maps the upper half of a byte
/// string through a table that is not in the VI, and Dart's own `toLowerCase`
/// is Unicode's, which differs there.
// TODO(lv-lowercase-high): decode LabVIEW's case-mapping table for code units
// 0x80..0xFF; until then this throws for them rather than choosing a table.
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

/// LabVIEW's **String Subset**: [length] code units of [text] starting at
/// [offset], or everything from [offset] on when [length] is null — which is
/// the value the node's own length terminal carries when the diagram leaves it
/// unwired.
///
/// [offset] is 0-based and may equal `text.length`, which yields the empty
/// string.
///
/// An operand outside the string throws. LabVIEW's rule for an offset past the
/// end, a negative offset, or a length running past the end is not established
/// from the file format, and the three candidates — clamp, empty, error — are
/// three different strings.
// TODO(lv-string-subset-range): decode what LabVIEW returns for an out-of-range
// offset or length; until then those operands throw rather than being clamped.
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

/// The hexadecimal digits, upper case — the form a LabVIEW number-to-string
/// conversion writes, and the reason a diagram that wants a lower-case digest
/// follows one with [lvToLowerCase].
const String _kHexDigits = '0123456789ABCDEF';

/// A [bits]-wide [value] written in **hexadecimal** at [width] digits, `0`
/// padded. [value] is read as an unsigned [bits]-wide pattern, so a narrow
/// signed carrier's sign bit prints as the bit it is.
// TODO(lv-hex-string-overflow): decode what LabVIEW writes when the value needs
// more than [width] digits — a wider field, or a truncation to the low digits.
// The proving vectors format 32 bits at width 8, where neither can arise, so
// the case throws rather than choosing one.
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

/// A LabVIEW **Initialize Array** row: [size] copies of [element].
///
/// A negative [size] throws. What LabVIEW yields there — an empty array, or an
/// error — is not established from the file format.
// TODO(lv-initialize-array-negative): decode what a negative dimension size
// produces; until then it throws rather than being read as empty.
List<T> lvInitializeArray<T>(int size, T element) {
  if (size < 0) {
    throw RangeError.value(size, 'size', "LabVIEW's Initialize Array rule for a negative size is not decoded");
  }
  return List<T>.filled(size, element);
}
