import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'wire_style_oracle.dart';

/// Unit pins for the wire render-style decode (`wire_render.dart`) and the
/// SYNTHETIC-input leg of the oracle machinery (`wire_style_oracle.dart`).
/// The corpus census (`wire_render_style_census_test.dart`, snapshot
/// `wire_render_styles`) re-derives its laws from the same oracle that
/// built the mapping; the synthetic pins here are the independent check
/// that the classifier and the registration scorer do what the census
/// assumes.
void main() {
  group('renderStyle (measured tier)', () {
    test('census-sampled cells map to their measured styles', () {
      const cases = <int, ViWireRenderStyle?>{
        0x105: ViWireRenderStyle.solid1px, // u8 scalar
        0x4105: ViWireRenderStyle.solid1px, // flag nibble does not restyle
        0x10a: ViWireRenderStyle.solid1px, // dbl scalar (n=1)
        0x205: ViWireRenderStyle.solid2px, // u8 1-D array
        0x303: ViWireRenderStyle.hollowDouble, // i32 2-D array (n=1)
        0x121: ViWireRenderStyle.dotted, // boolean scalar
        0x221: ViWireRenderStyle.dottedAlternating, // boolean 1-D array (n=1)
        0x230: ViWireRenderStyle.zigzag, // string scalar
        0x232: ViWireRenderStyle.zigzag, // path scalar
        0x237: ViWireRenderStyle.zigzag, // tag scalar
        0x330: ViWireRenderStyle.chainLink, // 1-D string array
        0x332: ViWireRenderStyle.chainLink, // 1-D path array
        0x430: ViWireRenderStyle.chainLinkWide, // 2-D string array
        0x350: ViWireRenderStyle.braid, // scalar cluster
        0x450: ViWireRenderStyle.braidWide, // 1-D cluster array
        0x353: ViWireRenderStyle.braidDense, // variant
        0x451: ViWireRenderStyle.braidDenseWide, // typedef-cluster 1-D array
        0x374: ViWireRenderStyle.weave, // kWeaveWireCode carrier
        0x170: ViWireRenderStyle.solid1px, // plain refnum
        0x270: ViWireRenderStyle.solid2px,
      };
      cases.forEach((word, style) {
        expect(ViSignalType(word).renderStyle, style, reason: '0x${word.toRadixString(16)}');
      });
    });

    test('unmeasured / contradictory / heterogeneous cells are null — never a guess', () {
      for (final word in const [
        0x102, // i16 scalar: sole census run contradicts the family rule
        0x109, // sgl scalar: never sampled
        0x304, // i64 depth 3: never sampled
        0x370, // deep refnum: stroke follows the embedded inner type
        0x571, // deep typed refnum
        0x171, // 0x71 depth 1: the census carries 0x71 only at depth 5
        0x271,
        0x337, // tag depth 3: never sampled
        0x432, // path depth 4: never sampled
        0x421, // boolean depth 4: never sampled
        0x233, // picture: sampled blank
        0x351, // 0x51 depth 3: colour-only in the census
      ]) {
        expect(ViSignalType(word).renderStyle, isNull, reason: '0x${word.toRadixString(16)}');
      }
    });
  });

  group('renderStyleEstimate (extrapolation tier)', () {
    test('family rules cover the unmeasured cells, labelled as estimates', () {
      const cases = <int, ViWireRenderStyle?>{
        0x102: ViWireRenderStyle.solid1px, // family rule; the measured tier keeps this null
        0x109: ViWireRenderStyle.solid1px, // sgl scalar by family
        0x209: ViWireRenderStyle.solid2px,
        0x309: ViWireRenderStyle.hollowDouble, // extrapolated from the n=1 0x03 cell
        0x337: ViWireRenderStyle.chainLink, // tag rides the string family
        0x432: ViWireRenderStyle.chainLinkWide,
        0x171: ViWireRenderStyle.solid1px, // 0x71 rides the refnum family
        0x271: ViWireRenderStyle.solid2px,
        0x370: null, // deep refnums stay null even as estimates
        0x571: null,
        0x421: null, // no family rule invented for unmeasured boolean depths
        0x351: null, // no analogy invented for 0x51 depth 3
      };
      cases.forEach((word, style) {
        expect(ViSignalType(word).renderStyleEstimate, style, reason: '0x${word.toRadixString(16)}');
      });
    });

    test('measured cells pass through unchanged', () {
      for (final word in const [0x105, 0x230, 0x121, 0x350, 0x374]) {
        expect(
          ViSignalType(word).renderStyleEstimate,
          ViSignalType(word).renderStyle,
          reason: '0x${word.toRadixString(16)}',
        );
      }
    });
  });

  group('dimDisabledFrameRgb', () {
    test('the four measured pairs, channel clamp included', () {
      expect(dimDisabledFrameRgb(0x0000ff), 0x9999ff, reason: 'wire blue');
      expect(dimDisabledFrameRgb(0x006600), 0x99cc99, reason: 'boolean-wire green (rejects 0.4c+153)');
      expect(dimDisabledFrameRgb(0x000000), 0x999999, reason: 'loop-border black');
      expect(dimDisabledFrameRgb(0xffffcc), 0xffffff, reason: 'label yellow, clamped');
      expect(dimDisabledFrameRgb(0xffffff), 0xffffff, reason: 'white is a fixed point');
    });

    test('odd channels truncate (current behaviour; no odd-channel pair measured yet)', () {
      // Every measured source channel is even, so truncation vs half-up
      // rounding is indistinguishable on the evidence; this pins the
      // implementation's truncation until an odd-channel pair exists (see
      // the TODO on dimDisabledFrameRgb).
      expect(dimDisabledFrameRgb(0x030303), 0x9a9a9a, reason: '153 + 3 ~/ 2 = 154');
      expect(dimDisabledFrameRgb(0x0000cd), 0x9999ff, reason: '153 + 205 ~/ 2 = 255 exactly');
    });
  });

  group('classifyCycle (synthetic pixels)', () {
    // A masks map spanning [0, n) columns cycling through [cycle].
    Map<int, int> cycled(List<int> cycle, {int n = 40, bool Function(int)? keep}) => {
      for (var x = 0; x < n; x++)
        if (keep == null || keep(x)) x: cycle[x % cycle.length],
    };

    test('every catalogued cycle classifies to its style', () {
      final cases = <String, List<int>>{
        'solid1px': [0x04],
        'solid2px': [0x0c],
        'hollowDouble': [0x0a],
        'dotted': [0x04, 0x00],
        'dottedAlternating': [0x02, 0x04],
        'zigzag': [0x04, 0x06, 0x02, 0x06],
        'chainLink': [0x04, 0x0e, 0x0a, 0x0e],
        'chainLinkWide': [0x05, 0x0f, 0x0a, 0x0f],
        'braid': [0x0a, 0x0a, 0x0e, 0x0e],
        'braidWide': [0x09, 0x0d, 0x0f, 0x0b],
        'braidDense': [0x0a, 0x0e],
        'braidDenseWide': [0x0b, 0x0d],
        'weave': [0x02, 0x0a, 0x02, 0x0e, 0x08, 0x0a, 0x08, 0x0e],
      };
      cases.forEach((style, cycle) {
        expect(classifyCycle(cycled(cycle)), style, reason: style);
      });
    });

    test('phase-correlated drops alias a chain-link onto the dense braid — the coverage gate catches it', () {
      // Drop every column of the chain-link's single-dot phase (as a
      // crossing recurring on the cycle pitch would): the survivors read as
      // the period-2 dense braid.
      final masks = cycled(const [0x04, 0x0e, 0x0a, 0x0e], keep: (x) => x % 4 != 0);
      expect(classifyCycle(masks, coverage: 0.75), 'lowcover:braidDense', reason: 'below the 0.8 coverage gate');
      // The full-coverage run classifies as itself.
      expect(classifyCycle(cycled(const [0x04, 0x0e, 0x0a, 0x0e])), 'chainLink');
      // Period-1 cycles are drop-immune and classify at any coverage.
      expect(classifyCycle(cycled(const [0x04], keep: (x) => x % 4 != 0), coverage: 0.75), 'solid1px');
    });

    test('unrecognized periodic cycles and non-periodic input stay honest', () {
      expect(classifyCycle(cycled(const [0x11, 0x04])), startsWith('unclassified:'));
      var x = 0;
      final noise = {
        for (final m in const [1, 5, 9, 2, 14, 7, 3, 11, 6, 13, 4, 8, 10, 15, 12, 1, 7, 2]) x++: m,
      };
      expect(classifyCycle(noise), 'aperiodic');
    });
  });

  group('registerDiagram (synthetic frame)', () {
    test('recovers the exact offset of a drawn structure border', () {
      // One 0x20 loop at diagram [20,10]..[120,70]; its border drawn as
      // black perimeter pixels on a white 200x150 raster shifted by
      // (dx=5, dy=7): raster x = diagX - 5, y = diagY - 7.
      const w = 200, h = 150, dx = 5, dy = 7;
      final rgba = Uint8List(w * h * 4)..fillRange(0, w * h * 4, 255);
      void ink(int diagX, int diagY) {
        final o = ((diagY - dy) * w + (diagX - dx)) * 4;
        rgba[o] = rgba[o + 1] = rgba[o + 2] = 0;
      }

      const rect = HeapRect(top: 10, left: 20, bottom: 70, right: 120);
      for (var x = rect.left; x < rect.right; x++) {
        ink(x, rect.top);
        ink(x, rect.bottom - 1);
      }
      for (var y = rect.top; y < rect.bottom; y++) {
        ink(rect.left, y);
        ink(rect.right - 1, y);
      }
      final loop = ViHeapObject(oid: 1, kind: 0x20, offset: 0)..absBounds = rect;
      final bd = ViDiagram(sectionTag: 'BDHb', objects: [loop]);
      final reg = registerDiagram(bd, (width: w, height: h, rgba: rgba), (left: 0, top: 0, right: w, bottom: h));
      expect((reg.dx, reg.dy), (dx, dy));
      expect(reg.leafMode, isFalse);
      expect(reg.score / reg.max, greaterThan(0.95), reason: 'the border verifies at the true offset');
    });
  });
}
