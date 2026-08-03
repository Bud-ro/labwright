/// The behavioural proof for the **N-input operand order**, the **Select**
/// terminals and the **Logical Shift** direction: the Dart lowered from
/// `crc32_lookup_table.vi`'s block diagram builds the CRC-32/ISO-HDLC table,
/// and that table reproduces the algorithm's published check value.
///
/// The VI is the reflected table generator — for each of 256 seeds, eight
/// rounds of *shift the register one bit toward the low end and, when the bit
/// leaving was set, fold in the polynomial*. Three decoded facts have to be
/// right at once for it to produce the published table, and each of them is a
/// rule that would be silently wrong if guessed:
///
/// - **Logical Shift's operand roles and direction.** The register is the
///   node's lower operand and the count its upper one, and the count is the
///   constant −1, so a positive count would have to shift the other way. Taking
///   the operands the other way round shifts the constant instead of the
///   register; reading the direction the other way multiplies by two.
/// - **Select's terminals.** The selector is the middle-drawn input and the
///   value the true case takes is the upper one. The VI's selector asks whether
///   the departing bit was CLEAR, so the upper value is the unfolded shift and
///   the lower the folded one; swapping them folds the polynomial in on exactly
///   the wrong half of the seeds.
/// - **A constant read at the width its wire states.** The count constant's
///   record holds the two bytes `FF FF`, which is −1 only when read as the I16
///   its wire declares.
///
/// The check value is the CRC of the nine ASCII bytes `123456789`, which is
/// 0xCBF43926 for CRC-32/ISO-HDLC — a published constant of the algorithm, so
/// nothing here is anchored to the VI.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_vi_transpile/labwright_vi_transpile.dart';
import 'package:test/test.dart';

import 'generated/crc32_lookup_table.g.dart';
import 'snippets.dart';

/// CRC-32/ISO-HDLC's reflected polynomial, and the check value its definition
/// fixes.
const int kCrc32ReflectedPoly = 0xEDB88320;
const int kCrc32Check = 0xCBF43926;

/// The table CRC-32/ISO-HDLC is defined by, built bit at a time from the
/// polynomial alone — the independent side of the comparison.
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

/// A table-driven CRC-32/ISO-HDLC over [message] using [table].
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
    // The whole point: the VI's own table, driven through the standard
    // algorithm, lands on the constant the algorithm is defined by.
    expect(crc32Of(latin1.encode('123456789'), crc32LookupTable()), kCrc32Check);
    for (final message in <List<int>>[
      const <int>[],
      latin1.encode('The quick brown fox jumps over the lazy dog'),
      [for (var index = 0; index < 512; index++) (index * 31 + 7) & 0xFF],
      List<int>.filled(1000, 0xFF),
    ]) {
      expect(crc32Of(message, crc32LookupTable()), crc32Of(message, crc32ReferenceTable()));
    }
  });

  test('the checked-in generated source is exactly what the block diagram lowers to', () {
    final vi = snippetVi('crc32_lookup_table');
    final result = emitLvFunction(
      vi.diagram,
      functionName: 'crc32LookupTable',
      sourceNote: 'crc32_lookup_table.vi',
      pool: vi.pool,
    );
    expect(result.refusal, isNull, reason: 'crc32_lookup_table.vi must lower');
    final committed = File(
      '${_testDir()}/generated/crc32_lookup_table.g.dart',
    ).readAsStringSync().replaceAll('\r\n', '\n');
    expect(
      result.source,
      committed,
      reason: 'regenerate with `dart run tool/generate.dart` after changing the emitter',
    );
  });
}

/// This package's `test/` directory, whichever directory the runner started in.
String _testDir() {
  for (final candidate in const ['test', 'packages/labwright_vi_transpile/test']) {
    if (Directory(candidate).existsSync()) return candidate;
  }
  throw StateError('cannot locate the test directory');
}
