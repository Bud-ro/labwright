/// Growable (stacked-terminal) built-in primitive nodes — the block-diagram
/// classes that carry **no primResID** ([PrimOp]) because the class itself
/// is the operation, growing by whole terminal rows instead of swapping
/// icons.
///
/// Structure (full-corpus law, 7,524 VIs + the snippet repos — see
/// `test/growable_prim_test.dart` for the recomputed censuses):
///
/// - The node's positional children are `0x15` terminal wrappers (plus an
///   optional `0x0A` label). Each wrapper holds at most one **class-paired
///   DCO** — a dedicated data-carrying class per operation ([dcoClassCode],
///   always `classCode + 1` except Format Into String's `0x91`). No corpus
///   wrapper holds any other object kind.
/// - Bit 0 of the inner DCO's objFlags ([kGrowableDcoOutputFlag]) is the
///   terminal's **direction** (set = output), the same low bit that marks a
///   front-panel DCO as an indicator. Per-class output counts follow the
///   operation's shape exactly (one output for Build Array / Bundle /
///   Concatenate Strings / …, input-count outputs for Unbundle, two for
///   Format Into String / Delete From Array).
/// - Node **height tracks the row count** (rows are 8 px, plus the fixed
///   chrome), so one class renders many box sizes; and the same size can
///   carry different row make-ups (Index Array in 2D uses two consecutive
///   index rows for one output where twice-1D interleaves outputs).
///
/// Per-row state — the discriminators that change LabVIEW's box art within
/// one class and terminal count (reference-pixel verified on the snippet
/// corpus, byte-exact box crops):
///
/// - **Build Array** `0x3A`: [kGrowableRowModeFlag] on an input's `0x3B`
///   DCO switches that row's glyph from the element square to the array
///   glyph (concatenate row). Three distinct arts at t3 in the snippet
///   corpus — (array, element), (element, array), (element, element) —
///   match the flag vector 1:1.
/// - **Index Array** `0x44`: [kGrowableRowModeFlag] on an index row's
///   `0x45` DCO hollows the index glyph (a dimension left un-indexed;
///   corpus-wide the flagged rows are exactly the unwired ones) and the
///   output row art follows. Verified at t4 (2D): flagged-first vs
///   unflagged rows are two distinct reference arts.
/// - **Compound Arithmetic** `0x6C`: the node's own objFlags carry a
///   3-bit **mode field** at [kCompoundArithModeShift]. Mode 4 is `Add`
///   (reference art shows the `+` glyph); modes 1/5/6 are observed —
///   5 dominates and sits on almost-exclusively boolean terminals, 1 is
///   boolean-only, 6 numeric — but their glyphs are not yet
///   reference-verified, so they are not named. Input DCOs also toggle
///   [kGrowableRowModeFlag] (24% of inputs; not yet art-verified — the
///   invert bubble is the open candidate).
/// - **Format Into String** `0x93`: the growable input rows render the
///   wired type's glyph (`DBL`, `TF`, the path glyph — three distinct
///   reference arts at t6 with identical flag vectors), so row art keys on
///   the resolved terminal type, not on flags.
///
/// Bits proven art-neutral by byte-identical reference crops across both
/// values: `0x40000` on Concatenate-Strings inputs, `0x80000` on the Index
/// Array node and its index DCOs, `0x10000` on the Build Array /
/// Initialize Array node itself (it shadows "any row flagged" with corpus
/// exceptions, so the row bits are the truth). The `0x200000`/`0x400000`
/// pair on index-family DCOs brackets a dimension group (first/last index
/// of one row group; a single-index row carries both).
///
/// Naming evidence per entry ([opName]): corpus `0x0A` node labels
/// (LabVIEW's default node name; count in the doc comment), cross-checked
/// against the open-source pylabview class-tag catalog (`aBuild`, `aIndx`,
/// `cpdArith`, `printf`, …) and, where the snippet corpus shows the node,
/// its reference art.
///
/// @docImport 'prim_ops.dart';
library;

import '../graph.dart';

/// Direction bit of a growable-terminal DCO's objFlags: set = the terminal
/// is an **output** of the node (the growable-node counterpart of the
/// front-panel DCO's indicator bit).
const int kGrowableDcoOutputFlag = 0x1;

/// Per-row mode bit (`0x10000`) of a growable-terminal DCO's objFlags. The
/// meaning is class-specific but always the row's art-changing state:
/// the array/concatenate glyph on a Build Array input row, the hollowed
/// (un-indexed dimension) glyph on an Index-family index row. On Compound
/// Arithmetic inputs the bit varies but its art effect is not yet
/// reference-verified.
const int kGrowableRowModeFlag = 0x10000;

/// First-index-of-dimension-group bit (`0x200000`) on index-family DCOs
/// (Index Array / Replace Array Subset / Delete From Array): a
/// multi-dimension access stacks index rows for one output row, bracketed
/// first→last; a single-index group carries both bits.
const int kIndexDimFirstFlag = 0x200000;

/// Last-index-of-dimension-group bit (`0x400000`); see [kIndexDimFirstFlag].
const int kIndexDimLastFlag = 0x400000;

/// Bit shift of the Compound Arithmetic (`0x6C`) mode field in the node's
/// objFlags: `(objFlags >> 17) & 0x7`. Observed corpus values: 1, 4, 5, 6.
const int kCompoundArithModeShift = 17;

/// Mask of the Compound Arithmetic mode field (3 bits).
const int kCompoundArithModeMask = 0x7;

/// The Compound Arithmetic mode whose reference art is the `+` glyph
/// (`Add`). The other observed modes (1, 5, 6) are not yet
/// reference-verified and stay unnamed — report the numeric mode.
const int kCompoundArithAddMode = 4;

/// A growable stacked-terminal primitive class (see the library doc for the
/// structure and evidence rules). [classCode] is the heap object-header
/// class; [dcoClassCode] the paired terminal-DCO class; [opName] LabVIEW's
/// default node name.
enum GrowablePrim {
  /// ×26 corpus labels `Bundle`; pylabview `mux`/`mxDCO`. One output
  /// (first), then a DCO-less middle wrapper (the optional
  /// cluster-passthrough input — 1,662/1,662 corpus nodes leave it
  /// DCO-less), then the element inputs.
  bundle(0x34, 0x35, 'Bundle'),

  /// ×25 corpus labels `Unbundle`; pylabview `demux`/`dmxDCO`. One input,
  /// then one output per element row.
  unbundle(0x36, 0x37, 'Unbundle'),

  /// ×74 corpus labels `Build Array`; pylabview `aBuild`/`aBuildDCO`.
  /// Output first, then the input rows; [kGrowableRowModeFlag] rows are
  /// concatenate (array-glyph) rows — reference-art verified.
  buildArray(0x3a, 0x3b, 'Build Array'),

  /// ×32 corpus labels `Concatenate Strings`; pylabview
  /// `concat`/`concatDCO`. Output first, then the input rows.
  concatenateStrings(0x3e, 0x3f, 'Concatenate Strings'),

  /// ×27 corpus labels `Index Array`; pylabview `aIndx`/`aIDCO`. Array
  /// input, then per row group: output + its index rows
  /// ([kIndexDimFirstFlag]/[kIndexDimLastFlag] bracket a group;
  /// [kGrowableRowModeFlag] marks an un-indexed dimension) — reference-art
  /// verified.
  indexArray(0x44, 0x45, 'Index Array'),

  /// ×1 corpus label `Array Subset`; pylabview `subset`/`subsetDCO`.
  /// Array input, output, then (index, length) input pairs per dimension.
  /// The pairs' `0x80000`/`0x20000` objFlags variation is not yet decoded
  /// (TODO: art-correlate once the snippet corpus shows both values).
  arraySubset(0x48, 0x49, 'Array Subset'),

  /// ×14 corpus labels `Compound Arithmetic`; pylabview
  /// `cpdArith`/`cpdArithDCO`. Output first, then the input rows; the
  /// node's objFlags carry the mode field ([kCompoundArithModeShift]).
  compoundArithmetic(0x6c, 0x6d, 'Compound Arithmetic'),

  /// ×37 corpus labels `Format Into String`; pylabview `printf` with
  /// `printfArg` DCOs (the one pairing that is not `classCode + 1`).
  /// Five fixed terminals (format in, initial-string in, output, error in,
  /// error out — the fixed five carry [kGrowableRowModeFlag], the growable
  /// inputs do not), then one row per formatted input; row art follows the
  /// wired type's glyph.
  formatIntoString(0x93, 0x91, 'Format Into String'),

  /// ×10 corpus labels `Replace Array Subset`; pylabview
  /// `aReplace`/`aRepDCO`. Array in, array out, then per row group the new
  /// element/subarray input + its index rows.
  replaceArraySubset(0xb9, 0xba, 'Replace Array Subset'),

  /// ×7 corpus labels `Delete From Array`; pylabview `aDelete`/`aDelDCO`.
  /// Shortened-array output, array input, length input, deleted-portion
  /// output, then the index rows.
  deleteFromArray(0xbd, 0xbe, 'Delete From Array'),

  /// ×3 corpus labels `Initialize Array` (renamed corpus nodes read
  /// `Overflow array`); pylabview `aInit`/`aInitDCO`. Element input,
  /// array output, then one dimension-size input per dimension.
  initializeArray(0x114, 0x115, 'Initialize Array'),

  /// ×113 corpus labels `Merge Errors`; pylabview
  /// `mergeErrors`/`mergeErrorsDCO`. Output first, then the input rows.
  mergeErrors(0x172, 0x173, 'Merge Errors')
  ;

  const GrowablePrim(this.classCode, this.dcoClassCode, this.opName);

  /// The node's heap object-header class code.
  final int classCode;

  /// The paired terminal-DCO class code (the only object kind a corpus
  /// `0x15` wrapper of this node holds).
  final int dcoClassCode;

  /// LabVIEW's default node name.
  final String opName;

  static final Map<int, GrowablePrim> _byClass = {
    for (final p in values) p.classCode: p,
  };

  /// The growable primitive for a heap [classCode], or null.
  static GrowablePrim? fromClassCode(int classCode) => _byClass[classCode];
}

/// The identity-bearing variant key of a growable-prim [node] in [diagram],
/// or null when [node] is not a growable-prim class. Two nodes whose boxes
/// LabVIEW may draw differently never share a key:
///
/// - one lower-case char per `0x15` terminal wrapper in heap order —
///   `o` output row, `i` input row, `p` DCO-less placeholder wrapper —
///   with an input's [kGrowableRowModeFlag] capitalising it to `I`;
/// - Compound Arithmetic prefixes its mode field as `m<mode>_`.
///
/// The key deliberately excludes the bits proven art-neutral (library doc)
/// and does not fold in terminal types: Format Into String's per-row type
/// glyphs key on the resolved [ViHeapObject.dataType] separately.
String? growablePrimVariantKey(ViDiagram diagram, ViHeapObject node) {
  final prim = GrowablePrim.fromClassCode(node.kind);
  if (prim == null) return null;
  final rows = StringBuffer();
  if (prim == GrowablePrim.compoundArithmetic) {
    final mode = ((node.objFlags ?? 0) >> kCompoundArithModeShift) & kCompoundArithModeMask;
    rows.write('m${mode}_');
  }
  for (final wrapper in diagram.children(node.oid)) {
    if (wrapper.kind != 0x15) continue;
    ViHeapObject? dco;
    for (final child in diagram.children(wrapper.oid)) {
      if (child.kind == prim.dcoClassCode) {
        dco = child;
        break;
      }
    }
    final flags = dco?.objFlags ?? 0;
    rows.write(
      dco == null
          ? 'p'
          : (flags & kGrowableDcoOutputFlag) != 0
          ? 'o'
          : (flags & kGrowableRowModeFlag) != 0
          ? 'I'
          : 'i',
    );
  }
  return rows.toString();
}
