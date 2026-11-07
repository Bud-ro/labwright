/// Bits of a heap object's `objFlags` word, each named for the class it is read on.
enum ViObjFlag {
  /// Bit 0 on a front-panel control: the control is an indicator.
  indicator(0x1),

  /// `0x08` on a label: the label is hidden.
  labelHidden(0x08),

  /// `0x800` on a label inside a placed-control container: painted without its background fill.
  labelNoBacking(0x800),

  /// `0x800000` on a terminal: its glyph is not drawn.
  terminalGlyphHidden(0x800000),

  /// `0x300000` (both bits) on a tunnel: a centre dot marks the tunnel.
  tunnelCentreDot(0x300000),

  /// `0x1000000` on a tunnel: the tunnel is hollow.
  tunnelHollow(0x1000000),

  /// `0x1000000` on a case structure: selector strings match case-insensitively.
  caseInsensitiveSelector(0x1000000),

  /// On a Build Array input terminal: the input concatenates (an array input drawn with the
  /// array glyph) instead of adding a dimension.
  buildArrayConcatenate(0x10000),

  /// `0x4000000` on a Read from Text File primitive: it reads lines, and its icon shows them.
  readLines(0x4000000),

  /// `0x400000` on a Type Cast primitive: it converts LabVIEW 4.x data, and its icon carries
  /// a red "4.x".
  convertLegacyData(0x400000);

  const ViObjFlag(this.mask);

  final int mask;
}
