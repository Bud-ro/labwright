/// The **numeric width model**: how each LabVIEW numeric type is carried in
/// Dart, and what a translated expression must do so that arithmetic keeps
/// LabVIEW's width.
///
/// Width is load-bearing, not cosmetic. A U32 `a + b` in LabVIEW truncates at
/// 32 bits; the same `a + b` in Dart carries into bit 32 and every downstream
/// digest byte is wrong. Every kind below therefore states its Dart carrier,
/// whether an operation result must be renormalized ([LvNumericKind.wrap]),
/// and which Dart operators are *silently wrong* on that carrier
/// ([LvNumericKind.hazards]).
///
/// Target: the Dart **native** runtime, where `int` is a two's-complement
/// signed 64-bit integer and `double` is IEEE-754 binary64. On the web
/// compilers `int` is a binary64 double with no wraparound at all, so none of
/// the wrap expressions below hold there and generated code is native-only.
library;

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// A Dart operator that reads a LabVIEW numeric's carrier **incorrectly**, and
/// the form that reads it correctly. Attached to the kinds that need them
/// ([LvNumericKind.hazards]) so a generator cannot emit the plain operator by
/// accident.
enum LvArithmeticHazard {
  /// `<` `<=` `>` `>=` on a U64 carrier compare the raw bit pattern as
  /// *signed*, so every value with bit 63 set sorts below every value without
  /// it. Correct form: compare with the sign bit flipped —
  /// `(a ^ -0x8000000000000000).compareTo(b ^ -0x8000000000000000)`.
  unsignedCompare(
    operators: ['<', '<=', '>', '>='],
    remedy: r'(a ^ -0x8000000000000000).compareTo(b ^ -0x8000000000000000)',
  ),

  /// `~/` and `%` on a U64 carrier divide as signed. Dart's core library has
  /// no unsigned integer division, so the translation needs a helper: the
  /// exact form is `(BigInt.from(a).toUnsigned(64) ~/ BigInt.from(b)
  /// .toUnsigned(64)).toSigned(64).toInt()`, which a generator may specialize
  /// when the divisor is a known power of two (`a >>> log2(b)`).
  unsignedDivide(operators: ['~/', '%'], remedy: 'BigInt-backed unsigned division helper'),

  /// `>>` on a U64 carrier is an arithmetic shift: it smears bit 63 into the
  /// vacated high bits. Correct form: Dart's logical shift `>>>`.
  unsignedShiftRight(operators: ['>>'], remedy: '>>>'),

  /// `toString`, `toDouble` and `toRadixString` on a U64 carrier read the bit
  /// pattern as signed, printing a negative number for any value above
  /// 2^63 - 1. Correct form: `BigInt.from(a).toUnsigned(64)`.
  unsignedFormat(operators: ['toString', 'toDouble', 'toRadixString'], remedy: 'BigInt.from(a).toUnsigned(64)'),

  /// Every arithmetic result on a SGL carrier is computed by Dart at binary64
  /// precision, so a sequence of single-precision operations drifts from
  /// LabVIEW's. Correct form: round each result back to binary32 —
  /// `(Float32List(1)..[0] = value)[0]`.
  floatNarrowing(operators: ['+', '-', '*', '/'], remedy: '(Float32List(1)..[0] = value)[0]')
  ;

  const LvArithmeticHazard({required this.operators, required this.remedy});

  /// The Dart operators/members that are wrong on the carrier.
  final List<String> operators;

  /// The expression form that is correct instead.
  final String remedy;
}

/// A LabVIEW numeric type with a decided Dart representation.
///
/// [wrap] is the whole width model in one expression: applied to the result of
/// every arithmetic operation it makes the Dart carrier hold exactly what
/// LabVIEW's register would. Unsigned kinds mask; signed narrow kinds
/// sign-extend by a shift pair; `I64` needs nothing (Dart's `int` *is* an I64);
/// `U64` cannot be renormalized at all (its value already fills the carrier)
/// and instead carries [hazards].
enum LvNumericKind {
  i8(code: TypeCode.i8, glyph: 'I8', bits: 8, signed: true, typedListType: 'Int8List'),
  i16(code: TypeCode.i16, glyph: 'I16', bits: 16, signed: true, typedListType: 'Int16List'),
  i32(code: TypeCode.i32, glyph: 'I32', bits: 32, signed: true, typedListType: 'Int32List'),

  /// Dart's `int` is exactly this type: `+ - * ~/ % >> <<` and every
  /// comparison already wrap and compare as a signed 64-bit two's-complement
  /// integer, so [wrap] is the identity and there are no hazards.
  i64(code: TypeCode.i64, glyph: 'I64', bits: 64, signed: true, typedListType: 'Int64List'),

  u8(code: TypeCode.u8, glyph: 'U8', bits: 8, signed: false, typedListType: 'Uint8List'),
  u16(code: TypeCode.u16, glyph: 'U16', bits: 16, signed: false, typedListType: 'Uint16List'),
  u32(code: TypeCode.u32, glyph: 'U32', bits: 32, signed: false, typedListType: 'Uint32List'),

  /// The problem case. A U64 value needs all 64 bits of the carrier, so the
  /// carrier holds the raw bit pattern and Dart reads it as signed: `+ - * &
  /// | ^ << ~` are still exact (two's complement wraparound is
  /// sign-agnostic), but comparison, division, `>>` and formatting are not —
  /// see [hazards]. [wrap] is the identity because there is nothing to mask.
  u64(
    code: TypeCode.u64,
    glyph: 'U64',
    bits: 64,
    signed: false,
    typedListType: 'Uint64List',
    hazards: [
      LvArithmeticHazard.unsignedCompare,
      LvArithmeticHazard.unsignedDivide,
      LvArithmeticHazard.unsignedShiftRight,
      LvArithmeticHazard.unsignedFormat,
    ],
  ),

  /// Single-precision float. Dart has no 32-bit double, so the carrier is a
  /// binary64 `double` and every result must be rounded back to binary32 —
  /// the float analogue of an integer mask (see
  /// [LvArithmeticHazard.floatNarrowing]).
  sgl(
    code: TypeCode.sgl,
    glyph: 'SGL',
    bits: 32,
    signed: true,
    isFloat: true,
    typedListType: 'Float32List',
    hazards: [LvArithmeticHazard.floatNarrowing],
  ),

  /// Double-precision float — Dart's `double` exactly.
  dbl(code: TypeCode.dbl, glyph: 'DBL', bits: 64, signed: true, isFloat: true, typedListType: 'Float64List')
  ;

  const LvNumericKind({
    required this.code,
    required this.glyph,
    required this.bits,
    required this.signed,
    required this.typedListType,
    this.isFloat = false,
    this.hazards = const [],
  });

  /// The `VCTP` type-enumerator byte this kind decodes from ([TypeCode]).
  final int code;

  /// LabVIEW's on-terminal label (`U32`, `DBL`).
  final String glyph;

  /// Width of the LabVIEW value in bits.
  final int bits;

  /// Whether the LabVIEW value is signed (floats are).
  final bool signed;

  /// Whether the value is a floating-point number rather than an integer.
  final bool isFloat;

  /// The `dart:typed_data` list that stores this kind at its exact width —
  /// the representation an array of it uses.
  final String typedListType;

  /// The Dart operators that misread this kind's carrier, with their remedies.
  final List<LvArithmeticHazard> hazards;

  /// The Dart type the value is carried in: `int` or `double`.
  String get dartType => isFloat ? 'double' : 'int';

  /// Whether an arithmetic result must be renormalized before it is stored or
  /// compared — i.e. whether [wrap] does anything.
  bool get needsWrap => wrap('x') != 'x';

  /// The mask literal an unsigned integer kind renormalizes with (`0xFF`,
  /// `0xFFFFFFFF`), or null for a signed, 64-bit or floating kind.
  String? get maskLiteral =>
      signed || isFloat || bits == 64 ? null : '0x${((1 << bits) - 1).toRadixString(16).toUpperCase()}';

  /// [expression] renormalized to this kind's width — what a generator wraps
  /// every arithmetic result in.
  ///
  /// Unsigned integers mask off the carry (`(a + b) & 0xFFFFFFFF`); signed
  /// integers narrower than the carrier sign-extend with a shift pair
  /// (`(a + b) << 32 >> 32`, exact because Dart's `>>` is arithmetic); `I64`
  /// and `U64` already fill the carrier and return [expression] unchanged;
  /// `SGL` rounds to binary32 through a one-element [Float32List]; `DBL`
  /// returns [expression] unchanged.
  String wrap(String expression) {
    if (isFloat) {
      return bits == 64 ? expression : '(Float32List(1)..[0] = $expression)[0]';
    }
    if (bits == 64) return expression;
    if (!signed) return '($expression) & ${maskLiteral!}';
    return '($expression) << ${64 - bits} >> ${64 - bits}';
  }

  /// The kind for a `VCTP` type-enumerator byte, or null when [code] is not a
  /// numeric with a decided representation (`EXT`, the complex family and the
  /// fixed-point pair have none — see `kUnmappedTypeCodes`).
  static LvNumericKind? ofCode(int code) => _byCode[code];

  static final Map<int, LvNumericKind> _byCode = {for (final kind in values) kind.code: kind};
}
