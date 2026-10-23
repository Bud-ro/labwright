/// Colors that LabVIEW renders have drawn differently across versions and platforms while
/// meaning the same thing. The inspector paints each alias's [canonical] color; the
/// comparison tooling treats every member of an alias as that one color, so a render and a
/// reference agree on a pixel exactly or not at all, never within a tolerance.
enum BdColorAlias {
  /// Floating-point wires and terminals: 0xFF6600 in current renders, 0xFF7F00 from 2013 to
  /// 2015.
  floatOrange(0xFF6600, {0xFF7F00}),

  /// Boolean wires and terminals: 0x006600, or 0x007F00 in the same older renders.
  booleanGreen(0x006600, {0x007F00}),

  /// Error cluster wires and the olive of error terminals: 0x666600 or 0x7F7F00.
  errorOlive(0x666600, {0x7F7F00}),

  /// Variant wires and terminals: 0x660066 or 0x7F007F.
  variantPurple(0x660066, {0x7F007F}),

  /// Refnum wires and terminals: 0x006666 or 0x007F7F.
  refnumTeal(0x006666, {0x007F7F}),

  /// The while loop's band grey: 0x777777 or 0x7F7F7F.
  whileBandGrey(0x777777, {0x7F7F7F}),

  /// The error case's field green: 0x99FF99 or 0xB2FFB2.
  errorCaseGreen(0x99FF99, {0xB2FFB2}),

  /// The sequence structure's band and the diagram's alignment grid: 0xDDDDDD or 0xE2E2E2.
  sequenceGrey(0xDDDDDD, {0xE2E2E2}),

  /// A free label's yellow backing: 0xFFFFCC or 0xFFFFD7.
  labelBacking(0xFFFFCC, {0xFFFFD7}),

  /// The ink of a node's frame and icon: black through 2015, 0x4C4C3D from 2016 to 2020 and
  /// from 2024 on, 0x444444 in the 2021 renders of one source and 0x474747 in other 2021
  /// renders.
  nodeInk(0x000000, {0x444444, 0x474747, 0x4C4C3D});

  const BdColorAlias(this.canonical, this.variants);

  /// The color the inspector paints, as 0xRRGGBB.
  final int canonical;

  /// The other colors references draw it with, as 0xRRGGBB.
  final Set<int> variants;

  static final Map<int, int> _canonicalByVariant = {
    for (final alias in values)
      for (final variant in alias.variants) variant: alias.canonical,
  };

  /// [rgb] (0xRRGGBB) with any alias variant replaced by its canonical color.
  static int canonicalRgb(int rgb) => _canonicalByVariant[rgb] ?? rgb;

  /// Whether two 0xRRGGBB colors are the same color once aliased.
  static bool sameColor(int a, int b) =>
      a == b || canonicalRgb(a) == canonicalRgb(b);
}

/// The canonical colors of wire ink in the snippet references, as 0xRRGGBB; a reference
/// pixel is wire ink when its [BdColorAlias.canonicalRgb] is one of these.
const Set<int> kWireInkPalette = {
  0xFF00FF,
  0x006666,
  0x0000FF,
  0x006600,
  0x666600,
  0xFFFF00,
  0xFF6600,
  0x660066,
};

/// Whether a reference pixel of color [rgb] (0xRRGGBB) is wire ink.
bool isWireInk(int rgb) =>
    kWireInkPalette.contains(BdColorAlias.canonicalRgb(rgb));
