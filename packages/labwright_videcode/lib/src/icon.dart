import 'dart:typed_data';

import 'decode.dart';

/// A decoded VI icon: a small uncompressed 24-bit RGB bitmap.
///
/// LabVIEW stores the recognizable VI icon as a plain RGB888 bitmap (no palette,
/// no compression) embedded inside a "picture" stream that can live under several
/// section tags (`PICC`, `DSIM`, `FPHb`, `FPSE`, `LIbd`, …) — *not* in the
/// classic `ICON`/`icl4`/`icl8` resource blocks (those hold unrelated LabVIEW
/// metadata: hashes, help text, tables). Corpus-validated: 310/349 VIs yield a
/// 20×20×24 icon that reconstructs to exactly `w*h*3` pixel bytes.
class ViIcon {
  const ViIcon({required this.width, required this.height, required this.rgb});

  /// Pixel width.
  final int width;

  /// Pixel height.
  final int height;

  /// `width * height * 3` bytes, row-major top-to-bottom, RGB per pixel.
  final Uint8List rgb;
}

int _u16(Uint8List b, int p) => (b[p] << 8) | b[p + 1];

/// Extracts an embedded 24-bit RGB icon bitmap from one section's [bytes], or
/// null if the section does not contain one.
///
/// The bitmap is stored with a fixed big-endian header — `u32@0 == 0`,
/// `width@4`, `height@6`, `depth@8 == 24`, and a doubled rect at offset 30
/// matching the one at offset 4 — followed (at the tail) by `width*height*3`
/// packed RGB bytes. This signature + the doubled-rect check is what
/// distinguishes the real bitmap from the vector/label "picture" ops that share
/// these section tags. Honest by construction: no palette or decompression is
/// involved (the data is already RGB888).
ViIcon? extractRgbIcon(Uint8List bytes) {
  if (bytes.length < 36) return null;
  if ((bytes[0] | bytes[1] | bytes[2] | bytes[3]) != 0) return null; // flags u32@0 == 0
  final w = _u16(bytes, 4), h = _u16(bytes, 6), depth = _u16(bytes, 8);
  if (depth != 24 || w < 1 || h < 1 || w > 512 || h > 512) return null;
  if (_u16(bytes, 30) != w || _u16(bytes, 32) != h) return null; // doubled-rect validation
  final need = w * h * 3;
  if (bytes.length - need < 30) return null; // pixels are the tail; header must precede them
  return ViIcon(width: w, height: h, rgb: bytes.sublist(bytes.length - need));
}

/// Finds the VI's icon by scanning all decoded [sections] for an embedded RGB
/// bitmap (it appears under different tags depending on the VI). Returns the
/// first match, or null when no uncompressed icon is present (~11% of VIs).
ViIcon? decodeViIcon(List<DecodedSection> sections) {
  for (final s in sections) {
    final icon = extractRgbIcon(s.bytes);
    if (icon != null) return icon;
  }
  return null;
}
