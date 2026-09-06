import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_lv_runtime/labwright_lv_runtime.dart';
import 'package:labwright_vi_transpile/labwright_vi_transpile.dart';
import 'package:test/test.dart';

import 'generated/reverse_bits_vim.g.dart';
import 'snippets.dart';

int reverseBitsReference(int value) {
  var reversed = 0;
  for (var bit = 0; bit < 64; bit++) {
    reversed = (reversed << 1) | ((value >>> bit) & 1);
  }
  return reversed;
}

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
        reverseBitsVim(numericIn: value),
        reverseBitsReference(value),
        reason: '0x${value.toRadixString(16)}',
      );
    }
  });

  test('a cast to bytes and back is the identity, which is what fixes the byte form', () {
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

String _testDir() {
  for (final candidate in const ['test', 'packages/labwright_vi_transpile/test']) {
    if (Directory(candidate).existsSync()) return candidate;
  }
  throw StateError('cannot locate the test directory');
}
