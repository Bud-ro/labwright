import 'dart:typed_data';

import '../decode.dart';

/// An embedded uncompressed 24-bit RGB picture extracted from a VI.
///
/// LabVIEW embeds RGB888 bitmaps (no palette, no compression) inside "picture"
/// streams that can live under several section tags (`PICC`, `DSIM`, `FPHb`,
/// `FPSE`, `LIbd`, …). [extractRgbIcon] recovers one such bitmap by signature.
///
/// HONESTY: on the PicoScope sample corpus the *first* such bitmap is **not** a
/// per-VI identity icon — there are only two distinct 20×20 images across all
/// files (a generic checkmark and an X glyph), byte-identical across unrelated
/// VIs. So this is best understood as "an embedded RGB glyph", not the VI's
/// unique icon. (The classic `ICON`/`icl4`/`icl8` blocks are *not* these
/// bitmaps either — they hold unrelated metadata: hashes/help-text/tables.)
/// The real per-VI custom icon, if any, is not reliably recovered yet.
class ViIcon {
  const ViIcon({required this.width, required this.height, required this.rgb});

  final int width;

  final int height;

  /// `width * height * 3` bytes, row-major top-to-bottom, RGB per pixel.
  final Uint8List rgb;
}

int _u16(Uint8List bytes, int at) => (bytes[at] << 8) | bytes[at + 1];

/// Largest plausible embedded-icon edge, in pixels; a sanity bound rejecting
/// garbage rects.
const int _maxIconEdge = 512;

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
  if (bytes[0] != 0 || bytes[1] != 0 || bytes[2] != 0 || bytes[3] != 0) {
    return null;
  }
  final width = _u16(bytes, 4), height = _u16(bytes, 6), depth = _u16(bytes, 8);
  if (depth != 24 || width < 1 || height < 1 || width > _maxIconEdge || height > _maxIconEdge) {
    return null;
  }
  if (_u16(bytes, 30) != width || _u16(bytes, 32) != height) return null;
  final need = width * height * 3;
  if (bytes.length - need < 30) return null;
  return ViIcon(width: width, height: height, rgb: bytes.sublist(bytes.length - need));
}

/// Finds the VI's icon by scanning all decoded [sections] for an embedded RGB
/// bitmap (it appears under different tags depending on the VI). Returns the
/// first match, or null when no uncompressed icon is present (~11% of VIs).
ViIcon? decodeViIcon(List<DecodedSection> sections) {
  for (final section in sections) {
    final icon = extractRgbIcon(section.bytes);
    if (icon != null) return icon;
  }
  return null;
}
