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

/// LabVIEW's To Byte Integer conversion: [value] renormalized to a signed
/// 8-bit range — exact for every value that width can hold.
// TODO(lv-convert-range): LabVIEW's rule for a value outside the target width
// (truncate or saturate) is not established from the file format; this
// truncates.
int lvToI8(int value) => value << 56 >> 56;

/// LabVIEW's To Word Integer conversion: [value] renormalized to a signed
/// 16-bit range.
// TODO(lv-convert-range): see [lvToI8].
int lvToI16(int value) => value << 48 >> 48;

/// LabVIEW's To Long Integer conversion: [value] renormalized to a signed
/// 32-bit range.
// TODO(lv-convert-range): see [lvToI8].
int lvToI32(int value) => value << 32 >> 32;

/// LabVIEW's To Quad Integer conversion. Dart's `int` **is** a signed 64-bit
/// two's-complement integer, so this is the identity.
int lvToI64(int value) => value;

/// LabVIEW's To Unsigned Byte Integer conversion.
// TODO(lv-convert-range): see [lvToI8].
int lvToU8(int value) => value & 0xFF;

/// LabVIEW's To Unsigned Word Integer conversion.
// TODO(lv-convert-range): see [lvToI8].
int lvToU16(int value) => value & 0xFFFF;

/// LabVIEW's To Unsigned Long Integer conversion.
// TODO(lv-convert-range): see [lvToI8].
int lvToU32(int value) => value & 0xFFFFFFFF;

/// LabVIEW's To Unsigned Quad Integer conversion. A U64 value fills the whole
/// carrier, so the bit pattern is kept as-is and Dart reads it as signed; see
/// the width model's unsigned hazards for the operators that misread it.
int lvToU64(int value) => value;

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
