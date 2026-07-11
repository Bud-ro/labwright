/// Block-diagram **wire render styles** — how LabVIEW strokes a signal on
/// screen — measured pixel-for-pixel from the paired snippet render oracle
/// (the `niVI` snippet PNGs whose visible raster is LabVIEW's own render of
/// the embedded VI; see `png_snippet.dart`). Every claim below is a
/// measurement over the snippet corpora
/// (`rcpacini_VI-Snippets` + `rcpacini_LabVIEW-VI-Snippet`), pinned by the
/// `wire_render_styles` snapshot section (owned by
/// `wire_render_style_census_test.dart`, which registers each decoded
/// diagram onto its reference raster and classifies the pixel pattern of
/// every straight wire run).
///
/// **The style is a pure function of the signal's wire-type word**
/// ([ViSignalType]: element type code + structural depth). The other
/// per-signal fields were each measured against the rendered style and
/// carry none of it:
///
/// * `signalState 0x115` — styles vary freely within one state value and
///   one style spans multiple values;
/// * the wire-type word's **flag nibble** (bits 12-15, `0x0/0x4/0x8/0xc`) —
///   identical styles across flag values for the same code+depth;
/// * the `0x1e7` wire-table header byte (scalar `0x08` vs container forms)
///   — orthogonal (it encodes the route, not the look);
/// * the signal's objFlags — absent from nearly every sampled signal.
///
/// **Crossing rule** (20 attributed crossing gaps corpus-wide, pinned):
/// where two wires cross, the **later-serialized signal breaks** — it is
/// drawn with a 1-px background gap on each side of the surviving wire —
/// and the earlier-serialized signal runs continuous. Zero later-survivor
/// counterexamples; orientation is NOT the rule (12 broken horizontals vs
/// 8 broken verticals). The break is cut for same-colour crossings too
/// (the scan detects the gap-core-gap signature independent of colour
/// contrast). This is pure render behaviour with no dedicated file data —
/// the serialization order of the `0x17` signal objects is the draw order.
///
/// **Disabled-frame palette**: inside a diagram-disable structure's
/// displayed `Disabled` frame, every sampled colour maps per channel as
/// `c' = min(255, 153 + c ~/ 2)` — see [dimDisabledFrameRgb].
library;

import 'dart:math' show min;

import 'blocks/type_pool.dart';
import 'graph.dart' show ViSignalType;

/// A measured wire stroke pattern. Each entry documents its **column
/// cycle** — the repeating per-column ink mask over the five rows centred
/// on the wire's route row, written low-row-first as 5-bit groups (bit 2 =
/// the route row; horizontal runs shown, vertical runs are the transpose) —
/// plus the carrier type codes and sample counts from the pinned census.
enum ViWireRenderStyle {
  /// One solid 1-px line on the route row (cycle `00100`). Carriers:
  /// scalar numerics (codes `0x02..0x08` ints, `0x0a` float) and plain
  /// refnums (`0x70` depth 1). The dominant style (110 sampled runs).
  solid1px,

  /// A solid 2-px line straddling the route row (cycle `00110`/`01100`,
  /// constant along the run). Carriers: depth-2 numeric wires (1-D arrays,
  /// codes `0x02..0x08`) and depth-2 refnums (42 runs, plus one
  /// single-run `0x02` depth-1 outlier pinned in the snapshot).
  solid2px,

  /// Two 1-px lines with an empty centre row (cycle `01010`, constant) —
  /// the 2-D-array double line. Direct carrier: `0x03` depth 3 (single
  /// sampled run; the colour census corroborates more depth-3 numerics).
  hollowDouble,

  /// 1-px on / 1-px off dots on the route row (period 2: `00100`, `00000`).
  /// Carrier: scalar booleans (`0x21` depth 1; 37 runs, greens
  /// `0x006600`/`0x007f00` — the darker green is the newer-version
  /// palette, per the version-keyed colour keys of the census).
  dotted,

  /// Alternating single dots on two adjacent rows, never connected
  /// (period 2: one pixel on the low row, then one on the high row).
  /// Carrier: 1-D boolean arrays (`0x21` depth 2; one sampled run plus the
  /// same-layout render in each crc snippet sibling).
  dottedAlternating,

  /// A connected two-row zigzag (period 4: `00100`, `00110`, `00010`,
  /// `00110` — one column on the top row, one on the bottom, joined by
  /// two-pixel columns). Carriers: the depth-2 string-family scalars —
  /// string `0x30` (57 runs, pink `0xff00ff`), path `0x32` (5 runs, teals),
  /// tag `0x37` (5 runs, `0x660066`).
  zigzag,

  /// The 3-row chain-link pattern (period 4: `00100`, `01110`, `01010`,
  /// `01110`). Carriers: depth-3 string-family wires (1-D arrays of
  /// string/path; 13 runs).
  chainLink,

  /// The 4-row chain-link (period 4: `00101`, `01111`, `01010`, `01111`).
  /// Carrier: depth-4 string wires (2-D string arrays; 7 runs).
  chainLinkWide,

  /// The 3-row braid (period 4: `01010`, `01010`, `01110`, `01110`).
  /// Carriers: scalar clusters (`0x50` depth 3, 9 runs — error clusters
  /// `0x666600`, string-bearing clusters `0xff00ff`) and depth-3 refnums
  /// embedding an inner type (5 runs).
  braid,

  /// The 4-row braid (period 4: `01001`, `01101`, `01111`, `01011`).
  /// Carrier: 1-D cluster arrays (`0x50` depth 4; 10 runs).
  braidWide,

  /// The dense 3-row braid (period 2: `01010`, `01110`). Carrier: variant
  /// wires (`0x53` depth 3; 8 runs, dark purple `0x660066`).
  braidDense,

  /// The dense 4-row braid (period 2: `01011`, `01101`). Carrier:
  /// depth-4 wires of the typedef/class cluster code (`0x51`; 4 runs,
  /// brown `0x993300`).
  braidDenseWide,

  /// The period-8 weave (`00010`, `00110`, `00100`, `00110`, `00010`,
  /// `00110`, `00100`, `00110` at 3 rows, canonical rotation
  /// `00010,01010,00010,01110,01000,01010,01000,01110`). Carrier: the
  /// uncatalogued wire-word code `0x74` at depth 3 (5 runs, `0x993300`) —
  /// the code resolves no VCTP type ([ViSignalType.dataType] is null), so
  /// only the look is catalogued here.
  weave,
}

/// The wire-type-word codes that stroke as the plain solid family
/// (numeric ints + floats; complex included by code range, though only
/// `0x02..0x08` and `0x0a` appear in the sampled runs — the census keys
/// record exactly which).
bool _isNumericCode(int code) => code >= TypeCode.i8 && code <= TypeCode.complexExt;

/// The measured render style of a signal's wire-type word, or null when the
/// (code, depth) cell was never sampled against the render oracle — callers
/// treat null as "not yet measured", never as "solid".
///
/// The census behind each cell lives on [ViWireRenderStyle]'s entries and
/// the `wire_render_styles` snapshot section. Cells deliberately left null:
///
/// * refnums (`0x70`/`0x71`) at depth ≥ 3 — measured BOTH [ViWireRenderStyle.braid]
///   and a 3-px solid there: the stroke follows the refnum's embedded inner
///   type, which the word alone does not carry;
/// * booleans at depth ≥ 3, the `0x20` boolean code (never observed in a
///   wire word), picture `0x33` (one depth-2 run sampled blank), and every
///   other unobserved combination.
extension ViSignalTypeRenderStyle on ViSignalType {
  /// See [ViSignalTypeRenderStyle].
  ViWireRenderStyle? get renderStyle {
    final code = typeCode;
    final d = depth;
    if (_isNumericCode(code)) {
      return switch (d) {
        1 => ViWireRenderStyle.solid1px,
        2 => ViWireRenderStyle.solid2px,
        3 => ViWireRenderStyle.hollowDouble,
        _ => null,
      };
    }
    if (code == TypeCode.boolean) {
      return switch (d) {
        1 => ViWireRenderStyle.dotted,
        2 => ViWireRenderStyle.dottedAlternating,
        _ => null,
      };
    }
    if (code == TypeCode.string || code == TypeCode.path || code == TypeCode.tag) {
      return switch (d) {
        2 => ViWireRenderStyle.zigzag,
        3 => ViWireRenderStyle.chainLink,
        4 => ViWireRenderStyle.chainLinkWide,
        _ => null,
      };
    }
    if (code == TypeCode.cluster) {
      return switch (d) {
        3 => ViWireRenderStyle.braid,
        4 => ViWireRenderStyle.braidWide,
        _ => null,
      };
    }
    if (code == ViSignalType.clusterVariantCode) {
      return d == 4 ? ViWireRenderStyle.braidDenseWide : null;
    }
    if (code == TypeCode.variant) {
      return d == 3 ? ViWireRenderStyle.braidDense : null;
    }
    if (code == TypeCode.refnum || code == ViSignalType.typedRefnumCode) {
      return switch (d) {
        1 => ViWireRenderStyle.solid1px,
        2 => ViWireRenderStyle.solid2px,
        _ => null, // depth ≥ 3 follows the embedded inner type (see doc).
      };
    }
    if (code == 0x74) {
      return d == 3 ? ViWireRenderStyle.weave : null;
    }
    return null;
  }
}

/// The colour LabVIEW renders [rgb] as inside a diagram-disable structure's
/// displayed **Disabled** frame: per channel `c' = min(255, 153 + c ~/ 2)`.
///
/// Measured pairs (snippet reference pixels at decoded wire runs / chrome,
/// pinned by the census test):
///
/// * wire blue `(0,0,255)` → `(153,153,255)`
/// * boolean-wire green `(0,102,0)` → `(153,204,153)` — the discriminating
///   sample: a plain `0.4·c + 153` linear blend predicts 194 for the green
///   channel and is refuted (measured 204 = `153 + 102 ~/ 2`);
/// * loop-border black `(0,0,0)` → `(153,153,153)`;
/// * label-backing yellow `(255,255,204)` → `(255,255,255)` — the blue and
///   yellow channels clamp (`153 + 127 = 280 → 255`, `153 + 102 = 255`).
///
/// Every measured source channel is even, so halving-rounding for odd
/// channels is not pinned (`~/ 2` chosen; TODO: pin on an odd-channel pair
/// when the corpus offers one).
int dimDisabledFrameRgb(int rgb) {
  int dim(int c) => min(255, 153 + (c >> 1));
  return (dim((rgb >> 16) & 0xff) << 16) | (dim((rgb >> 8) & 0xff) << 8) | dim(rgb & 0xff);
}
