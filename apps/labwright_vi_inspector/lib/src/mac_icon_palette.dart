/// Standard classic-Macintosh icon color lookup tables (CLUTs) for the
/// `ICON` (1-bit), `icl4` (4-bit) and `icl8` (8-bit) resource formats.
///
/// `ICON`/`icl4`/`icl8` are the classic Macintosh icon resource formats. Their
/// stored pixel bytes are INDICES into a fixed system palette, not a monochrome
/// mask — a color icon uses many indices, so drawing "any nonzero index as one
/// foreground color" would turn the picture into noise. These tables are the
/// documented standard Macintosh palettes the indices are defined against:
///
///  * **1-bit (`ICON`):** index 1 = black, 0 = white (the classic 1-bit icon
///    convention).
///  * **4-bit (`icl4`):** the standard Macintosh 16-color system palette
///    (white, yellow, orange, red, magenta, purple, blue, cyan, green,
///    dark-green, brown, tan, and light/medium/dark gray, ending in black),
///    with values from the classic Mac OS System-file color lookup table.
///  * **8-bit (`icl8`):** the standard Macintosh 256-color system palette — a
///    6×6×6 RGB cube (per-channel steps 255,204,153,102,51,0) at indices
///    0..214, then four 10-shade ramps (red, green, blue, then gray) over the
///    multiples of 17 that are not multiples of 51
///    (238,221,187,170,136,119,85,68,34,17) at indices 215..254, with black at
///    index 255. (Index 0 is white; index 255 is black.)
///
/// These are the format's standard palettes. We do not run LabVIEW, so this is
/// not claimed to be byte-for-byte identical to LabVIEW's on-screen renderer;
/// it is the documented Macintosh icon CLUT that the stored indices reference.
library;

/// Opaque ARGB (`0xFFRRGGBB`) for a legacy-icon pixel [index] at [bpp]
/// bits/pixel. `bpp` is 1 (`ICON`), 4 (`icl4`) or 8 (`icl8`); the index is
/// masked to the depth's range so an out-of-range value cannot throw.
int macIconArgb(int bpp, int index) => switch (bpp) {
  1 => (index & 1) != 0 ? 0xFF000000 : 0xFFFFFFFF,
  4 => _mac4Bit[index & 0x0f],
  8 => _mac8Bit[index & 0xff],
  _ => 0xFF000000,
};

/// The standard Macintosh 16-color (4-bit) system palette, index 0..15
/// (white → black). Values from the classic Mac OS System-file CLUT.
const List<int> _mac4Bit = <int>[
  0xFFFFFFFF, // 0  white
  0xFFFCF305, // 1  yellow
  0xFFFF6402, // 2  orange
  0xFFDD0806, // 3  red
  0xFFF20884, // 4  magenta
  0xFF4600A5, // 5  purple
  0xFF0000D4, // 6  blue
  0xFF02ABEA, // 7  cyan
  0xFF1FB714, // 8  green
  0xFF006411, // 9  dark green
  0xFF562C05, // 10 brown
  0xFF90713A, // 11 tan
  0xFFC0C0C0, // 12 light gray
  0xFF808080, // 13 medium gray
  0xFF404040, // 14 dark gray
  0xFF000000, // 15 black
];

/// The standard Macintosh 256-color (8-bit) system palette, built once at load.
final List<int> _mac8Bit = _buildMac8Bit();

/// Builds the standard Macintosh 256-color CLUT: the 6×6×6 color cube at
/// indices 0..214, the red/green/blue/gray ramps at 215..254, and black at 255.
List<int> _buildMac8Bit() {
  final table = List<int>.filled(256, 0xFF000000);
  // 6×6×6 cube: each channel steps 255,204,153,102,51,0 (index 0 = white).
  // Blue is the fast axis, then green, then red. The 216th cube color is black,
  // which the format places at index 255 instead of at the cube's tail — so the
  // cube fills indices 0..214.
  const step = <int>[255, 204, 153, 102, 51, 0];
  for (var x = 0; x < 215; x++) {
    final r = step[x ~/ 36];
    final g = step[(x ~/ 6) % 6];
    final b = step[x % 6];
    table[x] = 0xFF000000 | (r << 16) | (g << 8) | b;
  }
  // Four 10-shade ramps over the multiples of 17 that are not multiples of 51.
  const ramp = <int>[238, 221, 187, 170, 136, 119, 85, 68, 34, 17];
  for (var i = 0; i < ramp.length; i++) {
    final v = ramp[i];
    table[215 + i] = 0xFF000000 | (v << 16); // red ramp   215..224
    table[225 + i] = 0xFF000000 | (v << 8); //  green ramp 225..234
    table[235 + i] = 0xFF000000 | v; //          blue ramp  235..244
    table[245 + i] = 0xFF000000 | (v << 16) | (v << 8) | v; // gray 245..254
  }
  table[255] = 0xFF000000; // black
  return table;
}
