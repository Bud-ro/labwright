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

  /// The object's label/caption (from a `C4 22` record), or null.
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
  /// [HeapAttribute.constValue], raw `0x26C`, the `C6 6C FF` blob form) — e.g.
  /// `"%f"` or `"ps2000aRunStreaming"`, or null. This is the constant's literal
  /// data, NOT documentation; it is not help text and must not render as such.
  String? constText;

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

  /// A structure terminal's box **relative to its structure's frame**
  /// ([HeapAttribute.termBounds], raw `0x129`) — where a loop's iteration /
  /// count / conditional terminal (or shift register) sits — or null.
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

  /// A multi-frame structure's raw diagram-index word ([HeapAttribute.dIdx],
  /// raw `0x04d`) — which stacked frame LabVIEW displays — or null when the
  /// record is absent (the first frame is displayed). Bit 31 is a flag, not
  /// part of the index (corpus: every out-of-range raw value but one is
  /// `0x80000000 | index`); read [visibleFrameIndex].
  int? dIdx;

  /// The stacked frame index LabVIEW displays for this multi-frame structure
  /// (case/event/stacked-sequence): [dIdx] with the bit-31 flag stripped, or
  /// 0 when the record is absent. Snippet-validated against the in-box
  /// content heuristic: 106/117 agreement, with the disagreements in VIs
  /// whose content geometry the heuristic is known to mislocate, and every
  /// heuristic-undecidable structure resolved. Corpus: 8,070 of 16,959
  /// multi-frame structures carry the record; 8,069 are in range after the
  /// mask (one true outlier — callers must range-check against the actual
  /// frame count).
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
  /// with the vertical connector implicit between consecutive runs. The wire's
  /// datatype and its endpoint binding to terminals are not yet decoded, and
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
  /// The signal itself carries no bounds; its packed route lives in the
  /// compressedWireTable payload (interior undecoded). Its **datatype is not
  /// recovered**: neither the signal nor its endpoints carry a type, and the
  /// per-object [HeapAttribute.typeDescIndex] reachable from ~8.7% of signals
  /// (via an endpoint's `14 4f` dcoRef) is an object ordinal that agrees across
  /// a signal's endpoints in 0.0% of cases, so it cannot identify a shared wire
  /// type without resolving VCTP type content (see [ViWire]).
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
// 0x4d is dIdx (gated to the multi-frame structure kinds).
const _objAttrIds = {0x20, 0x21, 0x6c, 0x24, 0x28, 0x6f, 0x19, 0x2b, 0x2a, 0x29, 0x3a, 0xcb, 0xea, 0xe7, 0x4d};

/// The structure classes that stack multiple `0x1b` frames and display one
/// (case `0x2c`, event `0xcd`, stacked/timed variants `0xd5`/`0x29`) —
/// corpus multi-frame census 15,332 / 1,214 / 390 / 23. The displayed frame
/// comes from [ViHeapObject.visibleFrameIndex].
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
///
/// The wire's **datatype is not exposed**, because it is not corpus-provable
/// from the signal: neither the signal nor its endpoint objects carry a type,
/// and the per-object [HeapAttribute.typeDescIndex] reachable from ~8.7% of
/// signals (via an endpoint's `14 4f` dcoRef) is an object ordinal that agrees
/// across a signal's endpoints in 0.0% of cases — identifying a shared wire type
/// would require resolving the VCTP type table's flattened content, which this
/// model does not do. A consumer that wants to colour a wire can read the type
/// of a bounded endpoint owner it recognises; this model does not assert one.
class ViWire {
  ViWire({required this.signalOid, required this.endpointOids, required this.endpointAnchors, this.route});

  /// The [ViHeapObject.oid] of the signal (`0x17`) object this wire is.
  final int signalOid;

  /// The oids of the endpoint data-connection objects the signal joins (its
  /// `14 19` childRefs), in heap order. Two for 91% of signals (source + sink);
  /// three or more where the signal branches. Direction (which endpoint is the
  /// source) is not recovered, so the order is not asserted to be source-first.
  final List<int> endpointOids;

  /// The absolute bounds anchoring each endpoint — the [ViHeapObject.absBounds]
  /// of the endpoint's nearest bounded owner (itself or a positional ancestor:
  /// the node or `0x1d` wire segment it attaches to). Index-aligned with
  /// [endpointOids]; an entry is null only when the endpoint oid does not
  /// resolve (not observed in the corpus).
  final List<HeapRect?> endpointAnchors;

  /// The decoded stored route shape (see [ViWireRoute] / [decodeWireRoute]),
  /// or null when the signal carries the trivial scalar table (a straight
  /// wire), or a form not yet decoded (branching junction codes).
  final ViWireRoute? route;
}

/// The decoded shape of a signal's stored wire route (its `0x1e7` packed
/// table): [pointCount] route points as **alternating-axis segments starting
/// horizontal**, where [segmentLengths] are the unsigned lengths of the
/// leading segments and [jointSigns] the sign (+1 down/right, −1 up/left) of
/// the segment *leaving* each interior joint. The first segment's sign and
/// the trailing segment(s) are not stored — they are implied by the
/// endpoints, so a renderer aims the first segment toward the destination
/// and closes the route on the destination's connection point.
///
/// Corpus validation (7,524 VIs): on all 49,404 two-endpoint container
/// signals with bounded anchors, the decoded displacement lands the implied
/// final segment on the destination anchor (interval test, 8 px slack) for
/// **99.59%** under the horizontal-first reading (H-only fits 38,559,
/// either-orientation 10,640, V-only 38, no fit 166 — 99.66% counting the
/// V-only contradictions); interior-joint sign bytes are `0`/`1` at
/// 105,632 of 105,633 records (a single 2-endpoint exception). Ground
/// truth: consistent within 1 px of LabVIEW's own render of the
/// `basic.png` snippet (bend column measured at x=102-103 vs the decoded
/// 102; input row y=21).
class ViWireRoute {
  ViWireRoute({required this.pointCount, required this.segmentLengths, required this.jointSigns});

  /// The stored route point count (the table's leading byte).
  final int pointCount;

  /// Unsigned lengths of the stored leading segments, axis-alternating
  /// starting horizontal. `pointCount - 2` entries in the common form;
  /// `pointCount - 1` in the extended header form.
  final List<int> segmentLengths;

  /// Sign of the segment leaving interior joint i (+1 = down/right,
  /// −1 = up/left), aligned with the segment of the same index + 1.
  final List<int> jointSigns;
}

/// Decodes a signal's packed `0x1e7` container [table] into a [ViWireRoute].
///
/// Layout (derived + corpus-validated, see [ViWireRoute]):
/// `[u8 pointCount] [0x08 | 0x00 0x08] [(pointCount-2) sign bytes]
/// [length values]` where a length ≥ 255 is stored as `FF` + u16be. The
/// short header carries `pointCount-2` lengths (trailing segment implied);
/// the extended `00 08` header carries `pointCount-1` — a length-accounting
/// observation only: the extended form never occurs on two-endpoint signals,
/// so its geometry is not yet validated (TODO: validate once the branching
/// junction codes are decoded). Returns null for a malformed table or one
/// using the undecoded branching junction codes (sign bytes outside
/// `0`/`1` — observed almost exclusively on signals with 3+ endpoints; one
/// two-endpoint exception in the corpus).
ViWireRoute? decodeWireRoute(Uint8List table) {
  if (table.length < 2 || table[0] < 2) return null;
  final n = table[0];
  final int dataStart;
  if (table[1] == 0x08) {
    dataStart = 2;
  } else if (table.length > 2 && table[1] == 0x00 && table[2] == 0x08) {
    dataStart = 3;
  } else {
    return null;
  }
  var i = dataStart;
  final signs = <int>[];
  for (var k = 0; k < n - 2; k++) {
    if (i >= table.length) return null;
    final m = table[i++];
    if (m != 0 && m != 1) return null;
    signs.add(m == 0 ? 1 : -1);
  }
  final lengths = <int>[];
  while (i < table.length) {
    var v = table[i++];
    if (v == 0xff) {
      if (i + 1 >= table.length) return null;
      v = (table[i] << 8) | table[i + 1];
      i += 2;
    }
    lengths.add(v);
  }
  // The header determines the count: the short form stores pointCount-2
  // lengths, the extended form pointCount-1 — a mismatch is a malformed
  // table, not the other family.
  if (lengths.length != (dataStart == 2 ? n - 2 : n - 1)) return null;
  return ViWireRoute(pointCount: n, segmentLengths: lengths, jointSigns: signs);
}

/// A recovered block-diagram (or other heap) as a **nesting tree** of
/// [ViHeapObject]s with absolute coordinates. The `14 19 01 fd` references are
/// child-membership (structure → contained oids). LabVIEW's *logical* dataflow
/// wires are the **signal** objects (class `0x17`), which DO carry resolvable
/// oid endpoints — surfaced as [ViWire] via [wires]; the visual `0x1d` wire
/// segments are geometry-only (no oid endpoints). Partial/honest: object class
/// codes and wire direction/datatype are not fully decoded.
class ViDiagram {
  ViDiagram({required this.sectionTag, required this.objects});

  /// The section this diagram came from (`BDHb` = block diagram, `FPHb` = front panel).
  final String sectionTag;

  /// All recovered objects, in heap (pre-order) order.
  final List<ViHeapObject> objects;

  /// Objects indexed by their unique [ViHeapObject.oid]. Built once on first
  /// access (a repeated oid keeps the last object — see [ViHeapObject.oid]).
  late final Map<int, ViHeapObject> byId = {for (final object in objects) object.oid: object};

  /// The root object(s) of the nesting tree (parentOid == null) — normally the
  /// single diagram root (kind `0x7e`).
  Iterable<ViHeapObject> get roots => objects.where((o) => o.parentOid == null);

  /// The direct children of the object with [oid] in the nesting tree.
  Iterable<ViHeapObject> children(int oid) => objects.where((o) => o.parentOid == oid);

  /// The bounded objects (have an absolute rectangle) — the drawable layout layer.
  Iterable<ViHeapObject> get nodes => objects.where((o) => o.absBounds != null);

  /// The **dataflow wires** — one [ViWire] per signal (`0x17`) object, with its
  /// endpoint oids ([ViHeapObject.refs], the `14 19` childRefs) resolved to
  /// anchor rectangles. Built once on first access. Empty on a heap with no
  /// signals (e.g. a front panel). See [ViWire].
  late final List<ViWire> wires = [
    for (final object in objects)
      if (object.kind == 0x17)
        ViWire(
          signalOid: object.oid,
          endpointOids: List<int>.of(object.refs),
          endpointAnchors: [for (final oid in object.refs) _boundedOwnerBounds(oid)],
          route: object.wireTableRaw == null ? null : decodeWireRoute(object.wireTableRaw!),
        ),
  ];

  /// The [ViHeapObject.absBounds] of [oid]'s nearest bounded owner — the object
  /// itself if bounded, else the nearest positional ancestor with bounds — or
  /// null if none (and if [oid] does not resolve). Guards a repeated-oid cycle.
  HeapRect? _boundedOwnerBounds(int oid) {
    var object = byId[oid];
    final seen = <int>{};
    while (object != null && seen.add(object.oid)) {
      if (object.absBounds != null) return object.absBounds;
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

/// Recovers the [ViDiagram] from a decompressed heap [body] by walking its
/// balanced typed-group tree ([walkHeapObjects]): object headers become
/// [ViHeapObject]s parented by the enclosing object; `C4 2D`/`C4 22`/
/// `14 19 01 fd` records attach to the innermost object; absolute coordinates
/// compose down the object-ancestor chain. Total/bounds-safe.
ViDiagram buildDiagram(Uint8List body, {String sectionTag = 'BDHb'}) {
  final objects = <ViHeapObject>[];
  final c4ops = <ViHeapObject, Set<int>>{};
  final formatPayloads = <ViHeapObject, List<int>>{};
  final absTop = <ViHeapObject, int>{};
  final absLeft = <ViHeapObject, int>{};
  final length = body.length;

  walkHeapObjects<ViHeapObject>(
    body,
    onObjectOpen: (span, kind, oid, parent) {
      final cur = ViHeapObject(oid: oid, kind: kind, offset: span.offset);
      cur.parentOid = parent?.oid;
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
        if (attr.attribute == HeapAttribute.constValue && offset + 2 < length && body[offset + 2] == 0xff) {
          final text = attr.asString;
          if (text != null && text.isNotEmpty) cur.constText ??= text;
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
        // First-wins is safe: no signal in the corpus carries more than one
        // container-width table (155,158 container-bearing signals, 0 with a
        // second record).
        if (attr.attribute == HeapAttribute.compressedWireTable &&
            cur.kind == 0x17 &&
            attr.width == HeapAttrWidth.container) {
          cur.wireTableRaw ??= attr.rawValueBytes;
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
        .where((c) => c.kind == 0x0a)
        .map((c) => c.label?.trim())
        .where((cap) => cap != null && cap.isNotEmpty);
    if (caps.isNotEmpty) object.label = caps.first;
  }

  _reanchorScrolledControls(objects, byOid, nodeKids);
  return ViDiagram(sectionTag: sectionTag, objects: objects);
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
    for (final d in diagrams) {
      if (identical(d, own)) continue;
      final hit = d.byId[oid];
      if (hit != null) return hit;
    }
    return null;
  }

  // Direction needs no type table or base: a panel DCO's objFlags bit 0 set
  // = indicator (output); clear or absent on a typed DCO = control. A BD
  // terminal inherits it through its dcoRef (same-heap match first — the
  // corpus splits targets ~90/10 across heaps and oids repeat between
  // heaps).
  for (final d in diagrams) {
    for (final o in d.objects) {
      if (o.kind == 0x12 && o.typeDescIdx != null) {
        o.isIndicator = ((o.objFlags ?? 0) & 1) != 0;
      }
    }
  }
  for (final d in diagrams) {
    for (final o in d.objects) {
      if (o.isIndicator != null) continue;
      final dcoRefs = o.typedRefs[HeapRefKind.dcoRef];
      if (dcoRefs == null || dcoRefs.isEmpty) continue;
      o.isIndicator = findDco(d, dcoRefs.first)?.isIndicator;
    }
  }

  if (pool.isEmpty || table.isEmpty) return;

  ViType? resolve(int base, int index) {
    final ti = base + index;
    if (ti < 0 || ti >= table.length) return null;
    final pi = table[ti];
    return pi >= 0 && pi < pool.length ? pool[pi] : null;
  }

  final anchors = <(int, int)>[
    for (final d in blockDiagrams)
      for (final o in d.objects)
        if (o.typeDescIdx != null && _typeAnchors.containsKey(o.kind)) (o.kind, o.typeDescIdx!),
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

  for (final d in diagrams) {
    for (final o in d.objects) {
      final index = o.typeDescIdx;
      if (index == null) continue;
      final type = resolve(base, index);
      if (type == null) continue;
      final kind = _typeKindOf(type.kind);
      if (kind != null) o.typeKind = kind;
      o.dataType = type.kind;
      if (type.name != null && type.name!.trim().isNotEmpty) {
        o.typeName ??= type.name!.trim();
      }
    }
  }
  // A BD terminal inherits its paired DCO's resolved type: same-heap match
  // first, then the sibling heaps in diagram order.
  for (final d in diagrams) {
    for (final o in d.objects) {
      if (o.typeDescIdx != null) continue;
      final dcoRefs = o.typedRefs[HeapRefKind.dcoRef];
      if (dcoRefs == null || dcoRefs.isEmpty) continue;
      final dco = findDco(d, dcoRefs.first);
      if (dco == null) continue;
      if (dco.typeKind != ViTypeKind.unknown) o.typeKind = dco.typeKind;
      o.dataType ??= dco.dataType;
      o.typeName ??= dco.typeName;
    }
  }
}
