/// Decoder for the legacy **Mac-style icon bitmaps** — `icl8` / `icl4` / `ICON`.
///
/// Corpus-confirmed (exact, 100%): these are 32×32 icon bitmaps —
/// `icl8` = 1024 B @ **8 bpp** (palette-indexed, 7583/7583), `icl4` = 512 B @
/// **4 bpp**, `ICON` = 128 B @ **1 bpp** (monochrome, 7534). Each holds exactly
/// 32×32 = 1024 pixels (1 byte / 2 nibbles / 8 bits per byte). They are real,
/// varied icon data (ICON has 5242 distinct bodies) — NOT a stub or a name table
/// (the earlier "repurposed" reading was disproved by re-probe; `40 21` shows up
/// in only 0.8% of ICON, coincidentally).
///
/// Clean-room: the dimensions + bit-depth + pixel-index extraction are CONFIRMED.
/// The 4-/8-bpp index → RGB mapping needs LabVIEW's icon palette (not yet
/// recovered), so we expose raw palette indices, not colours.
library;

import 'dart:typed_data';


/// A decoded legacy icon bitmap (always 32×32).
class ViLegacyIcon {
  const ViLegacyIcon({required this.bpp, required this.pixels});

  static const int width = 32;
  static const int height = 32;

  /// Bits per pixel: 8 (`icl8`), 4 (`icl4`), or 1 (`ICON`).
  final int bpp;

  /// Row-major 32×32 = 1024 pixel values. For 1 bpp these are 0/1 (mask); for
  /// 4/8 bpp they are palette indices (RGB mapping is future work).
  final List<int> pixels;

}

/// Bits-per-pixel for a legacy-icon tag, or null if not a legacy-icon tag.
int? legacyIconBpp(String tag) => switch (tag) {
      'icl8' => 8,
      'icl4' => 4,
      'ICON' => 1,
      _ => null,
    };

/// Decodes an `icl8`/`icl4`/`ICON` body into its 1024-pixel index grid. Returns
/// null unless the buffer is the exact 32×32 size for [bpp]
/// (8→1024 B, 4→512 B, 1→128 B) — we never guess a partial bitmap.
ViLegacyIcon? decodeLegacyIcon(Uint8List body, int bpp) {
  const pixelCount = ViLegacyIcon.width * ViLegacyIcon.height;
  final expectBytes = pixelCount * bpp ~/ 8;
  if (body.length != expectBytes) return null;
  final pixels = List<int>.filled(pixelCount, 0);
  switch (bpp) {
    case 8:
      pixels.setAll(0, body);
    case 4:
      for (var j = 0; j < expectBytes; j++) {
        pixels[2 * j] = body[j] >> 4;
        pixels[2 * j + 1] = body[j] & 0x0f;
      }
    case 1:
      for (var j = 0; j < expectBytes; j++) {
        for (var k = 0; k < 8; k++) {
          pixels[8 * j + k] = (body[j] >> (7 - k)) & 1;
        }
      }
    default:
      return null;
  }
  return ViLegacyIcon(bpp: bpp, pixels: pixels);
}
