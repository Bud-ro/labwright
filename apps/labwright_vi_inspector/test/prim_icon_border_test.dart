import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_vi_inspector/src/prim_icon_border.dart';

void main() {
  Uint8List alphaOf(List<String> rows) => Uint8List.fromList([
    for (final row in rows)
      for (final c in row.codeUnits) c == 0x23 ? 1 : 0,
  ]);

  test('a full square\'s border is its outer ring', () {
    final border = primIconBorderMask(
      alphaOf(['####', '####', '####', '####']),
      4,
      4,
    );
    expect(border, [1, 1, 1, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 1, 1, 1]);
  });

  test('a transparent pixel makes its opaque neighbours border', () {
    final border = primIconBorderMask(
      alphaOf(['#####', '#####', '##.##', '#####', '#####']),
      5,
      5,
    );
    expect(border[1 * 5 + 2], 1);
    expect(border[2 * 5 + 1], 1);
    expect(border[2 * 5 + 3], 1);
    expect(border[3 * 5 + 2], 1);
    expect(border[1 * 5 + 1], 0);
    expect(border[2 * 5 + 2], 0);
  });

  test('a triangle\'s border follows its slope', () {
    final border = primIconBorderMask(
      alphaOf(['#....', '##...', '###..', '####.', '#####']),
      5,
      5,
    );
    expect(border, [
      1, 0, 0, 0, 0, //
      1, 1, 0, 0, 0, //
      1, 0, 1, 0, 0, //
      1, 0, 0, 1, 0, //
      1, 1, 1, 1, 1, //
    ]);
  });
}
