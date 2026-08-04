/// The **numeric width model** at run time: LabVIEW's fixed-width integer
/// conversions and its bit-rotation primitives.
///
/// Width is load-bearing. A U32 `a + b` in LabVIEW truncates at 32 bits; the
/// same expression on Dart's 64-bit `int` carries into bit 32 and every
/// downstream byte is wrong. Translated code therefore renormalizes each
/// result, either inline (a mask or a shift pair the transpiler writes) or
/// through the conversions here, which are the LabVIEW To-Integer nodes.
///
/// Target: the Dart **native** runtime, where `int` is a two's-complement
/// signed 64-bit integer. On the web compilers `int` is a binary64 double with
/// no wraparound, so none of these hold there.
library;

/// LabVIEW's To Byte Integer conversion.
// TODO(lv-convert-range): LabVIEW's rule for a value outside the target width
// (truncate or saturate) is not established from the file format; every
// conversion here truncates.
int lvToI8(int value) => value << 56 >> 56;

/// LabVIEW's To Word Integer conversion.
int lvToI16(int value) => value << 48 >> 48;

/// LabVIEW's To Long Integer conversion.
int lvToI32(int value) => value << 32 >> 32;

/// LabVIEW's To Quad Integer conversion. Dart's `int` **is** a signed 64-bit
/// two's-complement integer, so this is the identity.
int lvToI64(int value) => value;

/// LabVIEW's To Unsigned Byte Integer conversion.
int lvToU8(int value) => value & 0xFF;

/// LabVIEW's To Unsigned Word Integer conversion.
int lvToU16(int value) => value & 0xFFFF;

/// LabVIEW's To Unsigned Long Integer conversion.
int lvToU32(int value) => value & 0xFFFFFFFF;

/// LabVIEW's To Unsigned Quad Integer conversion. A U64 value fills the whole
/// carrier, so the bit pattern is kept as-is and Dart reads it as signed; see
/// the width model's unsigned hazards for the operators that misread it.
int lvToU64(int value) => value;

/// The 8-bit lanes of the carrier, alternating from bit 0 — the mask
/// [lvSwapBytes] exchanges across.
const int _kByteLanes = 0x00FF00FF00FF00FF;

/// The 16-bit lanes of the carrier — the mask [lvSwapWords] exchanges across.
const int _kWordLanes = 0x0000FFFF0000FFFF;

/// LabVIEW's **Swap Bytes**: within every 16-bit field of [value], the high and
/// low bytes exchange places — `0x12345678` becomes `0x34127856`, not
/// `0x78563412`. Reversing all four bytes of a 32-bit value is this composed
/// with [lvSwapWords].
///
/// Width-agnostic: it acts on the whole carrier, and the caller renormalizes
/// the result to the LabVIEW type's width, which is what re-establishes the
/// sign of a narrow signed carrier.
int lvSwapBytes(int value) => ((value & _kByteLanes) << 8) | ((value >>> 8) & _kByteLanes);

/// LabVIEW's **Swap Words**: within every 32-bit field of [value], the high and
/// low 16-bit halves exchange places — `0x12345678` becomes `0x56781234`. See
/// [lvSwapBytes] for the width contract.
int lvSwapWords(int value) => ((value & _kWordLanes) << 16) | ((value >>> 16) & _kWordLanes);

/// LabVIEW's **Quotient & Remainder**: the integer quotient of
/// [dividend] / [divisor] and the amount left over, as `(quotient, remainder)`.
///
/// The quotient rounds toward negative infinity, so the remainder carries the
/// divisor's sign; Dart's `~/` rounds toward zero, which is the whole of the
/// correction below. The published reference settles the direction for every
/// pair of signs — it names the two results `floor(x/y)` and `x-y*floor(x/y)`.
/// The corpus alone could not have: every node that fixes the operation's shape
/// does it with non-negative operands, where the two conventions agree.
// TODO(lv-divide-by-zero): what LabVIEW yields for a zero divisor is not
// established; this throws rather than inventing a result.
(int, int) lvQuotientRemainder(int dividend, int divisor) {
  final truncated = dividend ~/ divisor;
  final toZero = dividend - divisor * truncated;
  final quotient = toZero != 0 && (toZero < 0) != (divisor < 0) ? truncated - 1 : truncated;
  return (quotient, dividend - divisor * quotient);
}

/// LabVIEW's **Logical Shift** over a [bits]-wide value: a positive [count]
/// shifts [value] toward the high bits and a negative one toward the low bits,
/// zero filling from the far end either way. Shifting by the width or more
/// leaves nothing behind. The result is the raw [bits]-wide bit pattern; the
/// caller renormalizes it to the LabVIEW type's own width, which is what
/// re-establishes the sign of a narrow signed carrier.
///
/// One node covers both directions because the shift count is signed, so the
/// direction is a run-time value and cannot be folded into the operator.
int lvLogicalShift(int value, int count, int bits) {
  final mask = bits >= 64 ? -1 : (1 << bits) - 1;
  final masked = value & mask;
  if (count == 0) return masked;
  if (count >= bits || count <= -bits) return 0;
  return (count > 0 ? masked << count : masked >>> -count) & mask;
}

/// A **bit rotation** of a [bits]-wide value: [count] moves [value]'s bits
/// toward the high end and the bits that leave the top re-enter at the bottom.
/// The result is the raw [bits]-wide pattern, which the caller renormalizes to
/// the LabVIEW type's own width.
// TODO(lv-rotate-range): decode what LabVIEW does with a count outside
// `0 .. bits - 1` — reduce it, saturate it as [lvLogicalShift] does, or read a
// negative one as the other direction. The proving vectors supply 4..23 at 32
// bits; past a whole width there is nothing to read, so those counts throw.
int lvRotate(int value, int count, int bits) {
  if (count < 0 || count >= bits) {
    throw RangeError.range(count, 0, bits - 1, 'count', "LabVIEW's rotation past one width is not decoded");
  }
  final mask = bits >= 64 ? -1 : (1 << bits) - 1;
  final masked = value & mask;
  return count == 0 ? masked : ((masked << count) | (masked >>> (bits - count))) & mask;
}

/// LabVIEW's Rotate Left With Carry over a [bits]-wide value: the value shifts
/// up one bit, [carryIn] enters as bit 0, and the departing top bit is the
/// carry out.
(int, bool) lvRotateLeftWithCarry(int value, bool carryIn, int bits) => (
  ((value << 1) | (carryIn ? 1 : 0)) & ((1 << bits) - 1),
  (value >>> (bits - 1)) & 1 != 0,
);

/// LabVIEW's Rotate Right With Carry over a [bits]-wide value: the value
/// shifts down one bit, [carryIn] enters as the top bit, and the departing
/// bit 0 is the carry out.
(int, bool) lvRotateRightWithCarry(int value, bool carryIn, int bits) => (
  (value >>> 1) | (carryIn ? 1 << (bits - 1) : 0),
  value & 1 != 0,
);
