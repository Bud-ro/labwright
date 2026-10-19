import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_inspector/src/span_annotations.dart';

/// An `icl8` whose black ring leaves the four corners white and encloses a white interior.
ViLegacyIcon _ringIcon({bool gap = false}) {
  const dim = ViLegacyIcon.width;
  final bytes = Uint8List(dim * dim);
  for (var i = 0; i < dim; i++) {
    bytes[i] = bytes[(dim - 1) * dim + i] = bytes[i * dim] =
        bytes[i * dim + dim - 1] = 0xff;
  }
  for (final corner in [0, dim - 1, (dim - 1) * dim, dim * dim - 1]) {
    bytes[corner] = 0;
  }
  if (gap) bytes[16 * dim] = 0;
  return ViLegacyIcon.icl8(bytes);
}

void main() {
  test(
    'white reachable from the edge is transparent, enclosed white is not',
    () {
      final transparent = legacyIconTransparency(_ringIcon());
      expect(transparent[0], isTrue);
      expect(transparent[ViLegacyIcon.width - 1], isTrue);
      expect(transparent[16 * ViLegacyIcon.width + 16], isFalse);
      expect(transparent.where((t) => t).length, 4);
    },
  );

  test('a gap in the ring lets the transparency reach the interior', () {
    final transparent = legacyIconTransparency(_ringIcon(gap: true));
    expect(transparent[16 * ViLegacyIcon.width + 16], isTrue);
    expect(transparent[16 * ViLegacyIcon.width + 1], isTrue);
  });

  test('a fully drawn icon has no transparent pixel', () {
    final bytes = Uint8List(ViLegacyIcon.width * ViLegacyIcon.height)
      ..fillRange(0, ViLegacyIcon.width * ViLegacyIcon.height, 0xff);
    expect(
      legacyIconTransparency(ViLegacyIcon.icl8(bytes)).any((t) => t),
      isFalse,
    );
  });
}
