/// The behavioural proof of the **drawn operand order** and of the **byte
/// swap**: the Dart lowered from two Modbus VIs' block diagrams computes the
/// bytes those two published algorithms are defined to compute.
///
/// Each half turns on one of this reader's claims, so a wrong claim cannot
/// pass:
///
/// - `Calc LRC-8.vi` ends in a `Subtract`. Under the drawn operand order it
///   lowers to `255 - sum`, which with the following increment is the two's
///   complement the Modbus ASCII LRC is defined to be; under the opposite
///   order it would lower to `sum - 255` and the checksum identity below would
///   fail for every message but one sum in 256.
/// - `Calculate CRC.vi` ends in a `Swap Bytes` over a 16-bit register. It
///   reproduces CRC-16/MODBUS's **published check value** — the CRC of
///   `123456789`, defined as `0x4B37` — with the two bytes exchanged, which is
///   the wire order a Modbus RTU frame carries and the operation this reader
///   reads that node as.
///
/// - `Calc CRC-16.vi` is the **table-driven** form of the same CRC-16/MODBUS,
///   from a different repository, and it is the largest lowering the fetched
///   corpus produces. It carries two 256-byte tables and two shift registers
///   that cross over each iteration — the new register's low half comes from
///   one table and the old high half, its high half from the other table — so
///   the two tables, the crossover and the emitted byte order all have to be
///   right at once to reach the published check value. Swapping the tables,
///   dropping the crossover or reversing the output pair each moves it.
///
/// The two CRC-16 VIs are independent witnesses: one folds the polynomial bit
/// at a time, the other reads a precomputed table, and both are compared with
/// the same reference and the same published constant.
///
/// All references are written from the algorithms' public definitions rather
/// than from the VIs, so no side can drift alone.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_vi_transpile/labwright_vi_transpile.dart';
import 'package:test/test.dart';

import 'generated/lrc8.g.dart';
import 'generated/modbus_crc16.g.dart';
import 'generated/modbus_crc16_table.g.dart';
import 'snippets.dart';

/// CRC-16/MODBUS's defined check value: the CRC of the nine ASCII bytes
/// `123456789`.
const int kModbusCrcCheck = 0x4B37;

/// The reflected polynomial CRC-16/MODBUS is defined by (`0x8005` reversed).
const int kModbusCrcPoly = 0xA001;

/// A bit-at-a-time CRC-16/MODBUS by the public parameter model: the register
/// starts at `0xFFFF`, each message byte is XORed into the low byte, and the
/// register is shifted right eight times against the reflected polynomial.
int modbusCrcReference(List<int> message) {
  var register = 0xFFFF;
  for (final byte in message) {
    register ^= byte & 0xFF;
    for (var bit = 0; bit < 8; bit++) {
      register = register & 1 != 0 ? register >> 1 ^ kModbusCrcPoly : register >> 1;
    }
  }
  return register;
}

/// The Modbus ASCII LRC: the two's complement of the 8-bit sum of [message].
int lrcReference(List<int> message) {
  var sum = 0;
  for (final byte in message) {
    sum = sum + byte & 0xFF;
  }
  return -sum & 0xFF;
}

/// The messages both witnesses are compared over: the empty message, the
/// published check string, every single byte value, and spreads that cross the
/// loop boundaries.
List<Uint8List> messages() => [
  Uint8List(0),
  Uint8List.fromList(latin1.encode('123456789')),
  for (var byte = 0; byte < 256; byte++) Uint8List.fromList([byte]),
  Uint8List.fromList([for (var index = 0; index < 255; index++) (index * 31 + 7) & 0xFF]),
  Uint8List.fromList(latin1.encode('The quick brown fox jumps over the lazy dog')),
  Uint8List(1000)..fillRange(0, 1000, 0xFF),
];

void main() {
  test('the reference CRC-16/MODBUS reproduces its published check value', () {
    expect(modbusCrcReference(latin1.encode('123456789')), kModbusCrcCheck);
  });

  test('the reference LRC-8 zeroes the sum it is appended to', () {
    // The LRC's defining property: a receiver adds the message and the LRC and
    // expects zero. It holds for the reference on every message below.
    for (final message in messages()) {
      final sum = message.fold(0, (running, byte) => running + byte);
      expect(sum + lrcReference(message) & 0xFF, 0, reason: '${message.length} bytes');
    }
  });

  test('the code lowered from Calculate CRC.vi is CRC-16/MODBUS with its bytes swapped', () {
    for (final message in messages()) {
      final expected = modbusCrcReference(message);
      expect(
        modbusCrc16(data: message),
        (expected & 0xFF) << 8 | expected >> 8,
        reason: '${message.length} bytes',
      );
    }
    // Spelled out on the published vector, so the swap is visible and not just
    // asserted by the loop above.
    expect(modbusCrc16(data: Uint8List.fromList(latin1.encode('123456789'))), 0x374B);
  });

  test('the code lowered from Calc CRC-16.vi is CRC-16/MODBUS in Modbus RTU wire order', () {
    for (final message in messages()) {
      final expected = modbusCrcReference(message);
      expect(
        calcCrc16(frameIn: message),
        [expected & 0xFF, expected >> 8],
        reason: '${message.length} bytes',
      );
    }
    // A Modbus RTU frame carries the CRC low byte first, so the published
    // check value 0x4B37 appears on the wire as these two bytes in this order.
    expect(calcCrc16(frameIn: Uint8List.fromList(latin1.encode('123456789'))), [0x37, 0x4B]);
  });

  test('the two CRC-16 VIs agree, one folding bit at a time and one reading a table', () {
    for (final message in messages()) {
      final swapped = modbusCrc16(data: message);
      expect(
        calcCrc16(frameIn: message),
        [swapped >> 8, swapped & 0xFF],
        reason: '${message.length} bytes',
      );
    }
  });

  test('the code lowered from Calc LRC-8.vi agrees with the reference byte for byte', () {
    for (final message in messages()) {
      expect(lrc8(frameIn: message), lrcReference(message), reason: '${message.length} bytes');
    }
  });

  final corpus = corpusViDir();
  test(
    'the checked-in generated sources are exactly what the three block diagrams lower to',
    () {
      for (final (fileName, functionName, generated) in const [
        ('Calc LRC-8.vi', 'lrc8', 'lrc8.g.dart'),
        ('Calculate CRC.vi', 'modbusCrc16', 'modbus_crc16.g.dart'),
        ('Calc CRC-16.vi', 'calcCrc16', 'modbus_crc16_table.g.dart'),
      ]) {
        final path = corpusViPaths(corpus!).firstWhere((path) => path.endsWith(fileName));
        final unit = LvViUnit.fromSections(decodeSections(File(path).readAsBytesSync()), fileName: fileName);
        final result = emitLvLibrary(unit!, functionName: functionName, sourceNote: fileName);
        expect(result.refusal, isNull, reason: '$fileName must lower');
        // Compared with newlines normalised: the emitter always writes \n,
        // while a Windows checkout hands the committed file back as \r\n.
        final committed = File('${_testDir()}/generated/$generated').readAsStringSync().replaceAll('\r\n', '\n');
        expect(result.source, committed, reason: 'regenerate $generated after changing the emitter');
      }
    },
    tags: 'corpus',
    skip: corpus == null ? 'corpus not fetched' : null,
  );
}

/// This package's `test/` directory, whichever directory the runner started in.
String _testDir() {
  for (final candidate in const ['test', 'packages/labwright_vi_transpile/test']) {
    if (Directory(candidate).existsSync()) return candidate;
  }
  throw StateError('cannot locate the test directory');
}
