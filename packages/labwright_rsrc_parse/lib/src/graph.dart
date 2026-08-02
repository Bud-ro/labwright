import 'dart:math';
import 'dart:typed_data';

import 'blocks/prim_ops.dart';
import 'blocks/type_pool.dart';
import 'heap.dart';

/// The structural category of a heap object, from its class code + signals
/// (corpus-validated). Coarse but honest — node-vs-subVI and control-vs-indicator
/// are not separable from `BDEx` alone, so they are not distinguished.
enum ViObjectKind {
  /// A node's terminal/connector cluster (class `0x0c`; carries `C4 1F` terminals).
  terminalCluster,

  /// A terminal — a node connection point or a control/indicator terminal
  /// (classes `0x68`, `0x50/51/57/4f/5b`, `0x0a/0b/0d/e0`).
  terminal,

  /// A function / subVI node body (class `0x12`).
  node,

  /// A structure (loop/case/sequence) or a diagram container/frame
  /// (classes `0x53/52`, the root `0x7e`, `0x4c`, `0x11c`, `0x09`).
  structure,

  /// A decoration (unlabeled, never-wired large rect).
  decoration,

  /// A wire segment — one Manhattan run of a block-diagram wire (class `0x1d`).
  wire,

  /// Not classifiable from the available signals.
  unknown,
}

/// The inferred data-type kind of an object, from its attached `C4` records.
/// Payload-grounded; bool/string/array/cluster are not payload-encoded.
enum ViTypeKind {
  /// Integer numeric (a `C4 74` format string with a `b`/`d`/`o`/`x`/`X` conv).
  numericInt,

  /// Floating-point numeric (a `C4 74` format with an `e`/`f`/`g`/`p` conv).
  numericFloat,

  /// Enum / ring control (a `C4 2E` item list).
  enumRing,

  /// A filesystem/library path (`C4 A4` `PTH0`).
  path,

  /// A Call-Library node (`C4 C4` symbol + `C4 A4` library path).
  clnNode,

  /// A string (resolved from the VCTP data-space type).
  string,

  /// A boolean (resolved from the VCTP data-space type).
  boolean,

  /// A cluster/struct (resolved from the VCTP data-space type).
  cluster,

  /// An array (resolved from the VCTP data-space type).
  array,

  /// A refnum (resolved from the VCTP data-space type).
  refnum,

  /// No data-type signal present.
  unknown,
}

/// One object in a block-diagram heap, recovered by [buildDiagram].
///
/// The heap is a **balanced typed-group tree**: an object opens with
/// `10/11/12 <tag> 02 fe <u16 kind> fd <u16 oid>` and the tree is delimited by
/// high-nibble-1 group opens (`10/11/12/13 <tag>` where the byte after the count
/// is a type tag `FB`/`FE`/`FD`) and high-nibble-0 closes (`08/09/0a/0b`, popped
/// positionally). `oid` is usually unique within a VI (a few corpus VIs repeat one); [byId] keeps last-wins. Records attach to the innermost
/// object: `C4 2D` → [bounds]/[absBounds], `C4 22` → [label],
/// `14 19 01 fd <id>` → [refs] (child-membership ids, found on structure/diagram
/// container objects).
class ViHeapObject {
  ViHeapObject({required this.oid, required this.kind, required this.offset});

  /// The object's id (the `oid` field). Usually unique within a VI, but a few
  /// corpus VIs repeat an oid; id-keyed maps ([ViDiagram.byId]) keep last-wins.
  final int oid;

  /// The object's class code (the `kind` field of its header). `0x68` = terminal;
  /// `0x53`/`0x4c` = structure/diagram container; `0x12` = node; `0x0c` = terminal
  /// cluster.
  final int kind;

  /// Byte offset of the object's header within the heap body.
  final int offset;

  /// The object's bounding rectangle in **container-local** coordinates (from a
  /// `C4 2D` record), or null.
  HeapRect? bounds;

  /// The object's bounding rectangle in **absolute diagram coordinates**
  /// (recursively offset by its object-ancestors' origins), or null. Scrolled-
  /// cluster control terminals are re-anchored to their `0x11c` content viewport
  /// (see [_reanchorScrolledControls]). Validated: terminals fall inside their
  /// parent node/viewport ~99–100%.
  HeapRect? absBounds;

  /// The `oid` of this object's parent in the **byte-stream nesting tree** (the
  /// object open at the time this one opened), or null for the diagram root.
  ///
  /// NOTE: this is *positional* nesting (serialization order), NOT LabVIEW's
  /// declared structure/cluster membership. The heap also declares an explicit
  /// membership graph via the `0x14` typed-ref family ([refs] / [HeapRefKind]),
  /// and the two diverge substantially (~72% of `14 19` childRefs are not a
  /// descendant in this tree; `14 4f` memberRefs are orthogonal to it). The
  /// diagram/faithful layers currently group by this positional tree.
  int? parentOid;

  /// The object's label/caption — from a `C4 22` record, or from the same
  /// raw-0x022 tag stored at a scalar width when the text fits in 4 bytes
  /// ([HeapAttribute.shortText] via [HeapAttr.asciiText]) — or null.
  String? label;

  /// Child-membership object-id references from `14 19 01 fd <id>` records (the
  /// `10 55 01 fb` reflist) — the oids a structure/container holds, **not** wire
  /// endpoints. The childRef subset of [typedRefs] (kept for compatibility).
  final List<int> refs = <int>[];

  /// The full **`0x14` typed object-reference graph** for this object, keyed by
  /// relationship ([HeapRefKind]) and decoded by `decodeHeapRef` — the heap's
  /// *declared* membership/links, distinct from the positional [parentOid] tree.
  final Map<HeapRefKind, List<int>> typedRefs = <HeapRefKind, List<int>>{};

  /// The oids this object **declares as members** (childRef ∪ dcoRef) — used
  /// by the diagram to highlight a structure's members (which the positional
  /// nesting tree does not capture; the two diverge ~72%). May be empty.
  Iterable<int> get memberOids => <int>{
    ...?typedRefs[HeapRefKind.childRef],
    ...?typedRefs[HeapRefKind.dcoRef],
  };

  /// Number of `C4 1F` terminal records attached.
  int termCount = 0;

  /// The label's text **style runs** (from its tag-`0x25` run group — see
  /// [HeapPropertyToken.textStyleRuns]): each run overrides the default face
  /// for [label] from [start] (character offset) on, with the face bits of
  /// [style] catalogued in [HeapTextStyle]. Empty for the default face.
  /// Heap order (starts ascending in the corpus). A run's colour/face value
  /// (raw `0x029`) is not yet captured. // TODO(labwright)
  List<({int start, int style})> textStyleRuns = const [];

  /// Whether the caption's FIRST style run sets [HeapTextStyle.bold] — the
  /// face renderers apply to the whole label (multi-run labels are ~1% of
  /// carriers; per-run face switching is not rendered yet).
  bool get labelIsBold => textStyleRuns.isNotEmpty && HeapTextStyle.bold.isSetIn(textStyleRuns.first.style);

  /// Structural category (set during [buildDiagram]). See [ViObjectKind].
  ViObjectKind category = ViObjectKind.unknown;

  /// Inferred data-type kind from attached `C4` records. See [ViTypeKind].
  ViTypeKind typeKind = ViTypeKind.unknown;

  /// Enum/ring item labels (from a `C4 2E` string table) — the selectable
  /// values of an enum/ring control. Populated on the item-list object and
  /// propagated up to its enclosing control. Empty for non-enum objects.
  List<String> items = const [];

  /// Plot/curve names of a graph/chart indicator (`C4 27` strings, e.g.
  /// `Plot 0`, `Line 0`), in heap order. Corpus (7583 VIs): every object that
  /// carries these records is a `0x5E` graph — 253/253 objects, 100% (1208
  /// records across 169 VIs). Empty for non-graph objects.
  List<String> plotNames = const [];

  /// Decoded numeric-control **range minimum** (from the `0x20` f64 form on a
  /// control terminal) — null if none; may be `-infinity` (the "no minimum"
  /// sentinel). Use [formatControlRange] to render honestly.
  double? controlMin;

  /// Decoded numeric-control **range maximum** (from the `0x21` f64 form on a
  /// control terminal) — null if none; may be `+infinity` (the "no maximum"
  /// sentinel). Use [formatControlRange] to render honestly.
  double? controlMax;

  /// Decoded help / description text for this object (`C4 19` description), or
  /// null. The VI/control's documentation string.
  String? helpText;

  /// Flattened value of a block-diagram string constant (`bDConstDCO` `0x13`;
  /// [HeapAttribute.constValue], raw `0x26C`, the validated `C6 6C FF` blob and
  /// short `C6 6C <u8len>` u32-string forms) — e.g. `"%f"` or `"Test Status"`,
  /// or null. This is the constant's literal data, NOT documentation; it is not
  /// help text and must not render as such.
  String? constText;

  /// Decoded **numeric value** of a block-diagram constant (`bDConstDCO`
  /// `0x13`): an [int] for integer/enum payloads, a [double] for an 8-byte
  /// IEEE-754 payload — or null when the object is not a constant, carries no
  /// `0x26C` value record, or neither tier of [decodeBdConstValues] (the
  /// single decode pass: typed by the resolved data-space type first,
  /// type-independent fallback second) lands a reading. Enum/ring constants
  /// decode to their stored integer; the item labels ride [items].
  num? constNumeric;

  /// Decoded **boolean value** of a block-diagram constant (`bDConstDCO`
  /// `0x13` whose value carrier is a `0x4f` boolean control), or null. See
  /// [decodeBdConstantValue] for the gate and census.
  bool? constBool;

  /// A block-diagram constant's flattened `0x26C` value payload exactly as
  /// stored (`bDConstDCO` `0x13`): the length-prefixed container payload
  /// verbatim, or a scalar re-serialised big-endian at its stored width — or
  /// null off the DCO / when the record is absent. Captured at heap-parse
  /// time; all value interpretation happens later in [decodeBdConstValues],
  /// after data-space type resolution.
  Uint8List? constValueRaw;

  /// Whether the `0x26C` record stored [constValueRaw] at one of the scalar
  /// magnitude widths (u8/u16/u24/rgb) rather than a length-prefixed
  /// container/blob — a structural fact of the record encoding, captured at
  /// heap-parse time because the type-free gates of [decodeBdConstantValue]
  /// are width-form-scoped (booleans/integers ride scalars; the containered
  /// zero and 8-byte f64 forms ride containers).
  bool constValueScalar = false;

  /// Decoded element values of a block-diagram ARRAY constant, flattened in
  /// storage order (row-major across [constArrayDims]) — or null when the
  /// constant is not a resolved array of a fixed-width numeric element or
  /// its payload fails the length law. See [decodeBdConstValues].
  List<num>? constArray;

  /// The stored dimension sizes of [constArray] (`[rows, columns]` for a 2D
  /// array), or null alongside it.
  List<int>? constArrayDims;

  /// The `%`-led printf-style display-format text of a numeric display part
  /// ([HeapAttribute.formatStyle], raw `0x074`; e.g. `%.0f`, `%08x`) — or
  /// null. Corpus (7,524 VIs): 32,440 records, every one printable
  /// `%`-led text; 32,437 sit on the `0xe0` display window, 3 on `0x50`.
  /// Drives a constant's radix rendering (530 hex-format records).
  String? displayFormat;

  /// Decoded 24-bit `0xRRGGBB` **background** colour of this object
  /// ([HeapAttribute.backgroundColor], raw `0x028`, confirmed), or null when the
  /// object carries no such record. The colour belongs to the object that owns
  /// the record — often a control's cosmetic/part sub-object, not the drawable
  /// control itself — so a renderer must decide the part→owner mapping; this
  /// field asserts only the decoded value on its own object.
  int? bgRgb;

  /// Decoded 24-bit `0xRRGGBB` **foreground** colour of this object
  /// ([HeapAttribute.fgColor], raw `0x06f`, confirmed), or null. Same
  /// part-ownership caveat as [bgRgb].
  int? fgRgb;

  /// Decoded 24-bit `0xRRGGBB` **content** colour of this object
  /// ([HeapAttribute.contentColor], raw `0x024`, confirmed) — the interior/field
  /// fill of a control — or null. Same part-ownership caveat as [bgRgb].
  int? contentRgb;

  /// Decoded 24-bit `0xRRGGBB` **structure** colour of this object
  /// ([HeapAttribute.structColor], raw `0x119`, inferred) — a block-diagram
  /// structure's frame colour (loop / case / sequence / timed) — or null.
  /// Corpus: BDHb-only, 8 recurring values (the LabVIEW structure greys and the
  /// pale sequence/timed tint), so it is a real per-structure colour.
  int? structRgb;

  /// Decoded 24-bit `0xRRGGBB` **border** colour of this object
  /// ([HeapAttribute.borderColor], raw `0x02b`, inferred) — a front-panel
  /// control/graph border — or null. Corpus: FPHb-only.
  int? borderRgb;

  /// A terminal's box **relative to its enclosing frame** — the nearest
  /// bounded positional ancestor's top-left ([HeapAttribute.termBounds], raw
  /// `0x129`) — where a structure's tunnel / shift register / selector /
  /// count / conditional terminal (or a node's growable terminal) sits — or
  /// null. When the object also names a signal-endpoint DCO in its `14 19`
  /// childRefs, this rect is that wire endpoint's attach point (resolved
  /// absolutely by [ViDiagram.endpointTerminalBounds], which owns the corpus
  /// census). LabVIEW < 8.6 files store the rect in that era's absolute
  /// space instead (see [ViDiagram.endpointTerminalBounds]).
  HeapRect? termBounds;

  /// Which glyph the structure terminal shows ([HeapAttribute.termBMPs], raw
  /// `0x128`; corpus pairing: lCnt `i`→1, lMax `N`→2, lTst stop→192, shift
  /// registers →3/4, case selector →5) — or null.
  int? termBmp;

  /// The object's data-space slot ([HeapAttribute.typeDescIndex], raw
  /// `0x13a`) — an index into the VCTP top-level type table carrying a
  /// per-VI base (see `resolveDataSpaceTypes`) — or null.
  int? typeDescIdx;

  /// The resolved VCTP type's embedded name (`action`, `data in`, …) — the
  /// VI's own identifier for this data item — or null when the type is
  /// unresolved or unnamed. Set by `resolveDataSpaceTypes`.
  String? typeName;

  /// The resolved VCTP data type (finer than [typeKind]: `dbl` vs `i32`) —
  /// or null when unresolved. Set by `resolveDataSpaceTypes`.
  ViDataType? dataType;

  /// The full resolved VCTP descriptor behind [dataType] ([ViType]: raw
  /// code, cluster members, array element index + [ViType.dimCount]) — or
  /// null when unresolved. Set by `resolveDataSpaceTypes` alongside
  /// [dataType]; resolve member/element indices against `ViModel.types`.
  ViType? resolvedType;

  /// For a resolved [ViDataType.array], its ELEMENT's pool descriptor
  /// ([ViType.elementIndex] resolved during [resolveDataSpaceTypes]), or
  /// null — drives element-coloured array terminal art.
  ViType? resolvedElementType;

  /// The resolved member descriptors of [resolvedType] when it is a cluster
  /// (its [ViType.members] resolved against the pool during
  /// [resolveDataSpaceTypes]), else empty. Drives the cluster tint (LabVIEW
  /// inks a cluster by its member make-up, not a fixed colour).
  List<ViType> resolvedMembers = const [];

  /// [resolvedMembers] for the ELEMENT of a resolved array-of-cluster
  /// ([resolvedElementType]'s members), else empty.
  List<ViType> resolvedElementMembers = const [];

  /// The object's packed flags word ([HeapAttribute.objFlags], raw `0x0cb`)
  /// — or null when the record is absent.
  int? objFlags;

  /// Which built-in operation a primitive node performs
  /// ([HeapAttribute.primResID], raw `0x0ea`) — or null when the record is
  /// absent. Named via [PrimOp.fromId].
  int? primResId;

  /// LabVIEW's default node name for [primResId] (`Subtract`, `Select`, …),
  /// or null when the id is absent or uncatalogued (see [PrimOp]).
  String? get primName => primResId == null ? null : PrimOp.fromId(primResId!)?.opName;

  /// A signal's raw packed wire-route table ([HeapAttribute
  /// .compressedWireTable], raw `0x1e7`, container form) — or null for the
  /// scalar trivial forms and non-signal objects. Decoded by
  /// [decodeWireRoute].
  Uint8List? wireTableRaw;

  /// A signal's raw wire-type word ([HeapAttribute.lastSignalKind], raw
  /// `0x09f`, first-wins) — or null for non-signal objects and the rare
  /// record-less signal (14 of 428,043 corpus signals). Decoded by
  /// [ViSignalType]; surfaced as [ViWire.signalType].
  int? lastSignalKind;

  /// A multi-frame structure's raw diagram-index word ([HeapAttribute.dIdx],
  /// raw `0x04d`) — which stacked frame LabVIEW displays — or null when the
  /// record is absent (the first frame is displayed). Read through
  /// [visibleFrameIndex], which strips the bit-31 flag and owns the corpus
  /// census.
  int? dIdx;

  /// The stacked frame index LabVIEW displays for this multi-frame structure
  /// (see [kMultiFrameStructureKinds]): [dIdx] with the bit-31 flag stripped
  /// (every out-of-range raw corpus value but one is `0x80000000 | index`),
  /// or 0 when the record is absent. The index counts the structure's `0x1b`
  /// frame children in heap order. Only meaningful on the gated structure
  /// kinds — elsewhere the capture is dropped and this reads 0.
  ///
  /// Evidence: the absent-record default is render-verified directly (the
  /// GetCurrentDirectory snippet's two dIdx-absent structures both hold the
  /// rendered content in frame 0); heap-order indexing is pinned by event
  /// structures whose stored selector text carries the frame number — the
  /// Pages snippet's `[6] "Reload": Value Change` selector rides dIdx=6 of
  /// seven frames; the index semantics agree with the app-layer
  /// content-placement heuristic on 106/117 snippet structures
  /// (heuristic agreement, not a per-structure render comparison — the
  /// disagreements sit in VIs with known content-geometry defects and every
  /// heuristic-undecidable structure gets an answer). Corpus: 8,070 records
  /// on exactly the four gated kinds (case 7,325 / disable 431 / event 300 /
  /// stacked sequence 14); 8,069 in range after the mask (one true outlier —
  /// callers must range-check against the actual frame count); one object
  /// corpus-wide carries a second record (first-wins capture). 97 further
  /// `0x4d` records ride part kinds (`0x20`/`0x21`/`0x121`/`0x1b`/`0x105`)
  /// where the meaning is not decoded; the kind gate drops them.
  int get visibleFrameIndex => (dIdx ?? 0) & 0x7fffffff;

  /// Whether this **label part** (class `0xa`) is hidden in LabVIEW's
  /// block-diagram render: bit `0x08` of its [objFlags] (absent objFlags
  /// reads as shown). Render-verified against the snippet oracles' embedded
  /// BD renders; the minimal pair is GetCurrentDirectory's shown
  /// `kernel32.dll:…` label (flags `0x171142`) vs its hidden labels
  /// (`0x17114A` ×7, differing in bit `0x08` alone within one VI; the hidden
  /// subVI label's `0x26154B` shares only that bit across otherwise
  /// different flags). The hidden direction has eight direct samples; the
  /// shown direction rests on that one texted bit-clear sample plus five
  /// untexted bit-clear labels drawn via the type-name fill. The corpus
  /// split — 94,690 of 115,337 texted BD label parts set the bit vs 9,956
  /// of 101,790 on front panels — is consistent with terminal/constant
  /// labels defaulting hidden and panel labels shown, but is not itself
  /// render-verified, and no front-panel render oracle exists, so the FP
  /// reading is consistency-only. False for every other class: 0 of 17,018
  /// case-selector (`0x95`) labels set the bit, and the bit's meaning off
  /// label parts is not decoded.
  bool get isLabelHidden => kind == HeapObjectClass.controlLabel.code && ((objFlags ?? 0) & 0x08) != 0;

  /// Whether this data item is an **indicator** (an output) rather than a
  /// control: bit 0 of the owning DCO's [objFlags] (corpus-validated on
  /// named panels — "CRC-8"/"Sum"/"Elements"/"concatenated string" set it,
  /// every named input clears or omits it). Null when no paired DCO
  /// resolves. Set by `resolveDataSpaceTypes`.
  bool? isIndicator;

  /// Decoded 24-bit `0xRRGGBB` **plot** colours ([HeapAttribute.plotColor], raw
  /// `0x02a`, inferred), in heap order — the per-curve colours of a graph/chart's
  /// plot list. Empty when the object carries none. Corpus: FPHb-only, and all
  /// 234 carriers are the drawable `0x5E` graph object itself
  /// ([HeapObjectClass.graphIndicator], 234/234 bounded), so a renderer colours a
  /// graph's curves directly from its own list; a multi-plot graph holds one
  /// entry per curve (commonly 8–9). Index-parallel to [plotNames] where both
  /// were recovered.
  List<int> plotColors = const [];

  /// The named, documented class catalog entry for this object's [kind]
  /// (or [HeapObjectClass.unknown] if the code is not catalogued).
  HeapObjectClass get objectClass => HeapObjectClass.fromCode(kind);
}

/// How well-grounded a [HeapObjectClass]'s assigned name is. Clean-room RE, so
/// names are labelled honestly (see [HeapAttribute]'s `AttrConfidence`).
enum ClassConfidence {
  /// Pinned by a decisive structural correlation (a defining child/record, a
  /// 100%-consistent role across the corpus).
  confirmed,

  /// Role inferred from child profile / labels, but not provable without LabVIEW.
  inferred,

  /// Only the tree position is known; the purpose is a guess.
  kindOnly,
}

/// The catalog of known LabVIEW heap **object class codes** — the `<kind>` u16
/// in an object header `10 19 02 fe <kind> fd <oid>`.
///
/// HONEST COVERAGE: this catalog was effectively validated on **front-panel**
/// heaps (`FPHb`) — there object instances are ≈99% catalogued. **Block-diagram**
/// (`BDHb`) coverage splits two ways: (1) the high-volume **non-drawable** internal
/// records `0x15`/`0x33`/`0x17`/`0x30` (0 bounds — invisible, no render cost) are
/// unnamed but never shown; (2) of the render-accurate **drawable** BD objects
/// (~539k, post-scaffolding) ~99.4% are catalogued by code, and a structural
/// node-fallback (drawable + node-container `0x1b` parent + a `0x15` child + no
/// `0x68` connector + under a size cap -> node) classifies most of the rest, so
/// only ~0.19% render as a faint `unknown` placeholder. Naming (1) changes
/// nothing visible; the visible gap is (2). (The `BDEx`/`FPEx`
/// extended sections DO exist and are loaded — 3792/3000 of them — but in this
/// corpus they carry **no decodable object tree** (0 objects), so the object
/// heaps that matter are `BDHb`/`FPHb`; see ir.dart.)
///
/// SECTION-DEPENDENCE (honesty): a class code can mean different things on the
/// block diagram vs the front panel, so some names below describe the role where
/// the class was validated and are *not literal in the other section*. Probed
/// Genuinely DUAL-ROLE (observed in both heaps, corpus-probed): only `0x53` — a
/// BD while/for loop (5745 BD, each owns a `0x11c` viewport) vs an FP control-
/// container (21993 FP); its label carries both `(BD)`/`(FP)`.
/// FP-ONLY here (the legacy BD name is a misattribution — these appear 0 times in
/// the 3.86M decoded BD objects, which are dominated by the unnamed
/// 0x15/0x33/0x17/0x30 kinds — so the labels name the observed FP role): `0x12`
/// content group (42299), `0x4c` panel root frame (7568), and the rare
/// `0xc7`/`0xac` (102/60).
/// Section-CONSISTENT (same role both heaps, no split): `0x64` cluster/array shell
/// (BD 6705 / FP 9499) and `0x52` container-of-controls (BD 5190 / FP 6429, owns
/// no `0x11c` viewport either side — its old "case/sequence" name was dropped).
/// A label tagged `(BD)`/`(FP)` is not literal in the other section.
/// Each entry documents its role, coarse [category]
/// ([ViObjectKind]), evidence, and a [confidence] label. A control's *data type*
/// (numeric/enum/string/…) is read from its descendant `C4` records into
/// [ViHeapObject.typeKind]; the class additionally names the control *form*.
/// Resolve a raw code with [HeapObjectClass.fromCode]; the per-object catalog
/// entry is [ViHeapObject.objectClass].
enum HeapObjectClass {
  /// `0x7E` — the single **heap root** of a diagram (in both the BD and FP heaps);
  /// parentOid == null in all 15136 roots across the corpus.
  diagramRoot(0x7e, 'Diagram root', ViObjectKind.structure, ClassConfidence.confirmed),

  /// `0x4C` — the **front-panel root frame** under the heap root `0x7e`, owning the
  /// `14 19 01 fd` child-membership reflist; the panel pane holding the placed
  /// controls. Corpus: 7568 FP instances (one per VI, 7567 drawn), every one
  /// parented to `0x7e`, children are the `0x12` content groups + a `0x11c`
  /// viewport. FP-only here: it appears 0 times in the 3.86M decoded **BD** objects
  /// (those are dominated by the unnamed 0x15/0x33/0x17/0x30 kinds), so the legacy
  /// "diagram frame" BD reading is unsupported in this corpus — labelled for the
  /// role actually observed.
  diagramFrame(0x4c, 'Panel root frame (FP)', ViObjectKind.structure, ClassConfidence.confirmed),

  /// `0x7F` — a root-level **diagram property / scroll-state** record (no bounds).
  diagramProps(0x7f, 'Diagram properties', ViObjectKind.structure, ClassConfidence.inferred),

  /// `0x1D` — a **wire segment**: one Manhattan run of a block-diagram wire.
  /// Corpus (7584 VIs): 61673 instances, **BD-only** (0 FP); 61396/61396 of the
  /// rect records attached at the object's own level are degenerate lines
  /// (top == bottom, a horizontal run; a zero-length run marks a joint); a
  /// multi-segment wire is a run of consecutive `0x1d` siblings whose
  /// endpoints chain (verified 4741 exact end-to-start links in one source),
  /// with the vertical connector implicit between consecutive runs. A segment
  /// carries no datatype or terminal binding of its own (both live on the
  /// [signal] `0x17` — see [ViWire.signalType]), and
  /// the **absolute-coordinate anchoring is unverified** — rendered samples
  /// show some runs composing outside the diagram when treated like object
  /// bounds, so wire coords may be relative to a different ancestor frame.
  /// (Refuted encodings, corpus-probed: terminal typed-refs 0/2699; framed C4
  /// point-list payloads 0/22557; binary blob attributes carry no geometry.)
  /// The **logical** dataflow connection — with resolvable oid endpoints — is a
  /// separate class, the [signal] `0x17`; see [ViWire].
  bdWire(0x1d, 'Wire segment (BD)', ViObjectKind.wire, ClassConfidence.inferred),

  /// `0x17` — a **signal**: the block diagram's *logical* dataflow wire (the
  /// connection LabVIEW routes and colours between terminals). Corpus (7524
  /// VIs): 428,043 instances, BD-only. Each carries the per-signal record chain
  /// `signalState 0x115 → compressedWireTable 0x1e7 → lastSignalKind 0x9f`
  /// (~100% each) and, decisively, **its endpoint binding**: `14 19` childRefs
  /// naming the data-connection objects it joins — 902,107 refs that resolve
  /// **100.00%** within the BD heap, 91.2% of signals holding exactly 2
  /// (source + sink), 7.5% holding 3, the remainder branching further. The
  /// endpoints are DCO objects (`0x15` 95.6% / `0x16` 4.4%); each has a bounded
  /// owner object (**100%** — the node or `0x1d` wire-segment it attaches to),
  /// so the endpoints are spatially locatable (see [ViWire.endpointAnchors]).
  /// A sub-population of endpoints — the structure tunnels / border
  /// terminals and the growable-node terminals — additionally resolves an
  /// **attach rectangle** via the terminal object that names the endpoint in
  /// its own `14 19` childRefs and carries the `0x129` termBounds rect;
  /// [ViDiagram.endpointTerminalBounds] owns that census.
  /// The signal itself carries no bounds; its packed route lives in the
  /// compressedWireTable payload — decoded to an absolute polyline for
  /// two-endpoint signals ([ViWire.routePoints]) and an absolute tree for
  /// branching signals ([ViWire.routeTree]). Its
  /// **datatype is decoded — with measured agreement, not certainty — from
  /// its own lastSignalKind record** (element type code + array depth +
  /// flags, carried by all but 14 corpus signals): the decoded family
  /// agrees with VCTP-typed endpoints on 89.9% of the 144,668 signals that
  /// have one; [ViSignalType] owns the census and the disagreement
  /// partition. (The refuted alternative, kept for the record: the
  /// per-object [HeapAttribute.typeDescIndex] reachable from ~8.7% of
  /// signals via an endpoint's `14 4f` dcoRef is an object ordinal that
  /// agrees across a signal's endpoints in 0.0% of cases.)
  signal(0x17, 'Signal / dataflow wire (BD)', ViObjectKind.wire, ClassConfidence.inferred),

  /// `0x101` — a root **auxiliary** record; purpose undetermined.
  rootAux(0x101, 'Root auxiliary', ViObjectKind.unknown, ClassConfidence.kindOnly),

  /// `0x53` — a **viewport-owning structure**, section-dependent: on the **block
  /// diagram** a while/for **loop**; on the **front panel** a **control container**
  /// (cluster / tab / subpanel). Always owns exactly one `0x11c` content viewport +
  /// the child-membership reflist — so the label can't assert "loop" section-blind.
  /// Corpus: 5745 BD instances (100% own a `0x11c`); 21993 FP instances (all own a
  /// `0x11c`; in 94% its direct contents are placed control terminals
  /// 0x50/0x4f/0x51/0x57 — a container of controls, not a loop). The while-vs-for
  /// split is not separable.
  loop(0x53, 'Loop (BD) / container (FP)', ViObjectKind.structure, ClassConfidence.confirmed),

  /// `0x52` — a **container** holding placed controls. Section-CONSISTENT (like
  /// `0x64`, not split): the BD and FP child profiles are equivalent — corpus
  /// 5190 BD + 6429 FP instances, all drawn, holding a control terminal
  /// (0x50/0x51/0x64/0x53) in 100% of both. It owns a `0x11c` subdiagram viewport
  /// in 0/5190 BD instances, so the structural signature of a real case/sequence
  /// (per-frame subdiagrams, like the `0x53` loop's viewport) is ABSENT — the
  /// earlier "case/sequence" reading was unsupported, so the name stays a neutral
  /// "container" in both sections.
  caseOrSequence(0x52, 'Container (placed controls)', ViObjectKind.structure, ClassConfidence.inferred),

  /// `0x64` — a **cluster / array shell** on a node.
  clusterShell(0x64, 'Cluster/array shell', ViObjectKind.structure, ClassConfidence.inferred),

  /// `0x2C` — a **Case structure** frame. Corpus: 14563 BD instances (0 FP), big
  /// boxes (median **290×188**, p90 884×462), parented to the node container `0x1b`,
  /// holding node containers `0x1b`, the structural `0x15` records, and the `0x95`
  /// case-selector row. The kind IS recoverable: its `0xa` caption reads literally
  /// `Case Structure` (590 labelled instances) and its children are case selectors;
  /// it owns no `0x11c` viewport but contains a `0x53` per-frame body. Renders as a
  /// structure frame.
  bdStructureFrame(0x2c, 'Case structure', ViObjectKind.structure, ClassConfidence.inferred),

  /// `0x20` — a **For Loop** structure frame. Corpus: 4892 BD instances (0 FP),
  /// median 224×148 (p90 755×427), parented to the node container `0x1b`; its `0xa`
  /// caption reads literally `For Loop` / `For Each Element: …`. Renders as a
  /// structure frame.
  bdForLoop(0x20, 'For loop', ViObjectKind.structure, ClassConfidence.inferred),

  /// `0x21` — a **While Loop** structure frame. Corpus: 1654 BD instances (0 FP),
  /// large (median 614×386, p90 1317×734), parented to `0x1b`; its `0xa` caption
  /// reads `While Loop` (or a named state machine). Renders as a structure frame.
  bdWhileLoop(0x21, 'While loop', ViObjectKind.structure, ClassConfidence.inferred),

  /// `0xCD` — a **Diagram/Conditional Disable structure** frame. Corpus: 1186 BD
  /// (0 FP), median 258×144, parent the node container `0x1b`; `0xa` caption reads
  /// `Diagram Disable Structure` / `Conditional Disable Structure`. Renders as a
  /// structure frame.
  bdDisableStructure(0xcd, 'Disable structure', ViObjectKind.structure, ClassConfidence.inferred),

  /// `0x14D` — an **In Place Element Structure** frame. Corpus: 896 BD (0 FP),
  /// median 233×138, parent `0x1b`; `0xa` caption reads `In Place Element
  /// Structure`. Renders as a structure frame.
  bdInPlaceStructure(0x14d, 'In Place Element structure', ViObjectKind.structure, ClassConfidence.inferred),

  /// `0xCA` — a **Flat Sequence structure** frame. Corpus: 560 BD (0 FP), median
  /// 223×217, parent the node container `0x1b`; `0xa` caption reads `Flat Sequence
  /// Structure`. Renders as a structure frame.
  bdFlatSequence(0xca, 'Flat Sequence structure', ViObjectKind.structure, ClassConfidence.inferred),

  /// `0x29` — a **Stacked Sequence structure** frame. Corpus: 423 BD (0 FP), median
  /// 105×97, parent `0x1b`; `0xa` caption reads `Stacked Sequence Structure`.
  /// Renders as a structure frame.
  bdStackedSequence(0x29, 'Stacked Sequence structure', ViObjectKind.structure, ClassConfidence.inferred),

  /// `0xD5` — an **Event structure** frame. Corpus: 390 BD (0 FP), large (median
  /// 504×325), parent the node container `0x1b`; `0xa` caption reads `Event
  /// Structure`. Renders as a structure frame.
  bdEventStructure(0xd5, 'Event structure', ViObjectKind.structure, ClassConfidence.inferred),

  /// `0x121` — a **sequence subframe** (one frame of a Flat Sequence). Corpus: 843
  /// BD (0 FP), large (median 203×241), 835/843 parented to the Flat Sequence frame
  /// `0xca` — no caption (the frame body), but the parent + size identify it.
  bdSequenceFrame(0x121, 'Sequence frame', ViObjectKind.structure, ClassConfidence.inferred),

  /// `0x95` — a **case/sequence selector label row** on a structure frame's top
  /// edge (the `True`/`False`/case-name strip). Corpus: **16118 BD** instances
  /// (**83 FP** — not BD-only), median 53×19, ~14352 parented to the `0x2c` case
  /// frame, ~15280 carry a decoded label (~42% trim to the bare `True`/`False`, the
  /// rest case strings). NOTE the raw label often has surrounding spaces (` True `).
  /// Renders the selector text via [_LabelText]; the label is the recoverable part.
  bdSelectorLabel(0x95, 'Case selector label', ViObjectKind.terminal, ClassConfidence.inferred),

  /// `0x177` — a small fixed **node glyph / decoration** (12×12). Corpus: **17043 BD**
  /// instances (0 FP), ~92% (15659) at exactly 12×12, 100% parented to the node
  /// container `0x1b`, no label, no children — a fixed on-diagram glyph (e.g. a
  /// coercion dot / small marker). Role not separable, so [ClassConfidence.kindOnly];
  /// catalogued so it draws a faint marker instead of vanishing.
  bdGlyph(0x177, 'Node glyph', ViObjectKind.decoration, ClassConfidence.kindOnly),

  /// `0xC7` — a rare nested **container** parenting `0x12` bodies (BD nodes / FP
  /// content groups). Corpus: FP-only here (102 instances, all drawn, 99/102 nested
  /// under `0xc3`); 0 BD. The "subdiagram" name is the BD reading.
  subdiagramContainer(0xc7, 'Subdiagram container', ViObjectKind.structure, ClassConfidence.inferred),

  /// `0xEF` — a rare structure carrying refs + a `0x11c` viewport.
  rareStructure(0xef, 'Structure (rare)', ViObjectKind.structure, ClassConfidence.kindOnly),

  /// `0xAC` — a rare **group** parenting `0x12` bodies (BD nodes / FP content
  /// groups). Corpus: FP-only here (60 instances, drawn, mostly under the panel
  /// frame `0x4c`); 0 BD.
  nodeGroup(0xac, 'Node group', ViObjectKind.structure, ClassConfidence.kindOnly),

  /// `0x11C` — a **content viewport**: the scroll container holding a loop's /
  /// diagram's placed controls. Used as the control re-anchor frame; suppressed
  /// from the faithful render.
  contentViewport(0x11c, 'Content viewport', ViObjectKind.structure, ClassConfidence.confirmed),

  /// `0x12` — a **front-panel content group** (no bounds; never drawn) that holds
  /// the placed controls. Corpus: 42299 FP instances, 0 drawn, 41514 parented
  /// directly to the panel frame `0x4c`, with control/structure children
  /// (0x53/0x51/0x4f/0x64/0x50) — a panel container. FP-only here: it appears 0
  /// times in the 3.86M decoded **BD** objects (which are dominated by the unnamed
  /// 0x15/0x33/0x17/0x30 kinds — the real BD nodes), so the legacy "function/subVI
  /// node" BD reading is unsupported in this corpus and was dropped. (Category kept
  /// [ViObjectKind.node] — an undrawn grouping bucket; it is never rendered.)
  node(0x12, 'Content group (FP)', ViObjectKind.node, ClassConfidence.confirmed),

  /// `0x13` — a **block-diagram constant DCO** (`bDConstDCO`): the owner of a
  /// diagram constant's `0x26C` flattened-value record (record census on
  /// [HeapAttribute.constValue]) and of its `typeDescIndex`, wrapping one
  /// value-carrier control child ([numericControl] / [booleanOrClusterControl]
  /// / [stringOrArrayControl] / [enumRingControl]; arrays and clusters under
  /// their shells). Decoded values ride [ViHeapObject.constNumeric] /
  /// [ViHeapObject.constBool] / [ViHeapObject.constText]. Category stays
  /// [ViObjectKind.unknown]: the DCO is an undrawn wrapper — its drawable parts
  /// classify on their own classes.
  bdConstDco(0x13, 'Constant DCO (BD)', ViObjectKind.unknown, ClassConfidence.inferred),

  /// `0x2F` — a **built-in primitive node**. Corpus: 44395 BD instances, 0 FP, a
  /// uniform **32×32** icon footprint (LabVIEW's default node-icon size), parented
  /// to the node container `0x1b`, holding the structural `0x15` records. Only ~717
  /// carry an `0xa` caption, and those read as built-in primitives (`To Lower Case`,
  /// `Search 1D Array`, `Select`) — vs the subVI-named `0x31`. The specific
  /// primitive icon is not yet decoded, so it renders as a generic node box.
  bdNode(0x2f, 'Node (primitive)', ViObjectKind.node, ClassConfidence.inferred),

  /// `0x31` — a **subVI call node**. Corpus: 31995 BD instances, 0 FP, uniform
  /// **32×32**, parented to `0x1b`, with 31873/31995 carrying an `0xa` caption that
  /// is a VI filename (`PicoScope2000aOpen.vi`, `Application Directory.vi`, …) —
  /// definitively a subVI call (vs the primitive `0x2f`). Renders as a node box; the
  /// called-VI name is on its `0xa` caption.
  bdNamedNode(0x31, 'Node (subVI call)', ViObjectKind.node, ClassConfidence.inferred),

  /// `0x63` — a **growable/resizable block-diagram node** (e.g. Bundle/Unbundle
  /// By Name). Corpus: 13737 BD instances (0 FP), wide-short and variable (median
  /// **89×20**, p90 158×61), parented to the node container `0x1b`, holding the
  /// structural `0x15` records; labelled ones carry function names like
  /// `Unbundle By Name` — confirming a node. Renders as a node box.
  bdGrowableNode(0x63, 'Node (growable)', ViObjectKind.node, ClassConfidence.inferred),

  /// `0x8C` — a **subVI / expandable node**. Corpus: 6620 BD (0 FP), median
  /// **68×36**, parent the node container `0x1b`, structural `0x15` children; the
  /// `0xa` labels carry subVI names (`Meter (mV)`, `Channel D Settings`, …) —
  /// confirming a node. Renders as a node box.
  bdNode8c(0x8c, 'Node', ViObjectKind.node, ClassConfidence.inferred),

  /// `0x3A` — a **built-in primitive node**. Corpus: 3479 BD (0 FP), median
  /// **32×17** (height to 33), parent `0x1b`, structural `0x15` children; labelled
  /// ones read primitive names (`Build Array`, …) — confirming a node.
  bdNode3a(0x3a, 'Node (primitive)', ViObjectKind.node, ClassConfidence.inferred),

  /// `0xD6` — a **block-diagram node** (seen as an Event Data Node). Corpus: 2209 BD
  /// (0 FP), median **56×20** (height to ~103), parent `0x1b`, structural `0x15`
  /// children; the rare `0xa` caption reads `Event Data Node`. Renders as a node box.
  bdNoded6(0xd6, 'Node', ViObjectKind.node, ClassConfidence.inferred),

  /// `0x32` — a **subVI call node** (wide). Corpus: 2075 BD (0 FP), median 87×19,
  /// parent `0x1b`; 2066/2075 carry an `0xa` VI-filename caption (`Robot Main.vi`,
  /// `PicoScope2000aSettings.vi`). Renders as a node box.
  bdNode32(0x32, 'Node (subVI call)', ViObjectKind.node, ClassConfidence.inferred),

  /// `0xC5` — a **subVI call node** (icon). Corpus: 1518 BD (0 FP), uniform 32×32,
  /// parent `0x1b`; 1518/1518 carry an `0xa` VI-filename caption (`Analog to
  /// Digital.vi`). Renders as a node box.
  bdNodeC5(0xc5, 'Node (subVI call)', ViObjectKind.node, ClassConfidence.inferred),

  /// `0x104` — a **subVI call node** (icon). Corpus: 2155 BD (0 FP), uniform 32×32,
  /// parent `0x1b`; 2155/2155 carry an `0xa` VI-filename caption (`Prepare
  /// Response.vi`, `getFlags.vi`). Renders as a node box.
  bdNode104(0x104, 'Node (subVI call)', ViObjectKind.node, ClassConfidence.inferred),

  /// `0x44` — a **built-in primitive node**. Corpus: 3228 BD (0 FP), ~32×27, parent
  /// `0x1b`; labelled ones read `Index Array`. Renders as a node box.
  bdNode44(0x44, 'Node (primitive)', ViObjectKind.node, ClassConfidence.inferred),

  /// `0x3E` — a **built-in primitive node**. Corpus: 1961 BD (0 FP), ~32×17, parent
  /// `0x1b`; labelled ones read `Concatenate Strings`. Renders as a node box.
  bdNode3e(0x3e, 'Node (primitive)', ViObjectKind.node, ClassConfidence.inferred),

  /// `0x34` — a **built-in primitive node**. Corpus: 1665 BD (0 FP), ~32×25, parent
  /// `0x1b`; labelled ones read `Bundle`. Renders as a node box.
  bdNode34(0x34, 'Node (primitive)', ViObjectKind.node, ClassConfidence.inferred),

  /// `0xA9` — a **block-diagram node** (Invoke Node / Sub Panel / unit-conversion
  /// subVI). Corpus: 2416 BD (0 FP), median 82×70, parent `0x1b`; `0xa` captions
  /// vary (`Invoke Node`, `… Units`). Renders as a node box.
  bdNodeA9(0xa9, 'Node', ViObjectKind.node, ClassConfidence.inferred),

  /// `0x93` — a **built-in primitive node**. Corpus: 1479 BD (0 FP), median 32×29,
  /// parent `0x1b`; labelled ones read `Format Into String`. Renders as a node box.
  bdNode93(0x93, 'Node (primitive)', ViObjectKind.node, ClassConfidence.inferred),

  /// `0x172` — a **built-in primitive node**. Corpus: 1409 BD (0 FP), median 32×18,
  /// parent `0x1b`; labelled ones read `Merge Errors`. Renders as a node box.
  bdNode172(0x172, 'Node (primitive)', ViObjectKind.node, ClassConfidence.inferred),

  /// `0x6C` — a **built-in primitive node** (object kind, distinct from the `0x6c`
  /// help attribute id). Corpus: 1020 BD (0 FP), median 24×17, parent `0x1b`;
  /// labelled ones read `Compound Arithmetic`. Renders as a node box.
  bdNode6c(0x6c, 'Node (primitive)', ViObjectKind.node, ClassConfidence.inferred),

  /// `0x36` — a **built-in primitive node**. Corpus: 1002 BD (0 FP), median 32×17,
  /// parent `0x1b`; labelled ones read `Unbundle`. Renders as a node box.
  bdNode36(0x36, 'Node (primitive)', ViObjectKind.node, ClassConfidence.inferred),

  /// `0x153` — a **built-in primitive node** (icon, name not yet recovered). Corpus:
  /// 1466 BD (0 FP), 100% exactly **32×32** (the default node-icon footprint),
  /// 100% parented to the node container `0x1b`, children only structural `0x15`
  /// records — byte-for-byte the `0x2f` primitive profile, but with no `0xa`
  /// caption, so the specific primitive is not yet recovered: [ClassConfidence.kindOnly].
  bdNode153(0x153, 'Node (primitive)', ViObjectKind.node, ClassConfidence.kindOnly),

  /// `0x6A` — a **Call Library Function Node** (calls into a native DLL/.so).
  /// Corpus: 878 BD (0 FP), median 40×59, parent `0x1b`; 764/878 carry an `0xa`
  /// caption that is a library entry point (`ps3000.dll:_ps3000_open_unit@0`,
  /// `setMaxMinAppAndDriverBuffers`). Renders as a node box.
  bdCallLibrary(0x6a, 'Call Library node', ViObjectKind.node, ClassConfidence.inferred),

  /// `0xBD` — a **built-in primitive node**. Corpus: 623 BD (0 FP), median 32×33,
  /// parent `0x1b`; labelled ones read `Delete From Array`. Renders as a node box.
  bdNodeBd(0xbd, 'Node (primitive)', ViObjectKind.node, ClassConfidence.inferred),

  /// `0x114` — a **built-in primitive node**. Corpus: 425 BD (0 FP), median 32×27,
  /// parent `0x1b`; labelled ones read `Initialize Array` / `Overflow array`.
  /// Renders as a node box.
  bdNode114(0x114, 'Node (primitive)', ViObjectKind.node, ClassConfidence.inferred),

  /// `0xB6` — a **VI-reference / property-style node** (object kind, distinct from
  /// the `0xb6` method-name attribute id). Corpus: 503 BD (0 FP), median 58×21,
  /// parent `0x1b`; 469/503 carry an `0xa` caption (`This VI`, `Server in`).
  /// Renders as a node box.
  bdNodeB6(0xb6, 'Node', ViObjectKind.node, ClassConfidence.inferred),

  /// `0xB9` — a **built-in primitive node** (Replace Array Subset). Corpus: 372 BD
  /// (0 FP), 32×33, parent `0x1b`. Renders as a node box.
  bdNodeB9(0xb9, 'Node (primitive)', ViObjectKind.node, ClassConfidence.inferred),

  /// `0x48` — a **built-in primitive node** (Array Subset). Corpus: 304 BD (0 FP),
  /// 32×35, parent `0x1b`. Renders as a node box.
  bdNode48(0x48, 'Node (primitive)', ViObjectKind.node, ClassConfidence.inferred),

  /// `0xEB` — a **block-diagram node** (Register For Events). Corpus: 224 BD (0 FP),
  /// median 100×38, parent `0x1b`. Renders as a node box.
  bdNodeEb(0xeb, 'Node', ViObjectKind.node, ClassConfidence.inferred),

  /// `0x103` — a **subVI call node**. Corpus: 217 BD (0 FP), median 36×48, parent
  /// `0x1b`; 217/217 carry a `.vi`/`.lvclass` filename caption (`process.vi`).
  /// Renders as a node box.
  bdNode103(0x103, 'Node (subVI call)', ViObjectKind.node, ClassConfidence.inferred),

  /// `0x14A` — a **block-diagram node** (seen as a Feedback Node). Corpus: 367 BD
  /// (0 FP), 32×24, parent `0x1b`; captions include `Feedback Node`. Node box.
  bdNode14a(0x14a, 'Node', ViObjectKind.node, ClassConfidence.inferred),

  /// `0x16` — a **free-standing block-diagram terminal/constant leaf**. Corpus:
  /// 41830 BD instances, 0 FP, uniform **32×16** (41091/41830), each nested under a
  /// zero-area node body `0x1d` (grandparent the node container `0x1b`);
  /// `termCount == 0`, no decoded data type, and the `0xa` label slot is empty. It
  /// is NOT an on-node pin — corpus geometry: it overlaps a sibling node only ~2% of
  /// the time and sits ~112px (edge) / ~154px (center) from the nearest node — so it
  /// is a small free-standing leaf (a terminal or constant; not separable here).
  bdLeaf(0x16, 'Terminal/constant (BD)', ViObjectKind.terminal, ClassConfidence.inferred),

  /// `0x4E` — a small **block-diagram constant/terminal**. Corpus: 947 BD (0 FP),
  /// median **18×16**, parented to a `0x13` group, with exactly one `0x68` connector
  /// child; the labelled ones read as constants (`Carriage Return Constant`,
  /// `Empty String Constant`, `delimiter (Tab)`). Renders as a generic terminal.
  bdConstant4e(0x4e, 'Constant/terminal (BD)', ViObjectKind.terminal, ClassConfidence.inferred),

  /// `0x50` — a **numeric** control/indicator terminal (defining signal: a
  /// `0xE0` numeric-display child + `C4 74` printf format).
  numericControl(0x50, 'Numeric control', ViObjectKind.terminal, ClassConfidence.confirmed),

  /// `0x57` — an **enum / ring** control terminal (`C4 2E` item table + `0xE0`
  /// child).
  enumRingControl(0x57, 'Enum/ring control', ViObjectKind.terminal, ClassConfidence.confirmed),

  /// `0x4F` — a **boolean / cluster** control terminal (overloaded: 1 cluster
  /// child ≈ boolean, ≥2 ≈ cluster; occasionally a ring).
  booleanOrClusterControl(0x4f, 'Boolean/cluster control', ViObjectKind.terminal, ClassConfidence.inferred),

  /// `0x51` — a **string / array / refnum** control terminal.
  stringOrArrayControl(0x51, 'String/array control', ViObjectKind.terminal, ClassConfidence.inferred),

  /// `0x55` — a **control/indicator terminal** (section-consistent, in both heaps:
  /// 2234 BD + 4365 FP). Defining signal: exactly one `0x68` connector child (100%)
  /// + a `0xa` name caption (`Payload`, `Incoming Message`, `SessionMailbox`),
  /// parented to a control container (`0x13`/`0x11c`/`0x52`). Renders as a terminal.
  controlTerminal55(0x55, 'Control terminal', ViObjectKind.terminal, ClassConfidence.inferred),

  /// `0x10C` — a **control/indicator terminal** (section-consistent, FP-dominant:
  /// 797 BD + 7650 FP), median 48×48; 723/797 BD carry an `0xa` data-name caption
  /// (`Connection.WS in`, `CONNACK in`), parented to a control container
  /// (`0x13`/`0x11c`/`0x52`). Renders as a terminal.
  controlTerminal10c(0x10c, 'Control terminal', ViObjectKind.terminal, ClassConfidence.inferred),

  /// `0xC2` — a small **constant/terminal** (both heaps: 643 BD + 968 FP), median
  /// 15×19, parented to a control container (`0x11c`/`0x13`); labelled ones read as
  /// short data names (`variant`, `storage`, `cache`). Renders as a terminal.
  constantC2(0xc2, 'Constant/terminal', ViObjectKind.terminal, ClassConfidence.inferred),

  /// `0x5B` — a **path** control terminal (nests a browse-button `0x4F`).
  pathControl(0x5b, 'Path control', ViObjectKind.terminal, ClassConfidence.inferred),

  /// `0x5E` — a **graph / chart / waveform** indicator (`C4 27` plot names +
  /// legends/scales/cursors).
  graphIndicator(0x5e, 'Graph/chart indicator', ViObjectKind.terminal, ClassConfidence.inferred),

  /// `0xDF` — a rare **numeric** control variant (same child profile as `0x50`).
  numericControlVariant(0xdf, 'Numeric control (variant)', ViObjectKind.terminal, ClassConfidence.inferred),

  /// `0x59` — a rare control variant.
  controlVariant(0x59, 'Control (variant)', ViObjectKind.terminal, ClassConfidence.kindOnly),

  /// `0x0C` — a node/control **terminal cluster**: carries the `C4 1F` terminals
  /// (100% do).
  nodeTerminalCluster(0x0c, 'Terminal cluster', ViObjectKind.terminalCluster, ClassConfidence.confirmed),

  /// `0x0A` — a **control label** sub-part: bears the visible `C4 22` caption.
  controlLabel(0x0a, 'Label', ViObjectKind.terminal, ClassConfidence.confirmed),

  /// `0x68` — a **connector / wire terminal** (97% have no bounds; the rest are
  /// zero-area points). The control's/node's connection point.
  connectorTerminal(0x68, 'Connector terminal', ViObjectKind.terminal, ClassConfidence.confirmed),

  /// `0x0B` — an internal control **sub-part** (increment / boolean glyph /
  /// array index).
  controlSubPart(0x0b, 'Control sub-part', ViObjectKind.terminal, ClassConfidence.inferred),

  /// `0xE0` — a **numeric digital-display** sub-part (only under `0x50`/`0x57`).
  numericDisplay(0xe0, 'Numeric display', ViObjectKind.terminal, ClassConfidence.confirmed),

  /// `0x0D` — the **enum/ring item-label list** (`C4 2E` string table).
  enumItemList(0x0d, 'Enum item list', ViObjectKind.terminal, ClassConfidence.confirmed),

  /// `0xC1` — a **tip-strip / help-text** sub-part (`C4 19` only).
  tipStrip(0xc1, 'Tip strip', ViObjectKind.terminal, ClassConfidence.confirmed),

  /// `0x09` — **control chrome / resize handle**: a bounded, child-less,
  /// never-labelled leaf — the visual frame/handle of a control or structure.
  /// Suppressed from the faithful render.
  controlChrome(0x09, 'Resize handle/chrome', ViObjectKind.decoration, ClassConfidence.inferred),

  /// `0x8F` — a free **decoration** (free label / scale).
  freeDecoration(0x8f, 'Decoration', ViObjectKind.decoration, ClassConfidence.inferred),

  /// `0xE7` — a **graph legend / cursor** decoration.
  graphLegend(0xe7, 'Graph legend', ViObjectKind.decoration, ClassConfidence.inferred),

  /// `0xD2` — a legend **inner part**.
  legendSubPart(0xd2, 'Legend sub-part', ViObjectKind.decoration, ClassConfidence.inferred),

  /// `0x58` — rare; appears only as a parent of `0x0C`.
  rare58(0x58, 'Undetermined (0x58)', ViObjectKind.unknown, ClassConfidence.kindOnly),

  /// `0xC3` — a rare structure (parents `0xC7`/`0x57`).
  rareStructureC3(0xc3, 'Structure (rare 0xC3)', ViObjectKind.structure, ClassConfidence.kindOnly),

  /// `0xC8` — rare; appears as a parent of `0x0C`/`0x0B`.
  rareC8(0xc8, 'Undetermined (0xC8)', ViObjectKind.unknown, ClassConfidence.kindOnly),

  /// `0x56` — a rare control terminal (child profile = label + chrome +
  /// connector, like the other control terminals).
  controlRare56(0x56, 'Control (rare 0x56)', ViObjectKind.terminal, ClassConfidence.kindOnly),

  /// A class code that is not (yet) catalogued. Its [code] is -1; use
  /// [ViHeapObject.kind] for the actual value.
  unknown(-1, 'Unknown class', ViObjectKind.unknown, ClassConfidence.kindOnly)
  ;

  const HeapObjectClass(this.code, this.label, this.category, this.confidence);

  /// The class-code byte (the `<kind>` field); -1 for [unknown].
  final int code;

  /// A human-readable name for UI display.
  final String label;

  /// The coarse structural category this class maps to.
  final ViObjectKind category;

  /// How well-grounded [label] is (clean-room honesty).
  final ClassConfidence confidence;

  static final Map<int, HeapObjectClass> _byCode = {
    for (final objectClass in values)
      if (objectClass != unknown) objectClass.code: objectClass,
  };

  /// Maps a raw class code to its [HeapObjectClass], or [unknown].
  static HeapObjectClass fromCode(int code) => _byCode[code] ?? unknown;
}

/// The control/indicator terminal class codes (front-panel controls' diagram
/// footprint). Single source of truth.
const kControlTerminalCodes = {0x50, 0x4f, 0x57, 0x5b, 0x51};

/// The block-diagram **wire-endpoint DCO** class codes — the bounds-less
/// data-connection objects a signal's `14 19` childRefs bind (corpus: 902,107
/// endpoint refs across 7,524 VIs; `0x15` 862,159 / `0x16` 39,948; see
/// [HeapObjectClass.signal]). An endpoint's attach rectangle is resolved via
/// the terminal object that declares it a member —
/// [ViDiagram.endpointTerminalBounds], which owns the resolution census.
const kSignalEndpointDcoKinds = {kNodeEndpointDcoKind, 0x16 /* HeapObjectClass.bdLeaf */};

/// The **bounds-less node-endpoint DCO** class code (`0x15`) — the on-node
/// member of [kSignalEndpointDcoKinds] (its sibling is the bounded
/// free-standing `0x16` [HeapObjectClass.bdLeaf]). It carries no bounds of its
/// own; when it parents a `0x13` constant it is how a wired block-diagram
/// constant attaches to a signal (see [ViDiagram.endpointConstant]).
const int kNodeEndpointDcoKind = 0x15;

/// Heap object class ([ViHeapObject.kind]) of the **right shift-register
/// terminal** — the stacked output column on a loop's right edge (glyph
/// [ViHeapObject.termBmp] 4). Its stored-route wire connection column sits
/// [kShiftRegisterColumnLeftOffset] px LEFT of its attach-rect centre — the one
/// measured attach-point exception ([ViDiagram.wireAttachPoint] /
/// [ViDiagram._attachPointFrom]).
const int kRightShiftRegisterClass = 0x28;

/// Heap object class ([ViHeapObject.kind]) of the **left shift-register
/// terminal** — the input column on a loop's left edge (glyph
/// [ViHeapObject.termBmp] 3). Its stored-route wire connection column sits
/// [kShiftRegisterColumnRightOffset] px RIGHT of its attach-rect centre — the
/// mirror of the right register's [kShiftRegisterColumnLeftOffset]: both
/// registers connect one column toward the loop interior.
const int kLeftShiftRegisterClass = 0x27;

/// Pixels the right shift register's ([kRightShiftRegisterClass]) drawn wire
/// connection column sits LEFT of its attach-rect centre. Measured against
/// LabVIEW's own snippet renders: every x-testable routed walk from a right
/// shift-register endpoint (4 walks across 3 distinct VIs — ClassChildren, the
/// crc8/crc16 pair, crc32) lands its full interior leg on reference ink at
/// exactly `centre.x - 4` (support >= 0.96; the plain centre column scores
/// <= 0.03), pinned by `wire_one_anchored_oracle`.
const int kShiftRegisterColumnLeftOffset = 4;

/// Pixels the left shift register's ([kLeftShiftRegisterClass]) drawn wire
/// connection column sits RIGHT of its attach-rect centre — the mirror of
/// [kShiftRegisterColumnLeftOffset] (both registers connect one column toward
/// the loop interior). Measured against LabVIEW's own render of the MD5
/// snippet, whose nested loops carry eight branching routes anchored on
/// left-register terminals (16x12 rects): every walk placed at `centre.x + 4`
/// lands its bend columns and junction dots on the reference ink exactly, and
/// four of the trees additionally close ZERO-SLACK onto both far endpoints'
/// independently decoded attach points (which the plain centre misses by
/// exactly 4 px, the contradiction that withheld them).
const int kShiftRegisterColumnRightOffset = 4;

/// Heap object classes ([ViHeapObject.kind]) of the **node terminal strips** —
/// the termBounds-carrying rows and full-height columns an expandable node
/// draws its terminals in: `0x62` under the growable nodes (`0x63`, `0xd6`),
/// `0x35` under the `0x34` nodes. Strips come in two shapes: wide rows and the
/// [kTerminalStripColumnWidth]-px **columns**, whose stored-route DESTINATION
/// convention differs from the plain floored centre (see
/// [kTerminalStripTargetLeftOffset]).
const kNodeTerminalStripClasses = {0x62, 0x35};

/// Width (px) of a node terminal strip **column** — the full-height terminal
/// column of an expandable node ([kNodeTerminalStripClasses]). Corpus: 6,683
/// width-8 strips (5,024 `0x62` + 1,659 `0x35`) against row strips of widths
/// 11-99; only the width-8 columns carry the destination-column route
/// convention ([kTerminalStripTargetLeftOffset]).
const int kTerminalStripColumnWidth = 8;

/// Pixels a stored route's **destination point** on a node terminal strip
/// COLUMN ([kNodeTerminalStripClasses], width [kTerminalStripColumnWidth])
/// sits LEFT of the column rect's floored centre — i.e. 4 px left of the
/// rect's left edge, where the wire's drawn run stops at the column's
/// separator. Role-split convention, censused corpus-wide (7,524 VIs, pinned
/// by `wire_route_census_test`):
///
///  * routes **terminating on** a width-8 strip land at `centre.x - 8`
///    essentially unanimously — every near miss under the centre convention
///    (2,755 two-endpoint closings + 1,210 branch-tree leaves) sits at
///    exactly `(-8, 0)` across all four approach directions (34 more land
///    far — stale-route residue), while the centre cross-axis-closes exactly
///    1 two-endpoint route and 0 branch leaves corpus-wide;
///  * routes **originating from** one anchor at the plain floored CENTRE
///    (4,033 closed two-endpoint ships + 211 shipped trees), so
///    [ViDiagram.wireAttachPoint] is unchanged and the offset applies only to
///    the closure-arbitrated destination candidate
///    ([ViDiagram._stripFarTarget]).
const int kTerminalStripTargetLeftOffset = 8;

/// Object-flags ([ViHeapObject.objFlags]) bit marking a structure terminal's
/// glyph **hidden** in LabVIEW's block-diagram render. It rides the terminal's
/// DCO, not the terminal itself; [ViDiagram.terminalGlyphHidden] owns the
/// render verification and the corpus census.
const int kTerminalGlyphHiddenFlag = 0x800000;

/// Attribute id bytes `buildDiagram` surfaces onto [ViHeapObject] (a fast
/// pre-filter on the record's second byte before the heavier `decodeHeapAttr`):
/// 0x20/0x21 catch the `C6` control-range f64s (raw tags 0x220/0x221,
/// stdNumMin/stdNumMax), 0x6c the `C6 6C FF` constant-value text (raw 0x26C).
/// (0x31 names were dropped — they sit on non-drawable structural objects.)
// Low bytes of the object-attribute raw tags the graph builder captures. The
// gate is a fast prefilter on `body[offset+1]` (the raw tag's low 8 bits);
// `decodeHeapAttr` disambiguates the full 10-bit tag, so a low-byte collision
// (e.g. 0x19 shared by structColor 0x119 and any 0xN19) is harmless — the
// capture switch acts only on the exact decoded [HeapAttribute]. 0x19/0x2b are
// the structColor/borderColor low bytes.
// 0x29 also catches termBounds 0x129; 0x28 (already present for
// backgroundColor 0x028) catches termBMPs 0x128. 0xea is primResID (raws
// 0x1EA/0x2EA are uncatalogued today and decode to [HeapAttribute.unknown],
// which no capture below acts on — recheck this gate if one is catalogued).
// 0xe7 is the compressedWireTable container (capture gated to signal 0x17).
// 0x4d is dIdx (gated to the multi-frame structure kinds; raws 0x14d/0x24d
// are uncatalogued today and decode to [HeapAttribute.unknown], which no
// capture acts on — recheck this gate if one is catalogued).
// 0x9f is lastSignalKind, the wire-type word (gated to signal 0x17; raws
// 0x19f/0x29f are uncatalogued today and decode to [HeapAttribute.unknown],
// which no capture acts on — recheck this gate if one is catalogued).
// 0x22 is shortText (raw 0x022), the scalar-width caption; raw 0x122 is
// uncatalogued today ([HeapAttribute.unknown], no capture acts on it —
// recheck this gate if it is catalogued) and raw 0x222 is the stdNumInc f64,
// which no capture acts on.
const _objAttrIds = {
  0x20, 0x21, 0x6c, 0x24, 0x28, 0x6f, 0x19, 0x2b, 0x2a, 0x29, 0x3a, 0xcb, 0xea, 0xe7, 0x4d, 0x9f, 0x22, 0x74, //
};

/// The structure classes that stack multiple `0x1b` frames and display one —
/// case [HeapObjectClass.bdStructureFrame] `0x2c`, disable
/// [HeapObjectClass.bdDisableStructure] `0xcd`, event
/// [HeapObjectClass.bdEventStructure] `0xd5`, stacked sequence
/// [HeapObjectClass.bdStackedSequence] `0x29`. Flat sequences are a
/// different class (`0xca`, with `0x121` subframes, all drawn side by side)
/// and never enter this set. The displayed frame comes from
/// [ViHeapObject.visibleFrameIndex], which owns the corpus census.
const kMultiFrameStructureKinds = {0x2c, 0xcd, 0xd5, 0x29};

/// Pixel-area threshold (width×height) for the structural node fallback in
/// `buildDiagram`. A still-`unknown` object that otherwise matches the BD-node
/// signature (drawable, parented to the node container `0x1b`, holding the
/// structural `0x15` records, no `0x68` connector child) is reclassified as a
/// node — but only below this cap, so a rare large unknown object (a possible
/// structure body) stays a faint placeholder rather than a big node box. The
/// fallback classifies ~1953 objects across ~22 low-frequency kinds without
/// enumerating each.
const int _structureAreaCap = 20000;

String _fmtNum(double v) => v == v.roundToDouble() && v.abs() < 1e15 ? v.toInt().toString() : v.toString();

/// A human-readable range string for a control's decoded [min]/[max], or null
/// when there is nothing meaningful to show. Honest: a NaN in either slot means
/// the pair is uninitialized/untrustworthy (corpus: a NaN max paired with a
/// 0/-0.0 min was ~60% of "ranges" — decode noise), so the whole range is
/// suppressed. Otherwise it uses only **finite** bounds (a `±∞` sentinel =
/// "no bound" and an absent bound are both omitted), drops an inverted *or
/// degenerate* finite pair (`lo >= hi`, so `5 … 5` / `0 … -0.0` read as noise
/// rather than a real range), and renders a one-sided bound as `≥ x` / `≤ x`.
String? formatControlRange(double? min, double? max) {
  if (min?.isNaN == true || max?.isNaN == true) return null;
  final lo = (min != null && min.isFinite) ? min : null;
  final hi = (max != null && max.isFinite) ? max : null;
  if (lo == null && hi == null) return null;
  if (lo != null && hi != null) return lo >= hi ? null : '${_fmtNum(lo)} … ${_fmtNum(hi)}';
  return lo != null ? '≥ ${_fmtNum(lo)}' : '≤ ${_fmtNum(hi!)}';
}

/// Strips LabVIEW help **markup tags** (`<B>`/`<I>`/`<U>` and their closers, etc.)
/// from decoded [descriptionText] for *display only* — the raw decode stays
/// verbatim, this is presentation. ~90% of corpus help text is wrapped in these
/// tags (e.g. `<B>error out</B> contains…`), which would otherwise show literally
/// in the details card / tooltip. The regex also matches a bare angle-bracket
/// *token* like `<register>` (its body is letters), so removing an inline tag can
/// leave a run of spaces, and a help string that IS just such a token would strip
/// to nothing — so we collapse interior space runs (newlines preserved) and FALL
/// BACK to the raw text when stripping empties a non-empty input (the token was
/// real data, not markup). A math expression like `a < 5 > 0` is left untouched
/// (digit/space bodies don't match). Returns the trimmed result.
String stripHelpMarkup(String helpText) {
  final out = helpText.replaceAll(_helpMarkupTag, '').replaceAll(_interiorSpaces, ' ').trim();
  return out.isEmpty ? helpText.trim() : out;
}

final RegExp _helpMarkupTag = RegExp(r'<\s*/?\s*[A-Za-z][A-Za-z0-9]*\s*>');
final RegExp _interiorSpaces = RegExp(r'[ \t]{2,}');

/// Classifies a heap object into a [ViObjectKind] from its class code and signals
/// (corpus-validated; see the [HeapObjectClass] catalog). The data-driven
/// terminal-cluster signal (`C4 1F` terminals) takes precedence over the class's
/// catalog [HeapObjectClass.category].
ViObjectKind classifyObject({required int kind, required int termCount}) {
  if (kind == 0x0c || termCount >= 1) return ViObjectKind.terminalCluster;
  return HeapObjectClass.fromCode(kind).category;
}

/// The printf integer-conversion chars (`b` `d` `o` `x` `X`) that mark a numeric
/// format as integer rather than float. See [inferTypeKind].
const _intConvChars = {0x62, 0x64, 0x6f, 0x78, 0x58};

/// The printf conversion char of a `C4 74` numeric format-string payload, or null.
int? _formatConvChar(List<int> payload) {
  final pct = payload.indexOf(0x25);
  if (pct < 0) return null;
  for (final byte in payload.skip(pct + 1)) {
    if ((byte >= 0x41 && byte <= 0x5a) || (byte >= 0x61 && byte <= 0x7a)) return byte;
  }
  return null;
}

/// Infers a [ViTypeKind] from the set of `C4` opcodes attached to an object plus
/// the numeric format payload (if any). Payload-grounded.
ViTypeKind inferTypeKind(Set<int> c4ops, List<int>? formatPayload) {
  if (c4ops.contains(0xc4)) return ViTypeKind.clnNode;
  if (c4ops.contains(0xa4)) return ViTypeKind.path;
  if (c4ops.contains(0x2e)) return ViTypeKind.enumRing;
  if (c4ops.contains(0x74)) {
    final conv = formatPayload == null ? null : _formatConvChar(formatPayload);
    return (conv != null && _intConvChars.contains(conv)) ? ViTypeKind.numericInt : ViTypeKind.numericFloat;
  }
  return ViTypeKind.unknown;
}

/// A signal's decoded **wire-type word** — the value of the per-signal
/// [HeapAttribute.lastSignalKind] record (raw `0x09f`), which encodes the
/// datatype LabVIEW last routed/coloured the wire as. Carried by 428,029 of
/// the corpus's 428,043 signals (14 record-less). Layout (u16):
///
///   `[bits 12-15: flags] [bits 8-11: structural depth] [bits 0-7: type code]`
///
/// * **type code** (low byte) — the wire's scalar/element type in the VCTP
///   [TypeCode] space ([dataType]): `0x03` i32, `0x21` boolean, `0x30`
///   string, `0x32` path, `0x50` cluster, `0x70` refnum, … The code is the
///   **flattened element** type: an array-of-X wire carries X's code (the
///   array-ness lives in the depth field), an enum wire carries its
///   underlying integer code (`0x15..0x17` never appear), a typedef wire its
///   resolved base code, a substring wire the plain string code. Two codes
///   are wire-word-only (absent from VCTP descriptors), both family
///   variants: [clusterVariantCode] `0x51` and [typedRefnumCode] `0x71`.
///   Corpus census (all decoded signals): 28 distinct codes; 0x50 124,068 /
///   0x30 86,254 / 0x70 60,771 / 0x21 38,168 / 0x03 33,591 / 0x32 13,994 /
///   …; only `0xff` (519) and `0x74` (18) resolve no catalogued type.
/// * **depth** (bits 8-11) — the type's structural depth: a per-family
///   scalar base (**1** numeric/enum/boolean, **2** string/path/picture,
///   **3** cluster/variant/waveform) **plus one per array dimension** — so
///   i32 = 1, array-of-i32 = 2, 2D-array-of-string = 4 (2+2),
///   array-of-cluster = 4. Corpus range 1..6 (1: 138,606 / 2: 102,054 /
///   3: 168,343 / 4: 14,453 / 5: 4,384 / 6: 189; 0 outside). Refnum wires
///   have **no fixed base** (observed 1..6): a refnum embedding an inner
///   type (queue/notifier/DVR/event-registration) rides deeper with that
///   type, so [arrayDims] stays null for the refnum codes.
/// * **flags** (bits 12-15) — only `0x4` and `0x8` observed (0x0 204,394 /
///   0x8 148,758 / 0x4 65,604 / 0xc 9,273; bits 12-13 zero corpus-wide);
///   they vary freely within one type and their meaning is not decoded
///   (TODO: pin the two flag bits' semantics).
///
/// Validation (7,524-VI corpus; every figure below is pinned by the
/// `signal_types` snapshot section, owned by `signal_type_census_test.dart`):
/// against the 144,668 signals whose endpoints carry an unambiguous
/// VCTP-resolved type family (the oracle), the family predicted from this
/// word agrees **89.9%** overall — per oracle family: string 95.6%,
/// cluster 94.9%, refnum 93.4%, path 90.2%, int 88.8%, bool 86.0%, float
/// 83.5%, array 76.4% — plus the 1,474 enum-labeled wires reading as int
/// **by design** (the flatten above; 94.4% land exactly there).
///
/// The 14,657 disagreements are **partitioned by measured cause**
/// (`miss_<family>_element/nearby/other`):
///
/// * 34.0% (4,986) are *element-matches* — the word names the endpoint
///   array's ELEMENT family (or an array OF the endpoint's scalar family):
///   the loop-boundary/indexing-tunnel signature, where the typed endpoint
///   sits on the array side of the boundary the wire crosses. This
///   explains 81% (4,663/5,757) of the array row's misses.
/// * 0.0% (exactly 0) are explained by a different-family type elsewhere
///   in the endpoint neighbourhood — the ancestors/terminals beyond the
///   first typed object carry no second resolved type, so "the oracle
///   picked an adjacent object's type" is measured OFF the table.
/// * 66.0% (9,671 = 6.7% of all labeled wires) are an **unexplained
///   residual**, largest on bool (14.0% of its labeled wires) and float
///   (16.2%), smallest on string (4.2%) and array (4.5%). Whether the
///   word or the oracle is wrong in these is not attributable with the
///   decoded evidence; no family is gated to null over it — instead the
///   value is surfaced as an estimate with this census as its error bar,
///   and [ViWire.typeKind] documents the recommended precedence (a typed
///   terminal outranks the word).
///
/// Array-dimension agreement ([arrayDims] vs the exact VCTP dim count, on
/// wires whose element families agree so arrayness mismatches stay
/// visible): 0 dims 99.7% (94,756), 1D 85.7% (14,745), 2D 87.3% (1,203),
/// 3D 23/40. 98.8% of all corpus signals resolve a non-null [typeKind].
///
/// Rejected per-signal type carriers, measured on the same labeled set
/// (majority-family purity, pinned as `ruledOut*`): signalState `0x115`
/// 28.4% (146,142 records), the scalar `0x1e7` wire-table forms 33.8%
/// (97,885), the signal's objFlags 50.0% (3,348) — versus this word's
/// 89.9%; none of them is a type field.
class ViSignalType {
  const ViSignalType(this.raw);

  /// The raw u16 record value.
  final int raw;

  /// `0x51` — a wire-word-only **cluster-family** code. Corpus carriers
  /// (9,038 signals) are typedef'd / class-typed clusters (endpoint type
  /// names like `Class info`, `Coords`, object-oriented class wires), while
  /// plain and error clusters ride `0x50`; the exact 0x50/0x51 distinction
  /// is not pinned (TODO), but the family is: oracle carriers resolve to
  /// cluster/typedef descriptors, not to any other family.
  static const int clusterVariantCode = 0x51;

  /// `0x71` — a wire-word-only **refnum-family** code. Corpus carriers
  /// (5,702 signals) are refnums embedding an inner data type — endpoint
  /// names like `queue out`, `notifier out`, `data value reference` — where
  /// plain references (VI refs, occurrences, files) ride `0x70`; the split
  /// is consistent with inner-typed vs plain refnums but not pinned (TODO).
  static const int typedRefnumCode = 0x71;

  /// The scalar/element type code (low byte), in the VCTP [TypeCode] space
  /// plus the two wire-word-only codes above.
  int get typeCode => raw & 0xff;

  /// The structural depth (bits 8-11): the element family's scalar base
  /// (see the class doc) plus one per array dimension. Corpus range 1..6.
  int get depth => (raw >> 8) & 0xf;

  /// The flag nibble (bits 12-15): only `0x0/0x4/0x8/0xc` observed;
  /// meaning not decoded.
  int get flags => (raw >> 12) & 0xf;

  /// The wire's scalar/element datatype: [typeCode] resolved through the
  /// VCTP catalogue ([dataTypeOfCode]), with the two wire-word-only codes
  /// mapped to their families ([clusterVariantCode] → cluster,
  /// [typedRefnumCode] → refnum). Null for uncatalogued codes (`0xff`,
  /// `0x74`: 537 of 428k corpus signals). Enum/typedef/substring wires
  /// carry their flattened code, so those kinds never surface here.
  ViDataType? get dataType => switch (typeCode) {
    clusterVariantCode => ViDataType.cluster,
    typedRefnumCode => ViDataType.refnum,
    _ => dataTypeOfCode(typeCode),
  };

  /// The scalar/element type family of the wire, or null when [dataType]
  /// is missing or has no [ViTypeKind] rendering (tag `0x37`, picture
  /// `0x33`, variant `0x53`, waveform `0x54`, void `0x00`).
  ViTypeKind? get elementKind {
    final t = dataType;
    return t == null ? null : _typeKindOf(t);
  }

  /// The wire's array dimension count: [depth] minus the element family's
  /// corpus-pinned scalar base — 0 for a scalar wire, 1 for `array of X`,
  /// 2 for a 2D array. Null when the base is unknown for [typeCode]: the
  /// refnum codes (their depth rides the referenced inner type), the
  /// uncatalogued codes, and the never-observed-below-base combinations
  /// (kept null rather than clamped, so a contradiction is visible).
  int? get arrayDims {
    final base = _signalScalarDepth(typeCode);
    if (base == null) return null;
    final dims = depth - base;
    return dims < 0 ? null : dims;
  }

  /// Whether the wire carries an array — or **null when undecidable**
  /// ([arrayDims] null: the refnum codes and the uncatalogued codes), kept
  /// tristate so an array-of-refnum wire reads as *unknown* array-ness
  /// rather than a fabricated false.
  bool? get isArray {
    final dims = arrayDims;
    return dims == null ? null : dims > 0;
  }

  /// The wire-level type family: [ViTypeKind.array] when [isArray] is
  /// true, else the [elementKind]. Null when the element family is
  /// unresolved. Note the collapse: a renderer needs [elementKind] (LabVIEW
  /// colours an array wire by its ELEMENT type) plus [arrayDims] (stroke
  /// width), not this value alone; and a refnum wire reads as refnum here
  /// even when the underlying type is an array of refnums ([isArray] null,
  /// never false, in that case — the depth base is inner-type-dependent).
  ViTypeKind? get typeKind => isArray == true ? ViTypeKind.array : elementKind;

  /// Value equality on the raw word (the only state).
  @override
  bool operator ==(Object other) => other is ViSignalType && other.raw == raw;

  @override
  int get hashCode => raw.hashCode;
}

/// The corpus-pinned scalar depth base of a signal type code (see
/// [ViSignalType.depth]): the depth a non-array wire of that family carries.
/// Null for the refnum codes (depth varies 1..6 with the referenced inner
/// type) and for codes never censused in the wire-type word — including the
/// packed-string codes `0x34`/`0x35`/`0x3f`, which appear 0 times corpus-wide
/// (substring wires flatten to the plain `0x30`), so no scalar base is
/// derivable for them. Callers treat null as "array-ness undecidable",
/// never as scalar.
int? _signalScalarDepth(int code) {
  if (code >= TypeCode.i8 && code <= TypeCode.complexExt) return 1;
  if (code >= TypeCode.enumU8 && code <= TypeCode.enumU32) return 1;
  if (code == TypeCode.booleanU16 || code == TypeCode.boolean) return 1;
  if (code == TypeCode.string || code == TypeCode.path || code == TypeCode.picture) return 2;
  if (code == TypeCode.cluster ||
      code == ViSignalType.clusterVariantCode ||
      code == TypeCode.variant ||
      code == TypeCode.measureData) {
    return 3;
  }
  return null;
}

/// A recovered block-diagram **dataflow wire** — a LabVIEW *signal*
/// ([HeapObjectClass.signal], class `0x17`), the logical connection drawn
/// between terminals.
///
/// Unlike the visual [HeapObjectClass.bdWire] `0x1d` segments (Manhattan-run
/// geometry with no oid endpoints), a signal carries **oid endpoint binding**:
/// [endpointOids] are the data-connection objects it joins (`14 19` childRefs;
/// resolving 100% within the BD heap corpus-wide, 91% of signals holding two =
/// source + sink). Each endpoint is resolved to an [endpointAnchor] — the
/// absolute bounds of the endpoint's nearest bounded owner (the node or wire
/// segment it attaches to; 100% have one) — so a consumer can route the wire
/// between anchors. [endpointOids] and [endpointAnchors] are index-aligned; an
/// anchor is null only if that endpoint oid does not resolve (0% corpus-wide).
/// Where the endpoint is a structure tunnel / border terminal, the exact
/// attach rectangle is also decoded — [endpointAttachRects].
///
/// The wire's **datatype** is decoded from the signal's own
/// [HeapAttribute.lastSignalKind] record — [signalType] / [typeKind] (see
/// [ViSignalType] for the byte layout and the corpus validation). The
/// per-object [HeapAttribute.typeDescIndex] route was refuted instead: the
/// index reachable from ~8.7% of signals (via an endpoint's `14 4f` dcoRef)
/// is an object ordinal that agrees across a signal's endpoints in 0.0% of
/// cases, so it cannot identify a shared wire type.
/// The confidence tier of a shipped wire route ([ViWire.routePoints] /
/// [ViWire.routeTree]).
enum WireRouteFidelity {
  /// **Closure-proven**: every endpoint resolved an attach point and the walk
  /// closed with zero slack (two-endpoint) / every leaf landed on an endpoint
  /// (branching). The geometry is pinned at both ends against independently
  /// decoded attach rects.
  closed,

  /// **Walk-derived**: LabVIEW's stored route table decoded and placed from a
  /// SINGLE anchored endpoint — ink-validated against the reference render
  /// (`wire_one_anchored_oracle`) but NOT closure-verified. A two-endpoint
  /// walk snaps the far plain-node terminus onto its owner box edge (the exact
  /// terminal pin within a multi-terminal node is not independently confirmed);
  /// a branching walk takes plain-node leaves from the walk itself — a
  /// reverse-solved branching tree ([ViWire.routeTree]) additionally derives
  /// its plain-node ORIGIN from the resolved-endpoint closure. A consumer
  /// may render this identically to [closed] but MUST NOT treat it as proven.
  walked,
}

class ViWire {
  ViWire({
    required this.signalOid,
    required this.endpointOids,
    required this.endpointAnchors,
    List<HeapRect?>? endpointAttachRects,
    this.route,
    this.routePoints,
    this.routePointsFidelity,
    this.routeClosingStep,
    this.routeHeadSlack,
    this.branchRoute,
    ViWireRouteTree? routeTree,
    WireRouteFidelity? routeTreeFidelity,
    ({ViWireRouteTree tree, WireRouteFidelity fidelity})? Function()? routeTreeBuilder,
    this.signalType,
  }) : endpointAttachRects = endpointAttachRects ?? List<HeapRect?>.filled(endpointOids.length, null),
       _routeTree = routeTree,
       _directRouteTreeFidelity = routeTreeFidelity,
       _routeTreeBuilder = routeTreeBuilder;

  final ViWireRouteTree? _routeTree;
  final WireRouteFidelity? _directRouteTreeFidelity;
  final ({ViWireRouteTree tree, WireRouteFidelity fidelity})? Function()? _routeTreeBuilder;

  /// The [ViHeapObject.oid] of the signal (`0x17`) object this wire is.
  final int signalOid;

  /// The oids of the endpoint data-connection objects the signal joins (its
  /// `14 19` childRefs), in heap order. Two for 91% of signals (source + sink);
  /// three or more where the signal branches. Direction (which endpoint is the
  /// source) is not recovered, so the order is not asserted to be source-first.
  final List<int> endpointOids;

  /// The absolute bounds anchoring each endpoint — the constant value shell
  /// where the endpoint wraps a drawn block-diagram constant
  /// ([ViDiagram.endpointConstantBounds]: the box LabVIEW draws, e.g. a for
  /// loop's count feeder), else the [ViHeapObject.absBounds] of the
  /// endpoint's nearest bounded owner (itself or a positional ancestor: the
  /// node or `0x1d` wire segment it attaches to — for a constant endpoint
  /// that owner is a degenerate zero-area segment, which is why the shell
  /// takes precedence). Index-aligned with [endpointOids]; an entry is null
  /// only when the endpoint oid does not resolve (not observed in the
  /// corpus).
  final List<HeapRect?> endpointAnchors;

  /// The **attach rectangle** of each endpoint in absolute diagram
  /// coordinates — the structure tunnel square / shift-register box /
  /// selector glyph the wire visually connects to, or the value shell of a
  /// wired block-diagram constant — index-aligned with [endpointOids].
  /// Structure-framed rects are border-exact; node-framed (growable-node
  /// terminal) rects are approximate. Null where the endpoint has neither a
  /// termBounds-carrying terminal (a plain node's connection point) nor a
  /// bounded constant shell, or the file predates the frame-relative
  /// coordinate space; the coarse [endpointAnchors] owner rect still locates
  /// those. Decoded by [ViDiagram.endpointTerminalBounds] /
  /// [ViDiagram.endpointConstantBounds], which own the corpus censuses;
  /// defaults to all-null when constructed without a list (external callers
  /// re-deriving anchors keep their alignment guarantee).
  final List<HeapRect?> endpointAttachRects;

  /// The decoded stored route shape of a **two-endpoint** signal (see
  /// [ViWireRoute] / [decodeWireRoute]), or null when the signal carries no
  /// table record or the table is the extended multi-endpoint branching
  /// form ([branchRoute]).
  final ViWireRoute? route;

  /// The decoded stored route program of a **3+-endpoint (branching)**
  /// signal (see [ViWireBranchRoute] / [decodeWireBranchRoute]), or null
  /// when the signal has fewer than three endpoints, carries no table
  /// record, or the table is not the extended form. The unanchored analog
  /// of [route]; the anchored, leaf-closed absolute geometry is [routeTree].
  final ViWireBranchRoute? branchRoute;

  /// The wire's **absolute stored route tree** in diagram coordinates — the
  /// branching Manhattan geometry LabVIEW saved, polyline runs plus
  /// junction-dot points — or null when it is not shippable. Four tiers
  /// (endpoint matching always tries each endpoint's destination candidates:
  /// the terminal-strip column target first, then the attach centre, then
  /// the array element centre — see [kTerminalStripTargetLeftOffset]):
  ///
  ///  * **closed** — endpoint 0's attach point resolves
  ///    ([ViDiagram.wireAttachPoint]), every other endpoint resolves too, and
  ///    the walked [ViWireRouteTree.leaves] land on endpoints `1..n-1` in a
  ///    one-to-one zero-slack matching. The proven tier.
  ///  * **walked** — walked from a resolved endpoint-0 attach point, but some
  ///    endpoints are plain-node DCOs that resolve no attach geometry (a
  ///    primitive input/output, a subVI terminal), so their absolute position
  ///    is taken from the walked leaf. Every endpoint that DOES resolve must
  ///    still land on a distinct leaf: a resolved endpoint the walk misses is
  ///    a **contradiction** (the walk drifted) and ships null. This is the
  ///    origin-anchored, contradiction-free relaxation of the closed gate.
  ///  * **reverse-solved** (also reported [WireRouteFidelity.walked]) — the
  ///    ORIGIN is a plain-node DCO, so the tree's translation is solved from
  ///    the resolved far endpoints instead: ships only when exactly one
  ///    candidate translation closes every resolved endpoint AND lands the
  ///    implied origin inside the head endpoint's owner box
  ///    ([ViDiagram._reverseSolvedRouteTree]).
  ///  * **DCO-child closed** (reported [WireRouteFidelity.closed]) —
  ///    consulted only after the gates above declined, for an unanchored
  ///    origin: endpoints with no standard attach substitute their
  ///    [ViDiagram.dcoChildTerminalAttach] candidates and EVERY endpoint
  ///    must close zero-slack onto a distinct leaf — the branching analog
  ///    of [routePoints]' DCO-child closed tier
  ///    ([ViDiagram._dcoChildRouteTree]).
  ///
  /// Nothing is force-closed: a contradiction or a leaf-count mismatch ships
  /// null and the census counts it. Computed lazily on first access (a
  /// renderer's cost, not every [ViDiagram.wires] build).
  ///
  /// **What each gate proves.** The shipping gate proves the LEAF endpoints
  /// only — the interior bends and the junction-dot positions are decoded
  /// from the stored mode/length stream, not re-derived from an endpoint,
  /// so they are corroborated separately (below), not closed. The doc on
  /// [WireRouteJunction] carries the branch axis/sign rule and its two
  /// thin-support choices.
  ///
  /// Corpus census (7,524 VIs; 35,968 extended tables on 3+-endpoint
  /// signals, pinned by `wire_route_census_test`): every table decodes and
  /// walks. Closure is gated by attach-point exactness, not the walk rule:
  /// over the 18,233 anchored non-origin endpoints, 17,529 (96.14%) land
  /// exactly on a destination candidate (`extEpHit`); restricted to the
  /// **13,932 endpoints whose own AND origin
  /// attach geometry are exact** (structure-framed border rect via the real
  /// composing frame, or a `0x16` own-bounds box — NOT the approximate
  /// node-framed rects or the constant value-shell centres, whose attach
  /// point is the drawn edge, not the box centre), **13,920 (99.91%) land
  /// exactly** — the once-dominant in-rect miss class
  /// (`extEpExactMissInRect`) emptied when the shift-register connection
  /// columns were decoded ([kShiftRegisterColumnLeftOffset] /
  /// [kShiftRegisterColumnRightOffset]), leaving 12 (`extEpExactMissFar`)
  /// genuinely far.
  ///
  /// Corpus-wide the closed tier ships **2,421** trees (`extShippedClosed`);
  /// the walked tier adds **17,755** more (`extShippedWalked`) on the
  /// origin-anchored signals with plain-node leaves, the reverse-solved
  /// tier **8,950** more (`extShippedRev`) on the origin-unanchored ones,
  /// and the DCO-child closed tier **2,889** more (`extShippedDcoClosed`) —
  /// 32,015 of the 35,968 extended tables. The 3,953 unshipped remainder:
  /// origin-unanchored tables with no resolvable endpoint at all, plus
  /// the withheld contradictions/ambiguities on either side.
  ///
  /// Independent geometry check on well-registered snippets
  /// (`wire_one_anchored_oracle`, whose registration control discards snippets
  /// whose CLOSED-tier control overlay falls below 90%): shipped **closed**
  /// trees overlay LabVIEW's own render at ~100% (also `wire_branch_oracle`,
  /// 99.96%); shipped **walked** trees (reverse-solved included) overlay at
  /// **99.5%** (39,464/39,671 px, run pixels — the honest per-wire signal),
  /// with none below 50% (`oab_ship_qlo` = 0). The tree is DECODED LabVIEW
  /// geometry, not fabricated, and [routeTreeFidelity] carries the tier; a
  /// consumer needing closure-proven geometry reads that tier.
  late final ({ViWireRouteTree tree, WireRouteFidelity fidelity})? _routeTreeResult = _routeTreeBuilder?.call();
  late final ViWireRouteTree? routeTree = _routeTree ?? _routeTreeResult?.tree;

  /// The confidence tier of [routeTree] — [WireRouteFidelity.closed] when every
  /// endpoint resolved and closed, [WireRouteFidelity.walked] when the tree was
  /// placed from the origin alone or reverse-solved from the far endpoints
  /// (contradiction-free but not closure-proven) — or null when [routeTree] is
  /// null. A tree supplied directly (not built here) reports the fidelity its
  /// constructor passed, else null.
  late final WireRouteFidelity? routeTreeFidelity = routeTree == null
      ? null
      : (_routeTree != null ? _directRouteTreeFidelity : _routeTreeResult?.fidelity);

  /// The wire's **absolute stored polyline** in diagram coordinates — the
  /// Manhattan route LabVIEW saved — or null when it is not shippable. The
  /// signal must have exactly two endpoints and a decoding table; then three
  /// tiers:
  ///
  ///  * **closed** — both endpoints resolve an attach point
  ///    ([ViDiagram.wireAttachPoint]) and the walk **closes exactly**:
  ///    starting at the first endpoint's attach point and walking
  ///    [ViWireRoute.direction] + the stored signs/lengths, the implied final
  ///    segment lands on one of the second endpoint's destination candidates
  ///    dead-on (perpendicular coordinate equal, closing direction agreeing
  ///    with the stored final sign) — the terminal-strip column target where
  ///    one exists ([kTerminalStripTargetLeftOffset], tried first), else the
  ///    attach centre or an array element centre. Proven at both ends.
  ///  * **walked** — exactly one endpoint resolves an attach point and it is
  ///    an EXACT attach (a structure-framed terminal or an own-bounds leaf —
  ///    not a coarse owner box or off-centre constant shell); the far
  ///    endpoint is a plain-node DCO whose connection point is derived from
  ///    its owner box ([walkOneAnchoredRoute]). Ships forward walks and
  ///    reverse walks — a BENT reverse walk ships with the head's one
  ///    undecoded degree of freedom marked on [routeHeadSlack] — and only
  ///    when the derived closing run lands WITHIN the far box's span
  ///    (cross-axis containment) — a
  ///    terminus beside the node is a drifted/stale route and is withheld. The
  ///    far end is snapped to the owner box edge, so the exact terminal pin
  ///    inside a multi-terminal node is not independently verified; the walked
  ///    PATH is what the oracle validates. When the last decoded bend already
  ///    lies INSIDE the far box (the implied run enters the node rather than
  ///    reaching its edge), the polyline stops at that bend and
  ///    [routeClosingStep] carries the run's direction — the parse ships no
  ///    fabricated terminus at the node's undecoded input-pin depth.
  ///  * **DCO-child last resort** — consulted only after both tiers above
  ///    decline: an endpoint with no standard attach substitutes its
  ///    [ViDiagram.dcoChildTerminalAttach] candidates (the inverse
  ///    terminal-storage convention, where the `0x15` DCO parents its own
  ///    termBounds part). A zero-slack closure over the substituted pairs
  ///    ships as [WireRouteFidelity.closed] (`shippedClosedDcoChild`,
  ///    103,652 corpus routes); a wide-row cell anchor with no standard far
  ///    attach ships a one-anchored walk (`shippedWalkedDcoRow`, 2,705).
  ///    The standard attach rects/anchors the model exposes are untouched.
  ///
  /// Nothing is force-closed: a walk that misses, drifts out of the far box, or
  /// falls in an unshippable class returns null and the census counts it. The
  /// polyline carries [ViWireRoute.pointCount] points — one fewer when the
  /// closing/derived run is zero-length (the walk ends ON the far point; no
  /// duplicate vertex), EXCEPT a [routeHeadSlack] ship, which always carries
  /// its anchor as an explicit trailing point. Read [routePointsFidelity] to
  /// tell the tiers apart.
  ///
  /// Corpus census (7,524 VIs; pinned by `wire_route_census_test`): the
  /// standard closed tier ships **131,258** exact closures
  /// (`shippedClosed`). The one-anchored walked tier adds **71,155
  /// forward + 48,573 reverse = 119,728** more (`shippedWalkedFwd` +
  /// `shippedWalkedRev`); the reverse count includes the bent reverse
  /// walks shipped with [routeHeadSlack] marked, and the forward count
  /// includes **7,630 into-node closes** (`shippedWalkedIntoNode`) whose
  /// last decoded bend enters the far node INTERIOR and whose truncated
  /// polyline the consumer completes along [routeClosingStep]. The rest of
  /// the single-anchor population (`oneAnchorUnshipped`) stay withheld:
  /// coarse anchors, out-of-box termini,
  /// degenerate zero-segment into-node closes, and no-far-box. Independent
  /// quality check
  /// (`wire_one_anchored_oracle`, over the well-registered snippets its
  /// closed-tier registration control admits): shipped walked paths overlay
  /// LabVIEW's snippet ink at **99.7%** (39,763/39,870 px) with **zero** shipped
  /// wires below 50% overlay (`oa2_ship_qlo == 0`, a census law; the into-node
  /// ships are ALSO isolated as `oa2_into` with their own zero-gross-miss law,
  /// overlaying 100% — 2,568/2,568 px — on their own) — at the closed control's
  /// own **99%** snippet overlay. The withheld one-anchored walks overlay
  /// worse than the shipped ones (`oa2_held_*`, an oracle law — the miss
  /// that justifies withholding them); the
  /// slack ships are quality-bucketed apart (`oa2_slack_*`), their anchored
  /// closing row/column on ink but their perpendicular runs displaced by
  /// each head's unresolved terminal depth, and the DCO-child tier's ships
  /// apart again (`oa2_dcoclosed_*` / `oa2_dcorow_*` — their runs
  /// legitimately thread under node boxes, so raw overlay undercounts).
  /// The snippet
  /// overlay is a quality measure over the registrable subset; the corpus-wide
  /// ship counts are the structural-gate coverage.
  final List<ViPoint>? routePoints;

  /// The confidence tier of [routePoints] — [WireRouteFidelity.closed] when
  /// both endpoints closed with zero slack, [WireRouteFidelity.walked] when it
  /// was placed from a single exact anchor plus the stored table (ink-validated
  /// but not closure-verified; the far plain-node terminal pin is snapped to
  /// the owner box edge) — or null when [routePoints] is null.
  final WireRouteFidelity? routePointsFidelity;

  /// The unit direction of an **implied closing run into the far plain node**,
  /// when [routePoints]' last point is the final DECODED bend and the run that
  /// enters the node has an undecoded length (the node's input-pin depth) — a
  /// forward one-anchored walk whose last bend lies in the far box interior
  /// (see [walkOneAnchoredRoute]). Null for every other route: closed routes,
  /// reverse walks, and forward walks whose closing run reached the far box
  /// edge (already [routePoints]' last point — including a zero-length close).
  ///
  /// When non-null, [routePoints] is deliberately TRUNCATED short of the true
  /// endpoint (its last point is a bend inside the node, not the connection),
  /// and a consumer MUST complete the wire by extending from that point along
  /// this step to the node's drawn ink edge at the arrival row (the last
  /// point's cross-axis coordinate), where the wire visibly meets the icon —
  /// the parse ships no fabricated terminus at a guessed depth. A consumer that
  /// ignores this step draws the wire short of its node.
  final ViStep? routeClosingStep;

  /// The unit direction along which a **bent reverse walk's head must
  /// slide** — non-null only when [routePointsFidelity] is
  /// [WireRouteFidelity.walked], the walk was anchored at its SECOND
  /// endpoint, and the stored route bends. The head ([routePoints]' first
  /// point) is pinned at the far plain node's box edge, but LabVIEW measures
  /// the stored lengths from the node's TERMINAL — builtin geometry an
  /// undecoded depth INTERIOR to the box — so this step points from the
  /// pinned edge toward that interior. A consumer must translate every point
  /// except the final anchor along this step until the head lands on the
  /// node's terminal (the closing run onto the anchor absorbs the slide and
  /// only lengthens — a slide against this step, or one that would invert
  /// the closing run, means the resolved terminal is wrong); a slack ship
  /// always carries the anchor as an explicit trailing point, even when the
  /// stored closing run is zero-length, so the all-but-the-last-point
  /// contract needs no special casing. Drawing unresolved leaves the
  /// perpendicular runs off the drawn wire by the terminal depth. The parse
  /// ships no fabricated depth.
  final ViStep? routeHeadSlack;

  /// The wire's decoded type word ([HeapAttribute.lastSignalKind]) — element
  /// type code, array depth, flags — or null for the 14 corpus signals with
  /// no record. See [ViSignalType].
  final ViSignalType? signalType;

  /// The wire-level type family ([ViSignalType.typeKind]:
  /// [ViTypeKind.array] for array wires, else the element family), or null
  /// when the record is absent or its code unresolved.
  ///
  /// **This is an estimate.** Against endpoints with a VCTP-resolved type
  /// it agrees 89.9% overall — a resolved value disagrees with a typed
  /// endpoint roughly 1-in-10 — and worse on the weakest families (float
  /// 83.5%, bool 86.0%; array 76.4%, mostly the word naming the element
  /// across a loop boundary). The full measured census, including the
  /// disagreement partition, lives on [ViSignalType]. A renderer that has
  /// a typed terminal at an endpoint
  /// should let the terminal's resolved type OUTRANK this word for that
  /// wire; use this as the fallback for the majority of wires that touch no
  /// typed terminal. Null here means honest absence — deliberately unlike
  /// [ViHeapObject.typeKind]'s [ViTypeKind.unknown] sentinel, because a
  /// wire has exactly one record-backed source (absent record = no claim),
  /// where an object's kind is a fusion of signals that can merely fail to
  /// fire. For rendering, pair [elementTypeKind] (colour) with
  /// [ViSignalType.arrayDims] (stroke width) rather than this collapsed
  /// value.
  ViTypeKind? get typeKind => signalType?.typeKind;

  /// The wire's scalar/element type family ([ViSignalType.elementKind]) —
  /// what LabVIEW colours the wire by, arrays included — or null when the
  /// record is absent or its code unresolved.
  ViTypeKind? get elementTypeKind => signalType?.elementKind;
}

/// An absolute block-diagram point (LabVIEW diagram coordinates, y down).
typedef ViPoint = ({int x, int y});

/// A unit step along one diagram axis (exactly one of `dx`/`dy` is ±1, the
/// other 0) — the direction of a wire's implied **closing run into a plain
/// node** (see [ViWire.routeClosingStep] and [walkOneAnchoredRoute]).
typedef ViStep = ({int dx, int dy});

/// The **initial-direction code** of a stored wire route — the packed
/// `0x1e7` table's second byte, naming the axis AND sign of the route's
/// first segment. Corpus (7,524 VIs; 388,828 two-endpoint signal tables,
/// census pinned by `wire_route_census_test`): 387,786 decode under one of
/// these four one-hot codes — `right` 326,073 / `up` 27,372 / `down`
/// 27,120 / `left` 7,221 — plus 560 direction-less 1-point tables and 482
/// undecoded residue tables. `0x00` opens the extended multi-endpoint
/// (branching) form instead and appears on NO two-endpoint signal (a
/// pinned law).
enum WireRouteDirection {
  /// `0x01` — the first segment runs **up** (−y).
  up(0x01, 0, -1),

  /// `0x02` — the first segment runs **left** (−x).
  left(0x02, -1, 0),

  /// `0x04` — the first segment runs **down** (+y).
  down(0x04, 0, 1),

  /// `0x08` — the first segment runs **right** (+x) — the dominant code
  /// (LabVIEW dataflow runs left-to-right).
  right(0x08, 1, 0)
  ;

  const WireRouteDirection(this.code, this.dx, this.dy);

  /// The stored byte value.
  final int code;

  /// Unit x step of the first segment (−1, 0, +1).
  final int dx;

  /// Unit y step of the first segment (−1, 0, +1).
  final int dy;

  /// Whether the first segment runs along the x axis.
  bool get isHorizontal => dy == 0;

  /// The catalog entry for a stored direction byte, or null for any other
  /// value (the `0x00` extended-form opener included).
  static final Map<int, WireRouteDirection> _byCode = {
    for (final value in values) value.code: value,
  };

  static WireRouteDirection? fromCode(int code) => _byCode[code];
}

/// The decoded shape of a signal's stored wire route (its `0x1e7` packed
/// table): a Manhattan polyline of [pointCount] points whose segments
/// alternate axis. The stored fields split the polyline's degrees of
/// freedom exactly:
///
///  * [direction] — the first segment's axis and sign (the table's second
///    byte, see [WireRouteDirection]);
///  * [jointSigns] — the sign of every LATER segment (segments
///    `1..pointCount-2`; the axis alternates so only the sign is stored);
///  * [segmentLengths] — the unsigned length of every segment EXCEPT the
///    last (segments `0..pointCount-3`).
///
/// The one missing quantity — the final segment's length — is implied by
/// the destination: the route starts at the first endpoint's attach point
/// and the final segment closes onto the second endpoint's attach point
/// ([ViWire.routePoints] performs that closure and owns the corpus census;
/// the walked perpendicular must land exactly, so nothing is fabricated).
/// A 2-point route stores no signs/lengths (one implied straight segment);
/// a 1-point table (both endpoints on one spot) stores no direction byte.
///
/// Ground truth: the walked geometry reproduces LabVIEW's own render of
/// the `basic.png` snippet — its upper wire walks the terminal's attach
/// centre (74,9) → bend (102,9) → bend (102,21), matching the drawn bend
/// column measured at x=102-103 and the drawn add-input row y=21; the
/// lower wire mirrors it onto the y=31 input row. The corpus-wide proof is
/// the closure census on [ViWire.routePoints]: walked routes land on the
/// far endpoint's independently decoded attach rect with zero slack.
class ViWireRoute {
  /// [direction] defaults to [WireRouteDirection.right] — the dominant
  /// stored code — so constructions predating the field keep compiling;
  /// [decodeWireRoute] always passes the stored value explicitly.
  ViWireRoute({
    required this.pointCount,
    this.direction = WireRouteDirection.right,
    required this.segmentLengths,
    required this.jointSigns,
  });

  /// The stored route point count (the table's leading byte), including
  /// both endpoint attach points.
  final int pointCount;

  /// The first segment's direction, or null only for the 1-point table
  /// (which stores no direction byte).
  ///
  /// HAZARD for consumers written before this field existed: without it,
  /// [segmentLengths] / [jointSigns] are NOT a complete geometry — the
  /// first segment's axis and sign live here alone, so guessing them
  /// (e.g. aiming the first run at the sink) renders every
  /// up/left/down-first route wrong. That is no corner case: 61,713 of
  /// the 387,786 direction-bearing decoded two-endpoint corpus tables
  /// open with a non-`right` code.
  final WireRouteDirection? direction;

  /// Unsigned lengths of segments `0..pointCount-3` (every segment except
  /// the final closing one): `pointCount - 2` entries (empty for 1/2-point
  /// routes).
  final List<int> segmentLengths;

  /// Sign (+1 = down/right, −1 = up/left) of segments `1..pointCount-2`
  /// (every segment except the first, whose sign rides [direction]):
  /// `pointCount - 2` entries, index i = segment i+1. The LAST entry is the
  /// closing segment's stored sign — its length is implied but its
  /// direction is written, giving the closure an integrity check (moot for
  /// a zero-length closing run, which has no drawable direction; see
  /// [ViWire.routePoints]).
  final List<int> jointSigns;
}

/// Decodes a route table's length tail from [start]: one byte per segment,
/// with `FF` escaping a big-endian u16 in the next two bytes. Null on a
/// truncated escape.
List<int>? _decodeLengthTail(Uint8List table, int start) {
  var i = start;
  final lengths = <int>[];
  while (i < table.length) {
    var value = table[i++];
    if (value == 0xff) {
      if (i + 1 >= table.length) return null;
      value = (table[i] << 8) | table[i + 1];
      i += 2;
    }
    lengths.add(value);
  }
  return lengths;
}

/// Decodes a signal's packed `0x1e7` wire-table bytes into a [ViWireRoute].
///
/// Layout (corpus-validated, census pinned by `wire_route_census_test`):
/// `[u8 pointCount] [u8 direction] [(pointCount-2) sign bytes]
/// [(pointCount-2) length values]` where sign bytes are `00` (+, down/right)
/// or `01` (−, up/left), a length ≥ 255 is stored as `FF` + u16be, and
/// [direction] is a one-hot [WireRouteDirection] code. The 1-point table is
/// the single byte `01`; the 2-point table is `[02][direction]`.
///
/// Returns null (not decoded here) for:
///  * the extended `[n][00]…` **multi-endpoint branching form** (35,970
///    corpus tables, on non-two-endpoint signals only — census
///    `multiExtTable`), decoded by [decodeWireBranchRoute] instead;
///  * a second byte that is no direction code;
///  * sign bytes outside `00`/`01`, or a length count that disagrees with
///    the point count (malformed / not this grammar). The two-endpoint
///    residue is 482 of 388,828 corpus tables, 479 of them opening with
///    the `up` code and carrying two trailing bytes this grammar does not
///    explain (e.g. `02 01 00 08`) — censused as `undecoded2ep` /
///    `undecoded2epHdr*`; TODO.
ViWireRoute? decodeWireRoute(Uint8List table) {
  if (table.isEmpty) return null;
  final n = table[0];
  if (n == 1) {
    if (table.length != 1) return null;
    return ViWireRoute(pointCount: 1, direction: null, segmentLengths: const [], jointSigns: const []);
  }
  if (n < 2 || table.length < 2) return null;
  final direction = WireRouteDirection.fromCode(table[1]);
  if (direction == null) return null;
  var i = 2;
  final signs = <int>[];
  for (var k = 0; k < n - 2; k++) {
    if (i >= table.length) return null;
    final m = table[i++];
    if (m != 0 && m != 1) return null;
    signs.add(m == 0 ? 1 : -1);
  }
  final lengths = _decodeLengthTail(table, i);
  if (lengths == null) return null;
  if (lengths.length != n - 2) return null;
  return ViWireRoute(pointCount: n, direction: direction, segmentLengths: lengths, jointSigns: signs);
}

/// The **junction codes** of the extended (branching) stored wire route —
/// the mode bytes marking a point where the wire tree forks. Each code is a
/// fixed catalog of the junction's outgoing tree-edge directions, in visit
/// order: the FIRST direction is walked by the segment carrying the code
/// itself; each later one is walked by a later pop segment
/// ([ViWireBranchRoute.popCode]) returning to this junction. The directions
/// are absolute, with one substitution: a listed direction equal to the
/// reverse of the junction's incoming travel direction (walking back along
/// the edge just walked) is replaced by [WireRouteDirection.left] — the one
/// direction no catalog entry lists. Corpus (7,524 VIs, 35,968 extended
/// tables, census pinned by `wire_route_census_test`): 41,304 junction
/// segments — `downRight` 23,561 (`extJuncDownRight`) / `upRight` 13,235
/// (`extJuncUpRight`) / `upDown` 4,110 (`extJuncUpDown`) / `cross` 398
/// (`extJuncCross`) — of which 535 substitute (`extJuncSubst`; all four
/// codes, every blockable incoming direction observed).
///
/// The catalog visit orders and the substitution were selected against the
/// 13,932-endpoint exact-attach labelled subset (see [ViWire.routeTree]):
/// the shipped ordering closes 89.19%, beating every reordered cross
/// catalog (next best 88.62%), no substitution (88.99%), and a right
/// substitution (89.00%). The `cross` visit order and the LEFT
/// substitution are the thinnest-supported choices (their nearest
/// alternatives differ by ~80 and ~28 endpoints respectively); the
/// pixel-overlay oracle corroborates the shipped trees at 99.96%
/// (`wire_branch_oracle`), but a future larger anchored sample could
/// refine these two choices.
enum WireRouteJunction {
  /// `0x04` — a four-way **cross** junction: three outgoing edges, visited
  /// up, then down, then right (two pop returns).
  cross(0x04, [WireRouteDirection.up, WireRouteDirection.down, WireRouteDirection.right]),

  /// `0x05` — branch **down** now, resume **right** on pop.
  downRight(0x05, [WireRouteDirection.down, WireRouteDirection.right]),

  /// `0x06` — branch **up** now, resume **right** on pop.
  upRight(0x06, [WireRouteDirection.up, WireRouteDirection.right]),

  /// `0x07` — branch **up** now, resume **down** on pop.
  upDown(0x07, [WireRouteDirection.up, WireRouteDirection.down])
  ;

  const WireRouteJunction(this.code, this.outgoing);

  /// The stored mode-byte value.
  final int code;

  /// The junction's outgoing directions in visit order (first = the segment
  /// carrying the code, rest = later pop returns), before the
  /// blocked-direction substitution (see the enum doc).
  final List<WireRouteDirection> outgoing;

  /// The catalog entry for a stored junction byte, or null for any other
  /// value.
  static final Map<int, WireRouteJunction> _byCode = {
    for (final value in values) value.code: value,
  };

  static WireRouteJunction? fromCode(int code) => _byCode[code];
}

/// The decoded shape of a signal's **extended (branching) wire table** —
/// the `[u8 pointCount][00][(pointCount-1) mode bytes][(pointCount-1)
/// length values]` form carried by multi-endpoint signals (the `00` second
/// byte distinguishes it from the two-endpoint form, whose second byte is a
/// direction code; the extended form appears on NO two-endpoint signal, a
/// pinned law). Unlike the two-endpoint form, EVERY tree-edge length is
/// stored (`FF` + u16be escape for ≥ 255) — nothing is implied by the far
/// endpoint.
///
/// The mode stream is a depth-first walk of the wire TREE, one byte per
/// edge in walk order:
///
///  * the **first** byte is either a one-hot [WireRouteDirection] code
///    (the first edge's absolute direction) or a multi-bit **mask of
///    one-hot direction codes** — the start point is itself a junction, its
///    outgoing edges walked in ascending code order (up `01`, left `02`,
///    down `04`, right `08`), the first by this edge and the rest by pop
///    returns;
///  * `00`/`01` — a plain bend: the edge's axis alternates off the previous
///    edge and the byte is its sign (`00` = down/right, `01` = up/left),
///    exactly the two-endpoint form's joint-sign bytes;
///  * `04`–`07` — a [WireRouteJunction]: the current point is a branch
///    point (LabVIEW draws its junction dot there) and the edge walks the
///    catalog's first outgoing direction;
///  * `03` ([popCode]) — the point just reached is a **leaf** (an endpoint
///    attach point); the edge walks the next unconsumed outgoing direction
///    of the most recently declared junction that still has one (LIFO).
///
/// The point after the final edge is the last leaf, so the walk emits
/// `#pop + 1` leaves — one per pop plus the trailing run — and the signal's
/// endpoint count is those leaves plus the origin, `#pop + 2`. Structural
/// laws, corpus-wide over all 35,968 extended tables (census pinned by
/// `wire_route_census_test`): the pending-return count exactly balances —
/// `#pop = (#maskBits−1 for a multi-bit first byte) + Σ (outgoing−1) per
/// junction` — every mode byte is one of the forms above, and `#pop + 2`
/// equals the endpoint count on 35,939 of 35,968 tables (99.92%; 29
/// structural exceptions, key `extLeafLawViol`, walked but never
/// force-matched — 22 of them fall in origin-anchored walkable tables,
/// key `extLeafMismatch`). Geometry proof lives on [ViWire.routeTree].
class ViWireBranchRoute {
  /// Private: only [decodeWireBranchRoute] constructs a branch route, so
  /// every instance satisfies the pop-balance and mode-grammar invariants
  /// [walkWireBranchRoute] relies on (it is total on any instance).
  ViWireBranchRoute._({required this.pointCount, required this.modes, required this.segmentLengths});

  /// The stored mode byte marking a pop edge — the walk returns to the most
  /// recent junction with an unconsumed outgoing direction. Deliberately
  /// NOT a [WireRouteJunction] catalog value: the byte declares no
  /// directions of its own.
  static const int popCode = 0x03;

  /// The stored tree point count (the table's leading byte): endpoints +
  /// bends + junctions.
  final int pointCount;

  /// The raw mode bytes, one per tree edge in walk order ([pointCount]−1;
  /// validated against the grammar by [decodeWireBranchRoute]).
  final Uint8List modes;

  /// Unsigned lengths of every tree edge, index-aligned with [modes].
  final List<int> segmentLengths;
}

/// Decodes a signal's packed `0x1e7` wire-table bytes as the **extended
/// (branching) form** into a [ViWireBranchRoute], or null when the bytes
/// are not that form (the two-endpoint form has a direction code where the
/// extended form has `00` — see [decodeWireRoute]) or violate its grammar:
/// a first mode byte outside `0x01..0x0f`, a later mode byte that is no
/// sign/pop/junction code, a length count disagreeing with the point count,
/// or an unbalanced pop stream (a pop with no pending junction direction,
/// or pending directions left unconsumed at the end). Corpus (7,524 VIs):
/// all 35,968 extended tables on 3+-endpoint signals decode; census pinned
/// by `wire_route_census_test`.
ViWireBranchRoute? decodeWireBranchRoute(Uint8List table) {
  if (table.length < 2 || table[1] != 0) return null;
  final n = table[0];
  if (n < 2 || table.length < 1 + n) return null;
  final modes = Uint8List.sublistView(table, 2, 1 + n);
  // First byte: a one-hot direction or a multi-bit absolute direction mask.
  // Pending pop returns start at its extra mask bits.
  final first = modes[0];
  if (first == 0 || first > 0x0f) return null;
  var pending = _bitCount(first) - 1;
  for (var k = 1; k < modes.length; k++) {
    final m = modes[k];
    if (m == 0 || m == 1) continue;
    if (m == ViWireBranchRoute.popCode) {
      if (pending == 0) return null;
      pending--;
      continue;
    }
    final junction = WireRouteJunction.fromCode(m);
    if (junction == null) return null;
    pending += junction.outgoing.length - 1;
  }
  if (pending != 0) return null;
  final lengths = _decodeLengthTail(table, 1 + n);
  if (lengths == null || lengths.length != n - 1) return null;
  return ViWireBranchRoute._(pointCount: n, modes: modes, segmentLengths: lengths);
}

/// Set-bit count of a mode byte (Dart has no int.popCount; masks are ≤ 4 bits).
int _bitCount(int v) => (v & 1) + ((v >> 1) & 1) + ((v >> 2) & 1) + ((v >> 3) & 1);

/// A walked branching wire route in absolute diagram coordinates — what a
/// renderer draws: every polyline run plus the junction (branch-dot)
/// points. Produced unanchored by [walkWireBranchRoute] and shipped proven
/// as [ViWire.routeTree].
class ViWireRouteTree {
  ViWireRouteTree({required this.polylines, required this.junctions});

  /// The drawn Manhattan runs. The first starts at the walk origin (the
  /// first endpoint's attach point); every later one starts at a junction
  /// point; every one ends on a **leaf** — an endpoint attach point. One
  /// run per leaf: `polylines.length == endpointCount - 1` when the tree
  /// matches its signal.
  final List<List<ViPoint>> polylines;

  /// The junction points, in walk order — where LabVIEW draws the wire's
  /// branch dots (a multi-bit first mode byte contributes the walk origin
  /// itself: the wire forks at its first endpoint's terminal).
  final List<ViPoint> junctions;

  /// The leaf landing points in walk order (each polyline's last point) —
  /// the walked positions of the other `endpointCount - 1` endpoints.
  /// Computed once on first access.
  late final List<ViPoint> leaves = [for (final polyline in polylines) polyline.last];
}

/// Walks a decoded branching route from [start] (the first endpoint's
/// attach point), returning the absolute tree geometry. Total for every
/// [decodeWireBranchRoute]-validated table (the decoder already enforced
/// the pop balance the walk relies on).
///
/// The walk follows the mode-stream semantics on [ViWireBranchRoute], with
/// the blocked-direction substitution on junction codes (a catalog
/// direction reversing the incoming edge becomes [WireRouteDirection.left];
/// see [WireRouteJunction]). Start-mask directions never substitute — the
/// origin has no incoming edge.
ViWireRouteTree walkWireBranchRoute(ViWireBranchRoute route, ViPoint start) {
  final modes = route.modes;
  final lengths = route.segmentLengths;
  final polylines = <List<ViPoint>>[];
  final junctionPoints = <ViPoint>[];
  // Junction stack: the point plus its unconsumed outgoing directions.
  final stack = <(ViPoint, List<WireRouteDirection>)>[];
  var run = <ViPoint>[start];
  var pos = start;
  WireRouteDirection? prev;
  for (var k = 0; k < modes.length; k++) {
    final m = modes[k];
    final WireRouteDirection direction;
    if (k == 0) {
      final oneHot = WireRouteDirection.fromCode(m);
      if (oneHot != null) {
        direction = oneHot;
      } else {
        // Multi-bit start mask: outgoing directions in ascending code order.
        final dirs = [
          for (final d in WireRouteDirection.values)
            if (m & d.code != 0) d,
        ]..sort((a, b) => a.code.compareTo(b.code));
        direction = dirs.first;
        stack.add((pos, dirs.sublist(1)));
        junctionPoints.add(pos);
      }
    } else if (m == 0 || m == 1) {
      // Bend: alternate axis, stored sign.
      final positive = m == 0;
      direction = prev!.isHorizontal
          ? (positive ? WireRouteDirection.down : WireRouteDirection.up)
          : (positive ? WireRouteDirection.right : WireRouteDirection.left);
    } else if (m == ViWireBranchRoute.popCode) {
      // Leaf reached: resume the nearest junction with a pending direction.
      polylines.add(run);
      while (stack.last.$2.isEmpty) {
        stack.removeLast();
      }
      final (jpos, dirs) = stack.last;
      pos = jpos;
      run = <ViPoint>[pos];
      direction = dirs.removeAt(0);
    } else {
      // Junction: current point is a branch dot; walk the catalog's first
      // direction, blocked entries substituted with `left`.
      final blocked = _reverse(prev!);
      final dirs = [
        for (final d in WireRouteJunction.fromCode(m)!.outgoing) d == blocked ? WireRouteDirection.left : d,
      ];
      direction = dirs.first;
      stack.add((pos, dirs.sublist(1)));
      junctionPoints.add(pos);
    }
    pos = (x: pos.x + direction.dx * lengths[k], y: pos.y + direction.dy * lengths[k]);
    run.add(pos);
    prev = direction;
  }
  polylines.add(run);
  return ViWireRouteTree(polylines: polylines, junctions: junctionPoints);
}

/// The opposite one-hot direction (walking back along the edge just walked).
WireRouteDirection _reverse(WireRouteDirection d) => switch (d) {
  WireRouteDirection.up => WireRouteDirection.down,
  WireRouteDirection.down => WireRouteDirection.up,
  WireRouteDirection.left => WireRouteDirection.right,
  WireRouteDirection.right => WireRouteDirection.left,
};

/// Walks a decoded two-endpoint [ViWireRoute] from a **single anchored
/// endpoint**, deriving the plain-node endpoint at the far end (a primitive
/// input/output or subVI terminal, which carries no independently decoded
/// attach geometry) from its owner node box [farBox]. This is the walked tier
/// behind [ViWire.routePoints] — the polyline LabVIEW saved, placed by one
/// attach point instead of closed between two.
///
/// [anchoredIndex] selects the anchored end: `0` walks **forward** from the
/// route's first endpoint ([anchor]) through the stored bends, then closes the
/// implied final run onto the near edge of [farBox] (the second endpoint's
/// connection point). `1` walks **reverse** from the second endpoint: the
/// stored bends are exact off [anchor], and the first endpoint rides the far
/// edge of [farBox]. The stored table implies only the closing run's length,
/// so a forward walk isolates that one derived coordinate at the far end, while
/// a reverse walk must solve it from the box — recoverable only when the
/// departing segment shares the closing run's axis (an even stored point
/// count); an odd count leaves the far endpoint's along-run position unpinned
/// and returns null.
///
/// A forward walk whose LAST decoded bend lies PAST the near edge — in the
/// INTERIOR of [farBox] — is an **into-node** close: the implied run enters the
/// plain node instead of reaching its edge, and its length (the node's
/// input-pin depth) is not decoded. Such a walk ships the polyline TRUNCATED at
/// the last bend — deliberately short of the true endpoint — and reports
/// `closingStep` = the run's unit direction; the consumer MUST complete the
/// wire along that step to the node's drawn ink, since the parse fabricates no
/// terminus at a guessed depth. The into-node case is accepted only when the
/// polyline carries a real segment (>= 2 points) and the run points INTO the
/// interior — the last bend and the pixel one step deeper both lie within
/// `[left, right-1] x [top, bottom-1]` (right/bottom EXCLUSIVE); a bend at or
/// beyond an edge, or a step that would exit the box, is rejected.
///
/// Returns `(points, closingStep, headSlack)`: the absolute polyline (anchor
/// end to the far connection, in storage order) — [ViWireRoute.pointCount]
/// points, one fewer when the closing run is zero-length OR enters the node
/// (except a `headSlack` ship, whose anchor is always an explicit trailing
/// point) — with `closingStep` non-null only for the into-node case and
/// `headSlack` non-null only for a bent reverse walk (the head's undecoded
/// terminal-depth degree of freedom; see [ViWire.routeHeadSlack]). Null when
/// the reverse geometry is underdetermined (above), the derived closing run
/// would double back against the stored final sign (an inconsistent [farBox]
/// placement), or an into-node close is not a genuine interior entry
/// (above). Total on any decoded route.
///
/// This is pure geometry: [ViWire.routePoints] applies the shipping gate
/// (exact anchor, cross-axis containment) and the
/// reference-pixel validation (`wire_one_anchored_oracle`,
/// which pins the shipped-tier overlay and the worse withheld-walk
/// overlay). Coarse anchors are computed here so the oracle can measure
/// them, but are not shipped.
({List<ViPoint> points, ViStep? closingStep, ViStep? headSlack})? walkOneAnchoredRoute(
  ViWireRoute route, {
  required ViPoint anchor,
  required int anchoredIndex,
  required HeapRect farBox,
}) {
  if (route.pointCount < 2) return null;
  final direction = route.direction;
  if (direction == null) return null;
  // Walk the stored bends in a local frame (origin at the first endpoint,
  // closing run length 0): local[0..pointCount-2], the last being the final
  // stored bend before the implied closing run.
  var x = 0, y = 0;
  var horizontal = direction.isHorizontal;
  var sign = direction.dx + direction.dy;
  final local = <ViPoint>[(x: 0, y: 0)];
  final lengths = route.segmentLengths;
  for (var k = 0; k < lengths.length; k++) {
    if (k > 0) sign = route.jointSigns[k - 1];
    if (horizontal) {
      x += lengths[k] * sign;
    } else {
      y += lengths[k] * sign;
    }
    local.add((x: x, y: y));
    horizontal = !horizontal;
  }
  final closingHorizontal = horizontal;
  final closingSign = route.jointSigns.isEmpty ? (direction.dx + direction.dy) : route.jointSigns.last;
  final lastBend = local.last;

  if (anchoredIndex == 0) {
    // Forward: translate the local frame onto the anchor, then close the
    // implied final run onto — or into — the far box.
    final pts = [for (final p in local) (x: p.x + anchor.x, y: p.y + anchor.y)];
    final tail = pts.last;
    final ViPoint terminus;
    if (closingHorizontal) {
      // Cross-axis containment: the terminus row must lie within the box's
      // vertical span, else the closing run points into empty space beside
      // the node — a stale/drifted route the closed tier's zero-slack closure
      // would have rejected.
      if (tail.y < farBox.top || tail.y > farBox.bottom) return null;
      final tx = closingSign > 0 ? farBox.left : farBox.right - 1;
      if ((tx - tail.x) * closingSign < 0) {
        // The last decoded bend sits PAST the near edge, inside the far node:
        // the implied closing run ENTERS the node INTERIOR rather than reaching
        // its edge. Its length is the plain-node input-pin depth (undecoded),
        // so ship the polyline to the last bend and expose the run's direction
        // — the consumer completes it along closingStep to the node's drawn ink
        // (see [ViWire.routeClosingStep]). Accept ONLY a genuine interior
        // entry: the polyline must carry a real segment (>= 2 points), and the
        // arrival ROW, the last bend, AND the pixel one step deeper must all lie
        // in the box INTERIOR ([left, right-1] x [top, bottom-1]; right/bottom
        // are EXCLUSIVE) — so the run heads INTO the node, never out of it.
        final ahead = tail.x + closingSign;
        if (pts.length < 2 ||
            tail.y < farBox.top ||
            tail.y >= farBox.bottom ||
            tail.x < farBox.left ||
            tail.x >= farBox.right ||
            ahead < farBox.left ||
            ahead >= farBox.right) {
          return null;
        }
        return (points: pts, closingStep: (dx: closingSign, dy: 0), headSlack: null);
      }
      terminus = (x: tx, y: tail.y);
    } else {
      if (tail.x < farBox.left || tail.x > farBox.right) return null;
      final ty = closingSign > 0 ? farBox.top : farBox.bottom - 1;
      if ((ty - tail.y) * closingSign < 0) {
        // Into-node closing run along y — the same interior-entry gate as the
        // horizontal branch (see there): a real segment, and the arrival
        // COLUMN, the last bend, and the pixel one step deeper all interior.
        final ahead = tail.y + closingSign;
        if (pts.length < 2 ||
            tail.x < farBox.left ||
            tail.x >= farBox.right ||
            tail.y < farBox.top ||
            tail.y >= farBox.bottom ||
            ahead < farBox.top ||
            ahead >= farBox.bottom) {
          return null;
        }
        return (points: pts, closingStep: (dx: 0, dy: closingSign), headSlack: null);
      }
      terminus = (x: tail.x, y: ty);
    }
    if (terminus != tail) pts.add(terminus);
    return (points: pts, closingStep: null, headSlack: null);
  }

  // Reverse: the anchored second endpoint pins the perpendicular-to-closing
  // axis; the far edge of the box pins the departing segment's axis. Solvable
  // only when those axes differ — i.e. the departing segment shares the
  // closing run's axis.
  final seg0Sign = direction.dx + direction.dy;
  if (direction.isHorizontal != closingHorizontal) return null;
  final int tx, ty;
  if (closingHorizontal) {
    ty = anchor.y - lastBend.y;
    // Cross-axis containment: the terminus row must lie within the box's span.
    if (ty < farBox.top || ty > farBox.bottom) return null;
    tx = seg0Sign > 0 ? farBox.right - 1 : farBox.left;
  } else {
    tx = anchor.x - lastBend.x;
    if (tx < farBox.left || tx > farBox.right) return null;
    ty = seg0Sign > 0 ? farBox.bottom - 1 : farBox.top;
  }
  final pts = [for (final p in local) (x: p.x + tx, y: p.y + ty)];
  final tail = pts.last;
  if (closingHorizontal) {
    if (tail.y != anchor.y || (anchor.x - tail.x) * closingSign < 0) return null;
  } else {
    if (tail.x != anchor.x || (anchor.y - tail.y) * closingSign < 0) return null;
  }
  // A bent reverse walk pins the head at the far box EDGE, but the true head
  // sits at the node's terminal — an undecoded depth along the departing
  // axis, INTERIOR to the box. Every point except the anchor slides together
  // by that depth (the closing run absorbs it), so the head-side placement
  // carries one degree of freedom the consumer must resolve against the
  // node's builtin-terminal geometry ([ViWire.routeHeadSlack]); the shipped
  // step points the direction that slide must take (opposite the departing
  // segment). A straight reverse walk stores no bend to displace and ships
  // unmarked. So the translate-all-but-the-anchor contract holds even when
  // the closing run has zero stored length, a slack ship always carries its
  // anchor as an explicit trailing point.
  final headSlack = route.segmentLengths.isEmpty
      ? null
      : closingHorizontal
      ? (dx: -seg0Sign, dy: 0)
      : (dx: 0, dy: -seg0Sign);
  if (anchor != tail || headSlack != null) pts.add(anchor);
  return (points: pts, closingStep: null, headSlack: headSlack);
}

/// Whether a `vers` string predates the **frame-relative termBounds
/// coordinate space** — true iff it parses as a `major.minor` below 8.6.
/// LabVIEW < 8.6 heaps store termBounds (and `C4 2D` bounds) in an absolute
/// space the composed coordinate model does not cover (see
/// [ViDiagram.endpointTerminalBounds]). A null or unparseable version reads
/// false — treated as current-era (every corpus VI carries a parseable
/// version; a bare heap body without container context has no version and
/// gets the current-era reading).
bool _predatesFrameRelativeTermBounds(String? version) {
  if (version == null) return false;
  final parts = version.split('.');
  if (parts.length < 2) return false;
  final major = int.tryParse(parts[0]);
  final minor = int.tryParse(parts[1]);
  if (major == null || minor == null) return false;
  return major < 8 || (major == 8 && minor < 6);
}

/// A recovered block-diagram (or other heap) as a **nesting tree** of
/// [ViHeapObject]s with absolute coordinates. The `14 19 01 fd` references are
/// child-membership (structure → contained oids). LabVIEW's *logical* dataflow
/// wires are the **signal** objects (class `0x17`), which DO carry resolvable
/// oid endpoints — surfaced as [ViWire] via [wires]; the visual `0x1d` wire
/// segments are geometry-only (no oid endpoints). Partial/honest: object class
/// codes and wire direction are not fully decoded (wire datatype is — see
/// [ViWire.signalType]).
class ViDiagram {
  ViDiagram({required this.sectionTag, required this.objects, this.version});

  /// The section this diagram came from (`BDHb` = block diagram, `FPHb` = front panel).
  final String sectionTag;

  /// The LabVIEW version the VI was saved in (the `vers` string, e.g. `20.0`),
  /// or null when unknown (a bare heap body with no container context). Gates
  /// the version-dependent coordinate decodes ([endpointTerminalBounds]).
  final String? version;

  /// All recovered objects, in heap (pre-order) order.
  final List<ViHeapObject> objects;

  /// Objects indexed by their unique [ViHeapObject.oid]. Built once on first
  /// access (a repeated oid keeps the last object — see [ViHeapObject.oid]).
  late final Map<int, ViHeapObject> byId = {for (final object in objects) object.oid: object};

  /// The root object(s) of the nesting tree (parentOid == null) — normally the
  /// single diagram root (kind `0x7e`).
  Iterable<ViHeapObject> get roots => objects.where((o) => o.parentOid == null);

  /// The direct children of the object with [oid] in the nesting tree.
  Iterable<ViHeapObject> children(int oid) => childrenByOid[oid] ?? const <ViHeapObject>[];

  /// The bounded objects (have an absolute rectangle) — the drawable layout layer.
  Iterable<ViHeapObject> get nodes => objects.where((o) => o.absBounds != null);

  /// The **dataflow wires** — one [ViWire] per signal (`0x17`) object, with its
  /// endpoint oids ([ViHeapObject.refs], the `14 19` childRefs) resolved to
  /// anchor rectangles. Built once on first access. Empty on a heap with no
  /// signals (e.g. a front panel). See [ViWire].
  late final List<ViWire> wires = [
    for (final object in objects)
      if (object.kind == 0x17) _buildWire(object),
  ];

  ViWire _buildWire(ViHeapObject object) {
    final raw = object.wireTableRaw;
    final route = raw == null ? null : decodeWireRoute(raw);
    final branchRoute = raw == null || object.refs.length < 3 ? null : decodeWireBranchRoute(raw);
    // Resolve each endpoint's constant value shell once and reuse it for the
    // attach rect, the anchor, and the route closure (its child scan is not
    // free — most endpoints wrap no constant and scan nothing, but the shared
    // local avoids re-walking the ones that do).
    final constantBounds = [for (final oid in object.refs) endpointConstantBounds(oid)];
    final attachRects = [
      for (var i = 0; i < object.refs.length; i++) endpointTerminalBounds(object.refs[i]) ?? constantBounds[i],
    ];
    final attachPoints = [
      for (var i = 0; i < object.refs.length; i++) _attachPointFrom(attachRects[i], object.refs[i]),
    ];
    // An array constant's route may anchor at the shell centre OR its element
    // box's centre (both conventions occur; see
    // [endpointConstantElementBounds]) — the element point is the alternate
    // candidate the closure-arbitrated gates may swap in.
    final altAttachPoints = [
      for (var i = 0; i < object.refs.length; i++)
        switch (endpointConstantElementBounds(object.refs[i])) {
          null => null,
          final elem => attachPoints[i] == null ? null : _attachPointFrom(elem, object.refs[i]),
        },
    ];
    // A route terminating on a node terminal strip COLUMN aims 8 px left of
    // the column centre (see [kTerminalStripTargetLeftOffset]) — the
    // destination candidate the closure-arbitrated gates try first.
    final stripTargets = [
      for (var i = 0; i < object.refs.length; i++) _stripFarTarget(object.refs[i], attachRects[i], attachPoints[i]),
    ];
    // A constant endpoint anchors on its own value shell (the box LabVIEW
    // draws); every other endpoint on its nearest bounded owner.
    final anchors = [
      for (var i = 0; i < object.refs.length; i++) constantBounds[i] ?? _boundedOwnerBounds(object.refs[i]),
    ];
    final points = route == null || object.refs.length != 2
        ? null
        : _routePointsFor(route, object.refs, attachPoints, anchors, altAttachPoints, stripTargets);
    return ViWire(
      signalOid: object.oid,
      endpointOids: List<int>.of(object.refs),
      endpointAnchors: anchors,
      endpointAttachRects: attachRects,
      route: route,
      routePoints: points?.points,
      routePointsFidelity: points?.fidelity,
      routeClosingStep: points?.closingStep,
      routeHeadSlack: points?.headSlack,
      branchRoute: branchRoute,
      // Lazy: the walk + closure runs only when a consumer reads routeTree.
      routeTreeBuilder: branchRoute == null
          ? null
          : () =>
                _shippableRouteTree(branchRoute, attachPoints, altAttachPoints, stripTargets, anchors[0]) ??
                _dcoChildRouteTree(branchRoute, object.refs, attachPoints, altAttachPoints, stripTargets),
      signalType: object.lastSignalKind == null ? null : ViSignalType(object.lastSignalKind!),
    );
  }

  /// The shippable polyline for a two-endpoint [route] (see [ViWire.routePoints]),
  /// or null when unshippable — the geometry only; [_routePointsFidelity] reports
  /// which tier produced it.
  ///
  /// Highest tier first: when BOTH endpoints resolve an attach point and the
  /// walk closes exactly ([_closedRoutePoints]), that proven polyline ships.
  /// The far attach candidate set includes a terminal-strip COLUMN's
  /// destination point ([_stripFarTarget], tried first) — a route ending on a
  /// width-8 strip column aims [kTerminalStripTargetLeftOffset] px left of the
  /// column centre, never the centre itself (1 corpus exception).
  /// Otherwise the **walked tier** — exactly one endpoint resolves an EXACT
  /// attach ([_exactAttach]: a structure-framed terminal or an own-bounds leaf,
  /// never a coarse owner box or off-centre constant shell), and the far
  /// plain-node endpoint is derived from its owner box via
  /// [walkOneAnchoredRoute]. Ships forward walks and reverse walks — a bent
  /// reverse walk carries the head's undecoded terminal depth on
  /// [ViWire.routeHeadSlack] — and only when the walk's cross-axis
  /// containment holds
  /// (the terminus lands within the far box span). Both shift registers'
  /// connection columns are decoded ([kShiftRegisterColumnLeftOffset] /
  /// [kShiftRegisterColumnRightOffset]), so a bent walk anchored on either
  /// register lands on the drawn column.
  ({List<ViPoint> points, WireRouteFidelity fidelity, ViStep? closingStep, ViStep? headSlack})? _routePointsFor(
    ViWireRoute route,
    List<int> refs,
    List<ViPoint?> attachPoints,
    List<HeapRect?> anchors,
    List<ViPoint?> altAttachPoints,
    List<ViPoint?> stripTargets,
  ) {
    // Zero-slack closure arbitrates the attach convention: a terminal-strip
    // column destination first ([kTerminalStripTargetLeftOffset] — the
    // near-unanimous convention for a strip-column far end), then the
    // shell-centre pair, then each combination that swaps an array endpoint
    // onto its element-centre candidate ([endpointConstantElementBounds]).
    for (final pair in [
      (attachPoints[0], stripTargets[1]),
      (altAttachPoints[0], stripTargets[1]),
      (attachPoints[0], attachPoints[1]),
      (altAttachPoints[0], attachPoints[1]),
      (attachPoints[0], altAttachPoints[1]),
      (altAttachPoints[0], altAttachPoints[1]),
    ]) {
      final closed = _closedRoutePoints(route, pair.$1, pair.$2);
      if (closed != null) {
        return (points: closed, fidelity: WireRouteFidelity.closed, closingStep: null, headSlack: null);
      }
    }
    final int anchoredIndex;
    if (attachPoints[0] != null && attachPoints[1] == null) {
      anchoredIndex = 0;
    } else if (attachPoints[1] != null && attachPoints[0] == null) {
      anchoredIndex = 1;
    } else {
      return _dcoChildTierPoints(route, refs, attachPoints, altAttachPoints, stripTargets, anchors);
    }
    if (_exactAttach(refs[anchoredIndex])) {
      final farBox = anchors[1 - anchoredIndex];
      if (farBox != null) {
        final walked = walkOneAnchoredRoute(
          route,
          anchor: attachPoints[anchoredIndex]!,
          anchoredIndex: anchoredIndex,
          farBox: farBox,
        );
        if (walked != null) {
          return (
            points: walked.points,
            fidelity: WireRouteFidelity.walked,
            closingStep: walked.closingStep,
            headSlack: walked.headSlack,
          );
        }
      }
    }
    return _dcoChildTierPoints(route, refs, attachPoints, altAttachPoints, stripTargets, anchors);
  }

  /// The **DCO-child terminal** last-resort tier behind [ViWire.routePoints]:
  /// consulted only after every standard tier declined, so it can add routes
  /// but never change one — the endpoint attach rects/anchors the rest of the
  /// model exposes ([ViWire.endpointAttachRects], [wireAttachPoint]) are
  /// deliberately untouched.
  ///
  /// Ships, in order:
  ///  * **closed** — a zero-slack closure ([_closedRoutePoints]) over the
  ///    endpoint candidate sets, where an endpoint with no standard attach
  ///    point substitutes its [dcoChildTerminalAttach] candidates (an
  ///    endpoint that resolves neither way has no candidates and no pair
  ///    ships). At least one end must use the fallback — the standard pairs
  ///    were already tried and refused.
  ///  * **walked** — no pair closes, one end is a fallback WIDE-ROW cell
  ///    (the shape whose centre-row anchor is reference-proven — see
  ///    [dcoChildTerminalAttach]) and the far end has no standard attach;
  ///    [walkOneAnchoredRoute] places the route off the row's centre point
  ///    with the usual cross-axis containment, the far terminus pinned by
  ///    the owner box (a failed far fallback candidate does not block —
  ///    the walk supersedes it).
  ({List<ViPoint> points, WireRouteFidelity fidelity, ViStep? closingStep, ViStep? headSlack})? _dcoChildTierPoints(
    ViWireRoute route,
    List<int> refs,
    List<ViPoint?> attachPoints,
    List<ViPoint?> altAttachPoints,
    List<ViPoint?> stripTargets,
    List<HeapRect?> anchors,
  ) {
    final fallback = [for (final oid in refs) dcoChildTerminalAttach(oid)];
    final usesFallback = [
      for (var i = 0; i < 2; i++) attachPoints[i] == null && (fallback[i]?.candidates.isNotEmpty ?? false),
    ];
    if (!usesFallback[0] && !usesFallback[1]) return null;
    final sourceCandidates = usesFallback[0]
        ? fallback[0]!.candidates
        : [
            if (attachPoints[0] != null) attachPoints[0]!,
            if (altAttachPoints[0] != null) altAttachPoints[0]!,
          ];
    final targetCandidates = usesFallback[1]
        ? fallback[1]!.candidates
        : [
            if (stripTargets[1] != null) stripTargets[1]!,
            if (attachPoints[1] != null) attachPoints[1]!,
            if (altAttachPoints[1] != null) altAttachPoints[1]!,
          ];
    for (final source in sourceCandidates) {
      for (final target in targetCandidates) {
        final closed = _closedRoutePoints(route, source, target);
        if (closed != null) {
          return (points: closed, fidelity: WireRouteFidelity.closed, closingStep: null, headSlack: null);
        }
      }
    }
    // Walked: one wide-row fallback anchor; the far end resolves no standard
    // attach (a failed far fallback CANDIDATE does not block — the walk pins
    // the far terminus from the anchor and the owner box instead).
    final int anchoredIndex;
    if (usesFallback[0] && (fallback[0]?.wideRow ?? false) && attachPoints[1] == null) {
      anchoredIndex = 0;
    } else if (usesFallback[1] && (fallback[1]?.wideRow ?? false) && attachPoints[0] == null) {
      anchoredIndex = 1;
    } else {
      return null;
    }
    final farBox = anchors[1 - anchoredIndex];
    if (farBox == null) return null;
    final walked = walkOneAnchoredRoute(
      route,
      anchor: fallback[anchoredIndex]!.candidates.first,
      anchoredIndex: anchoredIndex,
      farBox: farBox,
    );
    return walked == null
        ? null
        : (
            points: walked.points,
            fidelity: WireRouteFidelity.walked,
            closingStep: walked.closingStep,
            headSlack: walked.headSlack,
          );
  }

  /// Whether [oid]'s attach point is **exact**: it resolves a terminal whose
  /// real composing frame (the nearest bounded ancestor of the terminal's
  /// parent, matching how [endpointTerminalBounds] composes) is a structure, or
  /// it is an own-bounds `0x16` leaf (no terminal and no constant shell). The
  /// coarse cases — node-framed terminal rects and constant value-shell centres,
  /// whose attach point is the drawn edge, not the box centre — read false.
  /// This is the walked-tier gate ([_routePointsFor]) and the exact-attach
  /// subset the branch census isolates.
  bool _exactAttach(int oid) {
    final terminal = endpointTerminal(oid);
    if (terminal == null) return endpointConstantBounds(oid) == null;
    final parent = terminal.parentOid == null ? null : byId[terminal.parentOid!];
    final frame = parent == null ? null : _boundedOwnerObject(parent);
    return frame != null && frame.category == ViObjectKind.structure;
  }

  /// Walks a branching [route] from the first endpoint's attach point and ships
  /// the tree when every RESOLVED endpoint corroborates it — the
  /// **contradiction-free** gate. The origin (first endpoint) must resolve; the
  /// walked leaf count must equal the endpoint count; and each OTHER endpoint
  /// that resolves an attach point must land on a distinct walked leaf — on
  /// any of its destination candidates: the terminal-strip column target
  /// ([_stripFarTarget], tried first), the attach centre, or the array
  /// element centre. Plain-node leaves that resolve nothing ride the walk
  /// (their absolute position is the tree's leaf). A resolved endpoint the
  /// walk MISSES is a contradiction (the walk drifted) and ships null. When
  /// every endpoint resolves and closes this is the proven closed tier; when
  /// some are plain nodes it is the walked tier (see [ViWire.routeTree]).
  /// Never force-closed.
  ///
  /// An UNRESOLVED origin falls through to the **reverse-solved** gate
  /// ([_reverseSolvedRouteTree]): the tree's translation is solved from the
  /// resolved far endpoints instead.
  static ({ViWireRouteTree tree, WireRouteFidelity fidelity})? _shippableRouteTree(
    ViWireBranchRoute route,
    List<ViPoint?> attachPoints,
    List<ViPoint?> altAttachPoints,
    List<ViPoint?> stripTargets,
    HeapRect? headBox,
  ) {
    if (attachPoints.length < 3) return null;
    if (attachPoints[0] == null) {
      return _reverseSolvedRouteTree(route, attachPoints, altAttachPoints, stripTargets, headBox);
    }
    // The origin's attach convention is closure-arbitrated like the
    // two-endpoint tier: shell centre first, the array element centre second.
    for (final origin in [attachPoints[0], altAttachPoints[0]]) {
      if (origin == null) continue;
      final tree = walkWireBranchRoute(route, origin);
      final leaves = tree.leaves;
      if (leaves.length != attachPoints.length - 1) continue;
      final remaining = <ViPoint, int>{};
      for (final leaf in leaves) {
        remaining.update(leaf, (c) => c + 1, ifAbsent: () => 1);
      }
      var fullyAnchored = true;
      var contradiction = false;
      for (var i = 1; i < attachPoints.length; i++) {
        if (attachPoints[i] == null) {
          fullyAnchored = false;
          continue; // plain-node leaf: rides the walk
        }
        ViPoint? match;
        for (final candidate in [stripTargets[i], attachPoints[i], altAttachPoints[i]]) {
          if (candidate != null && remaining.containsKey(candidate)) {
            match = candidate;
            break;
          }
        }
        if (match == null) {
          contradiction = true; // resolved endpoint the walk misses
          break;
        }
        final count = remaining[match]!;
        if (count == 1) {
          remaining.remove(match);
        } else {
          remaining[match] = count - 1;
        }
      }
      if (contradiction) continue;
      return (tree: tree, fidelity: fullyAnchored ? WireRouteFidelity.closed : WireRouteFidelity.walked);
    }
    return null;
  }

  /// The **reverse-solved** branching tier: the origin (first endpoint) is a
  /// plain-node DCO with no attach geometry, so the tree's one degree of
  /// freedom — its translation — is solved from the resolved FAR endpoints
  /// instead of walked from the origin. The walk shape is fully stored
  /// (every edge direction and length), so a single resolved far endpoint
  /// pins the translation exactly once its leaf is identified; the gate
  /// ships only when EXACTLY ONE candidate translation both
  ///
  ///  * closes every resolved far endpoint onto a distinct walked leaf (each
  ///    on any of its destination candidates, strip column target first), and
  ///  * lands the implied origin INSIDE the head endpoint's owner box
  ///    ([ViWire.endpointAnchors], bounds inclusive) — the branching analog
  ///    of the two-endpoint reverse walk's far-box containment.
  ///
  /// An ambiguous solve (two in-box candidates) or an origin beside the head
  /// node ships nothing. Nothing is fabricated: the geometry is the stored
  /// tree, placed by resolved-endpoint closure; the derived origin is
  /// implied, not guessed, but the head is not independently confirmed, so
  /// the tier is [WireRouteFidelity.walked]. Corpus (7,524 VIs, census
  /// pinned by `wire_route_census_test`): 15,155 extended tables have an
  /// unresolved origin; 9,147 carry a resolved far endpoint
  /// (`extRevAnchored`), and 8,867 solve to a unique in-box translation and
  /// ship (`extShippedRev`) — the other 280 are withheld (no candidate
  /// closes, none lands in the head box, or two do). Of the shipped tables'
  /// 8,148 UNRESOLVED far endpoints, 8,136 (99.85%) land their leaf within
  /// 8 px of their own owner box (`extRevPlainLeafInBox`) — independent
  /// corroboration the gate does not consume.
  static ({ViWireRouteTree tree, WireRouteFidelity fidelity})? _reverseSolvedRouteTree(
    ViWireBranchRoute route,
    List<ViPoint?> attachPoints,
    List<ViPoint?> altAttachPoints,
    List<ViPoint?> stripTargets,
    HeapRect? headBox,
  ) {
    if (headBox == null) return null;
    final local = walkWireBranchRoute(route, (x: 0, y: 0));
    final leaves = local.leaves;
    if (leaves.length != attachPoints.length - 1) return null;
    List<ViPoint> candidatesOf(int i) => [
      for (final p in [stripTargets[i], attachPoints[i], altAttachPoints[i]])
        if (p != null) p,
    ];
    // Whether translating the local walk by [origin] closes every resolved
    // far endpoint onto a distinct leaf.
    bool closesAll(ViPoint origin) {
      final remaining = <ViPoint, int>{};
      for (final leaf in leaves) {
        final p = (x: leaf.x + origin.x, y: leaf.y + origin.y);
        remaining.update(p, (c) => c + 1, ifAbsent: () => 1);
      }
      for (var i = 1; i < attachPoints.length; i++) {
        if (attachPoints[i] == null) continue;
        ViPoint? match;
        for (final candidate in candidatesOf(i)) {
          if (remaining.containsKey(candidate)) {
            match = candidate;
            break;
          }
        }
        if (match == null) return false;
        final count = remaining[match]!;
        if (count == 1) {
          remaining.remove(match);
        } else {
          remaining[match] = count - 1;
        }
      }
      return true;
    }

    // Candidate translations: the first resolved far endpoint against every
    // leaf (one of them must be its leaf, so the true translation is in the
    // set); dedupe via the set literal (records compare structurally).
    int? seed;
    for (var i = 1; i < attachPoints.length; i++) {
      if (attachPoints[i] != null) {
        seed = i;
        break;
      }
    }
    if (seed == null) return null;
    final candidates = <ViPoint>{
      for (final leaf in leaves)
        for (final p in candidatesOf(seed)) (x: p.x - leaf.x, y: p.y - leaf.y),
    };
    ViPoint? solved;
    for (final origin in candidates) {
      if (origin.x < headBox.left || origin.x > headBox.right || origin.y < headBox.top || origin.y > headBox.bottom) {
        continue;
      }
      if (!closesAll(origin)) continue;
      if (solved != null) return null; // ambiguous: two in-box solutions
      solved = origin;
    }
    if (solved == null) return null;
    return (tree: walkWireBranchRoute(route, solved), fidelity: WireRouteFidelity.walked);
  }

  /// The **DCO-child closed** branching tier — the branching analog of the
  /// two-endpoint [_dcoChildTierPoints] closed tier, consulted only after
  /// [_shippableRouteTree] (and its reverse-solved gate) declined. Applies
  /// only when the ORIGIN resolves no standard attach point: each origin
  /// candidate from [dcoChildTerminalAttach] walks the stored tree, and the
  /// tier ships — as [WireRouteFidelity.closed] — only when EVERY far
  /// endpoint closes zero-slack onto a distinct walked leaf via one of its
  /// destination candidates (the strip-column target, the standard/alternate
  /// attach points, or its own [dcoChildTerminalAttach] candidates, in that
  /// order). Nothing rides the walk: an endpoint with no candidate, or one
  /// the walk misses, withholds the tree.
  ({ViWireRouteTree tree, WireRouteFidelity fidelity})? _dcoChildRouteTree(
    ViWireBranchRoute route,
    List<int> refs,
    List<ViPoint?> attachPoints,
    List<ViPoint?> altAttachPoints,
    List<ViPoint?> stripTargets,
  ) {
    if (attachPoints.length < 3 || attachPoints[0] != null) return null;
    final origins = dcoChildTerminalAttach(refs[0])?.candidates;
    if (origins == null) return null;
    for (final origin in origins) {
      final tree = walkWireBranchRoute(route, origin);
      final leaves = tree.leaves;
      if (leaves.length != attachPoints.length - 1) continue;
      final remaining = <ViPoint, int>{};
      for (final leaf in leaves) {
        remaining.update(leaf, (c) => c + 1, ifAbsent: () => 1);
      }
      var closed = true;
      for (var i = 1; i < attachPoints.length; i++) {
        ViPoint? match;
        for (final candidate in [
          stripTargets[i],
          attachPoints[i],
          altAttachPoints[i],
          ...?dcoChildTerminalAttach(refs[i])?.candidates,
        ]) {
          if (candidate != null && remaining.containsKey(candidate)) {
            match = candidate;
            break;
          }
        }
        if (match == null) {
          closed = false;
          break;
        }
        final count = remaining[match]!;
        if (count == 1) {
          remaining.remove(match);
        } else {
          remaining[match] = count - 1;
        }
      }
      if (closed) return (tree: tree, fidelity: WireRouteFidelity.closed);
    }
    return null;
  }

  /// Member oid → the oid of the **terminal object** that declares it in its
  /// own `14 19` childRefs *and* carries a [ViHeapObject.termBounds] rect (a
  /// structure tunnel / shift register / selector / count terminal, or a
  /// node's growable terminal). The mapping is single-valued in the corpus
  /// (see [endpointTerminalBounds]); a target two distinct terminals claim is
  /// mapped to the [_ambiguousTerminal] sentinel and never guessed at. Built
  /// once on first access.
  late final Map<int, int> _terminalOidByMemberOid = _buildTerminalIndex();

  /// Sentinel in [_terminalOidByMemberOid] for a member oid that two distinct
  /// terminals claim (0 corpus instances; unseen input only). Oids are
  /// non-negative in both header forms, so -1 cannot collide.
  static const int _ambiguousTerminal = -1;

  Map<int, int> _buildTerminalIndex() {
    final index = <int, int>{};
    for (final object in objects) {
      if (object.termBounds == null) continue;
      for (final target in object.typedRefs[HeapRefKind.childRef] ?? const <int>[]) {
        final prev = index[target];
        index[target] = (prev == null || prev == object.oid) ? object.oid : _ambiguousTerminal;
      }
    }
    return index;
  }

  /// The **terminal object** a signal-endpoint DCO ([kSignalEndpointDcoKinds])
  /// attaches through — the object that names [oid] in its `14 19` childRefs
  /// and carries the endpoint's [ViHeapObject.termBounds] attach rect (plus
  /// its [ViHeapObject.termBmp] glyph where present) — or null when [oid] is
  /// not an endpoint DCO, no such terminal exists (a plain node's connection
  /// point), or the claim is ambiguous. See [endpointTerminalBounds] for the
  /// corpus census.
  ViHeapObject? endpointTerminal(int oid) {
    final endpoint = byId[oid];
    if (endpoint == null || !kSignalEndpointDcoKinds.contains(endpoint.kind)) return null;
    final terminalOid = _terminalOidByMemberOid[oid];
    return terminalOid == null || terminalOid == _ambiguousTerminal ? null : byId[terminalOid];
  }

  /// Direct children by parent oid — the positional child lists behind
  /// [children] and the constant/DCO resolvers. Built once on first access.
  late final Map<int, List<ViHeapObject>> childrenByOid = _childrenByParentOid(objects);

  /// Terminal oid → the oid of the endpoint **DCO it carries** (the inverse of
  /// [_terminalOidByMemberOid], with the added `14 4f` dcoRef backlink gate),
  /// or the [_ambiguousTerminal] sentinel where two distinct DCOs claim the
  /// terminal. Built once so [terminalDco] is an O(1) lookup rather than a
  /// per-call child walk. Only termBounds-carrying terminals appear.
  late final Map<int, int> _dcoOidByTerminalOid = _buildTerminalDcoIndex();

  Map<int, int> _buildTerminalDcoIndex() {
    final index = <int, int>{};
    for (final terminal in objects) {
      if (terminal.termBounds == null) continue;
      for (final target in terminal.typedRefs[HeapRefKind.childRef] ?? const <int>[]) {
        final candidate = byId[target];
        if (candidate == null || !kSignalEndpointDcoKinds.contains(candidate.kind)) continue;
        if (!(candidate.typedRefs[HeapRefKind.dcoRef] ?? const <int>[]).contains(terminal.oid)) continue;
        final prev = index[terminal.oid];
        index[terminal.oid] = (prev == null || prev == candidate.oid) ? candidate.oid : _ambiguousTerminal;
      }
    }
    return index;
  }

  /// The signal-endpoint **DCO a terminal carries** — [endpointTerminal]'s
  /// inverse: the unique `14 19` childRef target of terminal [oid] that is an
  /// endpoint-DCO kind ([kSignalEndpointDcoKinds]) *and* names the terminal
  /// back in its own `14 4f` dcoRef — or null when [oid] carries no
  /// [ViHeapObject.termBounds] rect, no such target exists, or more than one
  /// does (never guessed). Backed by the built-once [_dcoOidByTerminalOid].
  ///
  /// Corpus (7,524 VIs; censused with the glyph census on
  /// [terminalGlyphHidden]): the loop terminals resolve almost totally — the
  /// `i` iteration terminals (termBmp 1, class `0x24`) 6,883/6,889, the `N`
  /// count terminals (termBmp 2) 5,270/5,277, the loop-condition stop
  /// terminals (termBmp 192) 1,892/1,892, and the left shift registers
  /// (termBmp 3) 6,787/6,796 — while the case-selector row (termBmp 5:
  /// 66/15,398) and the right shift-register stacks (termBmp 4:
  /// 6,421/6,737) often claim several DCOs (a stacked register holds one per
  /// frame) and resolve only where the claim is unique.
  ViHeapObject? terminalDco(int oid) {
    final dcoOid = _dcoOidByTerminalOid[oid];
    return dcoOid == null || dcoOid == _ambiguousTerminal ? null : byId[dcoOid];
  }

  /// Whether LabVIEW **hides this structure terminal's glyph**:
  /// [kTerminalGlyphHiddenFlag] of the carried DCO's [ViHeapObject.objFlags]
  /// (via [terminalDco]; an unresolved DCO or absent flags word reads as
  /// shown). Lets a renderer drop exactly the loop-corner glyphs LabVIEW
  /// drops instead of guessing from wiring.
  ///
  /// Render-verified on the crc8 snippet's own LabVIEW raster (four for
  /// loops in one VI): the two drawn `i` glyphs ride DCO flags `0x020140`
  /// and the two absent ones `0x820140` — minimal pairs differing in the
  /// hidden bit alone — while all four `N` glyphs are drawn and all four
  /// count DCOs clear the bit (the crc8 unit test pins those four raw flag
  /// words). Corpus (7,524 VIs, structure terminals with a resolved DCO):
  /// the bit hides 100/6,883 resolved `i` iteration terminals — every one
  /// unwired, consistent with LabVIEW offering the hide only for unused
  /// terminals — and, on the timed-loop terminal pair, 8 `0xd7` (termBmp 214)
  /// and 4 `0xd8` (termBmp 215) terminals (also all unwired); it is never set
  /// on a count (0/5,270), stop (0/1,892), shift-register (0/13,208), or
  /// selector (0/66) DCO. The same bit rides 9,024 endpoint
  /// DCOs no terminal uniquely claims — parented under expandable-node kinds
  /// (`0x8c` 3,450 / `0xd6` 2,663 / `0x6a` 1,558 / `0x2f` 308 / …) and the
  /// `0x1d` endpoint buckets (350) — plausibly the same hidden/unused-terminal
  /// meaning there, but no reference render pins those, so this accessor stays
  /// scoped to termBounds-carrying terminals.
  bool terminalGlyphHidden(int oid) => ((terminalDco(oid)?.objFlags ?? 0) & kTerminalGlyphHiddenFlag) != 0;

  /// The **block-diagram constant** a signal-endpoint DCO wraps — the `0x13`
  /// [HeapObjectClass.bdConstDco] child of a bounds-less `0x15` endpoint —
  /// or null when [oid] is not such an endpoint or wraps none. The returned
  /// object carries the decoded value ([ViHeapObject.constNumeric] /
  /// [ViHeapObject.constText] / [ViHeapObject.constBool]); its drawable box
  /// is [endpointConstantBounds]. This is how a wired constant appears in
  /// the heap: the signal's endpoint DCO *parents* the constant, so e.g. a
  /// for loop's count feeder resolves as `N-part endpoint ↔ signal ↔
  /// constant endpoint → 0x13 → the value box LabVIEW draws beside `N`.
  ///
  /// Corpus (7,524 VIs; census pinned by `loop_terminal_census_test`):
  /// 54,627 signal endpoints wrap a constant — each exactly one `0x13`
  /// (0 multi), 38,131 with a decoded value — and every one of the 51,146
  /// two-endpoint signals resolving a constant shell holds it at endpoint 0
  /// (the route source), never at endpoint 1 and never at both ends.
  ViHeapObject? endpointConstant(int oid) {
    final endpoint = byId[oid];
    // The 0x16 bdLeaf endpoints are bounded leaves themselves and never wrap
    // a constant; only the bounds-less node-endpoint form does.
    if (endpoint == null || endpoint.kind != kNodeEndpointDcoKind) return null;
    for (final child in childrenByOid[oid] ?? const <ViHeapObject>[]) {
      if (child.kind == HeapObjectClass.bdConstDco.code) return child;
    }
    return null;
  }

  /// The **absolute bounds of a constant endpoint's value shell** — the first
  /// bounded direct child of [endpointConstant]'s `0x13` (the numeric /
  /// boolean / string control or array/cluster shell LabVIEW draws as the
  /// constant's box) — or null when no constant resolves, the shell is
  /// unbounded, or [version] predates the frame-relative coordinate space
  /// (< 8.6, the same gate as [endpointTerminalBounds]).
  ///
  /// Corpus (7,524 VIs; census pinned by `loop_terminal_census_test`): all
  /// 54,627 constant endpoints resolve exactly one bounded shell (0 boxless,
  /// 0 with two). Attach-point law, proven by the stored routes' zero-slack
  /// closure ([ViWire.routePoints]): walking each closable two-endpoint
  /// constant signal from this rect's floored centre closes exactly on the
  /// far attach point for 12,757 of 14,486 (88.1%) — the same centre
  /// convention as the bounded `0x16` endpoints. Of the 1,729 misses,
  /// 1,508 (87%) sit on composite array/cluster/container shells — `0x64`
  /// 621, `0x53` 492, `0x52` 395 (breakdown pinned per shell kind by
  /// `loop_terminal_census_test`) — where the true attach point sits
  /// off-centre (the element region, not the shell) and is not yet decoded;
  /// those routes stay unshipped rather than force-closed. TODO: decode the
  /// composite-shell attach offset.
  HeapRect? endpointConstantBounds(int oid) {
    if (_predatesFrameRelativeTermBounds(version)) return null;
    final constant = endpointConstant(oid);
    if (constant == null) return null;
    for (final child in childrenByOid[constant.oid] ?? const <ViHeapObject>[]) {
      if (child.absBounds != null) return child.absBounds;
    }
    return null;
  }

  /// The **element box** of an ARRAY-shell (`0x52`) constant endpoint — the
  /// rightmost bounded child that is not scaffolding (resize handles `0x9`,
  /// the label `0xa`): the `0x50` index displays sit on the LEFT and the
  /// value element (a `0x50` numeric, `0x4f` enum, a string box, …) sits
  /// right of them — or null for every other endpoint. An array constant's
  /// stored route anchors at either the shell's centre or this element's
  /// centre; the two conventions coexist in the corpus (1,408 shell / 119
  /// element closures), so the route closure arbitrates ([_routePointsFor] /
  /// [_shippableRouteTree] try the shell first and fall back to this rect,
  /// shipping only a zero-slack closure). Proven on crc8's LUT branch wire,
  /// whose route walked from this box's floored centre closes exactly on
  /// BOTH far tunnel attach rects.
  HeapRect? endpointConstantElementBounds(int oid) {
    if (_predatesFrameRelativeTermBounds(version)) return null;
    final constant = endpointConstant(oid);
    if (constant == null) return null;
    for (final child in childrenByOid[constant.oid] ?? const <ViHeapObject>[]) {
      if (child.absBounds == null) continue;
      if (child.kind != 0x52) return null;
      HeapRect? element;
      for (final kid in childrenByOid[child.oid] ?? const <ViHeapObject>[]) {
        final kidBounds = kid.absBounds;
        if (kid.kind == 0x9 || kid.kind == 0xa || kidBounds == null) continue;
        if (element == null || kidBounds.left > element.left) {
          element = kidBounds;
        }
      }
      return element;
    }
    return null;
  }

  /// The **absolute attach rectangle** of the signal-endpoint DCO [oid] — the
  /// structure tunnel square / shift-register box / selector glyph the wire
  /// visually connects to: [endpointTerminal]'s termBounds offset by the
  /// terminal's enclosing frame origin (its nearest bounded strict ancestor's
  /// top-left) — or null when no terminal resolves, no ancestor is bounded,
  /// or [version] predates the frame-relative coordinate space (LabVIEW
  /// < 8.6 — returning those would emit wrongly-composed rects).
  ///
  /// Corpus evidence (7,524 VIs; 902,107 signal endpoints — the single owner
  /// of this census, referenced by the related docs): 404,885 endpoints
  /// (44.88%) resolve a terminal; the endpoint→terminal mapping is unique
  /// (0 endpoints with two distinct claimants) and no resolving terminal
  /// carries own `C4 2D` bounds (0/404,885), so the nearest bounded strict
  /// ancestor is exactly the enclosing frame. Split by that frame:
  /// **structure** 382,691, **node** 20,052 (growable-node terminals),
  /// none/other 2,142. Structure-framed, LabVIEW **≥ 8.6** (381,505): the
  /// rect touches the frame's border ring exactly (0 px slack) for **99.09%**
  /// (378,016) and the remaining 0.91% (3,489 — interior terminals such as a
  /// loop's conditional terminal) land fully inside the frame — **100.00%**
  /// on-or-inside, 0 outliers. The boundary version itself is thin: 8.6 is
  /// the only pre-9.0 version above it with resolved endpoints (4, all
  /// border-exact). Node-framed rects are **approximate**: 91.92% inside the
  /// node ± 2 px — TODO: decode the 8.08% off-node residual. Structure-framed
  /// endpoints in **< 8.6** files (1,186, all v8.5) store termBounds in that
  /// era's absolute coordinate space (their `C4 2D` bounds records are
  /// absolute too, so the composed [ViHeapObject.absBounds] this offsets
  /// against is equally affected) — gated to null here; TODO: decode the
  /// < 8.6 absolute-coordinate heap convention as a whole. The unresolved
  /// 55.12% are dominated by plain-node endpoints (397,730 — node connection
  /// points do not use this record; their coarse anchor is the node itself).
  HeapRect? endpointTerminalBounds(int oid) {
    if (_predatesFrameRelativeTermBounds(version)) return null;
    final terminal = endpointTerminal(oid);
    final rel = terminal?.termBounds;
    if (terminal == null || rel == null) return null;
    final parentOid = terminal.parentOid;
    final frame = parentOid == null ? null : _boundedOwnerBounds(parentOid);
    if (frame == null) return null;
    return HeapRect(
      top: frame.top + rel.top,
      left: frame.left + rel.left,
      bottom: frame.top + rel.bottom,
      right: frame.left + rel.right,
    );
  }

  /// The **DCO-child terminal** attach candidates of endpoint [oid] — the
  /// second, inverse storage convention for a growable node's terminal
  /// geometry: instead of a termBounds-carrying terminal NAMING the DCO in
  /// its `14 19` childRefs (the [endpointTerminal] convention), the
  /// bounds-less `0x15` DCO itself PARENTS one termBounds-carrying child
  /// (an `0x30`/`0x33`/`0x3b`/`0x45`/`0x62`/… node-part), whose rect is
  /// relative to the DCO's nearest bounded ancestor (the node box). Returns
  /// the candidate attach points (most-likely first) plus whether the part
  /// is a **wide row cell**, or null when [oid] is not a bounds-less `0x15`
  /// DCO, parents no termBounds child or more than one (never guessed), no
  /// ancestor is bounded, or the file predates the frame-relative
  /// coordinate space (< 8.6, the same gate as [endpointTerminalBounds]).
  ///
  /// The attach point is the composed rect's floored centre — the same
  /// convention as [wireAttachPoint]. For a **wide row cell** (`0x62`,
  /// width > height: a growable node's row strip) the centre sits deep in
  /// the node's interior; the reference render (Excel_Read_XLSX's two row
  /// wires) pins the stored route on exactly that centre ROW, with the
  /// wire's visible ink stopping at the node border — the interior run is
  /// covered by the node body, like a route closing under a prim's icon.
  ///
  /// Corpus (7,524 VIs; pinned by `wire_route_census_test`): before this
  /// tier 139,907 two-endpoint tables shipped no route and 139,072 of them
  /// resolve this fallback on at least one end; 103,652 close zero-slack
  /// against it (`shippedClosedDcoChild`) and 2,705 more ship as wide-row
  /// anchored walks (`shippedWalkedDcoRow`). A part TALLER than one row can
  /// carry its centre off the true connection row (reference-read on a
  /// 16×27 `0x45` connecting 9 px below centre and an 11×21 `0x14b`
  /// connecting 6 px below), so the point is a closure CANDIDATE, never
  /// shipped bare — a signal whose candidates close nothing stays withheld.
  /// TODO: decode the multi-row part connection row.
  ({List<ViPoint> candidates, bool wideRow})? dcoChildTerminalAttach(int oid) {
    if (_predatesFrameRelativeTermBounds(version)) return null;
    final endpoint = byId[oid];
    if (endpoint == null || endpoint.kind != kNodeEndpointDcoKind || endpoint.absBounds != null) return null;
    ViHeapObject? part;
    for (final child in childrenByOid[oid] ?? const <ViHeapObject>[]) {
      if (child.termBounds == null) continue;
      if (part != null) return null; // two claimants: never guessed
      part = child;
    }
    final rel = part?.termBounds;
    if (part == null || rel == null) return null;
    final frame = _boundedOwnerBounds(oid);
    if (frame == null) return null;
    final left = frame.left + rel.left, top = frame.top + rel.top;
    final width = rel.right - rel.left, height = rel.bottom - rel.top;
    final centre = (x: left + width ~/ 2, y: top + height ~/ 2);
    return (
      candidates: [centre],
      wideRow: part.kind == 0x62 && width > height,
    );
  }

  /// The **attach point** of the signal-endpoint DCO [oid] — the absolute
  /// diagram point stored wire routes anchor to — or null when no attach
  /// geometry resolves. The point is the centre (halves floored, matching
  /// LabVIEW's integer grid) of the endpoint's attach rectangle:
  /// [endpointTerminalBounds] where a terminal resolves one (structure
  /// tunnels / border terminals), else [endpointConstantBounds] where the
  /// endpoint wraps a drawn constant, else the endpoint object's OWN bounds
  /// when it is bounded (the `0x16` front-panel-terminal endpoints — e.g. a
  /// 32×16 terminal at (58,1) attaches at its centre (74,9), which LabVIEW's
  /// own render of that wire confirms). One measured exception: a right shift
  /// register ([kRightShiftRegisterClass]) connects
  /// [kShiftRegisterColumnLeftOffset] px left of its rect centre (see
  /// [_attachPointFrom]). Null for the plain-node `0x15`
  /// endpoints (no attach geometry is stored; the wire meets the node at a
  /// per-terminal point the route's closing segment implies — see
  /// [ViWire.routePoints]) and for pre-8.6 files (the old coordinate space,
  /// same gate as [endpointTerminalBounds]).
  ViPoint? wireAttachPoint(int oid) =>
      _attachPointFrom(endpointTerminalBounds(oid) ?? endpointConstantBounds(oid), oid);

  /// [wireAttachPoint] with the endpoint's attach rect already resolved
  /// (so [_buildWire] reuses the rects it just computed): the rect's
  /// floored centre, else the own-bounds fallback — gated to the `0x16`
  /// [HeapObjectClass.bdLeaf] endpoints alone. The `0x15` node endpoints
  /// are bounds-less corpus-wide (0 of 862,159 carry bounds, a pinned
  /// law), and a bounded one would not make its box an attach rect.
  ///
  /// **Shift-register ([kRightShiftRegisterClass] /
  /// [kLeftShiftRegisterClass]) exception**: the stored-route connection
  /// column sits one column toward the loop INTERIOR of the register rect's
  /// centre — [kShiftRegisterColumnLeftOffset] px left for the right register,
  /// [kShiftRegisterColumnRightOffset] px right for the left register. Only
  /// the x moves; the y stays the floored centre (pinned by the vertical-first
  /// walk and by every crossing row). See the two constants for the
  /// render-oracle evidence. The offset applies only to a resolved attach
  /// rect (a terminal/constant bounds), never the own-bounds `0x16` fallback.
  ViPoint? _attachPointFrom(HeapRect? attachRect, int oid) {
    var rect = attachRect;
    if (rect == null) {
      if (_predatesFrameRelativeTermBounds(version)) return null;
      final endpoint = byId[oid];
      if (endpoint == null || endpoint.kind != HeapObjectClass.bdLeaf.code) return null;
      rect = endpoint.absBounds;
      if (rect == null) return null;
    }
    var x = rect.left + (rect.right - rect.left) ~/ 2;
    if (attachRect != null) {
      final terminalKind = endpointTerminal(oid)?.kind;
      if (terminalKind == kRightShiftRegisterClass) {
        x -= kShiftRegisterColumnLeftOffset;
      } else if (terminalKind == kLeftShiftRegisterClass) {
        x += kShiftRegisterColumnRightOffset;
      }
    }
    return (x: x, y: rect.top + (rect.bottom - rect.top) ~/ 2);
  }

  /// The stored-route **destination point** of endpoint [oid] when it attaches
  /// through a node terminal strip COLUMN — [kTerminalStripTargetLeftOffset]
  /// px left of the attach centre — or null for every other endpoint. Only a
  /// [kNodeTerminalStripClasses] terminal whose attach rect is exactly
  /// [kTerminalStripColumnWidth] px wide qualifies (row strips and other
  /// terminals keep the centre convention). The offset applies to routes
  /// ENDING on the strip alone; a route ORIGINATING from one anchors at the
  /// plain centre (see [kTerminalStripTargetLeftOffset] for the role-split
  /// census), so this is a far-endpoint candidate for the closure-arbitrated
  /// gates ([_routePointsFor], [_shippableRouteTree]), never the
  /// [wireAttachPoint].
  ViPoint? _stripFarTarget(int oid, HeapRect? attachRect, ViPoint? attach) {
    if (attachRect == null || attach == null) return null;
    if (attachRect.right - attachRect.left != kTerminalStripColumnWidth) return null;
    if (!kNodeTerminalStripClasses.contains(endpointTerminal(oid)?.kind)) return null;
    return (x: attach.x - kTerminalStripTargetLeftOffset, y: attach.y);
  }

  /// Walks [route] from attach point [s] and closes it onto attach point
  /// [t], returning the absolute polyline — [ViWireRoute.pointCount] points,
  /// one fewer when the closing run is zero-length (the walk already ends ON
  /// [t]; a duplicate terminal vertex is never emitted) — or null when
  /// either anchor is unknown or the closure is not exact (see
  /// [ViWire.routePoints]; never force-closed).
  static List<ViPoint>? _closedRoutePoints(ViWireRoute route, ViPoint? s, ViPoint? t) {
    if (s == null || t == null) return null;
    final n = route.pointCount;
    if (n == 1) return s == t ? [s] : null;
    final direction = route.direction;
    if (direction == null) return null;
    var x = s.x, y = s.y;
    var horizontal = direction.isHorizontal;
    var sign = direction.dx + direction.dy;
    final points = <ViPoint>[s];
    final lengths = route.segmentLengths;
    for (var k = 0; k < lengths.length; k++) {
      if (k > 0) sign = route.jointSigns[k - 1];
      if (horizontal) {
        x += lengths[k] * sign;
      } else {
        y += lengths[k] * sign;
      }
      points.add((x: x, y: y));
      horizontal = !horizontal;
    }
    // The closing segment: its length is implied by [t], so the walk must
    // already agree on the perpendicular axis, and the closing direction
    // must match the stored final sign. A zero-length closure has no drawn
    // run to check the sign against (census: `shippedZeroClose`) and the
    // walk already ended ON [t] — appending it would emit a degenerate
    // duplicate vertex, so the polyline is one point shorter there.
    if (horizontal ? y != t.y : x != t.x) return null;
    final along = horizontal ? t.x - x : t.y - y;
    final closingSign = route.jointSigns.isEmpty ? sign : route.jointSigns.last;
    if (along != 0 && (along > 0 ? 1 : -1) != closingSign) return null;
    if (along != 0) points.add(t);
    return points;
  }

  /// The [ViHeapObject.absBounds] of [oid]'s nearest bounded owner — the object
  /// itself if bounded, else the nearest positional ancestor with bounds — or
  /// null if none (and if [oid] does not resolve). Guards a repeated-oid cycle.
  HeapRect? _boundedOwnerBounds(int oid) {
    final start = byId[oid];
    return start == null ? null : _boundedOwnerObject(start)?.absBounds;
  }

  /// [start]'s nearest bounded owner OBJECT — [start] itself if bounded, else
  /// the nearest positional ancestor with [ViHeapObject.absBounds] — or null if
  /// none. The object-returning analog of [_boundedOwnerBounds] used by
  /// [_exactAttach] to read the composing frame's [ViHeapObject.category].
  /// Guards a repeated-oid cycle.
  ViHeapObject? _boundedOwnerObject(ViHeapObject start) {
    ViHeapObject? object = start;
    final seen = <int>{};
    while (object != null && seen.add(object.oid)) {
      if (object.absBounds != null) return object;
      final parentOid = object.parentOid;
      object = parentOid == null ? null : byId[parentOid];
    }
    return null;
  }
}

/// Groups [objects] by their [ViHeapObject.parentOid] (objects with a null parent
/// are omitted) — the positional child lists used by both the node-fallback pass
/// and the scrolled-control re-anchor.
Map<int, List<ViHeapObject>> _childrenByParentOid(List<ViHeapObject> objects) {
  final kids = <int, List<ViHeapObject>>{};
  for (final object in objects) {
    if (object.parentOid != null) (kids[object.parentOid!] ??= <ViHeapObject>[]).add(object);
  }
  return kids;
}

/// Scalar value-byte count of an attribute record's stored width, or null for
/// the length-prefixed forms (`blob`/`container`/`f64`/`rect`).
int? _attrScalarBytes(HeapAttrWidth width) => switch (width) {
  HeapAttrWidth.flag => 0,
  HeapAttrWidth.u8 => 1,
  HeapAttrWidth.u16 => 2,
  HeapAttrWidth.u24 => 3,
  HeapAttrWidth.rgb => 4,
  _ => null,
};

/// An attribute record's value payload as flat bytes: the length-prefixed
/// payload verbatim, or a scalar re-serialised big-endian at its stored
/// width. Null for the zero-byte flag form and non-integer scalars.
Uint8List? _attrFlatBytes(HeapAttr record) {
  final raw = record.rawValueBytes;
  if (raw != null) return raw;
  final scalarBytes = _attrScalarBytes(record.width);
  final value = record.asInt;
  if (scalarBytes == null || scalarBytes == 0 || value == null) return null;
  final out = Uint8List(scalarBytes);
  for (var i = 0; i < scalarBytes; i++) {
    out[i] = (value >> (8 * (scalarBytes - 1 - i))) & 0xff;
  }
  return out;
}

/// An integer scalar is certain only below this (2²³): a 4-byte scalar at or
/// above it has a nonzero SGL exponent field, i.e. its bits also read as a
/// **representable normal single** (≥ ~1.2e-38), so the integer reading is not
/// certain and the decode declines — in both directions: 16 corpus constants
/// in `[2²³, 2³¹)` with a low leading byte are declined as possible SGL bits,
/// and an SGL **subnormal** (< ~1.2e-38, bits < 2²³) would decode as its small
/// integer bit value — corpus ground truth shows zero subnormal-sgl constants,
/// so the integer reading is taken there.
const int _intCertainCeil = 0x800000;

/// The magnitude window in which an 8-byte constant payload is accepted as an
/// IEEE-754 double. Corpus-separated: every f64 reading of a `0x50` 8-byte
/// payload is either in `[1e-9, 3.2e9]` (real doubles — the DFDS-ground-truthed
/// values all sit here) or below `1e-309` (denormal-region readings — how
/// i64/u64 payloads under 2⁵² read when misinterpreted), with **nothing
/// between**; the window takes the real-double band plus margin. An aliasing
/// integer inside the window must lie in the narrow non-round band
/// `[0x3D7 << 52, 0x427 << 52]` ≈ `[4.43e18, 4.79e18]` (or its negative
/// mirror near −2⁶³) — round large integers (e.g. 10¹⁸) read below `1e-241`
/// and are declined. NaN (i64 −1 = `FF…FF`) and ±∞ (`0x7FF0…`/`0xFFF0…`,
/// plausible i64 bit patterns) are declined outright.
const double _dblWindowFloor = 1e-12, _dblWindowCeil = 1e12;

/// The all-zero length-prefixed payload lengths accepted as a numeric zero:
/// the containered zero of a 4-byte (`4+1`) or 8-byte (`8+1`) type. The corpus
/// also holds 7 all-zero extended-width forms (`16+1`, `32+1`) which are
/// declined with the rest of the EXT family, and no other all-zero lengths.
const Set<int> _zeroPayloadLengths = {5, 9};

/// Decodes a **flattened path** (`PTH0`) constant-value payload into the text
/// LabVIEW displays inside the path-constant box, or null (not decoded).
///
/// Layout: 4-byte ident `PTH0`, `u32` content length, then the content —
/// `u16` path type, `u16` component count, `count` × Pascal-string segments.
/// Bytes beyond `8 + length` are slot padding, not content (68 of the 514
/// corpus records carry it). Corpus (7,574 files): 514 path-typed constValue
/// records, every one on a `0x13` [HeapObjectClass.bdConstDco]; 153 are the
/// RELATIVE form (type 1) whose display is reference-render ground-truthed
/// (Excel_Read_XLSX's `xl\workbook.xml` / `xl\sharedStrings.xml` /
/// `xl\worksheets`): the segments joined by `\`. Absolute (type 0), UNC
/// (type 2), the single `PTH2` record and empty paths are framed here but
/// stay text-undecoded — their display form has no reference-render pin yet
/// (TODO: pin `C:`-style absolute display against a reference before
/// claiming it).
String? decodeFlatPathText(Uint8List? raw) {
  if (raw == null || raw.length < 12) return null;
  if (raw[0] != 0x50 || raw[1] != 0x54 || raw[2] != 0x48 || raw[3] != 0x30) {
    return null;
  }
  final view = ByteData.sublistView(raw);
  final contentLength = view.getUint32(4);
  final end = 8 + contentLength;
  if (end > raw.length) return null;
  final pathType = view.getUint16(8);
  final count = view.getUint16(10);
  if (pathType != 1 || count < 1) return null;
  var offset = 12;
  final segments = <String>[];
  for (var i = 0; i < count; i++) {
    if (offset >= end) return null;
    final len = raw[offset];
    if (offset + 1 + len > end) return null;
    segments.add(String.fromCharCodes(raw, offset + 1, offset + 1 + len));
    offset += 1 + len;
  }
  if (offset != end) return null;
  return segments.join(r'\');
}

/// The **type-independent FALLBACK tier** of [decodeBdConstValues]: decodes a
/// BD constant's captured `0x26C` payload ([flat], stored at a [scalar]
/// magnitude width or a length-prefixed container/blob) without a VCTP type —
/// the payload is typed by the constant's value-carrier class [innerKind]
/// (the `0x13` [HeapObjectClass.bdConstDco]'s first nested child) plus
/// payload-shape gates, and every gate declines rather than guessing.
/// Returns a [bool], [int], finite [double], [String], or null (not decoded).
///
/// Corpus (7,524 VIs; 54,801 constants, each carrying exactly one value record
/// — census on [HeapAttribute.constValue]); "ground truth" = decoded constants
/// whose payload uniquely byte-matches a value slot of a tiled `DFDS` data
/// space ([dataSpaceSlots]), typed by that slot's VCTP descriptor. Every
/// number below is recomputed and pinned exactly by the `bd_const_values`
/// corpus-snapshot census (`const_value_census_test.dart`):
///
///   * **boolean** — carrier [HeapObjectClass.booleanOrClusterControl], scalar
///     of ≤ 2 value bytes, value in {0, 1} → the bool. 7,504 decode; every
///     corpus `0x4f` constant payload is binary (5,149 one-byte + 2,355
///     two-byte; the two-byte form matches the legacy 2-byte boolean type the
///     VCTP catalogs as `booleanU16`). DFDS cannot ground-truth booleans
///     (their {0,1} payloads zero-extend onto any same-valued slot width), so
///     this gate rests on the class catalog and the all-binary domain.
///   * **integer** — carrier [HeapObjectClass.numericControl] (or
///     [HeapObjectClass.enumRingControl] / [HeapObjectClass.clusterShell]
///     carrying an enum item table); scalar payload; certain only when
///     non-negative in every integer reading (leading stored byte < `0x80` —
///     `FF FF FF FF` is i32 −1 or u32 4,294,967,295 depending on the
///     unresolved type) **and** below [_intCertainCeil] (else the bits also
///     read as a normal SGL); plus the [_zeroPayloadLengths] containered zero
///     → the zero-extended magnitude. 15,611 decode (2,871 of them containered
///     zeros); ground truth 1,840/1,840 integer-family
///     (i8..u64/enum/typeDef). The cost of the two-sided declines:
///     high-leading-byte scalars (legitimate large unsigned values among
///     them) and `[2²³, 2³¹)` integers stay undecoded.
///   * **double** — carrier `0x50`, 8-byte payload whose f64 reading is finite
///     with magnitude 0 or within [_dblWindowFloor]..[_dblWindowCeil] → the
///     double (see the window's alias analysis). 860 decode; ground truth
///     179/179 `dbl`.
///
/// String constants (carrier [HeapObjectClass.stringOrArrayControl]) are
/// decoded by the [ViHeapObject.constText] path: 14,813 constants; ground
/// truth 4,342 matched → 4,264 `string` + 55 `typeDef` (named string
/// wrappers) + 23 composite-slot byte-coincidences. The remaining 16,013
/// constants (compound arrays/clusters/paths, 16/32-byte extendeds, ambiguous
/// scalars and 8-byte payloads) are framed but not value-decoded.
Object? decodeBdConstantValue({
  required int? innerKind,
  required Uint8List? flat,
  required bool scalar,
  bool hasEnumItems = false,
}) {
  if (flat == null) return null;
  final scalarBytes = scalar ? flat.length : null;
  int? scalarValue;
  if (scalar) {
    var magnitude = 0;
    for (final byte in flat) {
      magnitude = (magnitude << 8) | byte;
    }
    scalarValue = magnitude;
  }
  // The length-prefixed payload (container or validated blob; a blob is
  // printable-validated text, so the all-zero and 8-byte-f64 content gates
  // below can never fire on one).
  final raw = scalar ? null : flat;
  final carrier = innerKind == null ? HeapObjectClass.unknown : HeapObjectClass.fromCode(innerKind);
  switch (carrier) {
    case HeapObjectClass.pathControl:
      return decodeFlatPathText(raw);
    case HeapObjectClass.stringOrArrayControl:
      // The 8-byte `[u32 strLen][ascii]` form: [decodeHeapAttr]'s u32-string
      // gate excludes length 8 (width-ambiguous with a stored f64 without the
      // carrier class in view), so the string carrier resolves it here. The
      // framing must be exact (strLen + 4 == payload) and fully printable —
      // Excel_Read_XLSX's `INIT` is the reference-render pin.
      if (raw != null && raw.length == 8) {
        final strLen = ByteData.sublistView(raw).getUint32(0);
        if (strLen == 4 && raw.skip(4).every((b) => b >= 0x20 && b < 0x7f)) {
          return String.fromCharCodes(raw, 4);
        }
      }
      return null;
    case HeapObjectClass.booleanOrClusterControl:
      if (scalarBytes != null && scalarBytes <= 2 && (scalarValue == 0 || scalarValue == 1)) {
        return scalarValue == 1;
      }
      return null;
    case HeapObjectClass.enumRingControl when hasEnumItems:
    case HeapObjectClass.clusterShell when hasEnumItems:
    case HeapObjectClass.numericControl:
      if (scalarBytes != null && scalarValue != null) {
        if (scalarValue == 0) return scalarValue;
        final leading = (scalarValue >>> (8 * (scalarBytes - 1))) & 0xff;
        if (leading >= 0x80 || scalarValue >= _intCertainCeil) return null;
        return scalarValue;
      }
      if (carrier != HeapObjectClass.numericControl || raw == null) return null;
      if (_zeroPayloadLengths.contains(raw.length) && raw.every((byte) => byte == 0)) {
        return 0;
      }
      if (raw.length == 8) {
        // An all-zero 8-byte payload lands here as +0.0.
        final f64Reading = ByteData.sublistView(raw).getFloat64(0);
        if (!f64Reading.isFinite) return null;
        if (f64Reading == 0 || (f64Reading.abs() >= _dblWindowFloor && f64Reading.abs() <= _dblWindowCeil)) {
          return f64Reading;
        }
      }
      return null;
    default:
      return null;
  }
}

/// Recovers the [ViDiagram] from a decompressed heap [body] by walking its
/// balanced typed-group tree ([walkHeapObjects]): object headers become
/// [ViHeapObject]s parented by the enclosing object; `C4 2D`/`C4 22`/
/// `14 19 01 fd` records attach to the innermost object; absolute coordinates
/// compose down the object-ancestor chain. Total/bounds-safe. [version] is
/// the VI's `vers` string when the caller has container context — it gates
/// the version-dependent coordinate decodes (see [ViDiagram.version]).
ViDiagram buildDiagram(Uint8List body, {String sectionTag = 'BDHb', String? version}) {
  final objects = <ViHeapObject>[];
  final c4ops = <ViHeapObject, Set<int>>{};
  final formatPayloads = <ViHeapObject, List<int>>{};
  final absTop = <ViHeapObject, int>{};
  final absLeft = <ViHeapObject, int>{};
  final liveParent = <ViHeapObject, ViHeapObject?>{};
  final length = body.length;

  // Text style-run capture (the tag-`0x25` group inside a label object; see
  // [HeapPropertyToken.textStyleRuns]): one tag-`0x19` sub-group per run,
  // whose narrow `0x27`/`0x28` records are the run's start offset and face
  // mask. The shared-tag records inside the group (`0x28` = style mask, not
  // backgroundColor) are routed here and never reach the object handlers.
  ViHeapObject? styleRunOwner;
  var styleRunGroupDepth = 0;
  var styleRunStart = 0;
  var styleRunMask = 0;
  var styleRunOpen = false;
  var styleRuns = <({int start, int style})>[];

  walkHeapObjects<ViHeapObject>(
    body,
    onGroupOpen: (groupTag, cur) {
      if (styleRunOwner == null) {
        if (groupTag == 0x25 && cur != null) {
          styleRunOwner = cur;
          styleRunGroupDepth = 1;
          styleRuns = [];
        }
        return;
      }
      styleRunGroupDepth++;
      if (groupTag == 0x19 && styleRunGroupDepth == 2) {
        styleRunOpen = true;
        styleRunStart = 0;
        styleRunMask = 0;
      }
    },
    onGroupClose: (groupTag, cur) {
      if (styleRunOwner == null) return;
      styleRunGroupDepth--;
      if (styleRunOpen && styleRunGroupDepth == 1) {
        styleRuns.add((start: styleRunStart, style: styleRunMask));
        styleRunOpen = false;
      }
      if (styleRunGroupDepth == 0) {
        if (styleRuns.isNotEmpty) styleRunOwner!.textStyleRuns = styleRuns;
        styleRunOwner = null;
      }
    },
    onObjectOpen: (span, kind, oid, parent) {
      final cur = ViHeapObject(oid: oid, kind: kind, offset: span.offset);
      cur.parentOid = parent?.oid;
      liveParent[cur] = parent;
      absTop[cur] = absTop[parent] ?? 0;
      absLeft[cur] = absLeft[parent] ?? 0;
      objects.add(cur);
      c4ops[cur] = <int>{};
      return cur;
    },
    onRecord: (span, cur) {
      if (cur == null) return;
      final offset = span.offset;
      final lead = span.lead;
      if (styleRunOpen && identical(cur, styleRunOwner)) {
        final attr = decodeHeapAttr(body, offset);
        final value = attr?.asInt;
        if (attr != null && value != null) {
          if (attr.id == 0x27) styleRunStart = value;
          if (attr.id == 0x28) styleRunMask = value;
        }
        return;
      }
      if (lead == kHeapRecordPrefix) {
        final rec = c4FrameAt(body, offset, sectionTag);
        if (rec == null) return;
        c4ops[cur]!.add(rec.opcode);
        switch (rec.opcode) {
          case 0x2d:
            if (cur.bounds == null && rec.bounds != null) {
              final bounds = rec.bounds!;
              cur.bounds = bounds;
              final top = (absTop[cur] ?? 0) + bounds.top;
              final left = (absLeft[cur] ?? 0) + bounds.left;
              absTop[cur] = top;
              absLeft[cur] = left;
              cur.absBounds = HeapRect(top: top, left: left, bottom: top + bounds.height, right: left + bounds.width);
            }
          case 0x22:
            cur.label ??= rec.text;
          case 0x1f:
            cur.termCount++;
          case 0x74:
            formatPayloads[cur] ??= rec.payload;
          case 0x2e:
            if (cur.items.isEmpty) cur.items = _parseEnumItems(rec.payload);
          case 0x19:
            cur.helpText ??= rec.descriptionText;
          case 0x27:
            {
              final text = rec.text ?? rec.path ?? rec.descriptionText;
              if (text != null && text.isNotEmpty) cur.plotNames = [...cur.plotNames, text];
            }
        }
      } else if (lead == 0x14) {
        final ref = decodeHeapRef(body, offset);
        if (ref != null) {
          (cur.typedRefs[ref.kind] ??= <int>[]).add(ref.targetOid);
          if (ref.kind == HeapRefKind.childRef) cur.refs.add(ref.targetOid);
        }
      } else if (offset + 1 < length && _objAttrIds.contains(body[offset + 1])) {
        final attr = decodeHeapAttr(body, offset);
        if (attr == null) return;
        final number = attr.asDouble;
        if (number != null && kControlTerminalCodes.contains(cur.kind)) {
          if (attr.attribute == HeapAttribute.stdNumMin) cur.controlMin ??= number;
          if (attr.attribute == HeapAttribute.stdNumMax) cur.controlMax ??= number;
        }
        // Both validated string forms of the record decode to asString: the
        // `C6 6C FF <u16len>` blob and the short `C6 6C <u8len>` u32-string
        // (see [decodeHeapAttr]); non-validating payloads decode as container
        // and stay off this path.
        if (attr.attribute == HeapAttribute.constValue) {
          final text = attr.asString;
          if (text != null && text.isNotEmpty) cur.constText ??= text;
        }
        // A caption of 1-4 characters stored at a scalar attribute width:
        // raw 0x022 ([HeapAttribute.shortText]) is the same tag as the
        // `C4 22` caption container, with the text bytes magnitude-encoded
        // big-endian in reading order (`84 22 58 4F 52 3F` = "XOR?"). It is
        // the dedicated short-label tag: 96.9% of the captured records sit on
        // the label class 0x0A (98% across the text-label classes 0x0A/0x95),
        // the rest on the enum/selector text carriers. A record becomes a
        // caption only when every stored byte is a printable ASCII glyph AND
        // the decoded text fills the whole stored width — a genuine N-char
        // caption uses the N-byte width, so a value whose leading byte is null
        // (a shorter string than the width, e.g. `00 42 42 42` at u32) is a
        // number, not text, and stays numeric ([HeapAttr.asciiText] length <
        // width). Non-printable bytes — control codes AND high-bit Latin-1
        // alike — likewise stay numeric. Corpus (7,524 VIs, all heap
        // sections): 148,449 scalar-width records — 72,537 captured, 72,359
        // zero (empty), 2 width-inconsistent and 3,551 non-printable (550
        // high-bit, 3,001 control) left numeric. First-wins against `C4 22`
        // is trivially safe: no corpus object carries both forms.
        if (attr.attribute == HeapAttribute.shortText) {
          final text = attr.asciiText;
          if (text != null && text.length == _attrScalarBytes(attr.width)) {
            cur.label ??= text;
          }
        }
        // A BD constant's flattened value record scopes to the 0x13 DCO itself
        // (record census on [HeapAttribute.constValue]). First-wins is
        // trivially safe: no corpus constant carries a second record. CAPTURE
        // only — the value is interpreted later by [decodeBdConstValues],
        // once data-space types have resolved.
        if (attr.attribute == HeapAttribute.constValue &&
            cur.kind == HeapObjectClass.bdConstDco.code &&
            cur.constValueRaw == null) {
          cur.constValueRaw = _attrFlatBytes(attr);
          cur.constValueScalar = _attrScalarBytes(attr.width) != null;
        }
        // The numeric display window's printf-style display format
        // ([HeapAttribute.formatStyle], raw 0x074). Corpus: 32,440 records,
        // every one printable '%'-led text (scalar widths carry the bytes
        // magnitude-encoded big-endian, e.g. 0x25303878 = "%08x").
        if (attr.attribute == HeapAttribute.formatStyle) {
          final bytes = _attrFlatBytes(attr);
          if (bytes != null && bytes.isNotEmpty && bytes.first == 0x25 && bytes.every((b) => b >= 0x20 && b < 0x7f)) {
            cur.displayFormat ??= String.fromCharCodes(bytes);
          }
        }
        if (attr.attribute == HeapAttribute.termBounds) cur.termBounds ??= attr.asRect;
        if (attr.attribute == HeapAttribute.termBMPs) cur.termBmp ??= attr.asInt;
        if (attr.attribute == HeapAttribute.typeDescIndex) cur.typeDescIdx ??= attr.asInt;
        if (attr.attribute == HeapAttribute.objFlags) cur.objFlags ??= attr.asInt;
        // primResID is class-scoped (0x2F at 99.95%) and u16-encoded in the
        // corpus; the rare off-class or off-width carriers are not primitive
        // identities, so they must not fabricate a primName.
        if (attr.attribute == HeapAttribute.primResID && cur.kind == 0x2f && attr.width == HeapAttrWidth.u16) {
          cur.primResId ??= attr.asInt;
        }
        if (attr.attribute == HeapAttribute.dIdx && kMultiFrameStructureKinds.contains(cur.kind)) {
          cur.dIdx ??= attr.asInt;
        }
        // The wire table rides every attribute width: long tables use the
        // length-prefixed container; tables of 1/2/4 bytes ride the scalar
        // u8/u16/rgb widths (a 2-byte straight-wire table `[02][dir]` is a
        // u16 scalar, a 4-byte one-bend table `[03][dir][sign][len]` a
        // 4-byte scalar). The 3-byte u24 width is captured for totality but
        // unobserved on signals (0 corpus tables of length 3 — the pinned
        // `tables3Byte` law; the grammar has no 3-byte form). Scalars are
        // re-serialised big-endian so [wireTableRaw] is the table bytes in
        // every case. First-wins is safe: no corpus signal carries a second
        // table record.
        if (attr.attribute == HeapAttribute.compressedWireTable && cur.kind == 0x17) {
          if (attr.width == HeapAttrWidth.container) {
            cur.wireTableRaw ??= attr.rawValueBytes;
          } else {
            final scalarBytes = _attrScalarBytes(attr.width);
            final value = attr.asInt;
            if (scalarBytes != null && scalarBytes > 0 && value != null) {
              final table = Uint8List(scalarBytes);
              for (var b = 0; b < scalarBytes; b++) {
                table[b] = (value >> (8 * (scalarBytes - 1 - b))) & 0xff;
              }
              cur.wireTableRaw ??= table;
            }
          }
        }
        // Kind-gated to the signal class (the record census puts the tag on
        // 0x17 at 99.99% — the stray off-class carriers are not wire types)
        // and width-gated to the documented u16 layout: an over-wide value
        // is not a wire-type word and is dropped rather than masked (the
        // census law `oversizedTypeWord == 0` pins that none exist).
        if (attr.attribute == HeapAttribute.lastSignalKind && cur.kind == 0x17) {
          final word = attr.asInt;
          if (word != null && word <= 0xffff) cur.lastSignalKind ??= word;
        }
        // The transparent sentinel (flag 0x01, RGB 0) is "no colour", not
        // black — capturing it would paint transparent label backings and
        // fills as solid black. Raw value 0x00000001 is likewise a flag, not
        // a colour: every label part carries a trailing backgroundColor
        // record of exactly 0x1 after its real (often transparent) colour,
        // and RGB 0x000001 as a deliberate near-black is implausible.
        final rawColor = attr.kind == HeapAttrKind.color && attr.value is int ? attr.value as int : null;
        final rgb = attr.isTransparent || rawColor == 0x1 ? null : attr.rgb;
        if (rgb != null) {
          switch (attr.attribute) {
            case HeapAttribute.backgroundColor:
              cur.bgRgb ??= rgb;
            case HeapAttribute.fgColor:
              cur.fgRgb ??= rgb;
            case HeapAttribute.contentColor:
              cur.contentRgb ??= rgb;
            case HeapAttribute.structColor:
              cur.structRgb ??= rgb;
            case HeapAttribute.borderColor:
              cur.borderRgb ??= rgb;
            case HeapAttribute.plotColor:
              (cur.plotColors.isEmpty ? (cur.plotColors = <int>[]) : cur.plotColors).add(rgb);
            default:
              break;
          }
        }
      }
    },
  );

  // A label part composes against its OWNER's final origin. The walk-time
  // accumulator misses exactly one case: an owner whose own bounds record
  // serialises after the label child (a structure label stored at (-17,0),
  // directly above its case) — the label then composed against the
  // grandparent frame. Recomposing every bounded-owner label against the
  // owner's final origin is identical when the owner's bounds came first
  // (the common order) and fixes the late-bounds owners.
  for (final object in objects) {
    if (object.kind != HeapObjectClass.controlLabel.code) continue;
    final parent = liveParent[object];
    final local = object.bounds;
    final ownerBounds = parent?.bounds;
    final ownerAbs = parent?.absBounds;
    if (local == null || ownerBounds == null || ownerAbs == null) continue;
    object.absBounds = HeapRect(
      top: ownerAbs.top + local.top,
      left: ownerAbs.left + local.left,
      bottom: ownerAbs.top + local.top + local.height,
      right: ownerAbs.left + local.left + local.width,
    );
  }

  // A flat sequence's `0x121` frames compose against the `0xca`'s own final
  // origin regardless of record order. The 0xca's bounds record serialises
  // AFTER its frame children open, so the walk-time accumulator composed the
  // whole strip's content against the strip's PARENT frame (Excel_Read_XLSX:
  // every strip child lands 491px left / 106px up of its reference ink;
  // shifted, 24 of 26 boxed children sit at 96-100% perimeter-on-ink, the
  // other two are text labels). Constants and other late-bounds carriers
  // keep the order-scoped composition — recomposing them against final
  // origins regresses the wire-closure censuses — so this pass is scoped to
  // 0xca→0x121 subtrees.
  final childrenOf = <ViHeapObject, List<ViHeapObject>>{};
  for (final object in objects) {
    final parent = liveParent[object];
    if (parent != null) (childrenOf[parent] ??= []).add(object);
  }
  void shiftSubtree(ViHeapObject root, int dTop, int dLeft) {
    final b = root.absBounds;
    if (b != null) {
      root.absBounds = HeapRect(
        top: b.top + dTop,
        left: b.left + dLeft,
        bottom: b.bottom + dTop,
        right: b.right + dLeft,
      );
    }
    for (final child in childrenOf[root] ?? const <ViHeapObject>[]) {
      shiftSubtree(child, dTop, dLeft);
    }
  }

  for (final object in objects) {
    if (object.kind != 0xca || object.absBounds == null) continue;
    for (final frame in childrenOf[object] ?? const <ViHeapObject>[]) {
      final local = frame.bounds;
      final abs = frame.absBounds;
      if (frame.kind != 0x121 || local == null || abs == null) continue;
      final dTop = object.absBounds!.top + local.top - abs.top;
      final dLeft = object.absBounds!.left + local.left - abs.left;
      if (dTop != 0 || dLeft != 0) shiftSubtree(frame, dTop, dLeft);
    }
  }

  for (final object in objects) {
    object.category = classifyObject(kind: object.kind, termCount: object.termCount);
    object.typeKind = inferTypeKind(c4ops[object] ?? const <int>{}, formatPayloads[object]);
  }

  final byOid = {for (final object in objects) object.oid: object};
  for (final object in objects) {
    if (object.items.isEmpty) continue;
    var parentOid = object.parentOid;
    var depth = 0;
    while (parentOid != null && depth < 12) {
      final po = byOid[parentOid];
      if (po == null) break;
      if (kControlTerminalCodes.contains(po.kind)) {
        if (po.items.isEmpty) po.items = object.items;
        break;
      }
      parentOid = po.parentOid;
      depth++;
    }
  }

  for (final object in objects) {
    final helpText = object.helpText;
    if (helpText == null || helpText.isEmpty || object.absBounds != null) continue;
    var parentOid = object.parentOid;
    final seen = <int>{};
    while (parentOid != null && seen.add(parentOid)) {
      final po = byOid[parentOid];
      if (po == null) break;
      if (po.absBounds != null) {
        po.helpText ??= helpText;
        break;
      }
      parentOid = po.parentOid;
    }
  }

  final nodeKids = _childrenByParentOid(objects);

  for (final object in objects) {
    if (object.category != ViObjectKind.unknown) continue;
    final bounds = object.absBounds;
    if (bounds == null || bounds.width <= 0 || bounds.height <= 0) continue;
    if (bounds.width * bounds.height >= _structureAreaCap) continue;
    if (object.parentOid == null || byOid[object.parentOid]?.kind != 0x1b) continue;
    final cs = nodeKids[object.oid];
    if (cs == null) continue;
    final hasStructural = cs.any((c) => c.kind == 0x15);
    final hasConnector = cs.any((c) => c.kind == 0x68);
    if (!hasStructural || hasConnector) continue;
    object.category = ViObjectKind.node;
  }

  for (final object in objects) {
    if (object.category != ViObjectKind.node || object.label != null) continue;
    final caps = (nodeKids[object.oid] ?? const <ViHeapObject>[])
        .where((c) => c.kind == HeapObjectClass.controlLabel.code)
        .map((c) => c.label?.trim())
        .where((cap) => cap != null && cap.isNotEmpty);
    if (caps.isNotEmpty) object.label = caps.first;
  }

  _reanchorScrolledControls(objects, byOid, nodeKids);
  return ViDiagram(sectionTag: sectionTag, objects: objects, version: version);
}

/// Parses a `C4 2E` string-table payload into its ordered enum/ring item labels
/// (packed Pascal strings `[u8 len][chars]…`), keeping every item in order
/// including short ones (`On`, `Up`). For an enum the item position IS its
/// ordinal, so this is ordinal-safe: if any entry is malformed (length overruns)
/// or non-printable, the whole table is rejected (returns `[]`) rather than
/// silently dropping one entry and shifting every later ordinal.
List<String> _parseEnumItems(List<int> payload) {
  final out = <String>[];
  var i = 0;
  while (i < payload.length) {
    final len = payload[i++];
    if (len == 0) continue;
    if (i + len > payload.length) return const [];
    final text = String.fromCharCodes(payload.sublist(i, i + len));
    i += len;
    if (!text.codeUnits.every((c) => c >= 0x20 && c < 0x7f)) return const [];
    out.add(text);
  }
  return out;
}

/// Re-anchors **scrolled-cluster control terminals** to their content viewport.
///
/// A control terminal nested under a `0x11c` content viewport stores its bounds
/// in the viewport's *scrolled content* coordinate frame (tops are typically
/// large-negative), so composing absolute coordinates down the ancestor chain
/// detaches the control — it floats far above its own cluster. The fix: re-anchor
/// every such control to its viewport's absolute origin, using the **min corner
/// of the control group sharing that viewport** as the content origin (an
/// overlap-safe equivalent of the unstored scroll origin — each group's source
/// coordinates are internally non-overlapping, so a pure group translation
/// preserves that). The whole control subtree (label, sub-terminals) is shifted
/// by the same delta so it stays intact.
///
/// Control terminals **not** under a `0x11c` (direct on-diagram terminals) are
/// already in correct absolute coordinates and are left untouched. Validated on a
/// 398-section sample: control↔control overlap 6.5% → 0.35%,
/// re-anchored-control-center-inside-its-viewport 12% → 99%.
///
/// [byOid] and [kids] are [buildDiagram]'s oid index and positional child
/// lists; this pass reads them and mutates neither.
void _reanchorScrolledControls(
  List<ViHeapObject> objects,
  Map<int, ViHeapObject> byOid,
  Map<int, List<ViHeapObject>> kids,
) {
  /// The viewport to re-anchor [o] to — its nearest `0x11c` ancestor — but null
  /// if any control or other positioned/bounded container sits between them
  /// (those put [o]'s bounds in that container's frame, not the viewport's, so it
  /// must ride along with the parent's subtree shift instead). Guards a parentOid
  /// cycle (oids can repeat) so the walk can't loop forever.
  int? reanchorViewport(ViHeapObject object) {
    var parentOid = object.parentOid;
    final seen = <int>{};
    while (parentOid != null) {
      if (!seen.add(parentOid)) return null;
      final po = byOid[parentOid];
      if (po == null) return null;
      if (po.kind == 0x11c) return po.oid;
      if (kControlTerminalCodes.contains(po.kind) || po.bounds != null) return null;
      parentOid = po.parentOid;
    }
    return null;
  }

  final groups = <int, List<ViHeapObject>>{};
  for (final object in objects) {
    if (!kControlTerminalCodes.contains(object.kind) || object.bounds == null || object.absBounds == null) continue;
    final viewport = reanchorViewport(object);
    if (viewport != null) (groups[viewport] ??= <ViHeapObject>[]).add(object);
  }

  /// Shifts [root] and its whole subtree by (dTop, dLeft). Because `kids` is keyed
  /// by oid and oids can repeat, two guards keep this O(reachable) instead of
  /// O(objects^2) on large diagrams: dedup by object identity at enqueue (`seen`),
  /// and expand each oid's child list at most once (`expanded`). Each object is
  /// still shifted exactly once by the same delta, so the result is unchanged.
  void shiftSubtree(ViHeapObject root, int dTop, int dLeft) {
    if (dTop == 0 && dLeft == 0) return;
    final seen = <ViHeapObject>{root};
    final expanded = <int>{};
    final work = <ViHeapObject>[root];
    while (work.isNotEmpty) {
      final object = work.removeLast();
      final bounds = object.absBounds;
      if (bounds != null) {
        object.absBounds = HeapRect(
          top: bounds.top + dTop,
          left: bounds.left + dLeft,
          bottom: bounds.bottom + dTop,
          right: bounds.right + dLeft,
        );
      }
      if (!expanded.add(object.oid)) continue;
      final cs = kids[object.oid];
      if (cs != null) {
        for (final child in cs) {
          if (seen.add(child)) work.add(child);
        }
      }
    }
  }

  for (final MapEntry(key: vOid, value: controls) in groups.entries) {
    final viewport = byOid[vOid];
    if (viewport?.absBounds == null) continue;
    final minTop = controls.map((c) => c.bounds!.top).reduce(min);
    final minLeft = controls.map((c) => c.bounds!.left).reduce(min);
    for (final control in controls) {
      final newTop = viewport!.absBounds!.top + (control.bounds!.top - minTop);
      final newLeft = viewport.absBounds!.left + (control.bounds!.left - minLeft);
      shiftSubtree(control, newTop - control.absBounds!.top, newLeft - control.absBounds!.left);
    }
  }
}

/// The [ViTypeKind] a resolved pool type kind renders as, or null for kinds
/// the renderer has no signal for.
ViTypeKind? _typeKindOf(ViDataType type) => switch (type) {
  ViDataType.i8 ||
  ViDataType.i16 ||
  ViDataType.i32 ||
  ViDataType.i64 ||
  ViDataType.u8 ||
  ViDataType.u16 ||
  ViDataType.u32 ||
  ViDataType.u64 => ViTypeKind.numericInt,
  ViDataType.sgl ||
  ViDataType.dbl ||
  ViDataType.ext ||
  ViDataType.complexSgl ||
  ViDataType.complexDbl ||
  ViDataType.complexExt => ViTypeKind.numericFloat,
  ViDataType.enumU8 || ViDataType.enumU16 || ViDataType.enumU32 => ViTypeKind.enumRing,
  ViDataType.boolean => ViTypeKind.boolean,
  ViDataType.string || ViDataType.cString || ViDataType.pascalString || ViDataType.subString => ViTypeKind.string,
  ViDataType.path => ViTypeKind.path,
  ViDataType.cluster => ViTypeKind.cluster,
  ViDataType.array || ViDataType.subArray || ViDataType.arrayDataPointer => ViTypeKind.array,
  ViDataType.refnum => ViTypeKind.refnum,
  _ => null,
};

/// The calibration anchors: BD object classes whose data kind the class
/// catalog pins down, keyed by class code — the single source for both the
/// anchor filter and the expectation test. Codes follow [HeapObjectClass]:
/// `0x51` string/array control, `0x4f` boolean/cluster control, `0x25`
/// loop conditional, `0x24`/`0x26` loop count/maximum.
final Map<int, bool Function(ViDataType)> _typeAnchors = {
  0x51: (t) {
    final kind = _typeKindOf(t);
    return kind == ViTypeKind.string || kind == ViTypeKind.array || kind == ViTypeKind.refnum;
  },
  0x4f: (t) => t == ViDataType.boolean || t == ViDataType.cluster,
  0x25: (t) => t == ViDataType.boolean,
  0x24: (t) => _typeKindOf(t) == ViTypeKind.numericInt,
  0x26: (t) => _typeKindOf(t) == ViTypeKind.numericInt,
};

/// Resolves every heap object's `typeDescIndex` through the VCTP top-level
/// [table] into the [pool], setting [ViHeapObject.typeKind],
/// [ViHeapObject.dataType] and [ViHeapObject.typeName]; an object without
/// its own index (a BD terminal `0x16`) inherits through its `dcoRef` (the
/// paired front-panel DCO), resolved same-heap first (the corpus splits
/// dcoRef targets ~90% same heap / ~10% sibling heap, and oids repeat
/// across heaps).
///
/// The heap's indices carry a **per-VI base**: where that base is stored
/// has not been found, so it is **self-calibrated** per VI — the offset
/// that maximises agreement between the [_typeAnchors] classes and their
/// resolved kinds. Calibration demands at least 2 anchors and 90%
/// agreement; otherwise every type stays unresolved rather than guessed.
/// The search window (−8..48) is wider than the bases observed on the
/// snippet corpus (0..9 over 31/32 calibrating VIs) to cover larger VIs;
/// a wrong window cannot mis-resolve silently because the agreement gate
/// still applies. Calibration uses block-diagram anchors and applies the
/// base to both heaps: the data space is VI-global (verified on the corpus
/// by the resolved panel names and reference-render colours agreeing).
///
/// A successful resolution **overwrites** a heuristically inferred
/// [ViHeapObject.typeKind] — the pool descriptor is the VI's own type
/// declaration, where the `C4 74` format inference is a guess — so colour
/// and glyph can never disagree.
///
/// Ends by running [decodeBdConstValues] over every diagram — the single
/// BD-constant value decode pass, deliberately placed after type resolution
/// so the typed tier has every resolvable type in hand.
void resolveDataSpaceTypes({
  required List<ViType> pool,
  required List<int> table,
  required List<ViDiagram> blockDiagrams,
  required List<ViDiagram> frontPanelDiagrams,
}) {
  final diagrams = [...blockDiagrams, ...frontPanelDiagrams];

  ViHeapObject? findDco(ViDiagram own, int oid) {
    final local = own.byId[oid];
    if (local != null) return local;
    for (final diagram in diagrams) {
      if (identical(diagram, own)) continue;
      final hit = diagram.byId[oid];
      if (hit != null) return hit;
    }
    return null;
  }

  // Direction needs no type table or base: a panel DCO's objFlags bit 0 set
  // = indicator (output); clear or absent on a typed DCO = control. A BD
  // terminal inherits it through its dcoRef (same-heap match first — the
  // corpus splits targets ~90/10 across heaps and oids repeat between
  // heaps).
  for (final diagram in diagrams) {
    for (final object in diagram.objects) {
      if (object.kind == 0x12 && object.typeDescIdx != null) {
        object.isIndicator = ((object.objFlags ?? 0) & 1) != 0;
      }
    }
  }
  for (final diagram in diagrams) {
    for (final object in diagram.objects) {
      if (object.isIndicator != null) continue;
      final dcoRefs = object.typedRefs[HeapRefKind.dcoRef];
      if (dcoRefs == null || dcoRefs.isEmpty) continue;
      object.isIndicator = findDco(diagram, dcoRefs.first)?.isIndicator;
    }
  }

  _resolveTypeIndices(pool: pool, table: table, blockDiagrams: blockDiagrams, diagrams: diagrams, findDco: findDco);

  // The single BD-constant value decode pass, now that every resolvable type
  // is on its object. Runs unconditionally: on a VI whose base never
  // calibrates nothing resolves and the pass is fallback-only.
  for (final diagram in diagrams) {
    decodeBdConstValues(diagram);
  }
}

/// The table+base type resolution behind [resolveDataSpaceTypes] (see its
/// doc for the calibration law); split out so the decode pass that follows
/// it runs even when calibration declines.
void _resolveTypeIndices({
  required List<ViType> pool,
  required List<int> table,
  required List<ViDiagram> blockDiagrams,
  required List<ViDiagram> diagrams,
  required ViHeapObject? Function(ViDiagram own, int oid) findDco,
}) {
  if (pool.isEmpty || table.isEmpty) return;

  ViType? resolve(int base, int index) {
    final ti = base + index;
    if (ti < 0 || ti >= table.length) return null;
    final pi = table[ti];
    return pi >= 0 && pi < pool.length ? pool[pi] : null;
  }

  final anchors = <(int, int)>[
    for (final diagram in blockDiagrams)
      for (final object in diagram.objects)
        if (object.typeDescIdx != null && _typeAnchors.containsKey(object.kind)) (object.kind, object.typeDescIdx!),
  ];
  if (anchors.length < 2) return;
  int? base;
  var bestHits = 0;
  for (var k = -8; k <= 48; k++) {
    var hits = 0;
    for (final (kind, index) in anchors) {
      final type = resolve(k, index);
      if (type != null && _typeAnchors[kind]!(type.kind)) hits++;
    }
    if (hits > bestHits) {
      bestHits = hits;
      base = k;
    }
  }
  if (base == null || bestHits < anchors.length * 0.9) return;

  for (final diagram in diagrams) {
    for (final object in diagram.objects) {
      final index = object.typeDescIdx;
      if (index == null) continue;
      final type = resolve(base, index);
      if (type == null) continue;
      final kind = _typeKindOf(type.kind);
      if (kind != null) object.typeKind = kind;
      object.dataType = type.kind;
      object.resolvedType = type;
      // The array descriptor's elementIndex addresses the POOL directly
      // (verified on Excel_Read_XLSX: 'Cells'->string, 'Unzipped
      // files'->path, 'filenames'->string; the table+base route resolves
      // those to booleans). 'Worksheets' resolves to an array of CLUSTERS
      // — LabVIEW's pink array rendering is the cluster-of-strings tint,
      // not the string tint.
      final elementIndex = type.elementIndex;
      if (type.kind == ViDataType.array && elementIndex != null && elementIndex >= 0 && elementIndex < pool.length) {
        object.resolvedElementType = pool[elementIndex];
        if (object.resolvedElementType!.kind == ViDataType.cluster) {
          object.resolvedElementMembers = clusterFields(object.resolvedElementType!, pool);
        }
      }
      if (type.kind == ViDataType.cluster) {
        object.resolvedMembers = clusterFields(type, pool);
      }
      if (type.name != null && type.name!.trim().isNotEmpty) {
        object.typeName ??= type.name!.trim();
      }
    }
  }
  // A BD terminal inherits its paired DCO's resolved type: same-heap match
  // first, then the sibling heaps in diagram order.
  for (final diagram in diagrams) {
    for (final object in diagram.objects) {
      if (object.typeDescIdx != null) continue;
      final dcoRefs = object.typedRefs[HeapRefKind.dcoRef];
      if (dcoRefs == null || dcoRefs.isEmpty) continue;
      final dco = findDco(diagram, dcoRefs.first);
      if (dco == null) continue;
      if (dco.typeKind != ViTypeKind.unknown) object.typeKind = dco.typeKind;
      object.dataType ??= dco.dataType;
      object.resolvedType ??= dco.resolvedType;
      object.resolvedElementType ??= dco.resolvedElementType;
      if (object.resolvedMembers.isEmpty) {
        object.resolvedMembers = dco.resolvedMembers;
      }
      if (object.resolvedElementMembers.isEmpty) {
        object.resolvedElementMembers = dco.resolvedElementMembers;
      }
      object.typeName ??= dco.typeName;
    }
  }
}

/// Flat serialized byte size of a fixed-width numeric [ViDataType], or null
/// for every other kind.
int? _flatNumericSize(ViDataType kind) => switch (kind) {
  ViDataType.i8 || ViDataType.u8 || ViDataType.enumU8 => 1,
  ViDataType.i16 || ViDataType.u16 || ViDataType.enumU16 => 2,
  ViDataType.i32 || ViDataType.u32 || ViDataType.enumU32 || ViDataType.sgl => 4,
  ViDataType.i64 || ViDataType.u64 || ViDataType.dbl => 8,
  _ => null,
};

/// One numeric element read big-endian from [flat] at [offset], typed by
/// [kind]: signed integers two's-complement at full width, sgl/dbl IEEE-754,
/// everything else unsigned. (An i64/u64 top-bit value lands in Dart's
/// wrapped 64-bit int.)
num _flatNumericAt(Uint8List flat, int offset, ViDataType kind, int size) {
  if (kind == ViDataType.sgl) return ByteData.sublistView(flat).getFloat32(offset);
  if (kind == ViDataType.dbl) return ByteData.sublistView(flat).getFloat64(offset);
  var value = 0;
  for (var i = 0; i < size; i++) {
    value = (value << 8) | flat[offset + i];
  }
  final signed = kind == ViDataType.i8 || kind == ViDataType.i16 || kind == ViDataType.i32 || kind == ViDataType.i64;
  return signed ? value.toSigned(8 * size) : value;
}

/// The **TYPED tier** of [decodeBdConstValues]: decodes a BD constant's
/// captured payload strictly by its **resolved data-space type**
/// ([ViHeapObject.resolvedType] over [constValueRaw]). Every gate declines
/// rather than guessing. Corpus (7,524 VIs, resolved-type constants only):
///
///   * **numeric scalar** — a fixed-width numeric type whose scalar payload
///     fits the type's width decodes as that type: unsigned/enum as stored,
///     signed two's-complement at full width, `sgl` as its IEEE-754 bits
///     (the SGL-alias and sign ambiguities of the type-independent gates are
///     settled by the descriptor). 5,211 of 5,730 integer-typed scalars fit
///     (877 of them beyond the type-independent gates); the 519 stored WIDER
///     than their type (e.g. a 3-byte scalar on a u16 type) are declined —
///     TODO: their encoding is not yet decoded.
///   * **array** — `[u32 × dimCount dims][elements big-endian]` for a
///     resolved array of a fixed-width numeric element ([constArray] /
///     [constArrayDims]): 205 payloads match the length law exactly and 322
///     empty arrays (every dim 0) carry exactly one trailing zero pad byte;
///     5 length mismatches and 2 dims-truncated payloads decline. Non-numeric
///     element kinds (string/path/cluster/…, 1,107 constants) are not yet
///     decoded (TODO).
///
/// Boolean, string and path types have no typed layout law here yet — their
/// populations decode entirely through the fallback tier's carrier-class
/// gates (whose corpus census they own).
void _typedBdConstDecode(ViHeapObject object) {
  final flat = object.constValueRaw;
  final type = object.resolvedType;
  if (flat == null || type == null) return;
  final scalarSize = _flatNumericSize(type.kind);
  if (scalarSize != null) {
    if (flat.isEmpty || flat.length > scalarSize) return;
    // A payload narrower than the type is the value's zero-extended
    // magnitude; sgl/dbl and signed readings need the full width.
    if (flat.length < scalarSize && (type.kind == ViDataType.sgl || type.kind == ViDataType.dbl)) {
      return;
    }
    final size = flat.length;
    final kind = size < scalarSize ? ViDataType.u64 : type.kind;
    final value = _flatNumericAt(flat, 0, kind, size);
    if (value is double && !value.isFinite) return;
    object.constNumeric = value;
    return;
  }
  if (type.kind != ViDataType.array) return;
  final element = object.resolvedElementType;
  final dimCount = type.dimCount;
  if (element == null || dimCount == null || dimCount < 1 || dimCount > 8) {
    return;
  }
  final elementSize = _flatNumericSize(element.kind);
  if (elementSize == null || flat.length < 4 * dimCount) return;
  final view = ByteData.sublistView(flat);
  final dims = [for (var d = 0; d < dimCount; d++) view.getUint32(4 * d)];
  var count = 1;
  for (final dim in dims) {
    count *= dim;
  }
  final expected = 4 * dimCount + count * elementSize;
  final emptyPadded = count == 0 && flat.length == 4 * dimCount + 1 && flat.last == 0;
  if (flat.length != expected && !emptyPadded) return;
  object.constArrayDims = dims;
  object.constArray = [
    for (var i = 0; i < count; i++) _flatNumericAt(flat, 4 * dimCount + i * elementSize, element.kind, elementSize),
  ];
}

/// Decodes every BD constant's value in [diagram] — the single decode pass.
/// The architecture: heap parse ([buildDiagram]) only CAPTURES the flattened
/// `0x26C` payload ([ViHeapObject.constValueRaw] + its stored width form);
/// [resolveDataSpaceTypes] then resolves each object's data-space type; this
/// pass, run once after that, does all value interpretation. Two tiers, one
/// precedence: the typed law first ([_typedBdConstDecode], strict by the
/// resolved type), then the type-independent carrier-class rules
/// ([decodeBdConstantValue]) for whatever the typed tier left undecoded —
/// including constants whose type never resolved.
///
/// The fallback runs on a typed DECLINE too, not only on an unresolved type,
/// because the corpus shows the constant-DCO type resolution mis-assigns for
/// a minority — payload+carrier evidence contradicts the resolved kind (an
/// 8-byte IEEE-754 payload on an i32-resolved constant; a `{0,1}` `0x4f`
/// boolean payload on a string-resolved constant) — while the type-free
/// gates still decode: corpus (7,524 VIs) 2,082 containered zeros, 88
/// payloads wider than their resolved type, 24 narrower than their resolved
/// float type, 2,404 numerics on resolved kinds with no typed layout law
/// (typeDef/string/boolean/refnum/cluster/void/…), 600 booleans and 1,469
/// texts on non-boolean/non-string-resolved constants. TODO: decode where
/// those constants' `typeDescIndex` actually points. The tier ORDER is
/// value-neutral on the whole corpus: everywhere both tiers land (4,347
/// integer + 454 double constants) they agree exactly, so the typed tier
/// never contradicts the carrier-class census and vice versa.
void decodeBdConstValues(ViDiagram diagram) {
  final nodeKids = _childrenByParentOid(diagram.objects);
  // Depth-capped: the positional tree is stack-balanced, but oids are not
  // guaranteed unique, so an oid-keyed descent must not trust acyclicity.
  bool subtreeHasItems(ViHeapObject o, [int depth = 0]) {
    if (o.items.isNotEmpty) return true;
    if (depth >= 16) return false;
    for (final kid in nodeKids[o.oid] ?? const <ViHeapObject>[]) {
      if (subtreeHasItems(kid, depth + 1)) return true;
    }
    return false;
  }

  for (final object in diagram.objects) {
    if (object.kind != HeapObjectClass.bdConstDco.code || object.constValueRaw == null) continue;
    _typedBdConstDecode(object);
    // The value carrier class is the constant DCO's first nested child (see
    // [HeapObjectClass.bdConstDco]); enum items may sit on any descendant,
    // so the item probe walks the whole subtree — but only for the
    // enum-shaped carriers that consume it.
    final kids = nodeKids[object.oid];
    if (kids == null || kids.isEmpty) continue;
    final carrierKind = kids.first.kind;
    final wantsItems =
        carrierKind == HeapObjectClass.enumRingControl.code || carrierKind == HeapObjectClass.clusterShell.code;
    final value = decodeBdConstantValue(
      innerKind: carrierKind,
      flat: object.constValueRaw,
      scalar: object.constValueScalar,
      hasEnumItems: wantsItems && subtreeHasItems(object),
    );
    if (value is bool) object.constBool ??= value;
    if (value is num) object.constNumeric ??= value;
    if (value is String) object.constText ??= value;
  }
}
