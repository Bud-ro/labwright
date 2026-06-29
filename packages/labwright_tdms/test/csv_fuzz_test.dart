import 'dart:math';

import 'package:labwright_tdms/labwright_tdms.dart';
import 'package:test/test.dart';

/// Robustness fuzz: `csvToTdms` accepts arbitrary text (it parses user-supplied
/// files) and must never throw, and the bytes it emits must always be a readable
/// TDMS file. Completes parser fuzz coverage (TDMS reader, viparse, JUnit, and
/// traceability are already fuzzed).
void main() {
  test('csvToTdms tolerates arbitrary junk and emits readable TDMS', () {
    final rng = Random(99);
    // A palette of characters that exercises the CSV parser's state machine
    // (delimiters, quotes, CR/LF, unicode, numbers, letters).
    const chars = [',', '\n', '\r', '"', ';', ' ', '\t', '1', '2', '.', '-', 'a', 'Z', 'é', '∑', '0'];

    String junk() {
      final len = rng.nextInt(60);
      final b = StringBuffer();
      for (var i = 0; i < len; i++) {
        b.write(chars[rng.nextInt(chars.length)]);
      }
      return b.toString();
    }

    for (var i = 0; i < 3000; i++) {
      final s = junk();
      final bytes = csvToTdms(s); // must not throw on any input
      expect(() => TdmsReader.read(bytes), returnsNormally, reason: 'unreadable TDMS from: ${s.codeUnits}');
    }

    // Explicit corner cases alongside the random sweep.
    for (final s in ['', '"', '""', '\n', '\r\n', ',', ',,,', '"unterminated', 'a\n"x""y"']) {
      expect(() => TdmsReader.read(csvToTdms(s)), returnsNormally, reason: 'corner case: ${s.codeUnits}');
    }

    // Custom-delimiter path is fuzzed too.
    for (var i = 0; i < 500; i++) {
      expect(() => TdmsReader.read(csvToTdms(junk(), delimiter: ';')), returnsNormally);
    }
  });
}
