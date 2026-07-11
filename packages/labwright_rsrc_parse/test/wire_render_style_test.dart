import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

/// Unit pins for the wire render-style decode (`wire_render.dart`). The
/// corpus measurements behind every pin live in
/// `wire_render_style_census_test.dart` (snapshot `wire_render_styles`).
void main() {
  test('renderStyle: measured (code, depth) cells map to their styles', () {
    const cases = <int, ViWireRenderStyle?>{
      0x105: ViWireRenderStyle.solid1px, // u8 scalar
      0x4105: ViWireRenderStyle.solid1px, // flag nibble does not restyle
      0x10a: ViWireRenderStyle.solid1px, // dbl scalar
      0x205: ViWireRenderStyle.solid2px, // u8 1-D array
      0x303: ViWireRenderStyle.hollowDouble, // i32 2-D array
      0x121: ViWireRenderStyle.dotted, // boolean scalar
      0x221: ViWireRenderStyle.dottedAlternating, // boolean 1-D array
      0x230: ViWireRenderStyle.zigzag, // string scalar
      0x232: ViWireRenderStyle.zigzag, // path scalar
      0x237: ViWireRenderStyle.zigzag, // tag scalar
      0x330: ViWireRenderStyle.chainLink, // 1-D string array
      0x430: ViWireRenderStyle.chainLinkWide, // 2-D string array
      0x350: ViWireRenderStyle.braid, // scalar cluster
      0x450: ViWireRenderStyle.braidWide, // 1-D cluster array
      0x353: ViWireRenderStyle.braidDense, // variant
      0x451: ViWireRenderStyle.braidDenseWide, // typedef-cluster 1-D array
      0x374: ViWireRenderStyle.weave, // uncatalogued 0x74 carrier
      0x170: ViWireRenderStyle.solid1px, // plain refnum
      0x270: ViWireRenderStyle.solid2px,
      0x370: null, // deep refnum: stroke follows the embedded inner type
      0x571: null,
      0x421: null, // unmeasured boolean depth
      0x233: null, // picture: sampled blank, not catalogued
    };
    cases.forEach((word, style) {
      expect(ViSignalType(word).renderStyle, style, reason: '0x${word.toRadixString(16)}');
    });
  });

  test('dimDisabledFrameRgb: the four measured pairs, channel clamp included', () {
    expect(dimDisabledFrameRgb(0x0000ff), 0x9999ff, reason: 'wire blue');
    expect(dimDisabledFrameRgb(0x006600), 0x99cc99, reason: 'boolean-wire green (rejects 0.4c+153)');
    expect(dimDisabledFrameRgb(0x000000), 0x999999, reason: 'loop-border black');
    expect(dimDisabledFrameRgb(0xffffcc), 0xffffff, reason: 'label yellow, clamped');
    expect(dimDisabledFrameRgb(0xffffff), 0xffffff, reason: 'white is a fixed point');
  });
}
