library;

int macIconArgb(int bpp, int index) => switch (bpp) {
  1 => (index & 1) != 0 ? 0xFF000000 : 0xFFFFFFFF,
  4 => _mac4Bit[index & 0x0f],
  8 => _mac8Bit[index & 0xff],
  _ => 0xFF000000,
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
