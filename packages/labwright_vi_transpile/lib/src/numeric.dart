import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

enum LvArithmeticHazard {
  unsignedCompare(
    operators: ['<', '<=', '>', '>='],
    remedy: r'(a ^ -0x8000000000000000).compareTo(b ^ -0x8000000000000000)',
  ),

  unsignedDivide(operators: ['~/', '%'], remedy: 'BigInt-backed unsigned division helper'),

  unsignedShiftRight(operators: ['>>'], remedy: '>>>'),

  unsignedFormat(operators: ['toString', 'toDouble', 'toRadixString'], remedy: 'BigInt.from(a).toUnsigned(64)'),

  floatNarrowing(operators: ['+', '-', '*', '/'], remedy: '(Float32List(1)..[0] = value)[0]')
  ;

  const LvArithmeticHazard({required this.operators, required this.remedy});

  final List<String> operators;

  final String remedy;
}

enum LvNumericKind {
  i8(code: TypeCode.i8, glyph: 'I8', bits: 8, signed: true, typedListType: 'Int8List'),
  i16(code: TypeCode.i16, glyph: 'I16', bits: 16, signed: true, typedListType: 'Int16List'),
  i32(code: TypeCode.i32, glyph: 'I32', bits: 32, signed: true, typedListType: 'Int32List'),

  i64(code: TypeCode.i64, glyph: 'I64', bits: 64, signed: true, typedListType: 'Int64List'),

  u8(code: TypeCode.u8, glyph: 'U8', bits: 8, signed: false, typedListType: 'Uint8List'),
  u16(code: TypeCode.u16, glyph: 'U16', bits: 16, signed: false, typedListType: 'Uint16List'),
  u32(code: TypeCode.u32, glyph: 'U32', bits: 32, signed: false, typedListType: 'Uint32List'),

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

  sgl(
    code: TypeCode.sgl,
    glyph: 'SGL',
    bits: 32,
    signed: true,
    isFloat: true,
    typedListType: 'Float32List',
    hazards: [LvArithmeticHazard.floatNarrowing],
  ),

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

  final int code;

  final String glyph;

  final int bits;

  final bool signed;

  final bool isFloat;

  final String typedListType;

  final List<LvArithmeticHazard> hazards;

  bool get needsWrap => wrap('x') != 'x';

  String? get maskLiteral =>
      signed || isFloat || bits == 64 ? null : '0x${((1 << bits) - 1).toRadixString(16).toUpperCase()}';

  String wrap(String expression) {
    if (isFloat) {
      return bits == 64 ? expression : '(Float32List(1)..[0] = $expression)[0]';
    }
    if (bits == 64) return expression;
    if (!signed) return '($expression) & ${maskLiteral!}';
    return '($expression) << ${64 - bits} >> ${64 - bits}';
  }

  static LvNumericKind? ofCode(int code) => _byCode[code];

  static final Map<int, LvNumericKind> _byCode = {for (final kind in values) kind.code: kind};
}
