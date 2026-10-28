import 'dart:math';

// TODO(lv-convert-range): truncate vs saturate outside the target width is not decoded; these truncate.
int lvToI8(int value) => value << 56 >> 56;
int lvToI16(int value) => value << 48 >> 48;
int lvToI32(int value) => value << 32 >> 32;
int lvToI64(int value) => value;
int lvToU8(int value) => value & 0xFF;
int lvToU16(int value) => value & 0xFFFF;
int lvToU32(int value) => value & 0xFFFFFFFF;
int lvToU64(int value) => value;
const int _kByteLanes = 0x00FF00FF00FF00FF;
const int _kWordLanes = 0x0000FFFF0000FFFF;
int lvSwapBytes(int value) => ((value & _kByteLanes) << 8) | ((value >>> 8) & _kByteLanes);
int lvSwapWords(int value) => ((value & _kWordLanes) << 16) | ((value >>> 16) & _kWordLanes);
// TODO(lv-divide-by-zero): LabVIEW's result for a zero divisor is not decoded; this throws.
(int, int) lvQuotientRemainder(int dividend, int divisor) {
  final truncated = dividend ~/ divisor;
  final toZero = dividend - divisor * truncated;
  final quotient = toZero != 0 && (toZero < 0) != (divisor < 0) ? truncated - 1 : truncated;
  return (quotient, dividend - divisor * quotient);
}

int lvLogicalShift(int value, int count, int bits) {
  final mask = bits >= 64 ? -1 : (1 << bits) - 1;
  final masked = value & mask;
  if (count == 0) return masked;
  if (count >= bits || count <= -bits) return 0;
  return (count > 0 ? masked << count : masked >>> -count) & mask;
}

int lvRotate(int value, int count, int bits) {
  if (count < 0 || count >= bits) {
    throw RangeError.range(count, 0, bits - 1, 'count', "LabVIEW's rotation past one width is not decoded");
  }
  final mask = bits >= 64 ? -1 : (1 << bits) - 1;
  final masked = value & mask;
  return count == 0 ? masked : ((masked << count) | (masked >>> (bits - count))) & mask;
}

(int, bool) lvRotateLeftWithCarry(int value, bool carryIn, int bits) => (
  ((value << 1) | (carryIn ? 1 : 0)) & ((1 << bits) - 1),
  (value >>> (bits - 1)) & 1 != 0,
);
(int, bool) lvRotateRightWithCarry(int value, bool carryIn, int bits) => (
  (value >>> 1) | (carryIn ? 1 << (bits - 1) : 0),
  value & 1 != 0,
);

final Random _random = Random();

/// Random Number (0-1): a double-precision number at or above 0 and below 1.
double lvRandomNumber() => _random.nextDouble();

/// Quotient & Remainder over floating-point operands: `floor(x/y)` and `x - y*floor(x/y)`; a
/// zero divisor gives an infinite quotient and a NaN remainder.
(double, double) lvQuotientRemainderFloat(double dividend, double divisor) {
  if (divisor == 0) return (dividend == 0 ? double.nan : dividend.sign * double.infinity, double.nan);
  final quotient = (dividend / divisor).floorToDouble();
  return (quotient, dividend - divisor * quotient);
}

/// Quotient & Remainder over integers with a zero divisor: the quotient is zero and the
/// remainder the dividend.
(int, int) lvQuotientRemainderInt(int dividend, int divisor) =>
    divisor == 0 ? (0, dividend) : lvQuotientRemainder(dividend, divisor);

/// Max & Min: the larger value first. One NaN operand gives the other operand twice; two give
/// NaN twice.
(T, T) lvMaxAndMin<T extends num>(T x, T y) {
  if (x is double && x.isNaN) return y is double && y.isNaN ? (x, x) : (y, y);
  if (y is double && y.isNaN) return (x, x);
  return x >= y ? (x, y) : (y, x);
}

/// Max & Min over strings or other comparable values.
(T, T) lvMaxAndMinComparable<T extends Comparable<T>>(T x, T y) => x.compareTo(y) >= 0 ? (x, y) : (y, x);

/// In Range and Coerce in its default configuration: the lower limit is inclusive and the
/// upper limit exclusive, so `lower <= x < upper`; `coerced` is [x] clamped into
/// `[lower, upper]`. Any NaN operand gives NaN and false.
({T coerced, bool inRange}) lvInRangeAndCoerce<T extends num>(T upperLimit, T x, T lowerLimit) {
  if (x is double && x.isNaN || upperLimit is double && upperLimit.isNaN || lowerLimit is double && lowerLimit.isNaN) {
    return (coerced: double.nan as T, inRange: false);
  }
  final inRange = x >= lowerLimit && x < upperLimit;
  final T coerced;
  if (x < lowerLimit) {
    coerced = lowerLimit;
  } else if (x > upperLimit) {
    coerced = upperLimit;
  } else {
    coerced = x;
  }
  return (coerced: coerced, inRange: inRange);
}

/// Boolean Array To Number: element 0 is the least significant bit. A long array is truncated
/// to [bits]; a short one is padded with its last element when [signExtend], else with false.
int lvBooleanArrayToNumber(List<bool> array, int bits, {required bool signed, bool? signExtend}) {
  final extend = signExtend ?? signed;
  var value = 0;
  final pad = array.isNotEmpty && extend && array.last;
  for (var bit = bits - 1; bit >= 0; bit--) {
    final set = bit < array.length ? array[bit] : pad;
    value = (value << 1) | (set ? 1 : 0);
  }
  if (bits >= 64) return value;
  return signed ? value.toSigned(bits) : value;
}

/// Number To Boolean Array: [bits] elements, element 0 the least significant bit of the two's
/// complement representation.
List<bool> lvNumberToBooleanArray(int number, int bits) => [
  for (var bit = 0; bit < bits; bit++) (number >> bit) & 1 != 0,
];

/// Boolean To (0,1).
int lvBooleanToZeroOne(bool value) => value ? 1 : 0;

/// Square Root; a negative operand is NaN.
double lvSquareRoot(num x) => sqrt(x);

/// Power Of X: `x` raised to `y`.
double lvPowerOfX(num x, num y) => pow(x, y).toDouble();

/// Power Of 10.
double lvPowerOf10(num x) => pow(10, x).toDouble();

/// Logarithm Base 10.
double lvLogarithmBase10(num x) {
  final estimate = log(x) / ln10;
  final nearest = estimate.roundToDouble();
  return nearest.isFinite && pow(10, nearest) == x ? nearest : estimate;
}

/// Sine and Cosine of an angle in radians.
double lvSine(num x) => sin(x);

double lvCosine(num x) => cos(x);

/// Mantissa & Exponent: `x = mantissa * 2^exponent` with `1 <= |mantissa| < 2`, or both zero
/// for zero.
(double, int) lvMantissaAndExponent(double x) {
  if (x == 0 || x.isNaN || x.isInfinite) return (x, 0);
  var exponent = 0;
  var mantissa = x.abs();
  while (mantissa >= 2) {
    mantissa /= 2;
    exponent++;
  }
  while (mantissa < 1) {
    mantissa *= 2;
    exponent--;
  }
  return (x.isNegative ? -mantissa : mantissa, exponent);
}

/// The nearest integer, ties to even, saturated into a [bits]-wide integer that is [signed] or
/// not, as the conversion functions round a float.
int lvRoundToInteger(double value, int bits, {required bool signed}) {
  if (value.isNaN) return 0;
  final rounded = _roundHalfEven(value);
  if (bits >= 64) {
    if (signed) return rounded.isInfinite ? (rounded > 0 ? 0x7FFFFFFFFFFFFFFF : -0x8000000000000000) : rounded.toInt();
    if (rounded <= 0) return 0;
    if (rounded >= 18446744073709551615.0) return -1;
    return rounded >= 9223372036854775808.0 ? (rounded - 18446744073709551616.0).toInt() : rounded.toInt();
  }
  final low = signed ? -(1 << (bits - 1)) : 0;
  final high = signed ? (1 << (bits - 1)) - 1 : (1 << bits) - 1;
  if (rounded <= low) return low;
  if (rounded >= high) return high;
  return rounded.toInt();
}

double _roundHalfEven(double value) {
  final floor = value.floorToDouble();
  final fraction = value - floor;
  if (fraction < 0.5) return floor;
  if (fraction > 0.5) return floor + 1;
  return floor % 2 == 0 ? floor : floor + 1;
}
