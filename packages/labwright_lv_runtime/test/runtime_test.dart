import 'dart:io';
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
    expect(lvFlatOfString('AB'), <int>[0x41, 0x42]);
    expect(lvStringOfFlat(Uint8List.fromList(const <int>[0x41, 0x42])), 'AB');
    expect(lvFlatOfIntList(const <int>[0x0102, 0x0304], 16), <int>[0x01, 0x02, 0x03, 0x04]);
    expect(lvIntListOfFlat(Uint8List.fromList(const <int>[0x01, 0x02, 0x03, 0x04]), 16), <int>[0x0102, 0x0304]);
    expect(lvFloatOfFlat(lvFlatOfFloat(1.5, 64), 64), 1.5);
    expect(lvFloatOfFlat(lvFlatOfFloat(-2.5, 32), 32), -2.5);
  });

  test('merging errors takes the first error, then the first warning, then nothing', () {
    const error1 = LvError(status: true, code: 5, source: 'first');
    const error2 = LvError(status: true, code: 6, source: 'second');
    const warning1 = LvError(status: false, code: 7, source: 'warn one');
    const warning2 = LvError(status: false, code: 8, source: 'warn two');
    const clear = LvError(status: false, code: 0, source: 'clear');
    for (final row in const <({String name, List<LvError> inputs, LvError expected})>[
      (name: 'first of two errors', inputs: [error1, error2], expected: error1),
      (name: 'an error outranks an earlier warning', inputs: [warning1, error2], expected: error2),
      (name: 'first of two warnings', inputs: [warning1, warning2], expected: warning1),
      (name: 'a warning outranks an earlier clear', inputs: [clear, warning2], expected: warning2),
      (name: 'all clear', inputs: [clear, clear], expected: LvError.none),
      (name: 'nothing at all', inputs: [], expected: LvError.none),
    ]) {
      final measured = lvMergeErrors(row.inputs);
      expect(
        (measured.status, measured.code, measured.source),
        (
          row.expected.status,
          row.expected.code,
          row.expected.source,
        ),
        reason: row.name,
      );
    }
  });

  test('a cast whose bytes do not fill the target raises rather than inventing one', () {
    expect(() => lvIntOfFlat(Uint8List(3), 32), throwsArgumentError);
    expect(() => lvIntListOfFlat(Uint8List(5), 16), throwsArgumentError);
  });

  test('a quotient floors, whatever the operands sign', () {
    const cases = <({int dividend, int divisor, int quotient, int remainder})>[
      (dividend: 7, divisor: 2, quotient: 3, remainder: 1),
      (dividend: -7, divisor: 2, quotient: -4, remainder: 1),
      (dividend: 7, divisor: -2, quotient: -4, remainder: -1),
      (dividend: -7, divisor: -2, quotient: 3, remainder: -1),
      (dividend: 8, divisor: 2, quotient: 4, remainder: 0),
      (dividend: -8, divisor: 2, quotient: -4, remainder: 0),
    ];
    for (final row in cases) {
      expect(
        lvQuotientRemainder(row.dividend, row.divisor),
        (row.quotient, row.remainder),
        reason: '${row.dividend} / ${row.divisor}',
      );
    }
  });

  test('a wait blocks for its request, measured by a clock it does not read', () {
    final wall = Stopwatch()..start();
    lvWaitMs(20);
    expect(wall.elapsedMicroseconds, greaterThanOrEqualTo(20 * Duration.microsecondsPerMillisecond));
  });

  test('the stock VIs: space, trimming, colour bytes, and an error from a code', () {
    expect(lvSpaceConstant(), ' ');
    expect(lvTrimWhitespace(string: '  a b \t\r\n'), 'a b');
    expect(lvTrimWhitespace(string: '  a b  ', location: LvTrimLocation.start), 'a b  ');
    expect(lvTrimWhitespace(string: '  a b  ', location: LvTrimLocation.end), '  a b');
    expect(lvTrimWhitespace(string: '   '), '');
    expect(lvColorToRgb(color: 0x00ff8001), (red: 0xff, green: 0x80, blue: 0x01));
    expect(lvApplicationDirectory().absolute, isTrue);
    expect(lvApplicationDirectory().components, isNotEmpty);
    final raised = lvErrorClusterFromErrorCode(errorCode: 5000, message: 'custom');
    expect((raised.status, raised.code, raised.source), (true, 5000, 'custom'));
    final clear = lvErrorClusterFromErrorCode(errorCode: 0, message: 'note');
    expect((clear.status, clear.code, clear.source), (false, 0, 'note'));
    const upstream = LvError(status: true, code: 1, source: 'earlier');
    expect(lvErrorClusterFromErrorCode(errorCode: 5000, errorIn: upstream), upstream);
  });

  test('Match Pattern follows the published special-character rules', () {
    const cases = <(String, String, int, String, String, String, int)>[
      ('Welcome to LabVIEW.', 't....', 0, 'Welcome ', 'to La', 'bVIEW.', 13),
      ('Welcome to LabVIEW.', '[z.]', 0, 'Welcome to LabVIEW', '.', '', 19),
      ('Hello LabVIEW!', 'el*', 0, 'H', 'ell', 'o LabVIEW!', 4),
      ('Hello LabVIEW!', 'el+', 0, 'H', 'ell', 'o LabVIEW!', 4),
      ('Hello LabVIEW!', 'el?', 0, 'H', 'el', 'lo LabVIEW!', 3),
      ('version=14.0.1', r'[0-9]+\.[0-9]+\.[0-9]+', 0, 'version=', '14.0.1', '', 14),
      ('Hello LabVIEW!', '^[^ ]+', 0, '', 'Hello', ' LabVIEW!', 5),
      ('Hello LabVIEW!', r'[^ ]+$', 0, 'Hello ', 'LabVIEW!', '', 14),
      (
        'Welcome\nto\tthe LabVIEW Help!',
        r'come\nto\tthe\sLabVIEW\sHelp\21',
        0,
        'Wel',
        'come\nto\tthe LabVIEW Help!',
        '',
        28,
      ),
      ('cdb', 'b*', 0, '', '', 'cdb', 0),
      ('bbbcd', 'b*', 0, '', 'bbb', 'cd', 3),
      ('abc', 'x', 0, 'abc', '', '', -1),
      ('volts', '[Vv][Oo][Ll][Tt][Ss]', 0, '', 'volts', '', 5),
      ('a-b', '[ +-]', 0, 'a', '-', 'b', 2),
      ('ab123c', '[0-9]+', 0, 'ab', '123', 'c', 5),
      ('12ab3', '[~0-9]+', 0, '12', 'ab', '3', 4),
      ('xLevel', '^Level', 1, 'x', 'Level', '', 6),
      ('xLevel', '^Level', 0, 'xLevel', '', '', -1),
      ('Volts Volts', r'Volts$', 0, 'Volts ', 'Volts', '', 11),
      ('a(b(c))d', '(.*)', 0, 'a', '(b(c))', 'd', 7),
      ('a(b(c))d', '([~()]*)', 0, 'a(b', '(c)', ')d', 6),
      ('a[b', r'\[', 0, 'a', '[', 'b', 2),
      ('the dog', '[cd][ao][tg]', 0, 'the ', 'dog', '', 7),
      ('hz+', 'hz[+]', 0, '', 'hz+', '', 3),
      ('aaab', 'a*ab', 0, '', 'aaab', '', 4),
      ('abc', 'b', -5, 'a', 'b', 'c', 2),
      ('abc', 'b', 3, 'abc', '', '', -1),
      ('abc', '', 2, 'ab', '', 'c', 2),
      ('a\nb', '.', 1, 'a\n', 'b', '', 3),
    ];
    for (final (string, pattern, offset, before, match, after, past) in cases) {
      expect(
        lvMatchPattern(string, pattern, offset),
        (before: before, match: match, after: after, offsetPastMatch: past),
        reason: '"$pattern" in "$string" at $offset',
      );
    }
    expect(() => lvMatchPattern('x', '*a'), throwsUnsupportedError);
    expect(() => lvMatchPattern('x', '[ab'), throwsUnsupportedError);
    expect(() => lvMatchPattern('x', r'a\'), throwsUnsupportedError);
  });

  test('Build Path appends a name or relative path, and invalid sides make Not A Path', () {
    const base = LvPath(components: ['c:', 'dir1'], absolute: true);
    final sep = Platform.pathSeparator;
    expect(lvBuildPath(base, 'vis').components, ['c:', 'dir1', 'vis']);
    expect(lvBuildPath(base, 'vis').absolute, isTrue);
    expect(lvBuildPath(base, 'vis${sep}first.vi').components, ['c:', 'dir1', 'vis', 'first.vi']);
    expect(lvBuildPath(base, const LvPath(components: ['vis'], absolute: false)).components, ['c:', 'dir1', 'vis']);
    expect(lvBuildPath(const LvPath(components: [], absolute: false), 'a').absolute, isFalse);
    expect(lvBuildPath(base, '').valid, isFalse);
    expect(lvBuildPath(LvPath.notAPath, 'a').valid, isFalse);
    expect(lvBuildPath(base, LvPath.notAPath).valid, isFalse);
    expect(lvBuildPath(const LvPath(components: [], absolute: false), base), base);
    expect(() => lvBuildPath(base, base), throwsUnsupportedError);
    expect(lvPathOfString('${sep}usr${sep}lib').absolute, isTrue);
    expect(lvPathOfString('${sep}usr${sep}lib').components, ['usr', 'lib']);
    expect(LvPath.notAPath.isEmpty, isFalse);
    expect(lvNotARefnum(LvRefnum.none), isTrue);
    expect(lvNotARefnum(const LvRefnum(7)), isFalse);
  });

  test('Format Into String pads, cuts and signs as the published examples show', () {
    expect(lvFormatRadix(12, 16, 32, width: 2, zeroPad: true), '0c');
    expect(lvFormatRadix(12, 16, 32, width: 2, zeroPad: true, upper: true), '0C');
    expect(lvFormatRadix(-1, 16, 8, upper: true), 'FF');
    expect(lvFormatRadix(12, 8, 32, width: 6, zeroPad: true), '000014');
    expect(lvFormatRadix(12, 2, 32), '1100');
    expect(lvFormatFixed(12.67, 1, width: 5), ' 12.7');
    expect(lvFormatFixed(12.67, 3, width: 5), '12.670');
    expect(lvFormatFixed(-1.5, 2, width: 7, zeroPad: true), '-001.50');
    expect(lvFormatFixed(1.5, 2, plusSign: true), '+1.50');
    expect(lvFormatText('Hello, World', width: 10, maxLength: 6), '    Hello,');
    expect(lvFormatText('ab', width: 4, leftJustify: true), 'ab  ');
    expect(lvFormatInt(-7, width: 4, zeroPad: true), '-007');
    expect(lvFormatInt(7, width: 4, leftJustify: true), '7   ');
    expect(lvFormatInt(7, plusSign: true), '+7');
  });

  test('Search 1D Array finds the first exact match at or after the start index', () {
    expect(lvSearch1dArray(['upper limit', 'lower limit'], 'limit'), -1);
    expect(lvSearch1dArray(['a', 'b', 'a'], 'a'), 0);
    expect(lvSearch1dArray(['a', 'b', 'a'], 'a', 1), 2);
    expect(lvSearch1dArray(['a', 'b', 'a'], 'a', 3), -1);
    expect(lvSearch1dArray(<bool>[false, true], true), 1);
    expect(lvSearch1dArray(Int32List.fromList([5, 6, 7]), 7), 2);
    const home = LvPath(components: ['home'], absolute: true);
    expect(
      lvSearch1dArray([
        LvPath.notAPath,
        const LvPath(components: ['home'], absolute: true),
      ], home),
      1,
    );
    expect(() => lvSearch1dArray(<int>[], 1, -1), throwsRangeError);
  });

  test('a timestamp is its seconds and fraction, the epoch being both zero', () {
    expect(LvTimestamp.epoch, const LvTimestamp(seconds: 0, fraction: 0));
    expect(const LvTimestamp(seconds: 3027456000, fraction: 0) == LvTimestamp.epoch, isFalse);
  });
}
