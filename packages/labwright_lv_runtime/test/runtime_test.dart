/// The runtime's own laws, as tables: a conversion renormalizes to its width
/// and nothing else, a rotation moves exactly one bit through the carry, and a
/// row-major offset addresses what its dimensions say.
library;

import 'dart:typed_data';

import 'package:labwright_lv_runtime/labwright_lv_runtime.dart';
import 'package:test/test.dart';

void main() {
  test('each To-Integer conversion renormalizes to its own width', () {
    const cases = <({String name, int Function(int) convert, int input, int expected})>[
      (name: 'I8 keeps an in-range value', convert: lvToI8, input: 127, expected: 127),
      (name: 'I8 sign-extends', convert: lvToI8, input: 0xFF, expected: -1),
      (name: 'I16 sign-extends', convert: lvToI16, input: 0x8000, expected: -32768),
      (name: 'I32 sign-extends', convert: lvToI32, input: 0xFFFFFFFF, expected: -1),
      (name: 'I64 is the identity', convert: lvToI64, input: -1, expected: -1),
      (name: 'U8 masks', convert: lvToU8, input: 0x1FF, expected: 0xFF),
      (name: 'U8 masks a negative', convert: lvToU8, input: -1, expected: 0xFF),
      (name: 'U16 masks', convert: lvToU16, input: 0x1FFFF, expected: 0xFFFF),
      (name: 'U32 masks', convert: lvToU32, input: -1, expected: 0xFFFFFFFF),
      (name: 'U64 keeps the bit pattern', convert: lvToU64, input: -1, expected: -1),
    ];
    for (final row in cases) {
      expect(row.convert(row.input), row.expected, reason: row.name);
    }
  });

  test('a rotate with carry moves exactly one bit through the carry', () {
    const cases = <({String name, bool left, int value, bool carryIn, int bits, int out, bool carryOut})>[
      (name: 'left, top bit leaves', left: true, value: 0x80, carryIn: false, bits: 8, out: 0x00, carryOut: true),
      (name: 'left, carry enters', left: true, value: 0x01, carryIn: true, bits: 8, out: 0x03, carryOut: false),
      (name: 'right, bit 0 leaves', left: false, value: 0x01, carryIn: false, bits: 8, out: 0x00, carryOut: true),
      (name: 'right, carry enters', left: false, value: 0x02, carryIn: true, bits: 8, out: 0x81, carryOut: false),
      (name: 'left at 32 bits', left: true, value: 0x80000000, carryIn: false, bits: 32, out: 0, carryOut: true),
    ];
    for (final row in cases) {
      final rotate = row.left ? lvRotateLeftWithCarry : lvRotateRightWithCarry;
      expect(rotate(row.value, row.carryIn, row.bits), (row.out, row.carryOut), reason: row.name);
    }
  });

  test('a rotation over eight bits returns to where it started', () {
    var value = 0xA5, carry = false;
    for (var step = 0; step < 9; step++) {
      (value, carry) = lvRotateLeftWithCarry(value, carry, 8);
    }
    expect((value, carry), (0xA5, false));
  });

  test('each swap exchanges the two halves of its own field width', () {
    const cases = <({String name, int Function(int) swap, int input, int expected})>[
      (name: 'bytes of a 16-bit value', swap: lvSwapBytes, input: 0xABCD, expected: 0xCDAB),
      (name: 'bytes of each 16-bit field', swap: lvSwapBytes, input: 0x12345678, expected: 0x34127856),
      (name: 'words of a 32-bit value', swap: lvSwapWords, input: 0x12345678, expected: 0x56781234),
      (name: 'words of each 32-bit field', swap: lvSwapWords, input: 0x1122334455667788, expected: 0x3344112277885566),
    ];
    for (final row in cases) {
      expect(row.swap(row.input), row.expected, reason: row.name);
    }
  });

  test('swapping words then bytes reverses all four bytes of a 32-bit value', () {
    // The composition LabVIEW diagrams use to change a 32-bit word's byte
    // order; it holds only because each swap is per-field.
    for (final value in const [0x12345678, 0xDEADBEEF, 0x00000001, 0xFFFFFFFF]) {
      final bytes = Uint8List(4)..buffer.asByteData().setUint32(0, value);
      final reversed = ByteData.sublistView(Uint8List.fromList(bytes.reversed.toList())).getUint32(0);
      expect(lvSwapBytes(lvSwapWords(value)) & 0xFFFFFFFF, reversed, reason: '0x${value.toRadixString(16)}');
    }
  });

  test('a quotient and its remainder reconstruct the dividend', () {
    const cases = <({int dividend, int divisor, int quotient, int remainder})>[
      (dividend: 17, divisor: 5, quotient: 3, remainder: 2),
      (dividend: 20, divisor: 5, quotient: 4, remainder: 0),
      (dividend: 7, divisor: 8, quotient: 0, remainder: 7),
      (dividend: -17, divisor: 5, quotient: -4, remainder: 3),
      (dividend: 17, divisor: -5, quotient: -4, remainder: -3),
      (dividend: -17, divisor: -5, quotient: 3, remainder: -2),
    ];
    for (final row in cases) {
      final measured = lvQuotientRemainder(row.dividend, row.divisor);
      expect(measured, (row.quotient, row.remainder), reason: '${row.dividend} / ${row.divisor}');
      expect(row.divisor * measured.$1 + measured.$2, row.dividend);
    }
  });

  test('a multi-dimensional array addresses its elements row-major', () {
    final array = LvArrayNd<Int32List>(
      Int32List.fromList(const <int>[0, 1, 2, 3, 4, 5]),
      Uint32List.fromList(const <int>[2, 3]),
    );
    for (final row in const <({List<int> at, int offset})>[
      (at: [0, 0], offset: 0),
      (at: [0, 2], offset: 2),
      (at: [1, 0], offset: 3),
      (at: [1, 2], offset: 5),
    ]) {
      expect(array.offsetOf(row.at), row.offset, reason: '${row.at}');
      expect(array.data[array.offsetOf(row.at)], row.offset);
    }
  });

  test('the iteration count is the smallest bound', () {
    expect(lvIterationCount(<int>[7]), 7);
    expect(lvIterationCount(<int>[7, 3, 9]), 3);
  });

  test('a value flattens to its own bytes, big-endian and unframed', () {
    const cases = <({String name, List<int> bytes, int value, int bits})>[
      (name: 'U8', bytes: [0xAB], value: 0xAB, bits: 8),
      (name: 'U16', bytes: [0xAB, 0xCD], value: 0xABCD, bits: 16),
      (name: 'U32', bytes: [0x01, 0x02, 0x03, 0x04], value: 0x01020304, bits: 32),
      (name: 'I64', bytes: [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF], value: -1, bits: 64),
    ];
    for (final row in cases) {
      expect(lvFlatOfInt(row.value, row.bits), row.bytes, reason: row.name);
      expect(lvIntOfFlat(Uint8List.fromList(row.bytes), row.bits), row.value, reason: row.name);
    }
    // No length prefix on a string and no dimension vector on an array: the
    // bytes are the elements and nothing else.
    expect(lvFlatOfString('AB'), <int>[0x41, 0x42]);
    expect(lvStringOfFlat(Uint8List.fromList(const <int>[0x41, 0x42])), 'AB');
    expect(lvFlatOfIntList(const <int>[0x0102, 0x0304], 16), <int>[0x01, 0x02, 0x03, 0x04]);
    expect(lvIntListOfFlat(Uint8List.fromList(const <int>[0x01, 0x02, 0x03, 0x04]), 16), <int>[0x0102, 0x0304]);
    expect(lvFloatOfFlat(lvFlatOfFloat(1.5, 64), 64), 1.5);
    expect(lvFloatOfFlat(lvFlatOfFloat(-2.5, 32), 32), -2.5);
  });

  test('a cast whose bytes do not fill the target raises rather than inventing one', () {
    // TODO(lv-typecast-size): the rule LabVIEW applies here is not decoded.
    expect(() => lvIntOfFlat(Uint8List(3), 32), throwsArgumentError);
    expect(() => lvIntListOfFlat(Uint8List(5), 16), throwsArgumentError);
  });
}
