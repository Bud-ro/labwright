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
