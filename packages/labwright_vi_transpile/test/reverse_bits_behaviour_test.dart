/// The behavioural proof for **Type Cast** and the flat byte form it reads
/// through: the Dart lowered from `ReverseBitsVim.vi`'s block diagram reverses
/// the 64 bits of its operand, which is what the VI is named for and which no
/// other reading of the cast produces.
///
/// The diagram casts a `U64` to a byte array, reverses that array, maps each
/// byte through a 256-entry lookup table and casts the result back to a `U64`.
/// Three decoded facts have to be right at once, and each is a rule the cast
/// would be silently wrong without:
///
/// - **The cast carries no leading count.** If a value's bytes were framed the
///   way its stored constant payload is — an `i32` length before a string, a
///   dimension vector before an array — then casting eight bytes to a byte
///   array would read four of them as a length and the round trip could not
///   return the operand at all.
/// - **The bytes are big-endian.** A little-endian cast reverses the byte
///   order twice over, which is the identity on the byte sequence and leaves
///   each byte's bits reversed but the bytes themselves in place.
/// - **Which terminal is the type.** The two casts wire the same two types in
///   the opposite roles; taking the value operand for the type operand makes
///   each cast the identity.
///
/// The reference below is a bit reversal written from the definition, so
/// nothing here is anchored to the VI: the lookup table is not read from it and
/// the comparison runs over the boundary values plus a spread of patterns.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_lv_runtime/labwright_lv_runtime.dart';
import 'package:labwright_vi_transpile/labwright_vi_transpile.dart';
import 'package:test/test.dart';

import 'generated/reverse_bits_vim.g.dart';
import 'snippets.dart';

/// The 64 bits of [value] in the opposite order, bit at a time — the
/// independent side of the comparison.
int reverseBitsReference(int value) {
  var reversed = 0;
  for (var bit = 0; bit < 64; bit++) {
    reversed = (reversed << 1) | ((value >>> bit) & 1);
  }
  return reversed;
}

/// The values the comparison runs over: the boundaries, the single bits, and a
/// spread of patterns.
Iterable<int> reverseBitsCases() sync* {
  yield* const <int>[0, 1, -1, 0x0123456789ABCDEF, 0x8000000000000000, 0xFF, 0x5555555555555555];
  for (var bit = 0; bit < 64; bit++) {
    yield 1 << bit;
  }
  for (var step = 0; step < 64; step++) {
    yield (step * 0x9E3779B97F4A7C15) & -1;
  }
}

void main() {
  test('the reference reversal is its own inverse and moves the bits it names', () {
    expect(reverseBitsReference(1), 0x8000000000000000);
    expect(reverseBitsReference(0x8000000000000000), 1);
    for (final value in reverseBitsCases()) {
      expect(reverseBitsReference(reverseBitsReference(value)), value, reason: '0x${value.toRadixString(16)}');
    }
  });

  test('the lowered ReverseBitsVim reverses all 64 bits', () {
    for (final value in reverseBitsCases()) {
      expect(
        reverseBitsVim(numericOut: value),
        reverseBitsReference(value),
        reason: '0x${value.toRadixString(16)}',
      );
    }
  });

  test('a cast to bytes and back is the identity, which is what fixes the byte form', () {
    // The round trip the VI is built on, stated on its own: a value's bytes
    // read back as that value, with no length or dimension prefix in between.
    for (final value in reverseBitsCases()) {
      final bytes = Uint8List.fromList(lvIntListOfFlat(lvFlatOfInt(value, 64), 8));
      expect(bytes.length, 8, reason: 'a U64 casts to exactly its own eight bytes');
      expect(lvIntOfFlat(lvFlatOfIntList(bytes, 8), 64), value, reason: '0x${value.toRadixString(16)}');
    }
  });

  test('the checked-in generated source is exactly what the block diagram lowers to', () {
    final vi = snippetVi('ReverseBitsVim');
    final result = emitLvFunction(
      vi.diagram,
      functionName: 'reverseBitsVim',
      sourceNote: 'ReverseBitsVim.vi',
      pool: vi.pool,
    );
    expect(result.refusal, isNull, reason: 'ReverseBitsVim.vi must lower');
    final committed = File(
      '${_testDir()}/generated/reverse_bits_vim.g.dart',
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
