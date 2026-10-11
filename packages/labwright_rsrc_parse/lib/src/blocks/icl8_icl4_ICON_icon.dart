/// `icl8` / `icl4` / `ICON` - Icon: [ViLegacyIcon]
///
/// The VI icon as a 32×32 bitmap in the Mac icon-resource layouts: one byte, one nibble or one
/// bit per pixel, rows top to bottom, pixels left to right, indices into the Mac system
/// palette. Every VI carries `icl8`, nearly every one `ICON`, about half `icl4`, one section
/// each. The shallower bitmaps are LabVIEW's own renderings, not reductions of `icl8`: `icl4`
/// rarely equals the nearest 16-colour match and `ICON` matches a luminance threshold in only
/// two of three VIs. [legacyIconFromSections] picks the deepest icon a VI carries.
///
/// ```text
/// icl8:
/// offset  size  field    type     meaning
/// 0       1024  pixels8  u8[1024] Palette index per pixel, 32 rows of 32.
/// icl4:
/// offset  size  field    type    meaning
/// 0       512   pixels4  u8[512] Palette index per pixel, one nibble each, high nibble first.
/// ICON:
/// offset  size  field    type    meaning
/// 0       128   pixels1  u8[128] One bit per pixel, most significant bit first: 1 = black, 0 = white.
/// ```
library;

import 'dart:typed_data';

import '../byte_layout.dart';
import '../byte_record.dart';
import '../viparse.dart' show ViSection;

/// The three bitmap layouts, by bits per pixel.
enum LegacyIconDepth {
  /// `ICON`: 1 bit per pixel, 128 bytes.
  mono(1, 'ICON', ViLegacyIcon.iconLayout),

  /// `icl4`: 4 bits per pixel, 512 bytes.
  fourBit(4, 'icl4', ViLegacyIcon.icl4Layout),

  /// `icl8`: 8 bits per pixel, 1024 bytes.
  eightBit(8, 'icl8', ViLegacyIcon.icl8Layout);

  const LegacyIconDepth(this.bits, this.tag, this.layout);

  final int bits;

  /// The section tag that stores this layout.
  final String tag;

  final ByteLayout layout;

  int get byteLength => layout.size!;

  static LegacyIconDepth? forTag(String tag) {
    for (final depth in values) {
      if (depth.tag == tag) return depth;
    }
    return null;
  }
}

final class ViLegacyIcon extends ByteRecord {
  ViLegacyIcon(Uint8List bytes, this.depth) : super(bytes, depth.layout);

  ViLegacyIcon.icl8(Uint8List bytes) : this(bytes, LegacyIconDepth.eightBit);

  ViLegacyIcon.icl4(Uint8List bytes) : this(bytes, LegacyIconDepth.fourBit);

  ViLegacyIcon.icon1(Uint8List bytes) : this(bytes, LegacyIconDepth.mono);

  static const int width = 32;

  static const int height = 32;

  final LegacyIconDepth depth;

  /// The palette index of the pixel at column [x], row [y].
  int pixelAt(int x, int y) {
    final pixel = y * width + x;
    return switch (depth) {
      LegacyIconDepth.eightBit => view.getUint8(pixel),
      LegacyIconDepth.fourBit => (pixel & 1) == 0 ? view.getUint8(pixel >> 1) >> 4 : view.getUint8(pixel >> 1) & 0x0f,
      LegacyIconDepth.mono => (view.getUint8(pixel >> 3) >> (7 - (pixel & 7))) & 1,
    };
  }

  /// The pixel at column [x], row [y] as `0xAARRGGBB` in the Mac system palette.
  int argbAt(int x, int y) => macIconArgb(depth, pixelAt(x, y));

  /// Whether every pixel carries the same palette index in both bitmaps, whatever their depths.
  bool sameGrid(ViLegacyIcon other) {
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        if (pixelAt(x, y) != other.pixelAt(x, y)) return false;
      }
    }
    return true;
  }

  static const _pixels8 = Bytes(0, size: 1024); // Palette index per pixel, 32 rows of 32.
  static const _pixels4 = Bytes(0, size: 512); // Palette index per pixel, one nibble each, high nibble first.
  static const _pixels1 = Bytes(0, size: 128); // One bit per pixel, most significant bit first: 1 = black, 0 = white.

  static const icl8Layout = ByteLayout([_pixels8]);
  static const icl4Layout = ByteLayout([_pixels4]);
  static const iconLayout = ByteLayout([_pixels1]);
}

/// The deepest icon among [sections]: `icl8`, else `icl4`, else `ICON`; null without any.
ViLegacyIcon? legacyIconFromSections(Iterable<ViSection> sections) {
  ViLegacyIcon? best;
  for (final section in sections) {
    final depth = LegacyIconDepth.forTag(section.tag);
    if (depth == null || section.bytes.length != depth.byteLength) continue;
    if (best == null || depth.bits > best.depth.bits) best = ViLegacyIcon(section.bytes, depth);
  }
  return best;
}

/// The Mac system palette entry for [index] at [depth], as `0xAARRGGBB`.
int macIconArgb(LegacyIconDepth depth, int index) => switch (depth) {
  LegacyIconDepth.mono => (index & 1) != 0 ? 0xFF000000 : 0xFFFFFFFF,
  LegacyIconDepth.fourBit => _mac4Bit[index & 0x0f],
  LegacyIconDepth.eightBit => _mac8Bit[index & 0xff],
};

const List<int> _mac4Bit = <int>[
  0xFFFFFFFF,
  0xFFFCF305,
  0xFFFF6402,
  0xFFDD0806,
  0xFFF20884,
  0xFF4600A5,
  0xFF0000D4,
  0xFF02ABEA,
  0xFF1FB714,
  0xFF006411,
  0xFF562C05,
  0xFF90713A,
  0xFFC0C0C0,
  0xFF808080,
  0xFF404040,
  0xFF000000,
];

final List<int> _mac8Bit = _buildMac8Bit();

List<int> _buildMac8Bit() {
  final table = List<int>.filled(256, 0xFF000000);
  const step = <int>[255, 204, 153, 102, 51, 0];
  for (var x = 0; x < 215; x++) {
    final r = step[x ~/ 36];
    final g = step[(x ~/ 6) % 6];
    final b = step[x % 6];
    table[x] = 0xFF000000 | (r << 16) | (g << 8) | b;
  }
  const ramp = <int>[238, 221, 187, 170, 136, 119, 85, 68, 34, 17];
  for (var i = 0; i < ramp.length; i++) {
    final v = ramp[i];
    table[215 + i] = 0xFF000000 | (v << 16);
    table[225 + i] = 0xFF000000 | (v << 8);
    table[235 + i] = 0xFF000000 | v;
    table[245 + i] = 0xFF000000 | (v << 16) | (v << 8) | v;
  }
  table[255] = 0xFF000000;
  return table;
}
