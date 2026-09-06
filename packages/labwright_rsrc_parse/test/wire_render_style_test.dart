import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'wire_style_oracle.dart';

void main() {
  group('renderStyle (measured tier)', () {
    test('census-sampled cells map to their measured styles', () {
      const cases = <int, ViWireRenderStyle?>{
        0x105: ViWireRenderStyle.solid1px,
        0x4105: ViWireRenderStyle.solid1px,
        0x10a: ViWireRenderStyle.solid1px,
        0x205: ViWireRenderStyle.solid2px,
        0x303: ViWireRenderStyle.hollowDouble,
        0x121: ViWireRenderStyle.dotted,
        0x221: ViWireRenderStyle.dottedAlternating,
        0x230: ViWireRenderStyle.zigzag,
        0x232: ViWireRenderStyle.zigzag,
        0x237: ViWireRenderStyle.zigzag,
        0x330: ViWireRenderStyle.chainLink,
        0x332: ViWireRenderStyle.chainLink,
        0x430: ViWireRenderStyle.chainLinkWide,
        0x350: ViWireRenderStyle.braid,
        0x450: ViWireRenderStyle.braidWide,
        0x353: ViWireRenderStyle.braidDense,
        0x451: ViWireRenderStyle.braidDenseWide,
        0x374: ViWireRenderStyle.weave,
        0x170: ViWireRenderStyle.solid1px,
        0x270: ViWireRenderStyle.solid2px,
      };
      cases.forEach((word, style) {
        expect(ViSignalType(word).renderStyle, style, reason: '0x${word.toRadixString(16)}');
      });
    });

    test('unmeasured / contradictory / heterogeneous cells are null — never a guess', () {
      for (final word in const [
        0x102,
        0x109,
        0x304,
        0x370,
        0x571,
        0x171,
        0x271,
        0x337,
        0x432,
        0x421,
        0x233,
        0x351,
      ]) {
        expect(ViSignalType(word).renderStyle, isNull, reason: '0x${word.toRadixString(16)}');
      }
    });
  });

  group('renderStyleEstimate (extrapolation tier)', () {
    test('family rules cover the unmeasured cells, labelled as estimates', () {
      const cases = <int, ViWireRenderStyle?>{
        0x102: ViWireRenderStyle.solid1px,
        0x109: ViWireRenderStyle.solid1px,
        0x209: ViWireRenderStyle.solid2px,
        0x309: ViWireRenderStyle.hollowDouble,
        0x337: ViWireRenderStyle.chainLink,
        0x432: ViWireRenderStyle.chainLinkWide,
        0x171: ViWireRenderStyle.solid1px,
        0x271: ViWireRenderStyle.solid2px,
        0x370: null,
        0x571: null,
        0x421: null,
        0x351: null,
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
      expect(dimDisabledFrameRgb(0x030303), 0x9a9a9a, reason: '153 + 3 ~/ 2 = 154');
      expect(dimDisabledFrameRgb(0x0000cd), 0x9999ff, reason: '153 + 205 ~/ 2 = 255 exactly');
    });
  });

  group('classifyCycle (synthetic pixels)', () {
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
      final masks = cycled(const [0x04, 0x0e, 0x0a, 0x0e], keep: (x) => x % 4 != 0);
      expect(classifyCycle(masks, coverage: 0.75), 'lowcover:braidDense', reason: 'below the 0.8 coverage gate');
      expect(classifyCycle(cycled(const [0x04, 0x0e, 0x0a, 0x0e])), 'chainLink');
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
