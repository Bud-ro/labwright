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
/// This library catalogues **measured render facts** — what LabVIEW draws
/// for decoded file data — not file-format byte decode; it lives in the
/// parse package beside the wire-type word it keys off ([ViSignalType])
/// because the facts are properties of that word's values, not of any
/// renderer.
///
/// **The style is a pure function of the signal's wire-type word**
/// ([ViSignalType]: element type code + structural depth). The other
/// per-signal fields were each cross-tabbed against the rendered style
/// (per-cell census keys + a no-restyle law each) and carry none of it:
///
/// * `signalState 0x115` — the majority style never changes across state
///   values within one code+depth cell (`state|…` keys, law-asserted);
/// * the wire-type word's **flag nibble** (bits 12-15, `0x0/0x4/0x8/0xc`) —
///   same style across flag values for the same code+depth (`flag|…` keys,
///   law-asserted);
/// * the `0x1e7` wire-table header byte (scalar `0x08` vs container forms)
///   — orthogonal, it encodes the route, not the look (`hdr|…` keys,
///   law-asserted);
/// * the signal's objFlags — absent on nearly every sampled signal and
///   never style-splitting where present (`objf|…` keys, law-asserted).
///
/// **Crossing rule** (attributed crossing gaps corpus-wide, pinned):
/// where two wires cross, the **later-serialized signal breaks** — it is
/// drawn with a 1-px background gap on each side of the surviving wire —
/// and the earlier-serialized signal runs continuous. Zero later-survivor
/// counterexamples; orientation is NOT the rule (broken horizontals and
/// broken verticals both occur, counts pinned). The break is cut for
/// same-colour crossings too (the scan detects the gap-core-gap signature
/// independent of colour contrast). This is pure render behaviour with no
/// dedicated file data — the serialization order of the `0x17` signal
/// objects is the draw order.
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
/// the route row) — plus the carrier type codes and sample counts from the
/// pinned census. Entries resting on a single sampled run say so
/// explicitly; they are measurements, not verified-at-volume catalogue
/// rows.
///
/// Cycles are catalogued from HORIZONTAL runs. Vertical runs of the
/// simple strokes (solid/hollow/dotted/braid families) measure as the
/// same cycles transposed, but the multi-row link strokes are NOT plain
/// transposes: the corpus's one sampled vertical 1-D-string-array run
/// draws the dense period-2 cycle where its horizontal siblings draw
/// [chainLink] (pinned under the census's `|V` style keys). Vertical
/// renditions of the other patterned strokes are not yet measured (TODO).
enum ViWireRenderStyle {
  /// One solid 1-px line on the route row (cycle `00100`). Carriers:
  /// scalar numerics (codes `0x03/0x05/0x06/0x07/0x08` at volume, `0x04`
  /// and float `0x0a` single runs) and plain refnums (`0x70` depth 1). The
  /// dominant style (110 sampled runs).
  solid1px,

  /// A solid 2-px line straddling the route row (cycle `00110`/`01100`,
  /// constant along the run). Carriers: depth-2 numeric wires (1-D arrays,
  /// codes `0x03/0x05/0x07/0x08`) and depth-2 refnums (42 runs). The
  /// census also holds one contradictory single run: code `0x02` at
  /// depth 1 measured solid2px — see [ViSignalTypeRenderStyle.renderStyle]
  /// for how that cell is treated.
  solid2px,

  /// Two 1-px lines with an empty centre row (cycle `01010`, constant) —
  /// the 2-D-array double line. Basis: n=1 — a single sampled run
  /// (`0x03` depth 3, a vertical run; the cycle is period-1 and so
  /// orientation-symmetric); the colour census corroborates other depth-3
  /// numerics but no second style run exists yet.
  hollowDouble,

  /// 1-px on / 1-px off dots on the route row (period 2: `00100`, `00000`).
  /// Carrier: scalar booleans (`0x21` depth 1; 37 runs, greens
  /// `0x006600`/`0x007f00` — the darker green is the newer-version
  /// palette, per the version-keyed colour keys of the census).
  dotted,

  /// Alternating single dots on two adjacent rows, never connected
  /// (period 2: one pixel on the low row, then one on the high row).
  /// Basis: n=1 — a single sampled run (`0x21` depth 2, a 1-D boolean
  /// array), corroborated visually by the same-layout render in each crc
  /// snippet sibling but not sampled at volume.
  dottedAlternating,

  /// A connected two-row zigzag (period 4, canonical `00010`, `00110`,
  /// `00100`, `00110` — one column on the top row, one on the bottom,
  /// joined by two-pixel columns). Carriers: the depth-2 string-family
  /// scalars — string `0x30` (55 horizontal runs, pink `0xff00ff`), path
  /// `0x32` (5 runs, teals), tag `0x37` (5 runs, `0x660066`). VERTICAL
  /// string wires draw compressed period-2 cycles instead
  /// (`00010`/`00110`-family; 7 runs pinned as `unclassified` `|V` keys —
  /// TODO: catalogue the vertical renditions).
  zigzag,

  /// The 3-row chain-link pattern (period 4: `00100`, `01110`, `01010`,
  /// `01110`). Carriers: depth-3 string-family wires (1-D arrays of
  /// string/path; 13 horizontal runs). Orientation-dependent: the one
  /// sampled VERTICAL run of the same cell draws the [braidDense] cycle
  /// instead (per-column `01010`/`01110` along the run) — this entry
  /// names the horizontal stroke.
  chainLink,

  /// The 4-row chain-link (period 4: `00101`, `01111`, `01010`, `01111`).
  /// Carrier: depth-4 string wires (2-D string arrays; 7 runs).
  chainLinkWide,

  /// The 3-row braid (period 4: `01010`, `01010`, `01110`, `01110`).
  /// Measured on scalar clusters (`0x50` depth 3, 9 runs — pink `0xff00ff`
  /// dominant, `0x006666` and `0x000000` singletons) and on 5 depth-3
  /// refnum runs; the refnum cell is NOT exposed through
  /// [ViSignalTypeRenderStyle.renderStyle] because the same cell also
  /// sampled non-braid cycles — a deep refnum's stroke follows its
  /// embedded inner type, which the word alone does not carry.
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

  /// The 3-row period-8 weave (canonical cycle
  /// `00010,01010,00010,01110,01000,01010,01000,01110`). Carrier:
  /// [kWeaveWireCode] at depth 3 (5 runs, `0x993300`) — the code resolves
  /// no VCTP type ([ViSignalType.dataType] is null), so only the look is
  /// catalogued here.
  weave,
}

/// `0x74` — an **uncatalogued wire-word-only element code** (18 corpus
/// signals; resolves no VCTP descriptor, so [ViSignalType.dataType] reads
/// null). Its depth-3 wires render as the [ViWireRenderStyle.weave] stroke
/// in brown `0x993300`; what the code *means* is not decoded (TODO).
const int kWeaveWireCode = 0x74;

/// The measured (code, depth) → style cells, keyed by the wire-type word's
/// low 12 bits (`depth << 8 | code`; the flag nibble is stroke-neutral,
/// law-asserted). EVERY entry is a census-sampled cell — the map is the
/// exact transcription of the majority style per `style|…` snapshot key,
/// nothing extrapolated. Cells the census sampled but that are NOT here:
///
/// * `0x02` depth 1 — its only run measured solid2px, contradicting the
///   numeric family's depth-1 rule; a single contradictory run neither
///   proves the family wrong nor itself right, so the cell stays null
///   (TODO: resample when the corpus offers more i16 scalar runs);
/// * `0x70` depth 3 — heterogeneous: braid AND non-braid cycles measured
///   (the stroke follows the refnum's embedded inner type);
/// * picture `0x33` depth 2 — sampled blank (no stroke recovered).
const Map<int, ViWireRenderStyle> _measuredCells = {
  // Depth-1 scalars.
  0x103: ViWireRenderStyle.solid1px,
  0x104: ViWireRenderStyle.solid1px, // n=1
  0x105: ViWireRenderStyle.solid1px,
  0x106: ViWireRenderStyle.solid1px,
  0x107: ViWireRenderStyle.solid1px,
  0x108: ViWireRenderStyle.solid1px,
  0x10a: ViWireRenderStyle.solid1px, // n=1
  0x170: ViWireRenderStyle.solid1px,
  // Depth-2 numeric/refnum 1-D arrays.
  0x203: ViWireRenderStyle.solid2px,
  0x205: ViWireRenderStyle.solid2px,
  0x207: ViWireRenderStyle.solid2px,
  0x208: ViWireRenderStyle.solid2px,
  0x270: ViWireRenderStyle.solid2px,
  // Depth-3 numeric 2-D array.
  0x303: ViWireRenderStyle.hollowDouble, // n=1
  // Booleans.
  0x121: ViWireRenderStyle.dotted,
  0x221: ViWireRenderStyle.dottedAlternating, // n=1
  // String family.
  0x230: ViWireRenderStyle.zigzag,
  0x232: ViWireRenderStyle.zigzag,
  0x237: ViWireRenderStyle.zigzag,
  0x330: ViWireRenderStyle.chainLink,
  0x332: ViWireRenderStyle.chainLink,
  0x430: ViWireRenderStyle.chainLinkWide,
  // Cluster / variant family.
  0x350: ViWireRenderStyle.braid,
  0x450: ViWireRenderStyle.braidWide,
  0x353: ViWireRenderStyle.braidDense,
  0x451: ViWireRenderStyle.braidDenseWide,
  // The uncatalogued weave carrier.
  (3 << 8) | kWeaveWireCode: ViWireRenderStyle.weave,
};

/// The wire-type-word codes of the plain solid numeric family used by the
/// estimate tier (ints + floats + complex by code range; the measured
/// subset is exactly the [_measuredCells] entries).
bool _isNumericCode(int code) => code >= TypeCode.i8 && code <= TypeCode.complexExt;

/// Render-style accessors on the wire-type word, in two explicit tiers:
///
/// * [renderStyle] — **measured only**: non-null exactly for the (code,
///   depth) cells the render-oracle census sampled and resolved to one
///   style. Null means "not measured", never "solid".
/// * [renderStyleEstimate] — measured value where one exists, else a
///   **family extrapolation** along the code axis (e.g. every depth-1
///   numeric solid, every depth-3 string-family chain-link). An estimate
///   is a prediction from the family pattern, not a measurement; renderers
///   wanting coverage take this tier knowingly.
extension ViSignalTypeRenderStyle on ViSignalType {
  /// The measured render style of this wire-type word, or null when the
  /// (code, depth) cell was never sampled against the render oracle — or
  /// sampled without resolving to one style. See [_measuredCells] for the
  /// exact cell list, the excluded contradictory/heterogeneous cells, and
  /// [ViWireRenderStyle] for per-cell counts (several rest on n=1).
  ViWireRenderStyle? get renderStyle => _measuredCells[raw & 0xfff];

  /// [renderStyle] where measured, else the family-rule extrapolation —
  /// explicitly an **estimate** for cells the oracle never sampled:
  ///
  /// * numerics (`0x01..0x0e`): depth 1 solid 1 px, depth 2 solid 2 px,
  ///   depth 3 hollow double (the depth-3 measurement itself is n=1);
  ///   this tier also covers the `0x02` depth-1 cell (family says solid
  ///   1 px; the cell's sole measured run contradicts it — solid 2 px —
  ///   which is why the measured tier keeps it null);
  /// * booleans: depth 1 dotted, depth 2 alternating dots;
  /// * string family (`0x30`/`0x32`/`0x37`): depth 2 zigzag, 3 chain-link,
  ///   4 wide chain-link;
  /// * clusters `0x50`: depth 3 braid, depth 4 wide braid; variant `0x53`
  ///   depth 3 dense braid; `0x51` depth 4 dense wide braid;
  /// * refnums (`0x70`/`0x71`): depth 1 solid 1 px, depth 2 solid 2 px —
  ///   deeper refnums stay null even here (measured heterogeneous, the
  ///   stroke follows the embedded inner type).
  ///
  /// Null when neither a measurement nor a family rule covers the cell.
  ViWireRenderStyle? get renderStyleEstimate {
    final measured = renderStyle;
    if (measured != null) return measured;
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
        _ => null, // deep refnums follow the embedded inner type (see doc)
      };
    }
    return null;
  }
}

/// The colour LabVIEW renders [rgb] as inside a diagram-disable structure's
/// displayed **Disabled** frame: per channel `c' = min(255, 153 + c ~/ 2)`.
/// A measured render fact (like the stroke catalogue), not file data.
///
/// Measured pairs (snippet reference pixels at decoded wire runs / chrome):
///
/// * wire blue `(0,0,255)` → `(153,153,255)` — law-asserted by the census;
/// * boolean-wire green `(0,102,0)` → `(153,204,153)` — law-asserted; the
///   discriminating sample: a plain `0.4·c + 153` linear blend predicts
///   194 for the green channel and is refuted (measured 204 =
///   `153 + 102 ~/ 2`);
/// * loop-border black `(0,0,0)` → `(153,153,153)` — law-asserted;
/// * label-backing yellow `(255,255,204)` → `(255,255,255)` — a **spot
///   measurement** (the census pins the raw `chrome…|labelBg` counts, but
///   enabled backings split between boxed yellow and transparent-on-white,
///   so no modal law holds); consistent with the formula, both high
///   channels clamping (`153 + 127 = 280 → 255`, `153 + 102 = 255`).
///
/// Every measured source channel is even, so the halving's rounding for
/// odd channels is not pinned by any pair; the implementation truncates
/// (`~/ 2`, asserted as the current behaviour by the unit suite — TODO:
/// pin on an odd-channel pair when the corpus offers one).
int dimDisabledFrameRgb(int rgb) {
  int dim(int c) => min(255, 153 + (c >> 1));
  return (dim((rgb >> 16) & 0xff) << 16) | (dim((rgb >> 8) & 0xff) << 8) | dim(rgb & 0xff);
}
