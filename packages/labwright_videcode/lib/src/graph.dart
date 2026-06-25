import 'dart:typed_data';

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

  /// The oids this object **declares as members** (childRef ∪ memberRef) — used
  /// by the diagram to highlight a structure's members (which the positional
  /// nesting tree does not capture; the two diverge ~72%). May be empty.
  Iterable<int> get memberOids => <int>{
        ...?typedRefs[HeapRefKind.childRef],
        ...?typedRefs[HeapRefKind.memberRef],
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
  /// `Plot 0`, `Line 0`), in heap order. Corpus: these records attach to the
  /// `0x5E` graph object (1013/1013). Empty for non-graph objects.
  List<String> plotNames = const [];

  /// Decoded numeric-control **range minimum** (from the `0x20` f64 form on a
  /// control terminal) — null if none; may be `-infinity` (the "no minimum"
  /// sentinel). Use [formatControlRange] to render honestly.
  double? controlMin;

  /// Decoded numeric-control **range maximum** (from the `0x21` f64 form on a
  /// control terminal) — null if none; may be `+infinity` (the "no maximum"
  /// sentinel). Use [formatControlRange] to render honestly.
  double? controlMax;

  /// Decoded help / description text for this object (`0x6C` blob / `C4 19`), or
  /// null. The VI/control's documentation string.
  String? helpText;

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
  // --- Diagram structure / containers ---
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

  // --- Nodes ---
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

  // --- Control / indicator terminal containers (top-level on the diagram) ---
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

  // --- Internal control sub-parts (nested only) ---
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

  // --- Decorations / chrome ---
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

  // --- Rare / undetermined ---
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
  unknown(-1, 'Unknown class', ViObjectKind.unknown, ClassConfidence.kindOnly);

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
    for (final c in values)
      if (c != unknown) c.code: c,
  };

  /// Maps a raw class code to its [HeapObjectClass], or [unknown].
  static HeapObjectClass fromCode(int code) => _byCode[code] ?? unknown;

  /// Whether this class is a front-panel-control/indicator **terminal** form
  /// (numeric/enum/boolean-cluster/string-array/path). The canonical set, so
  /// call sites don't hardcode the codes.
  bool get isControlTerminal => kControlTerminalCodes.contains(code);
}

/// The control/indicator terminal class codes (front-panel controls' diagram
/// footprint). Single source of truth — see [HeapObjectClass.isControlTerminal].
const kControlTerminalCodes = {0x50, 0x4f, 0x57, 0x5b, 0x51};

/// Attribute ids `buildDiagram` surfaces onto [ViHeapObject] (a fast id pre-filter
/// before the heavier `decodeHeapAttr`): 0x20/0x21 = control range, 0x6c = help
/// text. (0x31 names were dropped — they sit on non-drawable structural objects.)
const _objAttrIds = {0x20, 0x21, 0x6c};

String _fmtNum(double v) =>
    v == v.roundToDouble() && v.abs() < 1e15 ? v.toInt().toString() : v.toString();

/// A human-readable range string for a control's decoded [min]/[max], or null
/// when there is nothing meaningful to show. Honest: uses only **finite** bounds
/// (a `±∞` sentinel = "no bound" and an absent bound are both omitted), drops an
/// inverted *or degenerate* finite pair (`lo >= hi`, so `5 … 5` / `0 … -0.0`
/// read as noise rather than a real range), and renders a one-sided bound as
/// `≥ x` / `≤ x`.
String? formatControlRange(double? min, double? max) {
  // A NaN in EITHER slot means the pair is uninitialized/untrustworthy (corpus:
  // a NaN max paired with a 0/-0.0 min was ~60% of "ranges" — decode noise, not a
  // real bound). Suppress the whole range, not just the NaN half.
  if ((min?.isNaN ?? false) || (max?.isNaN ?? false)) return null;
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
String stripHelpMarkup(String s) {
  final out = s.replaceAll(_helpMarkupTag, '').replaceAll(_interiorSpaces, ' ').trim();
  return out.isEmpty ? s.trim() : out;
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

/// The printf conversion char of a `C4 74` numeric format-string payload, or null.
int? _formatConvChar(List<int> payload) {
  var seenPercent = false;
  for (final c in payload) {
    if (!seenPercent) {
      if (c == 0x25) seenPercent = true; // '%'
      continue;
    }
    if ((c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a)) return c;
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
    const intConvs = {0x62, 0x64, 0x6f, 0x78, 0x58}; // b d o x X
    return (conv != null && intConvs.contains(conv)) ? ViTypeKind.numericInt : ViTypeKind.numericFloat;
  }
  return ViTypeKind.unknown;
}

/// A recovered block-diagram (or other heap) as a **nesting tree** of
/// [ViHeapObject]s with absolute coordinates. The `14 19 01 fd` references are
/// child-membership (structure → contained oids), **not** signal wires: actual
/// dataflow wires are stored as geometry (no oid endpoints) and so do not appear
/// as resolvable edges here. Partial/honest: object class codes and wire
/// direction are not fully decoded.
class ViDiagram {
  ViDiagram({required this.sectionTag, required this.objects});

  /// The section this diagram came from (`BDHb` = block diagram, `FPHb` = front panel).
  final String sectionTag;

  /// All recovered objects, in heap (pre-order) order.
  final List<ViHeapObject> objects;

  /// Objects indexed by their unique [ViHeapObject.oid].
  Map<int, ViHeapObject> get byId => {for (final o in objects) o.oid: o};

  /// The root object(s) of the nesting tree (parentOid == null) — normally the
  /// single diagram root (kind `0x7e`).
  Iterable<ViHeapObject> get roots => objects.where((o) => o.parentOid == null);

  /// The direct children of the object with [oid] in the nesting tree.
  Iterable<ViHeapObject> children(int oid) => objects.where((o) => o.parentOid == oid);

  /// The bounded objects (have an absolute rectangle) — the drawable layout layer.
  Iterable<ViHeapObject> get nodes => objects.where((o) => o.absBounds != null);
}

bool _isTypeTag(int b) => b == 0xfb || b == 0xfe || b == 0xfd;

/// Recovers the [ViDiagram] from a decompressed heap [body] by walking its record
/// stream ([walkHeapBody]) as a **balanced typed-group tree**: a group opens at a
/// high-nibble-1 opcode (`10/11/12/13 <tag>` with a type tag after the count) and
/// closes at a high-nibble-0 opcode (`08/09/0a/0b`, popped positionally). Object
/// headers (`10/11/12 <tag> 02 fe <kind> fd <oid>`) become [ViHeapObject]s
/// parented by the enclosing object; `C4 2D`/`C4 22`/`14 19 01 fd` records attach
/// to the innermost object; absolute coordinates compose down the object-ancestor
/// chain. Total/bounds-safe.
ViDiagram buildDiagram(Uint8List body, {String sectionTag = 'BDHb'}) {
  final objects = <ViHeapObject>[];
  final c4ops = <ViHeapObject, Set<int>>{};
  final fmt = <ViHeapObject, List<int>>{};
  final absTop = <ViHeapObject, int>{};
  final absLeft = <ViHeapObject, int>{};
  // Group stack: each entry is (object-or-null, isObject). Non-object groups
  // (typed lists like `10 55 01 fb`) are pushed too, so closes balance.
  final stack = <ViHeapObject?>[];
  final n = body.length;

  ViHeapObject? innermostObject() {
    for (var k = stack.length - 1; k >= 0; k--) {
      if (stack[k] != null) return stack[k];
    }
    return null;
  }

  for (final s in walkHeapBody(body).spans) {
    final o = s.offset;
    final lead = s.lead;
    final isGroupOpen = (lead == 0x10 || lead == 0x11 || lead == 0x12 || lead == 0x13) &&
        o + 4 <= n &&
        _isTypeTag(body[o + 3]);
    if (isGroupOpen) {
      final isObj = (lead == 0x10 || lead == 0x11 || lead == 0x12) &&
          o + 9 <= n &&
          body[o + 2] == 0x02 &&
          body[o + 3] == 0xfe &&
          body[o + 6] == 0xfd;
      if (isObj) {
        final cur = ViHeapObject(
          oid: (body[o + 7] << 8) | body[o + 8],
          kind: (body[o + 4] << 8) | body[o + 5],
          offset: o,
        );
        final parent = innermostObject();
        cur.parentOid = parent?.oid;
        // absolute origin starts at the parent object's origin (pass-through).
        absTop[cur] = parent == null ? 0 : (absTop[parent] ?? 0);
        absLeft[cur] = parent == null ? 0 : (absLeft[parent] ?? 0);
        objects.add(cur);
        c4ops[cur] = <int>{};
        stack.add(cur);
      } else {
        stack.add(null);
      }
      continue;
    }
    if (lead == 0x08 || lead == 0x09 || lead == 0x0a || lead == 0x0b) {
      if (stack.isNotEmpty) stack.removeLast();
      continue;
    }
    final cur = innermostObject();
    if (cur == null) continue;
    if (lead == kHeapRecordPrefix) {
      final rec = c4FrameAt(body, o, sectionTag);
      if (rec == null) continue;
      c4ops[cur]!.add(rec.opcode);
      if (rec.opcode == 0x2d) {
        if (cur.bounds == null) {
          cur.bounds = rec.bounds;
          if (cur.bounds != null) {
            absTop[cur] = (absTop[cur] ?? 0) + cur.bounds!.top;
            absLeft[cur] = (absLeft[cur] ?? 0) + cur.bounds!.left;
            cur.absBounds = HeapRect(
              top: absTop[cur]!,
              left: absLeft[cur]!,
              bottom: absTop[cur]! + cur.bounds!.height,
              right: absLeft[cur]! + cur.bounds!.width,
            );
          }
        }
      } else if (rec.opcode == 0x22) {
        cur.label ??= rec.text;
      } else if (rec.opcode == 0x1f) {
        cur.termCount++;
      } else if (rec.opcode == 0x74) {
        fmt[cur] ??= rec.payload;
      } else if (rec.opcode == 0x2e) {
        if (cur.items.isEmpty) cur.items = _parseEnumItems(rec.payload);
      } else if (rec.opcode == 0x19) {
        cur.helpText ??= rec.descriptionText;
      } else if (rec.opcode == 0x27) {
        // Graph/chart plot name ("Plot 0"/"Line 0") — attaches to the 0x5E graph.
        final t = rec.text ?? rec.path ?? rec.descriptionText;
        if (t != null && t.isNotEmpty) cur.plotNames = [...cur.plotNames, t];
      }
    } else if (lead == 0x14) {
      // Typed object reference (the heap's declared object graph). Single-source
      // via decodeHeapRef (handles every subop + rejects the 0x53 literal).
      final r = decodeHeapRef(body, o);
      if (r != null) {
        (cur.typedRefs[r.kind] ??= <int>[]).add(r.targetOid);
        if (r.kind == HeapRefKind.childRef) cur.refs.add(r.targetOid);
      }
    } else if (o + 1 < n && _objAttrIds.contains(body[o + 1])) {
      // Fast-reject by id (most else-spans carry none) before the heavier
      // decodeHeapAttr, then surface a few decoded attributes on the object.
      final a = decodeHeapAttr(body, o);
      if (a != null) {
        final d = a.asDouble;
        // Numeric-control range: ONLY the 0x20/0x21 f64 form, and ONLY on control
        // terminals. (0xF5/0xF7 land on decorations with inverted values, so they
        // are not used for the object-level range.)
        if (d != null && kControlTerminalCodes.contains(cur.kind)) {
          if (a.attribute == HeapAttribute.foregroundColor) cur.controlMin ??= d;
          if (a.attribute == HeapAttribute.foregroundColorB) cur.controlMax ??= d;
        }
        // Help text ONLY from the genuine C6 6C FF blob (the <u8len> form carries
        // library/format tokens, not help — see HeapAttribute.helpDescription).
        if (a.attribute == HeapAttribute.helpDescription && o + 2 < n && body[o + 2] == 0xff) {
          final s = a.asString;
          if (s != null && s.isNotEmpty) cur.helpText ??= s;
        }
      }
    }
  }

  for (final o in objects) {
    o.category = classifyObject(kind: o.kind, termCount: o.termCount);
    o.typeKind = inferTypeKind(c4ops[o] ?? const <int>{}, fmt[o]);
  }

  // Propagate enum item-lists up to their enclosing control: the `C4 2E` items
  // live on the `0x0d` item-list child, but the faithful render needs them on
  // the enum/ring control object itself.
  final byOidItems = {for (final o in objects) o.oid: o};
  for (final o in objects) {
    if (o.items.isEmpty) continue;
    var p = o.parentOid;
    var depth = 0;
    while (p != null && depth < 12) {
      final po = byOidItems[p];
      if (po == null) break;
      if (kControlTerminalCodes.contains(po.kind)) {
        if (po.items.isEmpty) po.items = o.items;
        break;
      }
      p = po.parentOid;
      depth++;
    }
  }

  // Propagate help text up to the nearest DRAWABLE ancestor: help usually lives on
  // a non-drawable tip-strip (0xc1) / description child that carries no bounds, but
  // the details card / faithful tooltip can only show it on a drawn object. Corpus:
  // 97% of help-bearing objects have a drawable ancestor. ~25% of landings are on a
  // non-control drawable (predominantly a 0x53 structure) — intentional: structures
  // own help too, and the walk takes the *nearest* drawable, so it never bypasses a
  // drawable control to reach an enclosing structure. First-wins (`??=`) never
  // overwrites an ancestor that already carries its own help.
  for (final o in objects) {
    final h = o.helpText;
    if (h == null || h.isEmpty || o.absBounds != null) continue;
    var p = o.parentOid;
    final seen = <int>{};
    while (p != null && seen.add(p)) {
      final po = byOidItems[p];
      if (po == null) break;
      if (po.absBounds != null) {
        po.helpText ??= h;
        break;
      }
      p = po.parentOid;
    }
  }

  // Give each BD node its name: the function/subVI caption lives on a child `0xa`
  // label (e.g. "PicoScope2000aOpen.vi", "Build Array"), not on the node object
  // itself (node.label is null). Copy it up so the details card / tooltip name the
  // selected node. The faithful render keeps the node box as an icon placeholder
  // and still draws that 0xa child as a floating label where LabVIEW places it, so
  // this does not double-print on the canvas — it only enriches selection/inspect.
  final nodeKids = <int, List<ViHeapObject>>{};
  for (final o in objects) {
    if (o.parentOid != null) (nodeKids[o.parentOid!] ??= <ViHeapObject>[]).add(o);
  }

  // Structural node fallback: the BD node tail is dozens of low-frequency kinds
  // that all share one signature — a drawable object parented to the node
  // container `0x1b`, holding the structural `0x15` records, with NO `0x68`
  // connector child (that would make it a terminal). It may also carry a `0xa`
  // caption / `0x10b`/`0xbc`/`0x1b` sub-records (e.g. subVI calls `…​.vi`, formula
  // nodes `x*4+6`). Rather than enumerate every kind (0x2f/0x63/0x124/0xc0/…),
  // classify any still-`unknown` object matching it as a node so it renders as a
  // node box (and the `0xa` caption then propagates to its name). Corpus: ~1953
  // objects across ~22 kinds. A size cap keeps a rare large still-unknown object
  // (a possible structure body) as a faint placeholder rather than a big node box.
  for (final o in objects) {
    if (o.category != ViObjectKind.unknown) continue;
    final b = o.absBounds;
    if (b == null || b.width <= 0 || b.height <= 0) continue;
    if (b.width * b.height >= 20000) continue; // structure-sized -> leave as unknown
    if (o.parentOid == null || byOidItems[o.parentOid]?.kind != 0x1b) continue;
    final cs = nodeKids[o.oid];
    if (cs == null) continue;
    final hasStructural = cs.any((c) => c.kind == 0x15);
    final hasConnector = cs.any((c) => c.kind == 0x68);
    if (!hasStructural || hasConnector) continue; // need node records; a 0x68 = terminal
    o.category = ViObjectKind.node;
  }

  for (final o in objects) {
    if (o.category != ViObjectKind.node || o.label != null) continue;
    for (final c in nodeKids[o.oid] ?? const <ViHeapObject>[]) {
      final cap = c.kind == 0x0a ? c.label?.trim() : null;
      if (cap != null && cap.isNotEmpty) {
        o.label = cap;
        break;
      }
    }
  }

  _reanchorScrolledControls(objects);
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
    if (i + len > payload.length) return const []; // malformed → untrustworthy table
    final s = String.fromCharCodes(payload.sublist(i, i + len));
    i += len;
    if (!s.codeUnits.every((c) => c >= 0x20 && c < 0x7f)) return const []; // ordinal-unsafe
    out.add(s);
  }
  return out;
}

/// Control-terminal classes (front-panel control/indicator terminals).

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
void _reanchorScrolledControls(List<ViHeapObject> objects) {
  final byOid = {for (final o in objects) o.oid: o};
  final kids = <int, List<ViHeapObject>>{};
  for (final o in objects) {
    if (o.parentOid != null) (kids[o.parentOid!] ??= <ViHeapObject>[]).add(o);
  }

  // The viewport to re-anchor [o] to — its nearest `0x11c` ancestor — but only
  // if no *other control* sits between them. A control nested inside another
  // control (e.g. a sub-element of a path/cluster control) is positioned
  // relative to that parent control, not the viewport, so it must ride along
  // with the parent's subtree shift rather than be re-anchored independently
  // (otherwise it lands far outside, using the wrong origin).
  int? reanchorViewport(ViHeapObject o) {
    var p = o.parentOid;
    // Guard against a parentOid cycle (oids can repeat; byOid is last-wins, so two
    // objects can cross-link) — without this the walk loops forever on adversarial
    // input, like the shiftSubtree guard below.
    final seen = <int>{};
    while (p != null) {
      if (!seen.add(p)) return null;
      final po = byOid[p];
      if (po == null) return null;
      if (po.kind == 0x11c) return po.oid; // reached the viewport → re-anchor
      // A control, or ANY other positioned/bounded container (e.g. a 0x52
      // case/sequence or 0x64 cluster shell), between this control and the
      // viewport means the control's bounds are in THAT container's frame, not
      // the viewport's. Re-anchoring with the viewport group's min-corner would
      // mix frames and fling it outside — ride along with its parent instead.
      if (kControlTerminalCodes.contains(po.kind) || po.bounds != null) return null;
      p = po.parentOid;
    }
    return null;
  }

  // Group re-anchorable controls by the viewport that owns them.
  final groups = <int, List<ViHeapObject>>{};
  for (final o in objects) {
    if (!kControlTerminalCodes.contains(o.kind) || o.bounds == null || o.absBounds == null) continue;
    final v = reanchorViewport(o);
    if (v != null) (groups[v] ??= <ViHeapObject>[]).add(o);
  }

  void shiftSubtree(ViHeapObject root, int dTop, int dLeft) {
    if (dTop == 0 && dLeft == 0) return;
    final work = <ViHeapObject>[root];
    // `kids` is keyed by parentOid, and oids can repeat across objects (a control
    // nested under an object sharing its oid makes kids[oid] contain itself). Guard
    // by object identity so a self-referential/cyclic list can't loop forever.
    final seen = <ViHeapObject>{};
    while (work.isNotEmpty) {
      final o = work.removeLast();
      if (!seen.add(o)) continue;
      final a = o.absBounds;
      if (a != null) {
        o.absBounds = HeapRect(top: a.top + dTop, left: a.left + dLeft, bottom: a.bottom + dTop, right: a.right + dLeft);
      }
      final cs = kids[o.oid];
      if (cs != null) work.addAll(cs);
    }
  }

  groups.forEach((vOid, controls) {
    final v = byOid[vOid];
    if (v?.absBounds == null) return;
    var minTop = controls.first.bounds!.top;
    var minLeft = controls.first.bounds!.left;
    for (final c in controls) {
      if (c.bounds!.top < minTop) minTop = c.bounds!.top;
      if (c.bounds!.left < minLeft) minLeft = c.bounds!.left;
    }
    for (final c in controls) {
      final newTop = v!.absBounds!.top + (c.bounds!.top - minTop);
      final newLeft = v.absBounds!.left + (c.bounds!.left - minLeft);
      shiftSubtree(c, newTop - c.absBounds!.top, newLeft - c.absBounds!.left);
    }
  });
}
