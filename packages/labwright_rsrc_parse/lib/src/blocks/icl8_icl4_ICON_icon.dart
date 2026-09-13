/// `icl8` / `icl4` / `ICON` — the VI icon as a 32×32 bitmap in the Mac icon-resource layouts:
/// one byte, one nibble or one bit per pixel, rows top to bottom, pixels left to right, indices
/// into the Mac system palette.
///
/// ```text
/// icl8:
/// offset  size  field                      type     meaning
/// 0       1024  pixels                     u8[1024] palette index per pixel, 32 rows of 32
/// icl4:
/// offset  size  field                      type     meaning
/// 0       512   pixels                     u4[1024] palette index per pixel, high nibble first
/// ICON:
/// offset  size  field                      type     meaning
/// 0       128   pixels                     u1[1024] 1 = black, 0 = white, most significant bit
///                                                   first
/// ```
///
/// [ViLegacyIcon] is a view over the bitmap; [LegacyIconDepth] names the three layouts;
/// [decodeIcl8], [decodeIcl4] and [decodeIcon1] require the exact bitmap size;
/// [legacyIconFromSections] picks the deepest icon a VI carries.
library;

import 'dart:typed_data';

import '../block_layout.dart';
import '../block_record.dart';
import '../viparse.dart' show ViSection;

const _pixels8 = BlockField(0, 1024, 'pixels', 'u8[1024]', 'palette index per pixel, 32 rows of 32');
const _pixels4 = BlockField(0, 512, 'pixels', 'u4[1024]', 'palette index per pixel, high nibble first');
const _pixels1 = BlockField(0, 128, 'pixels', 'u1[1024]', '1 = black, 0 = white, most significant bit first');

const BlockLayout icl8Layout = [_pixels8];

const BlockLayout icl4Layout = [_pixels4];

const BlockLayout iconLayout = [_pixels1];

/// The three bitmap layouts, by bits per pixel.
enum LegacyIconDepth {
  /// `ICON`: 1 bit per pixel, 128 bytes.
  mono(1, 'ICON'),

  /// `icl4`: 4 bits per pixel, 512 bytes.
  fourBit(4, 'icl4'),

  /// `icl8`: 8 bits per pixel, 1024 bytes.
  eightBit(8, 'icl8')
  ;

  const LegacyIconDepth(this.bits, this.tag);

  final int bits;

  /// The section tag that stores this layout.
  final String tag;

  int get byteLength => ViLegacyIcon.width * ViLegacyIcon.height * bits ~/ 8;

  static LegacyIconDepth? forTag(String tag) {
    for (final depth in values) {
      if (depth.tag == tag) return depth;
    }
    return null;
  }
}

/// A view over an `icl8`, `icl4` or `ICON` bitmap.
class ViLegacyIcon implements BlockRecord {
  const ViLegacyIcon._(this.bytes, this.depth);

  static const int width = 32;

  static const int height = 32;

  final Uint8List bytes;

  final LegacyIconDepth depth;

  /// The palette index of the pixel at column [x], row [y].
  int pixelAt(int x, int y) {
    final pixel = y * width + x;
    return switch (depth) {
      LegacyIconDepth.eightBit => bytes[pixel],
      LegacyIconDepth.fourBit => (pixel & 1) == 0 ? bytes[pixel >> 1] >> 4 : bytes[pixel >> 1] & 0x0f,
      LegacyIconDepth.mono => (bytes[pixel >> 3] >> (7 - (pixel & 7))) & 1,
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

  @override
  Uint8List serialize() => bytes;
}

ViLegacyIcon decodeLegacyIcon(Uint8List bytes, LegacyIconDepth depth) {
  assert(bytes.length == depth.byteLength, 'a ${depth.tag} bitmap is ${depth.byteLength} bytes');
  return ViLegacyIcon._(bytes, depth);
}

ViLegacyIcon decodeIcl8(Uint8List bytes) => decodeLegacyIcon(bytes, LegacyIconDepth.eightBit);

ViLegacyIcon decodeIcl4(Uint8List bytes) => decodeLegacyIcon(bytes, LegacyIconDepth.fourBit);

ViLegacyIcon decodeIcon1(Uint8List bytes) => decodeLegacyIcon(bytes, LegacyIconDepth.mono);

/// The deepest icon among [sections]: `icl8`, else `icl4`, else `ICON`; null without any.
ViLegacyIcon? legacyIconFromSections(Iterable<ViSection> sections) {
  ViLegacyIcon? best;
  for (final section in sections) {
    final depth = LegacyIconDepth.forTag(section.tag);
    if (depth == null || section.bytes.length != depth.byteLength) continue;
    if (best == null || depth.bits > best.depth.bits) best = ViLegacyIcon._(section.bytes, depth);
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
