import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_vi_transpile/labwright_vi_transpile.dart';
import 'package:test/test.dart';

import 'generated/lrc8.g.dart';
import 'generated/modbus_crc16.g.dart';
import 'generated/modbus_crc16_table.g.dart';
import 'snippets.dart';

const int kModbusCrcCheck = 0x4B37;
const int kModbusCrcPoly = 0xA001;
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

int lrcReference(List<int> message) {
  var sum = 0;
  for (final byte in message) {
    sum = sum + byte & 0xFF;
  }
  return -sum & 0xFF;
}

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

  test(
    'the checked-in generated sources are exactly what the three block diagrams lower to',
    () {
      for (final (fileName, functionName, generated) in const [
        ('Calc LRC-8.vi', 'lrc8', 'lrc8.g.dart'),
        ('Calculate CRC.vi', 'modbusCrc16', 'modbus_crc16.g.dart'),
        ('Calc CRC-16.vi', 'calcCrc16', 'modbus_crc16_table.g.dart'),
      ]) {
        final path = corpusViPaths(corpusViDir()).firstWhere((path) => path.endsWith(fileName));
        final unit = LvViUnit.fromSections(decodeSections(File(path).readAsBytesSync()), fileName: fileName)!;
        final result = emitLvLibrary(unit, functionName: functionName, sourceNote: fileName);
        expect(result.refusal, isNull, reason: '$fileName must lower');
        final committed = File('${_testDir()}/generated/$generated').readAsStringSync().replaceAll('\r\n', '\n');
        expect(result.source, committed, reason: 'regenerate $generated after changing the emitter');
      }
    },
    tags: 'corpus',
  );
}

String _testDir() {
  for (final candidate in const ['test', 'packages/labwright_vi_transpile/test']) {
    if (Directory(candidate).existsSync()) return candidate;
  }
  throw StateError('cannot locate the test directory');
}
