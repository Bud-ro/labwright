import 'dart:typed_data';

/// The border of an icon's art: 1 for every opaque pixel of [alpha] (row-major, [width] by
/// [height], 0 transparent) that touches a transparent pixel or the image's edge through one
/// of its four sides, 0 elsewhere. A reference that anti-aliases the icon blends these pixels
/// with the background; the pixels inside them are the icon's interior.
Uint8List primIconBorderMask(Uint8List alpha, int width, int height) {
  final border = Uint8List(alpha.length);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final i = y * width + x;
      if (alpha[i] == 0) continue;
      final onEdge =
          x == 0 ||
          y == 0 ||
          x == width - 1 ||
          y == height - 1 ||
          alpha[i - 1] == 0 ||
          alpha[i + 1] == 0 ||
          alpha[i - width] == 0 ||
          alpha[i + width] == 0;
      if (onEdge) border[i] = 1;
    }
  }
  return border;
}
