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

import 'block_catalog.dart' show BlockConfidence;
import 'viparse.dart' show ViSection;

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

  /// Confidence in dimensions + bit-depth + index extraction (corpus-exact).
  static const BlockConfidence framingConfidence = BlockConfidence.confirmed;
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
ViLegacyIcon? decodeLegacyIcon(Uint8List b, int bpp) {
  const pixelCount = ViLegacyIcon.width * ViLegacyIcon.height; // 1024
  final expectBytes = pixelCount * bpp ~/ 8;
  if (b.length != expectBytes) return null;
  final pixels = List<int>.filled(pixelCount, 0);
  switch (bpp) {
    case 8:
      for (var i = 0; i < pixelCount; i++) {
        pixels[i] = b[i];
      }
    case 4:
      for (var j = 0; j < expectBytes; j++) {
        pixels[2 * j] = b[j] >> 4;
        pixels[2 * j + 1] = b[j] & 0x0f;
      }
    case 1:
      for (var j = 0; j < expectBytes; j++) {
        for (var k = 0; k < 8; k++) {
          pixels[8 * j + k] = (b[j] >> (7 - k)) & 1;
        }
      }
    default:
      return null;
  }
  return ViLegacyIcon(bpp: bpp, pixels: pixels);
}

/// Finds the best legacy icon among [sections], preferring richer depth
/// (`icl8` → `icl4` → `ICON`). Null if none present/decodable.
ViLegacyIcon? legacyIconFromSections(Iterable<ViSection> sections) {
  ViSection? icl8, icl4, icon;
  for (final s in sections) {
    if (s.tag == 'icl8') icl8 = s;
    if (s.tag == 'icl4') icl4 = s;
    if (s.tag == 'ICON') icon = s;
  }
  for (final s in [icl8, icl4, icon]) {
    if (s == null) continue;
    final bpp = legacyIconBpp(s.tag)!;
    final dec = decodeLegacyIcon(s.bytes, bpp);
    if (dec != null) return dec;
  }
  return null;
}
