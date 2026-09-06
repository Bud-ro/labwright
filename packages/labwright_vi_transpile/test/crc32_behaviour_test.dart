import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_vi_transpile/labwright_vi_transpile.dart';
import 'package:test/test.dart';

import 'generated/crc32_lookup_table.g.dart';
import 'generated/png_crc32.g.dart';
import 'snippets.dart';

const int kCrc32ReflectedPoly = 0xEDB88320;
const int kCrc32Check = 0xCBF43926;
Uint32List crc32ReferenceTable() {
  final table = Uint32List(256);
  for (var seed = 0; seed < 256; seed++) {
    var register = seed;
    for (var bit = 0; bit < 8; bit++) {
      register = register & 1 != 0 ? (register >>> 1) ^ kCrc32ReflectedPoly : register >>> 1;
    }
    table[seed] = register;
  }
  return table;
}

final List<List<int>> kCrc32Messages = [
  latin1.encode('123456789'),
  for (var byte = 0; byte < 256; byte++) <int>[byte],
  latin1.encode('The quick brown fox jumps over the lazy dog'),
  [for (var index = 0; index < 512; index++) (index * 31 + 7) & 0xFF],
  List<int>.filled(1000, 0xFF),
];
int crc32Of(List<int> message, Uint32List table) {
  var register = 0xFFFFFFFF;
  for (final byte in message) {
    register = table[(register ^ byte) & 0xFF] ^ (register >>> 8);
  }
  return (register ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

void main() {
  test('the reference CRC-32 table reproduces the published check value', () {
    expect(crc32Of(latin1.encode('123456789'), crc32ReferenceTable()), kCrc32Check);
  });

  test('the table lowered from crc32_lookup_table.vi is the CRC-32 table, entry for entry', () {
    expect(crc32LookupTable(), crc32ReferenceTable());
  });

  test('the lowered table computes the published check value', () {
    expect(crc32Of(latin1.encode('123456789'), crc32LookupTable()), kCrc32Check);
    for (final message in <List<int>>[const <int>[], ...kCrc32Messages]) {
      expect(crc32Of(message, crc32LookupTable()), crc32Of(message, crc32ReferenceTable()));
    }
  });

  test('the code lowered from PNG CRC32.vi computes the published check value', () {
    expect(pngCrc32(stringIn: '123456789'), kCrc32Check);
  });

  test('the code lowered from PNG CRC32.vi is CRC-32/ISO-HDLC on every non-empty message', () {
    final reference = crc32ReferenceTable();
    for (final message in kCrc32Messages) {
      expect(
        pngCrc32(stringIn: latin1.decode(message)),
        crc32Of(message, reference),
        reason: '${message.length} bytes',
      );
    }
  });

  test('PNG CRC32.vi digests one zero byte for the empty message', () {
    expect(pngCrc32(stringIn: ''), crc32Of(const [0], crc32ReferenceTable()));
    expect(pngCrc32(stringIn: ''), isNot(crc32Of(const [], crc32ReferenceTable())));
  });

  test('the checked-in generated sources are exactly what the block diagrams lower to', () {
    for (final (snippet, functionName, generated) in const [
      ('crc32_lookup_table', 'crc32LookupTable', 'crc32_lookup_table.g.dart'),
      ('PNG CRC32', 'pngCrc32', 'png_crc32.g.dart'),
    ]) {
      final vi = snippetVi(snippet);
      final result = emitLvFunction(
        vi.diagram,
        functionName: functionName,
        sourceNote: '$snippet.vi',
        pool: vi.pool,
      );
      expect(result.refusal, isNull, reason: '$snippet.vi must lower');
      final committed = File('${_testDir()}/generated/$generated').readAsStringSync().replaceAll('\r\n', '\n');
      expect(
        result.source,
        committed,
        reason: 'regenerate with `dart run tool/generate.dart` after changing the emitter',
      );
    }
  });
}

String _testDir() {
  for (final candidate in const ['test', 'packages/labwright_vi_transpile/test']) {
    if (Directory(candidate).existsSync()) return candidate;
  }
  throw StateError('cannot locate the test directory');
}
