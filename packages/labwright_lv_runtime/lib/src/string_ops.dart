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
