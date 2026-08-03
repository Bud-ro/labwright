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
}
