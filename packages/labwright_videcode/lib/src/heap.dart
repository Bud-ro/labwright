import 'dart:typed_data';

import 'decode.dart';

/// The byte that introduces a length-prefixed heap record (`C4 op len payload`).
/// See [HeapOpcode] for the opcode catalog.
const int kHeapRecordPrefix = 0xc4;

/// The catalog of known LabVIEW heap-record **opcodes** — the byte after
/// [kHeapRecordPrefix] in a `C4 <op> <u8 len> <payload>` record.
///
/// This enhanced enum is the single source of truth for every opcode we have
/// reverse-engineered from the corpus. Each value documents the record's meaning,
/// its payload layout, the corpus evidence, and its decoding status. The raw byte
/// in a [HeapRecord] is mapped here via [HeapRecord.kind] / [HeapOpcode.fromByte];
/// any byte not catalogued maps to [HeapOpcode.unknown].
///
/// Status legend:
/// - **decoded** — payload semantics confirmed and exposed by a typed accessor.
/// - **structural** — payload *shape* known (e.g. it is a rectangle), but the
///   semantic role is not yet determined, so it is intentionally not given a
///   meaning-specific accessor.
/// - **unknown** — not catalogued.
///
/// See `docs/vi-rsrc-and-heap-format.md` for the full evidence and probe history.
enum HeapOpcode {
  /// `0x2D` — **object bounds rectangle** (decoded). Payload is 8 bytes = four
  /// big-endian `s16` fields `top, left, bottom, right`, in pixels: the position
  /// and size of a control / node / decoration. Corpus: 99% are valid rectangles
  /// with sane dimensions. Decoded by [HeapRecord.bounds].
  bounds(0x2d, HeapShape.rectangle, isDecoded: true),

  /// `0x1F` — **origin-anchored size rectangle** (decoded). Same 8-byte 4× `s16`
  /// layout as [bounds] but `top == left == 0`, so it encodes a height×width
  /// extent rather than a position. Corpus: 100% valid, origin-anchored. Decoded
  /// by [HeapRecord.sizeRect].
  size(0x1f, HeapShape.rectangle, isDecoded: true),

  /// `0x2E` — **string table** (decoded). The only variable-length confirmed
  /// opcode: the payload is `len` bytes of packed `[u8 strlen][chars]` Pascal
  /// strings (a `u16` length is used when the table exceeds 255 bytes). Holds a
  /// group of related labels (enum/ring items, captions). Decoded by
  /// [HeapStringTable] / the string-table parser.
  stringTable(0x2e, HeapShape.stringTable, isDecoded: true),

  /// `0x22` — **caption** (decoded). A single control / parameter name; the
  /// payload *is* the text, sized by the record's own length byte. Corpus: 97%
  /// printable. Decoded by [HeapRecord.text].
  caption(0x22, HeapShape.string, isDecoded: true),

  /// `0x27` — **plot / legend name** (decoded). A single string naming a plot or
  /// series, e.g. `Plot 0`, `Plot 1`. Same single-string payload as [caption]
  /// (100% printable across the corpus). Decoded by [HeapRecord.text].
  plotName(0x27, HeapShape.string, isDecoded: true),

  /// `0x74` — **numeric format string** (decoded). A single string holding a
  /// display format specifier, e.g. `%020b`, `%016b`, `%#_6g`. Single-string
  /// payload (96% printable). Decoded by [HeapRecord.text].
  formatString(0x74, HeapShape.string, isDecoded: true),

  /// `0x20` — **item / label string** (decoded). A single identifier or
  /// enum/ring item label, e.g. `Line 0`..`Line 7`, `stringLength`, `<None>`.
  /// Single-string payload (100% printable across the corpus). Decoded by
  /// [HeapRecord.text].
  itemLabel(0x20, HeapShape.string, isDecoded: true),

  /// `0xC4` — **symbol / C-function name** (decoded). A single string holding a
  /// Call-Library function or decorated C entry-point name, e.g.
  /// `ps2000aRunStreaming`, `_ps5000SetEts@20`. Lives mostly in the `DTHP` type
  /// heap (93% printable). Decoded by [HeapRecord.text]. (The opcode byte here is
  /// `0xC4`, distinct from the record-prefix [kHeapRecordPrefix].)
  symbolName(0xc4, HeapShape.string, isDecoded: true),

  /// `0xB6` — **VI-Server method / invoke-node name** (decoded). A single string
  /// naming a property/invoke-node method, e.g. `FP.Open`, `FP.Close`, `FP.Center`,
  /// `Mass Compile`, `Reinit To Default`, `ClearCompObjCache`. 100% printable
  /// across the corpus (scoped to kinds 0xaa/0x0a). Decoded by [HeapRecord.text].
  methodName(0xb6, HeapShape.string, isDecoded: true),

  /// `0x19` — **description / help text** (decoded, heuristic). HTML-ish
  /// (`<B>…</B>`), multi-line tooltip/help text stored as length-prefixed text
  /// segments. The inner multi-segment framing is not fully decoded, so the text
  /// is recovered heuristically by [HeapRecord.descriptionText].
  description(0x19, HeapShape.helpText, isDecoded: true),

  /// `0xA4` — **filesystem path** (decoded). A LabVIEW `PTH0` path record:
  /// `'PTH0' <u32 len> <u16 type> <u16 nComponents>` then packed Pascal-string
  /// components — a DLL / library reference (e.g. `ps5000.dll`,
  /// `Program Files\Pico Technology\…`). Mostly in `DTHP` (100% start with
  /// `PTH0`). Decoded by [HeapRecord.path].
  path(0xa4, HeapShape.path, isDecoded: true),

  /// `0x4A` — **type / terminal bounds rectangle** (decoded). 8-byte 4× `s16`
  /// rectangle (100% valid), in the `DTHP` type heap — the bounds of a terminal /
  /// type element. Decoded by the generic [HeapRecord.rect].
  typeBounds(0x4a, HeapShape.rectangle, isDecoded: true),

  /// `0x44` — **composite container** (structural). A wrapper whose payload holds
  /// complete nested `C4` children (bounds `2D` + origin/size `1F` + caption `22`,
  /// interleaved with non-`C4` style/color tuples) — a control/decoration
  /// cluster. Children via [HeapRecord.children].
  container44(0x44, HeapShape.container),

  /// `0x64` — **composite container** (structural). Like [container44] but richer
  /// (bounds + captions + format strings + nested type tokens). Children via
  /// [HeapRecord.children].
  container64(0x64, HeapShape.container),

  /// `0x24` — **composite container** (structural). A bounds-rect-dominant cluster
  /// with captions; payload holds nested `C4` children. Children via
  /// [HeapRecord.children].
  container24(0x24, HeapShape.container),

  /// `0x5F` — **rectangle, role undetermined** (structural). Decodes as a 4× `s16`
  /// rectangle (97% valid) but allows negative coordinates and degenerate points,
  /// so its semantic role (offset? sub-region? connector extent?) is unknown.
  /// Readable via the generic [HeapRecord.rect]; no meaning-specific accessor.
  rect5f(0x5f, HeapShape.rectangle),

  /// `0x4C` — **rectangle, role undetermined** (structural). 8-byte 4× `s16`
  /// rectangle (100% valid), often all-zero or with negative coordinates. Role
  /// not yet determined. Readable via [HeapRecord.rect].
  rect4c(0x4c, HeapShape.rectangle),

  /// `0xD6` — **rectangle, role undetermined** (structural). 8-byte 4× `s16`
  /// rectangle (100% valid), frequently origin-anchored like [size]. Role not yet
  /// determined. Readable via [HeapRecord.rect].
  rectD6(0xd6, HeapShape.rectangle),

  /// `0x62` — **rectangle, role undetermined** (structural). 8-byte 4× `s16`
  /// rectangle (100% valid), typically positive coordinates like [bounds]. Role
  /// not yet determined. Readable via [HeapRecord.rect].
  rect62(0x62, HeapShape.rectangle),

  /// `0x26` — **rectangle, role undetermined** (structural). 8-byte 4× `s16`
  /// rectangle (100% valid). Role not yet determined. Readable via
  /// [HeapRecord.rect].
  rect26(0x26, HeapShape.rectangle),

  /// A heap opcode that is not (yet) catalogued. Its [byte] is -1; use
  /// [HeapRecord.opcode] for the actual byte value.
  unknown(-1, HeapShape.none);

  const HeapOpcode(this.byte, this.shape, {this.isDecoded = false});

  /// The opcode byte (the value after [kHeapRecordPrefix]); -1 for [unknown].
  final int byte;

  /// The shape of this opcode's payload (rectangle / string / …) — drives the
  /// generic accessors on [HeapRecord].
  final HeapShape shape;

  /// Whether this opcode has a confirmed *semantic* meaning (a meaning-specific
  /// accessor), vs. merely a known shape (structural) or unknown.
  final bool isDecoded;

  static final Map<int, HeapOpcode> _byByte = {
    for (final op in values)
      if (op != unknown) op.byte: op,
  };

  /// Maps a raw opcode byte to its [HeapOpcode], or [unknown] if not catalogued.
  static HeapOpcode fromByte(int b) => _byByte[b] ?? unknown;
}

/// The shape of a heap record's payload — what kind of value it holds, used to
/// drive the generic decoders on [HeapRecord]. See [HeapOpcode.shape].
enum HeapShape {
  /// An 8-byte 4× big-endian `s16` rectangle (`top, left, bottom, right`).
  rectangle,

  /// A single string occupying the whole payload (sized by the record length).
  string,

  /// A table of packed Pascal strings (the `C4 2E` form).
  stringTable,

  /// Length-prefixed help/description text segments (the `C4 19` form).
  helpText,

  /// A `PTH0` filesystem-path record (the `C4 A4` form).
  path,

  /// A composite record whose payload holds nested `C4` children.
  container,

  /// No known shape (uncatalogued opcode).
  none,
}

/// The **value kind** an [HeapAttribute] carries — what the attribute's bytes
/// *mean*, independent of how wide they are stored. The storage width comes from
/// the carrying opcode (see [HeapAttrWidth]); a few attributes are *dual-use*
/// across widths (e.g. [HeapAttribute.sizeOrIncrement] is a `u16` size or an
/// `f64` increment) — for those, [HeapAttr.kind] resolves the kind from the
/// width at decode time.
enum HeapAttrKind {
  /// A 24-bit RGB colour (carried as `84 <id> <flag><R><G><B>`; flag `0x01` with
  /// `R=G=B=0` is the *transparent* sentinel).
  color,

  /// A signed pixel coordinate / relative offset (`s16`).
  coordinate,

  /// An unsigned pixel extent — a width or height (`u16`).
  size,

  /// A small enumerated selector (object class / sub-kind / mode), `u8`.
  enumValue,

  /// A boolean-ish flag (`u8`, usually 0/1; the `Ex` nibble form carries it in
  /// zero bytes).
  flag,

  /// A sequential element index / ordinal (`u8`/`u16`).
  ordinal,

  /// A general numeric value — scale, packed pair, or large id — whose finer
  /// meaning is not pinned (kept honest rather than over-named).
  numeric,

  /// A floating-point numeric-control parameter (range min/max, increment,
  /// scale), carried as `C5 <id> 08 <f64>`. See [HeapAttribute.controlMin] etc.
  controlParam,

  /// Inline display text / style field.
  text,

  /// A length-prefixed string/blob (`C6 <id> FF <u16 len> <u32 strlen><ascii>`),
  /// e.g. a VISA resource name, serial, or firmware version.
  stringBlob,

  /// A 4× `s16` pixel rectangle carried in a length-prefixed `Cx <id> 08`
  /// payload — NOT every `Cx …08` is an `f64`; the `08` is a payload-length byte
  /// and a few ids (e.g. `0x29`) store a rectangle there. See [HeapAttribute.terminalRect].
  rectangle,

  /// Not catalogued.
  unknown,
}

/// How wide an [HeapAttr]'s value is stored — derived from the carrying opcode.
enum HeapAttrWidth {
  /// `2x` nibble form / `0x24` — one byte.
  u8,

  /// `4x` nibble form / `0x44` — two bytes, big-endian.
  u16,

  /// `6x` nibble form / `0x64` — three bytes, big-endian.
  u24,

  /// `8x` nibble form — four bytes (used by `0x84` as `flag.R.G.B`).
  rgb,

  /// `Ex` nibble form — zero value bytes (a bare flag).
  flag,

  /// `C5 <id> 08` — eight-byte big-endian IEEE-754 double.
  f64,

  /// `C6 <id> FF <u16 len>` — a length-prefixed string/blob.
  blob,

  /// `C5/C6 <id> 08` whose 8-byte payload is a 4× `s16` rectangle rather than an
  /// `f64` (the `08` is a length byte, not an f64 marker). See [HeapAttrKind.rectangle].
  rect,
}

/// How well-grounded an [HeapAttribute]'s assigned **name** is. This is a
/// clean-room reverse-engineering effort (no LabVIEW source), so names are
/// inferred from value distributions and must be labelled honestly.
enum AttrConfidence {
  /// Pinned by a decisive Rosetta — RGB triples, the transparent sentinel, a
  /// monotone min≤max ordering, a strictly-sequential index, or decoded ASCII.
  confirmed,

  /// Direction/role inferred from value patterns and host context, but the exact
  /// LabVIEW property name is not provable.
  inferred,

  /// Only the value *kind*/width is defensible; the name is a kind label.
  kindOnly,
}

/// The catalog of known LabVIEW heap **attribute ids** — the `<id>` byte in an
/// attribute record `<op> <id> <value>`, where the opcode sets the value width
/// (`0x24`→u8, `0x44`→u16, `0x64`→u24, the `2x/4x/6x/8x/Ex` nibble family,
/// `0xC5`→f64, `0xC6`→blob) and the *id* selects which property is being set.
///
/// This is the single place that names every attribute id we have decoded from
/// the corpus (1.23M attribute records across 398 BDEx sections). Each entry
/// documents its [kind], assigned name, [confidence], and the corpus evidence.
/// An id not catalogued maps to [HeapAttribute.unknown]; resolve a raw id with
/// [HeapAttribute.fromId] and decode a record with [decodeHeapAttr].
///
/// HONESTY: this is clean-room RE. `confirmed` names are pinned by a Rosetta
/// (RGB, transparent sentinel, monotone ordering, ASCII); `inferred` names give
/// the defensible direction (e.g. foreground vs background by transparent-rate)
/// but not the exact LabVIEW property name; `kindOnly` names are pure value-kind
/// labels. See `docs/vi-rsrc-and-heap-format.md` for the full evidence.
enum HeapAttribute {
  /// `0x1F` — **relative coordinate / offset** (`s16`, ≈99.96% high-bit-set as
  /// `u16` → a relative/negative position). The single highest-volume attribute.
  relativeOffset(0x1f, HeapAttrKind.coordinate, 'relativeOffset', AttrConfidence.inferred),

  /// `0x00` / `0x01` — **absolute coordinate X / Y** (`s16`, small with
  /// negatives).
  coordX(0x00, HeapAttrKind.coordinate, 'coordX', AttrConfidence.inferred),
  coordY(0x01, HeapAttrKind.coordinate, 'coordY', AttrConfidence.inferred),

  /// `0xDF` — **object type / class** (`u8`, 39 distinct values 0..118): a broad
  /// object-class *attribute*. NOTE: this is a distinct `u8` value space — it is
  /// NOT the same as the `u16` `HeapObjectClass` header `<kind>` code; the two do
  /// not index into each other.
  objectClass(0xdf, HeapAttrKind.enumValue, 'objectClass', AttrConfidence.kindOnly),

  /// `0xAF` — **object sub-kind** (`u8`, only ~9 distinct values): a small
  /// secondary kind enum.
  objectSubKind(0xaf, HeapAttrKind.enumValue, 'objectSubKind', AttrConfidence.kindOnly),

  /// `0x3A` — **element index / ordinal** (`u8`/`u16`, strictly sequential
  /// 1..n).
  elementIndex(0x3a, HeapAttrKind.ordinal, 'elementIndex', AttrConfidence.confirmed),

  /// `0x89` — **size / extent** (`u16`; values cluster on pixel sizes like 240,
  /// 4096, 12288): a width or height.
  sizeExtent(0x89, HeapAttrKind.size, 'sizeExtent', AttrConfidence.inferred),

  /// `0xF8` — **size (u16) OR coarse increment (f64)** — *dual-use*: a `u16`
  /// extent via the nibble form, or the coarse step of a numeric control via
  /// `C5`. [HeapAttr.kind] resolves it by width.
  sizeOrIncrement(0xf8, HeapAttrKind.size, 'sizeOrCoarseIncrement', AttrConfidence.inferred),

  /// `0x29` — **per-object pixel rectangle** carried as `C5/C6 29 08 <4× s16>`
  /// (NOT an f64 — see [decodeHeapAttr]). Corpus-confirmed *shape*: 100% valid
  /// rectangles (219,845/219,892), dims clustering on small glyph/terminal cells
  /// (8×8, 8×16, 9×9); the f64 reading is decisively garbage (0% sane doubles,
  /// 379k denormals). Exactly 0/1 per object → a single inner/terminal rect. The
  /// single highest-volume residual record (~2.4M bytes). The `84 29` form is a
  /// distinct opaque accent colour (resolved by width via [HeapAttr.kind]). The
  /// *role* (terminal vs hotpoint vs inner-content rect) is inferred from size.
  terminalRect(0x29, HeapAttrKind.rectangle, 'terminalRect', AttrConfidence.inferred),

  /// `0xDC` — **sub-element ordinal** (`u8`, strictly sequential 1..46), emitted
  /// immediately after the [terminalRect] (`0x29`) on diagram objects: the index
  /// of the rect/glyph sub-element. Confirmed by its strict sequence.
  elementOrdinal(0xdc, HeapAttrKind.ordinal, 'elementOrdinal', AttrConfidence.confirmed),

  /// `0x63` / `0x64` — a **paired pixel rectangle block** carried as
  /// `C5/C6 63|64 08 <4× s16>` (NOT f64). Corpus-confirmed shape: 100% valid
  /// rectangles, 0% sane f64; the two appear together (identical paired rects:
  /// e.g. 75×75, 768×432) followed by a colour attribute — a bounds/size rect
  /// pair plus fill on an object. Role (which is bounds vs size) not pinned.
  rectFieldA(0x63, HeapAttrKind.rectangle, 'rectFieldA', AttrConfidence.inferred),
  rectFieldB(0x64, HeapAttrKind.rectangle, 'rectFieldB', AttrConfidence.inferred),

  /// `0x9F` — **front-panel packed flags** (`u16`, 123 distinct values like
  /// 33616/560/16944 — bitfield-shaped), scoped to front-panel controls (kind
  /// 0x17) in the chain `…15 → E7 → 9F`. A packed property bitfield. (~147k recs.)
  fpPackedFlags(0x9f, HeapAttrKind.numeric, 'fpPackedFlags', AttrConfidence.kindOnly),

  /// `0x15` — **front-panel attr-chain selector** (`u8` with bit-flag values
  /// 1/0x11/0x21/0x31), always preceded by op `09` and followed by the `0xE7`
  /// group: it opens a front-panel control's attribute chain. (~147k recs.)
  fpChainSelector(0x15, HeapAttrKind.flag, 'fpChainSelector', AttrConfidence.inferred),

  /// `0x61` — **element link / index** (`u16`), emitted just after the
  /// [elementIndex] (`0x3A`) on nodes/diagram objects: a per-element link or
  /// secondary index. (~35k recs.)
  elementLink(0x61, HeapAttrKind.ordinal, 'elementLink', AttrConfidence.inferred),

  /// `0x06` — **row / cell field** (`u8`) on tables/decorations (kinds
  /// 0x0a/0x15/0x30), emitted before the [elementIndex]. (~76k recs.)
  rowField(0x06, HeapAttrKind.ordinal, 'rowField', AttrConfidence.kindOnly),

  /// `0x86` — **graph/cursor field** (`u8`) scoped to graph & cursor objects
  /// (kind 0x68), following the [elementIndex]. (~67k recs.)
  graphCursorField(0x86, HeapAttrKind.numeric, 'graphCursorField', AttrConfidence.kindOnly),

  /// `0x72` — **plot-style field** (`u8`) emitted immediately after the
  /// `0x28` background colour on front-panel plots. (~14k recs.)
  plotStyleField(0x72, HeapAttrKind.numeric, 'plotStyleField', AttrConfidence.kindOnly),

  /// `0x7B` — **graph-cursor sub-field** (`u8`) on graph objects (kind 0x68),
  /// following the `0xF8`/`0x5A` fields. (~13k recs.)
  cursorField(0x7b, HeapAttrKind.numeric, 'cursorField', AttrConfidence.kindOnly),

  /// `0x8A` — **rect-follow field** (`u8`) emitted right after the [terminalRect]
  /// (`0x29`) on kind-0x62 objects. (~7k recs.)
  rectFollowField(0x8a, HeapAttrKind.numeric, 'rectFollowField', AttrConfidence.kindOnly),

  /// `0x48` — **cell-index field** (`u8`/`u16`) on decorations/tables (kind 0x0a).
  cellIndexField(0x48, HeapAttrKind.ordinal, 'cellIndexField', AttrConfidence.kindOnly),

  /// `0x23` — **caption-style field** (`u8`, with a `0x84`-form colour variant)
  /// emitted after the `0x22` caption on FP controls (kinds 0x17/0x68). Distinct
  /// from the `C4 23` opcode. (~14k recs.)
  captionStyleField(0x23, HeapAttrKind.text, 'captionStyleField', AttrConfidence.kindOnly),

  /// `0xEA` / `0xE9` / `0xDE` — a **grow / resize cluster** (the adjacent triple
  /// `EA → E9 → DE`, `u8`/`u16`) that always co-occurs on resizable structures
  /// (kind 0x30): likely grow-handle / array-dimension fields.
  growClusterA(0xea, HeapAttrKind.numeric, 'growClusterA', AttrConfidence.kindOnly),
  growClusterB(0xe9, HeapAttrKind.numeric, 'growClusterB', AttrConfidence.kindOnly),
  growClusterC(0xde, HeapAttrKind.numeric, 'growClusterC', AttrConfidence.kindOnly),

  /// `0xCB` — **packed value / large numeric** (`u24` values stepping
  /// `0x10000`..`0x700000`): a packed numeric, not a colour despite the width.
  packedValue(0xcb, HeapAttrKind.numeric, 'packedValue', AttrConfidence.kindOnly),

  /// `0x19` — **scale factor / multiplier** (mixed widths). Same id family as the
  /// `C4 19` description opcode but here a numeric attribute.
  scaleFactor(0x19, HeapAttrKind.numeric, 'scaleFactor', AttrConfidence.inferred),

  /// `0x5E` — **large numeric / packed coordinate-pair** (`u32`, ~0.85M..3.9M).
  packedPair(0x5e, HeapAttrKind.numeric, 'packedPairOrId', AttrConfidence.inferred),

  /// `0xDA` — **packed flag / version** (`u24`, dominated by `0x000101`).
  packedFlags(0xda, HeapAttrKind.numeric, 'packedFlags', AttrConfidence.kindOnly),

  /// `0x28` — **background / fill colour** (RGB; ~38% transparent → a fill).
  backgroundColor(0x28, HeapAttrKind.color, 'backgroundColor', AttrConfidence.confirmed),

  /// `0x24` — **content / area colour** (RGB; ~72% transparent → a frame fill).
  contentColor(0x24, HeapAttrKind.color, 'contentColor', AttrConfidence.confirmed),

  /// `0x6F` — **fill / area colour** (RGB; greys + ~29% transparent).
  fillColor(0x6f, HeapAttrKind.color, 'fillColor', AttrConfidence.confirmed),

  /// `0x20` — **foreground colour** (RGB; greys/black, rarely transparent →
  /// foreground). Pairs with [foregroundColorB].
  foregroundColor(0x20, HeapAttrKind.color, 'foregroundColor', AttrConfidence.inferred),

  /// `0x21` — **foreground / line colour** (RGB; greys/reds, rarely transparent).
  foregroundColorB(0x21, HeapAttrKind.color, 'lineColor', AttrConfidence.inferred),

  /// `0xD0` — **colour** (RGB; diverse hues). Direction not pinned.
  miscColor(0xd0, HeapAttrKind.color, 'miscColor', AttrConfidence.inferred),

  /// `0xB7` — **style colour** (RGB; predominantly `(1,0,1)` ≈78% of records but
  /// genuinely varies — 3,600+ distinct values across the corpus). Direction/role
  /// not pinned, so not `confirmed`.
  styleColor(0xb7, HeapAttrKind.color, 'styleColor', AttrConfidence.inferred),

  /// `0x22` — **label colour / text-attribute field** (mixed `u8`/RGB with text
  /// style flags). Distinct from the `C4 22` caption opcode.
  textStyle(0x22, HeapAttrKind.text, 'textStyle', AttrConfidence.inferred),

  /// `0x74` — **printf-format style / colour** (RGB with style byte `0x25`, or a
  /// `u16`). Distinct from the `C4 74` format-string opcode.
  formatStyle(0x74, HeapAttrKind.text, 'formatStyle', AttrConfidence.inferred),

  /// `0x58` — **mode / style enum** (`u8`, 1..15, one value dominant).
  modeFlag(0x58, HeapAttrKind.enumValue, 'modeFlag', AttrConfidence.kindOnly),

  /// `0x44` — **enum / count** (`u8`, `255` sentinel + small ints). Distinct from
  /// the `C4 44` container opcode.
  countOrSentinel(0x44, HeapAttrKind.enumValue, 'countOrSentinel', AttrConfidence.kindOnly),

  /// `0x59` — **reserved / near-always-zero flag** (`u8`; ~99.9% zero across the
  /// corpus, with rare non-zero outliers).
  reservedFlag(0x59, HeapAttrKind.flag, 'reservedFlag', AttrConfidence.inferred),

  /// `0x5A` — **flag (u8) OR instrument-identity string (C6)** — *dual-use*: a
  /// `u8` flag via the nibble form, or a VISA resource / serial / firmware string
  /// via `C6`. [HeapAttr.kind] resolves it by width.
  flagOrIdentity(0x5a, HeapAttrKind.flag, 'flagOrIdentityString', AttrConfidence.confirmed),

  /// `0xF5` — numeric-control **range minimum** (`f64`). The `f5 ≤ f7` ordering
  /// holds 100% on the picotech sample but only ≈90% across the diverse corpus,
  /// so the min/max direction is inferred, not pinned.
  controlMin(0xf5, HeapAttrKind.controlParam, 'controlMin', AttrConfidence.inferred),

  /// `0xF7` — numeric-control **range maximum** (`f64`; pairs with [controlMin] —
  /// see its note on the ≈90%-corpus ordering).
  controlMax(0xf7, HeapAttrKind.controlParam, 'controlMax', AttrConfidence.inferred),

  /// `0xF9` — numeric-control **fine increment** (`f64`; `f9 ≤ f8` in 257/257
  /// groups).
  controlFineIncrement(0xf9, HeapAttrKind.controlParam, 'controlFineIncrement', AttrConfidence.confirmed),

  /// `0xF6` — numeric-control **scale / full-scale** (`f64`; always > 0, never
  /// inside `[min,max]` → not a default).
  controlScale(0xf6, HeapAttrKind.controlParam, 'controlScale', AttrConfidence.inferred),

  /// `0xFA` — numeric-control **unit multiplier** (`f64`, constant `1.0` in
  /// 257/257 groups).
  controlUnit(0xfa, HeapAttrKind.controlParam, 'controlUnit', AttrConfidence.confirmed),

  /// An attribute id that is not (yet) catalogued. Its [id] is -1.
  unknown(-1, HeapAttrKind.unknown, 'unknown', AttrConfidence.kindOnly);

  const HeapAttribute(this.id, this.kind, this.attrName, this.confidence);

  /// The attribute id byte (the `<id>` after the opcode); -1 for [unknown].
  final int id;

  /// The intrinsic value kind for this attribute's *primary* (integer/RGB) form.
  /// Dual-use attributes resolve their effective kind via [HeapAttr.kind].
  final HeapAttrKind kind;

  /// The human-assigned name. See [confidence] for how grounded it is.
  final String attrName;

  /// How well-grounded [attrName] is (clean-room honesty).
  final AttrConfidence confidence;

  static final Map<int, HeapAttribute> _byId = {
    for (final a in values)
      if (a != unknown) a.id: a,
  };

  /// Maps a raw attribute id to its [HeapAttribute], or [unknown] if not
  /// catalogued. Note ids `0xF8`/`0x5A` are dual-use (see [HeapAttr.kind]).
  static HeapAttribute fromId(int id) => _byId[id] ?? unknown;
}

/// A single decoded attribute record (`<op> <id> <value>`): the catalog
/// [attribute], the storage [width], and the typed [value]
/// (`int` | `double` | `String`). Produced by [decodeHeapAttr].
class HeapAttr {
  const HeapAttr({
    required this.attribute,
    required this.id,
    required this.width,
    required this.value,
    required this.length,
  });

  /// The catalog entry (or [HeapAttribute.unknown] for an uncatalogued id).
  final HeapAttribute attribute;

  /// The raw attribute id byte (valid even when [attribute] is unknown).
  final int id;

  /// How the value was stored.
  final HeapAttrWidth width;

  /// The typed value: `int` (numeric/coord/size/enum/flag, or packed RGB for
  /// colours), `double` (f64 control params), `String` (C6 blobs), or [HeapRect]
  /// (rectangle-payload ids like `0x29`).
  final Object value;

  /// The total byte length of the record (so a walker can advance by it).
  final int length;

  /// The *effective* value kind, resolving dual-use attributes by [width]:
  /// an `f64` payload is always a [HeapAttrKind.controlParam] and a `blob` is
  /// always a [HeapAttrKind.stringBlob]; otherwise the catalog [kind].
  HeapAttrKind get kind {
    if (width == HeapAttrWidth.f64) return HeapAttrKind.controlParam;
    if (width == HeapAttrWidth.blob) return HeapAttrKind.stringBlob;
    if (width == HeapAttrWidth.rect) return HeapAttrKind.rectangle;
    if (width == HeapAttrWidth.rgb) {
      // The `8x`/`84` form is an RGB tuple for colour ids and for rect-dual ids
      // (e.g. 0x29, whose other form is a rect — its `84` form is an accent
      // colour). But many catalogued ids appear in the 4-byte form carrying
      // packed ASCII/integers, NOT colour (textStyle="Pane", formatStyle="%.0f",
      // packedValue, ordinals) — those must keep their catalogued kind.
      return (attribute.kind == HeapAttrKind.color || attribute.kind == HeapAttrKind.rectangle)
          ? HeapAttrKind.color
          : attribute.kind;
    }
    return attribute.kind;
  }

  /// The value as an `int`, or null if it is not integer-stored.
  int? get asInt => value is int ? value as int : null;

  /// The value as a `double`, or null if it is not an `f64` control param.
  double? get asDouble => value is double ? value as double : null;

  /// The value as a `String`, or null if it is not a blob.
  String? get asString => value is String ? value as String : null;

  /// The value as a [HeapRect], or null if it is not a rectangle-payload id.
  HeapRect? get asRect => value is HeapRect ? value as HeapRect : null;

  /// For a [HeapAttrKind.color] value, the 24-bit `0xRRGGBB` (drops the flag).
  int? get rgb => kind == HeapAttrKind.color && value is int ? (value as int) & 0xffffff : null;

  /// For a colour, whether it is the transparent sentinel (flag `0x01`, RGB 0).
  bool get isTransparent => kind == HeapAttrKind.color && value is int && ((value as int) >>> 24) == 0x01 && ((value as int) & 0xffffff) == 0;
}

/// Attribute ids whose `C5/C6 <id> 08` 8-byte payload is a 4× `s16` rectangle
/// rather than an `f64` (see [HeapAttribute.terminalRect]). Corpus-validated at
/// 100% rectangle / 0% sane-f64: `0x29`, and the `0x63`/`0x64` paired-rect block.
const Set<int> _rectPayloadIds = {0x29, 0x63, 0x64};

/// Attribute ids whose `C5/C6 <id> 08` 8-byte payload is a genuine IEEE-754
/// `f64` (corpus-validated ≈99–100% sane doubles): the numeric-control parameter
/// family plus `0x22`. Every OTHER id at `…08` is NOT assumed to be an f64 —
/// blindly reading e.g. `0xE7` (a container) as a double yields garbage, so
/// uncatalogued `…08` records are left framed-but-undecoded (return null).
const Set<int> _f64PayloadIds = {0xf5, 0xf6, 0xf7, 0xf8, 0xf9, 0xfa, 0x22};

/// Decodes an attribute-style record at [offset] in a heap [body], or returns
/// null if the byte there does not introduce a known attribute form. Handles the
/// `2x/4x/6x/8x/Ex` nibble family, `C5`/`C6 …08` (a rectangle for
/// [_rectPayloadIds], an `f64` for [_f64PayloadIds], else undecoded), and
/// `C6 …FF` (string blob). The id is looked up in the [HeapAttribute] catalog.
HeapAttr? decodeHeapAttr(Uint8List body, int offset) {
  if (offset + 2 > body.length) return null;
  final op = body[offset];

  // C5/C6 <id> 08 <8-byte payload>. The `08` is a payload-LENGTH byte (the same
  // `Cx <id> <u8 len>` framing recordSkip uses), so the 8 bytes are *not*
  // universally an f64 — their type depends on the id (corpus-confirmed).
  if ((op == 0xc5 || op == 0xc6) && offset + 11 <= body.length && body[offset + 2] == 0x08) {
    final id = body[offset + 1];
    if (_rectPayloadIds.contains(id)) {
      final rect = HeapRect.fromPayload(body.sublist(offset + 3, offset + 11));
      if (rect != null) {
        return HeapAttr(attribute: HeapAttribute.fromId(id), id: id, width: HeapAttrWidth.rect, value: rect, length: 11);
      }
    }
    if (_f64PayloadIds.contains(id)) {
      final v = ByteData.sublistView(body, offset + 3, offset + 11).getFloat64(0);
      return HeapAttr(attribute: HeapAttribute.fromId(id), id: id, width: HeapAttrWidth.f64, value: v, length: 11);
    }
    return null; // uncatalogued …08 payload — framed by recordSkip, meaning undecoded
  }

  // C6 <id> FF <u16 len> <u32 strlen><ascii…> — string/blob.
  if (op == 0xc6 && offset + 5 <= body.length && body[offset + 2] == 0xff) {
    final id = body[offset + 1];
    final len = (body[offset + 3] << 8) | body[offset + 4];
    final end = offset + 5 + len;
    if (end > body.length) return null;
    var s = '';
    if (len >= 4) {
      final strLen = ByteData.sublistView(body, offset + 5, offset + 9).getUint32(0);
      final from = offset + 9, to = (from + strLen) <= end ? from + strLen : end;
      s = String.fromCharCodes(body.sublist(from, to).where((c) => c >= 0x20 && c < 0x7f));
    }
    return HeapAttr(attribute: HeapAttribute.fromId(id), id: id, width: HeapAttrWidth.blob, value: s, length: 5 + len);
  }

  // The `64 cb 26` form is a fixed 3-byte record, NOT a `0x64` u24 attribute —
  // recordSkip special-cases it, so mirror that here (else a walk-then-decode
  // consumer gets a fabricated u24 whose 3rd byte is the next record, and a
  // length that desyncs the walk). The dominant corpus decode/skip disagreement.
  if (op == 0x64 && offset + 3 <= body.length && body[offset + 1] == 0xcb && body[offset + 2] == 0x26) {
    return null;
  }

  // Nibble family: low nibble in {4,5,6}, high nibble selects the width.
  final lo = op & 0xf, hi = op >> 4;
  if (lo == 4 || lo == 5 || lo == 6) {
    const widthBytes = {0x2: 1, 0x4: 2, 0x6: 3, 0x8: 4, 0xe: 0};
    final w = widthBytes[hi];
    if (w == null) return null;
    final id = body[offset + 1];
    final valEnd = offset + 2 + w;
    if (valEnd > body.length) return null;
    HeapAttrWidth width;
    Object value;
    switch (hi) {
      case 0x2:
        width = HeapAttrWidth.u8;
        value = body[offset + 2];
      case 0x4:
        width = HeapAttrWidth.u16;
        value = (body[offset + 2] << 8) | body[offset + 3];
      case 0x6:
        width = HeapAttrWidth.u24;
        value = (body[offset + 2] << 16) | (body[offset + 3] << 8) | body[offset + 4];
      case 0x8:
        width = HeapAttrWidth.rgb;
        value = (body[offset + 2] << 24) | (body[offset + 3] << 16) | (body[offset + 4] << 8) | body[offset + 5];
      default: // 0xE — bare flag, no value bytes.
        width = HeapAttrWidth.flag;
        value = 1;
    }
    return HeapAttr(attribute: HeapAttribute.fromId(id), id: id, width: width, value: value, length: 2 + w);
  }

  return null;
}

/// A length-prefixed **`C4` opcode record** in a decompressed VI heap.
///
/// The heap is a stream of opcode-serialized objects. Records introduced by the
/// byte `0xC4` are **length-prefixed** — `C4 <op> <u8 len> <len payload bytes>` —
/// confirmed across the corpus (see `docs/vi-rsrc-and-heap-format.md`): e.g.
/// `C4 2D` always carries `len == 8` (an 11-byte record) and skipping `3 + len`
/// lands on the next record's opcode byte in 99.97% of cases. So each `C4` record
/// can be **framed and skipped without knowing its semantics** — the seed of a
/// real heap walker.
///
/// Note on confidence: the *framing* is confirmed, but most opcodes' *meanings*
/// are still undecoded. Only `C4 2E` (string table) is interpreted today
/// (see `HeapStringTable`). [opcode] is the raw selector byte; [payload] is the
/// raw operand bytes — no semantic interpretation is applied here.
class HeapRecord {
  const HeapRecord({
    required this.sectionTag,
    required this.offset,
    required this.opcode,
    required this.payload,
    this.headerLength = 3,
  });

  /// The 4-char tag of the section this record lives in (e.g. `BDEx`, `FPHb`).
  final String sectionTag;

  /// Byte offset of the introducing `0xC4` within the decompressed section.
  final int offset;

  /// Bytes from the introducing `0xC4` to the start of [payload]: **3** for the
  /// normal `C4 <op> <u8 len>` header, **5** for the extended-length form
  /// `C4 <op> FF <u16 len>` (used when the payload exceeds 255 bytes). The
  /// payload therefore starts at `offset + headerLength`.
  final int headerLength;

  /// The opcode selector byte (the byte after `0xC4`), e.g. `0x2D`, `0x2E`, `0x1F`.
  /// Prefer [kind] for matching against the known-opcode catalog.
  final int opcode;

  /// The raw payload bytes (`<len>` bytes after the length byte).
  final Uint8List payload;

  /// This record's catalogued [HeapOpcode] (or [HeapOpcode.unknown]).
  HeapOpcode get kind => HeapOpcode.fromByte(opcode);

  /// Total bytes this record occupies: header ([headerLength]) + payload.
  int get byteLength => headerLength + payload.length;

  /// The 4× `s16` rectangle for any [HeapShape.rectangle] opcode (`bounds`,
  /// `size`, `rect5f`, `rect4c`, …); null otherwise. The generic accessor — see
  /// [bounds] / [sizeRect] for the meaning-specific specializations.
  HeapRect? get rect => kind.shape == HeapShape.rectangle ? HeapRect.fromPayload(payload) : null;

  /// If this is a [HeapOpcode.bounds] record, the object's bounding rectangle —
  /// four big-endian `s16` fields `top, left, bottom, right`, in pixels; else null.
  /// (Position/size of a control/node/decoration.)
  HeapRect? get bounds => kind == HeapOpcode.bounds ? HeapRect.fromPayload(payload) : null;

  /// If this is a [HeapOpcode.size] record, the origin-anchored size/extent
  /// rectangle (same 4× `s16` layout, `top == left == 0`); else null. Kept
  /// distinct from [bounds] so positional layout data is not polluted by sizes.
  HeapRect? get sizeRect => kind == HeapOpcode.size ? HeapRect.fromPayload(payload) : null;

  /// If this is a single-string opcode ([HeapShape.string]: caption, plot name,
  /// or format string), the payload decoded as text — the whole payload is the
  /// string (no inner prefix); else null. Null when empty or not fully printable
  /// ASCII.
  String? get text {
    if (kind.shape != HeapShape.string || payload.isEmpty) return null;
    for (final b in payload) {
      if (b < 32 || b >= 127) return null;
    }
    return String.fromCharCodes(payload);
  }

  /// If this is a [HeapOpcode.description] record, the embedded help/tooltip text
  /// (often HTML-ish, multi-line), recovered from its length-prefixed text
  /// segments; null if none. **Heuristic** — the inner multi-segment framing is
  /// not fully decoded, so this recovers readable text, not exact fields. Total.
  String? get descriptionText {
    if (kind != HeapOpcode.description) return null;
    bool isText(int start, int len) {
      for (var j = start; j < start + len; j++) {
        final c = payload[j];
        if (c >= 32 && c < 127) continue;
        if (c == 9 || c == 10 || c == 13) continue; // tab/newline/CR
        return false;
      }
      return true;
    }

    final runs = <String>[];
    var i = 0;
    while (i < payload.length) {
      final len = payload[i]; // u8 length prefix
      if (len >= 6 && i + 1 + len <= payload.length && isText(i + 1, len)) {
        runs.add(String.fromCharCodes(payload.sublist(i + 1, i + 1 + len)));
        i += 1 + len;
      } else {
        i++;
      }
    }
    return runs.isEmpty ? null : runs.join('\n');
  }

  /// If this is a [HeapOpcode.path] record, the filesystem path it encodes — the
  /// `PTH0` record's packed Pascal-string components joined with `/`; null if not
  /// a valid `PTH0`. (A DLL / library reference.) Total/bounds-safe.
  String? get path {
    if (kind != HeapOpcode.path) return null;
    final p = payload;
    if (p.length < 12 || p[0] != 0x50 || p[1] != 0x54 || p[2] != 0x48 || p[3] != 0x30) {
      return null; // not 'PTH0'
    }
    final nComp = (p[10] << 8) | p[11];
    final parts = <String>[];
    var i = 12;
    for (var c = 0; c < nComp && i < p.length; c++) {
      final len = p[i];
      if (i + 1 + len > p.length) break;
      var ok = true;
      for (var j = i + 1; j < i + 1 + len; j++) {
        if (p[j] < 32 || p[j] >= 127) {
          ok = false;
          break;
        }
      }
      if (!ok) break;
      parts.add(String.fromCharCodes(p.sublist(i + 1, i + 1 + len)));
      i += 1 + len;
    }
    return parts.isEmpty ? null : parts.join('/');
  }

  /// If this is a [HeapShape.container] record (e.g. a `C4 44` cluster), the
  /// nested `C4` child records inside its payload (offsets relative to this
  /// record's payload); otherwise empty. Total.
  List<HeapRecord> get children =>
      kind.shape == HeapShape.container ? scanC4Records(payload, sectionTag) : const <HeapRecord>[];
}

/// Frames the `C4 <op> <u8 len> <payload>` records in [h] (a decompressed heap or
/// a container payload), tagging each with [sectionTag]. Non-`C4` bytes are
/// stepped over one at a time. Total/bounds-safe.
List<HeapRecord> scanC4Records(Uint8List h, String sectionTag) {
  final out = <HeapRecord>[];
  final n = h.length;
  var i = 0;
  while (i < n) {
    final r = c4FrameAt(h, i, sectionTag);
    if (r != null) {
      out.add(r);
      i += r.byteLength;
      continue;
    }
    i++;
  }
  return out;
}

/// Frames a `C4` record at [i] (if [h]\[i\] is `0xC4` and the record fits),
/// handling both the normal `C4 <op> <u8 len>` header and the extended-length
/// escape `C4 <op> FF <u16 len>` (payload > 255 bytes). Returns null otherwise.
/// Total/bounds-safe.
HeapRecord? c4FrameAt(Uint8List h, int i, String sectionTag) {
  final n = h.length;
  if (i + 3 > n || h[i] != kHeapRecordPrefix) return null;
  final op = h[i + 1];
  final lenByte = h[i + 2];
  int headerLen;
  int len;
  if (lenByte == 0xff) {
    if (i + 5 > n) return null;
    headerLen = 5;
    len = (h[i + 3] << 8) | h[i + 4];
  } else {
    headerLen = 3;
    len = lenByte;
  }
  if (i + headerLen + len > n) return null;
  return HeapRecord(
    sectionTag: sectionTag,
    offset: i,
    opcode: op,
    payload: Uint8List.sublistView(h, i + headerLen, i + headerLen + len),
    headerLength: headerLen,
  );
}

/// A bounding rectangle in LabVIEW's field order (`top, left, bottom, right`),
/// in pixels. The position/size of a VI object (control, node, decoration).
class HeapRect {
  const HeapRect({required this.top, required this.left, required this.bottom, required this.right});

  /// Decodes an 8-byte heap payload as four big-endian `s16` fields
  /// (`top, left, bottom, right`). Returns null if [payload] is not 8 bytes.
  /// Total/bounds-safe.
  static HeapRect? fromPayload(Uint8List payload) {
    if (payload.length != 8) return null;
    int s16(int i) {
      final v = (payload[i] << 8) | payload[i + 1];
      return v >= 0x8000 ? v - 0x10000 : v;
    }

    return HeapRect(top: s16(0), left: s16(2), bottom: s16(4), right: s16(6));
  }

  final int top;
  final int left;
  final int bottom;
  final int right;

  /// Height in pixels (`bottom - top`).
  int get height => bottom - top;

  /// Width in pixels (`right - left`).
  int get width => right - left;

  /// Whether this is a well-formed rectangle (`bottom ≥ top ∧ right ≥ left`).
  bool get isValid => bottom >= top && right >= left;

  @override
  String toString() => 'HeapRect(t:$top l:$left b:$bottom r:$right ${width}x$height)';
}

/// Scan-based inventory of the **`C4` length-prefixed records** in a VI's heaps.
///
/// Walks each decompressed section: at a `0xC4` it frames the record by its `u8`
/// length prefix and skips its payload (so a `0xC4` *inside* a framed record's
/// payload is not re-scanned); non-`C4` records — whose length rules are not yet
/// decoded — are stepped over one byte at a time. **Total** (never throws; all
/// records are in-bounds).
///
/// Best-effort, not a complete walker: until the non-`C4` opcode lengths are
/// decoded, a `0xC4` that occurs inside a non-`C4` record's payload can frame a
/// spurious record (the scan resynchronizes afterward). The dominant opcodes
/// (`C4 2D`, `C4 1F`, `C4 5F`, …) are framed reliably.
List<HeapRecord> heapC4Records(Uint8List viBytes) => heapC4RecordsFromDecoded(decodeSections(viBytes));

/// [heapC4Records] over already-decoded sections.
List<HeapRecord> heapC4RecordsFromDecoded(Iterable<DecodedSection> decoded) {
  final out = <HeapRecord>[];
  for (final d in decoded) {
    out.addAll(scanC4Records(d.bytes, d.tag));
  }
  return out;
}

/// One record found by [walkHeapBody]: its byte span and lead opcode byte.
class HeapSpan {
  const HeapSpan({required this.offset, required this.length, required this.lead});

  /// Byte offset of the record's start within the heap body.
  final int offset;

  /// Total byte length of the record.
  final int length;

  /// The record's lead byte — `0xC4` for a [HeapRecord]-style record, otherwise a
  /// non-`C4` record family byte (`0x10`, `0x84`, `0x14`, …).
  final int lead;

  /// Whether this is a `C4`-prefixed (length-prefixed) record.
  bool get isC4Record => lead == kHeapRecordPrefix;
}

/// Result of sequentially walking a decompressed heap body with [walkHeapBody]:
/// the ordered record spans, how far the walk got, and where (if anywhere) it
/// hit an opcode it could not frame.
class HeapWalk {
  const HeapWalk({
    required this.spans,
    required this.coveredBytes,
    required this.bodyBytes,
    this.stoppedAtOffset,
    this.stoppedLead,
  });

  /// The records framed, in heap order.
  final List<HeapSpan> spans;

  /// Bytes consumed by recognized records.
  final int coveredBytes;

  /// Length of the record stream (the body minus its leading `u32` content-length).
  final int bodyBytes;

  /// Offset where the walk stopped on an un-framable opcode, or null if it walked
  /// to the end.
  final int? stoppedAtOffset;

  /// The lead byte that stopped the walk (null if it completed).
  final int? stoppedLead;

  /// Fraction of the record stream covered before stopping (1.0 if complete).
  double get coverage => bodyBytes <= 0 ? 1.0 : coveredBytes / bodyBytes;

  /// Whether the walk reached the end of the body.
  bool get complete => stoppedAtOffset == null;
}

/// The serialized form of a [HeapPropertyToken] in the byte stream.
enum PropTokenForm {
  /// `<op> <subop> <count> <FB/FE/FD> <items>` — a tagged sub-list. The first
  /// item carries the value: tag `FE` → `s16`, `FB` → `u16`, `FD` → an object id.
  /// The `count` is 1 or 2 (≈50/50 across the corpus; the dominant `10 19` token
  /// is ≈79% count==2). [decodeHeapPropertyToken] returns only the **first**
  /// item's value; a frequently-present second item (often an `fd` object id) is
  /// not surfaced.
  taggedList,

  /// A bare 2-byte `<op> <subop>` selector — a fixed property *slot* on the
  /// current object that carries no inline value (the value, if any, lives in
  /// neighbouring attribute records).
  selector,
}

/// Catalog of the **hi-nibble 0/1 property tokens** — the `<op> <subop>` records
/// (`op >> 4 ∈ {0,1}`, plus the `0x12` case-structure triples) that decorate an
/// open heap object with a named property. These are framed by [recordSkip] /
/// [_typedList]; this enum gives the decoded *meaning* of the high-volume pairs.
///
/// Derived purely by clean-room statistical analysis over 2,630 EOF-balanced
/// heap walks (8,360 corpus VIs), restricted to object-scoped tokens. The
/// decisive finding: each `(op, subop)` pair carries exactly one item-tag (the
/// subop selects the property *and* its value class), the value is near-constant
/// per object kind for the role-marker pairs, and `op==0x04` two-byte tokens are
/// **not** properties at all but type-descriptor-grammar fragments (see
/// [isTypeDescriptorToken]). See `docs/vi-rsrc-and-heap-format.md`.
///
/// HONESTY ([AttrConfidence]): `confirmed` pairs are pinned by a decisive signal
/// (a value↔kind bijection, a known reflist opener, or 100%-invariant framing
/// neighbours); `inferred` names give the defensible direction from value+kind
/// correlation and co-occurring `C4` records; `kindOnly` names are value-kind
/// labels on a single scoped kind. No LabVIEW source was used. Resolve a pair
/// with [lookup]; map a record at an offset with [decodeHeapPropertyToken].
enum HeapPropertyToken {
  /// `10 19` (non-header form) — a small `FE`→s16 property token. NOTE: the
  /// dominant `10 19` shape in the corpus is the **object header**
  /// `10 19 02 fe <kind> fd <oid>` (≈79% of `10 19` records, count==2), which is
  /// NOT this token — [decodeHeapPropertyToken] excludes the object-header shape
  /// so it is not mis-read here. What remains (e.g. the `10 19 01 fe <s16>`
  /// single-item form) is a genuine property token, but its meaning is not pinned
  /// (the earlier "≈0x258 / value↔kind 1:1" claim conflated it with the header
  /// and is false — the header's first u16 is a diverse class code, not 0x258).
  selfRoleClass(0x10, 0x19, PropTokenForm.taggedList, 'selfRoleClass', AttrConfidence.kindOnly),

  /// `10 8d` — **text / appearance feature flag** (`FE`→s16, always 0x258) on
  /// label-bearing parts (chrome, label, numeric display). Co-occurs with the
  /// `C4 22` caption.
  textAppearanceFlag(0x10, 0x8d, PropTokenForm.taggedList, 'textAppearanceFlag', AttrConfidence.inferred),

  /// `10 22` — **terminal-cluster role marker** (`FE`→s16, always 0x258), scoped
  /// almost entirely to terminal clusters; co-occurs exactly with `C4 2D` +
  /// `C4 1F` (the terminal signature).
  terminalClusterRole(0x10, 0x22, PropTokenForm.taggedList, 'terminalClusterRole', AttrConfidence.inferred),

  /// `11 2d` — **text-element presence flag** (`FE`→s16, always 1) on labels,
  /// numeric displays and enum item-lists; co-occurs with `C4 2D` + `C4 22`.
  textElementPresent(0x11, 0x2d, PropTokenForm.taggedList, 'textElementPresent', AttrConfidence.inferred),

  /// `11 1f` — **sub-part / member-shape count** (`FB`→u16, small: 2/4/5),
  /// varying by control type. Tested **NOT** a child-membership count (0% match
  /// to actual child-object counts) — it is an intrinsic shape parameter.
  subPartShapeCount(0x11, 0x1f, PropTokenForm.taggedList, 'subPartShapeCount', AttrConfidence.inferred),

  /// `10 e1` — **control style / sub-element count** (`FB`→u16) whose value tracks
  /// the control class (numeric=7, boolean cluster=4, string array=6, enum ring=6,
  /// loop/diagram frame=4/6): a per-control-class style/part code.
  controlStyleCount(0x10, 0xe1, PropTokenForm.taggedList, 'controlStyleCount', AttrConfidence.inferred),

  /// `11 18` — **tip-strip flag** (`FB`→u16, observed values {1, 2}), scoped
  /// entirely to tip-strip objects; co-occurs only with `C4 19` help text.
  tipStripEnabled(0x11, 0x18, PropTokenForm.taggedList, 'tipStripEnabled', AttrConfidence.inferred),

  /// `10 25` — **text-table / item-list marker** (`FB`→u16, value 1) on labels,
  /// enum item-lists and numeric displays; co-occurs with `C4 2D` + `C4 22` +
  /// the `C4 2E` string table.
  textTableMarker(0x10, 0x25, PropTokenForm.taggedList, 'textTableMarker', AttrConfidence.inferred),

  /// `10 55` — **structure child reflist opener** (`FB`→u16): the header of the
  /// child-membership reference list on loops/case structures/diagram frames (the
  /// `10 55 01 fb <count>` form, each member a `14 19 01 fd <oid>` ref).
  structureChildReflist(0x10, 0x55, PropTokenForm.taggedList, 'structureChildReflist', AttrConfidence.confirmed),

  /// `11 4e` — **diagram-frame style / zoom parameter** (`FB`→u16: 2/3/4) on
  /// content viewports and diagram frames.
  diagramFrameStyle(0x11, 0x4e, PropTokenForm.taggedList, 'diagramFrameStyle', AttrConfidence.kindOnly),

  /// `11 eb` — **enum / ring property** (`FB`→u16, mostly 0), scoped to enum-ring
  /// controls.
  enumRingProperty(0x11, 0xeb, PropTokenForm.taggedList, 'enumRingProperty', AttrConfidence.inferred),

  /// `11 ea` — **enum / ring count / style** (`FB`→u16, varies), scoped to
  /// enum-ring controls.
  enumRingCount(0x11, 0xea, PropTokenForm.taggedList, 'enumRingCount', AttrConfidence.inferred),

  /// `10 49` — **diagram property** (`FB`→u16, value 12=0x0C dominant), scoped
  /// entirely to diagram-properties objects.
  diagramProperty(0x10, 0x49, PropTokenForm.taggedList, 'diagramProperty', AttrConfidence.kindOnly),

  /// `12 15` — **case/sequence frame parameter A** (`FB`→u16), scoped to
  /// case/sequence structures (one of a 3-tuple with [caseSeqParamB]/[caseSeqParamC]).
  caseSeqParamA(0x12, 0x15, PropTokenForm.taggedList, 'caseSeqParamA', AttrConfidence.inferred),

  /// `12 16` — **case/sequence frame parameter B** (`FB`→u16). See [caseSeqParamA].
  caseSeqParamB(0x12, 0x16, PropTokenForm.taggedList, 'caseSeqParamB', AttrConfidence.inferred),

  /// `12 17` — **case/sequence frame parameter C** (`FB`→u16). See [caseSeqParamA].
  caseSeqParamC(0x12, 0x17, PropTokenForm.taggedList, 'caseSeqParamC', AttrConfidence.inferred),

  /// `12 05` — **decoration property** (`FB`→u16, value 0), scoped to decorations.
  decorationProperty(0x12, 0x05, PropTokenForm.taggedList, 'decorationProperty', AttrConfidence.kindOnly),

  /// `11 10` — **viewport property slot 1** (bare selector). Pinned by a
  /// 100%-invariant context — it always sits between a `64`(u24 attr) and a
  /// `44`(u16 attr) inside content-viewport objects: a fixed scrollbar/viewport
  /// property slot.
  viewportSlot1(0x11, 0x10, PropTokenForm.selector, 'viewportSlot1', AttrConfidence.confirmed),

  /// `11 14` — **viewport property slot 2** (bare selector), same `64`/`44`
  /// framing as [viewportSlot1] inside content viewports.
  viewportSlot2(0x11, 0x14, PropTokenForm.selector, 'viewportSlot2', AttrConfidence.inferred);

  const HeapPropertyToken(this.op, this.subop, this.form, this.tokenName, this.confidence);

  /// The leading opcode byte (`op >> 4 ∈ {0,1}`, or `0x12` for the case triple).
  final int op;

  /// The sub-opcode that selects the property (and its value class).
  final int subop;

  /// How the value is carried in the byte stream.
  final PropTokenForm form;

  /// The human-assigned name. See [confidence] for how grounded it is.
  final String tokenName;

  /// How well-grounded [tokenName] is (clean-room honesty).
  final AttrConfidence confidence;

  static final Map<int, HeapPropertyToken> _byKey = {
    for (final t in values) (t.op << 8) | t.subop: t,
  };

  /// The catalogued token for an `(op, subop)` pair, or null if uncatalogued.
  static HeapPropertyToken? lookup(int op, int subop) => _byKey[(op << 8) | subop];
}

/// Whether a two-byte `<op> <subop>` token is an `op == 0x04` **type-descriptor
/// grammar fragment** rather than an object property. These chain as a
/// `04 SS 00 00` / `04 TT 00 00` stream (the DTHP type-descriptor token grammar)
/// and appear on graph/path objects; their *role* is known (structural) even
/// though no per-token property name applies. Distinct from [HeapPropertyToken].
bool isTypeDescriptorToken(int op) => op == 0x04;

/// A decoded property token at an offset: the catalogued [token] and, for a
/// [PropTokenForm.taggedList], the first item's [value] (the property value).
class HeapPropertyValue {
  const HeapPropertyValue({required this.token, required this.value, required this.length});

  /// The catalogued token.
  final HeapPropertyToken token;

  /// The first item's value for a tagged sub-list (`s16`/`u16`/object id), or null
  /// for a bare [PropTokenForm.selector].
  final int? value;

  /// Total bytes the record occupies (as framed by [recordSkip]).
  final int length;
}

/// Decodes the [HeapPropertyToken] record at [offset] in [body], or null if the
/// bytes there are not a catalogued `(op, subop)` token. Mirrors [recordSkip]'s
/// framing of the hi-nibble 0/1 family.
///
/// Returns null for the **object-header** shape `10/11/12 02 fe <kind> fd <oid>`
/// even though its `(op, subop)` may be catalogued (e.g. `10 19`): that is an
/// object declaration, not a property — decode it as a header (the (kind, oid)
/// pair), not via this primitive. (Callers that classify object headers first
/// were already correct; this keeps the primitive honest standalone.)
HeapPropertyValue? decodeHeapPropertyToken(Uint8List body, int offset) {
  if (offset + 2 > body.length) return null;
  // Object header, not a property token — see doc above.
  if (offset + 9 <= body.length &&
      (body[offset] == 0x10 || body[offset] == 0x11 || body[offset] == 0x12) &&
      body[offset + 2] == 0x02 && body[offset + 3] == 0xfe && body[offset + 6] == 0xfd) {
    return null;
  }
  final op = body[offset], subop = body[offset + 1];
  final token = HeapPropertyToken.lookup(op, subop);
  if (token == null) return null;
  if (token.form == PropTokenForm.selector) {
    return HeapPropertyValue(token: token, value: null, length: 2);
  }
  // Tagged sub-list `<op> <subop> <count> <tag> <items>`; decode the first item.
  if (offset + 4 > body.length || !_isTypeTag(body[offset + 3])) return null;
  final len = _typedList(body, offset);
  if (len == null) return null;
  final tag = body[offset + 3];
  int? value;
  if (tag == 0xfb && offset + 6 <= body.length) {
    value = (body[offset + 4] << 8) | body[offset + 5]; // u16 item
  } else if (tag == 0xfd && offset + 5 <= body.length && (body[offset + 4] & 0x80) != 0) {
    // 7-byte FD escape `fd 80 00 <u32 value>`: the u32 follows `80 00`.
    value = offset + 10 <= body.length
        ? (body[offset + 6] << 24) | (body[offset + 7] << 16) | (body[offset + 8] << 8) | body[offset + 9]
        : null;
  } else if ((tag == 0xfe || tag == 0xfd) && offset + 6 <= body.length) {
    // 3-byte item `<tag><hi><lo>`: the trailing 2 bytes are the s16/oid value.
    value = (body[offset + 4] << 8) | body[offset + 5];
  }
  return HeapPropertyValue(token: token, value: value, length: len);
}

/// Catalog of the **`0x14` typed-reference family** — the 6-byte
/// `14 <subop> 01 fd <u16 oid>` records that form the heap's object graph. Each
/// is a typed link from the current object to another object (by id); the
/// [subop] selects the *relationship*.
///
/// Corpus-validated: across the diverse corpus the `u16` resolves to an object id
/// declared in the same heap at **91–100%** for every subop — **except `0x53`**,
/// which resolves at 0% and is a literal `u16`, not a reference (see [literal]).
/// The dominant links are [childRef] (`14 19`, the structure child-membership ref
/// also gathered by the `10 55` reflist) and [memberRef] (`14 4f`). Resolve a
/// record with [decodeHeapRef].
enum HeapRefKind {
  /// `14 19` — **structure/container child-membership** reference (the members of
  /// a loop / case structure / cluster). The highest-volume link.
  childRef(0x19, 'childRef', AttrConfidence.confirmed),

  /// `14 4f` — **member** reference: an object-list owner enumerating its child /
  /// member objects (resolves ~91%). The dominant non-child link.
  memberRef(0x4f, 'memberRef', AttrConfidence.confirmed),

  /// `14 1f` — **owner / back-reference** (resolves 100%).
  ownerRef(0x1f, 'ownerRef', AttrConfidence.confirmed),

  /// `14 50` — **sibling / peer** object reference (resolves 100%).
  siblingRef(0x50, 'siblingRef', AttrConfidence.confirmed),

  /// A typed object reference whose subop is not individually named but which
  /// resolves to an object id at ~100% (e.g. `14 34`, `14 aa`, `14 f7`). [subop]
  /// is -1 (this is the catch-all returned by [fromSubop]).
  objectRef(-1, 'objectRef', AttrConfidence.inferred),

  /// `14 53` — a literal `u16` value, **NOT** an object reference (0% oid-resolve
  /// across the corpus). [decodeHeapRef] returns null for it.
  literal(0x53, 'literal', AttrConfidence.confirmed);

  const HeapRefKind(this.subop, this.refName, this.confidence);

  /// The sub-opcode that selects the relationship; -1 for the [objectRef] catch-all.
  final int subop;

  /// The human-assigned relationship name.
  final String refName;

  /// How well-grounded [refName] is.
  final AttrConfidence confidence;

  static final Map<int, HeapRefKind> _bySubop = {
    for (final r in values)
      if (r != objectRef) r.subop: r,
  };

  /// The relationship for a `0x14` subop: a named kind, [literal] for `0x53`, or
  /// the generic [objectRef] for any other (still a resolving typed reference).
  static HeapRefKind fromSubop(int subop) => _bySubop[subop] ?? objectRef;
}

/// A decoded `0x14` typed reference: its [kind] and the [targetOid] it links to.
class HeapRef {
  const HeapRef({required this.kind, required this.targetOid, required this.length});

  /// The relationship type.
  final HeapRefKind kind;

  /// The referenced object's id.
  final int targetOid;

  /// Total bytes the record occupies (always 6).
  final int length;
}

/// Decodes the `14 <subop> 01 fd <u16 oid>` typed reference at [offset], or null
/// if the bytes there are not such a record — or are the `14 53` [literal], which
/// is a value, not a reference. Mirrors [recordSkip]'s framing of the `0x14` family.
HeapRef? decodeHeapRef(Uint8List body, int offset) {
  if (offset + 6 > body.length) return null;
  if (body[offset] != 0x14 || body[offset + 2] != 0x01 || body[offset + 3] != 0xfd) return null;
  final kind = HeapRefKind.fromSubop(body[offset + 1]);
  if (kind == HeapRefKind.literal) return null;
  return HeapRef(kind: kind, targetOid: (body[offset + 4] << 8) | body[offset + 5], length: 6);
}

/// How fully a heap record is understood — the basis of the honest three-tier
/// coverage metric (see `tool/coverage.dart` + `corpus/README.md`).
enum HeapDecodeTier {
  /// We know what the record **means**: an object header (`kind`+`oid`), a
  /// bracket-tree group open/close, a typed object reference, a decoded `C4`
  /// opcode, or a *named* attribute/property-token of confirmed/inferred
  /// confidence.
  semantic,

  /// The value's **kind/width** is known but its meaning is not — a `kindOnly`
  /// catalog entry (a value-kind label, not a decoded role).
  valueKindKnown,

  /// Only the record **boundary** is known (it was framed); its content is not
  /// interpreted at all.
  framed,
}

/// Classifies the record at [offset] in a heap [body] (whose lead byte is [lead],
/// living in section [sectionTag]) into a [HeapDecodeTier]. The single source of
/// truth shared by the coverage tool and its regression test so they cannot
/// drift. Assumes [offset] is a record start as produced by [walkHeapBody].
HeapDecodeTier heapDecodeTier(Uint8List body, int offset, int lead, String sectionTag) {
  // Object header (class + oid), group open/close (bracket tree) — structural meaning.
  if ((lead == 0x10 || lead == 0x11 || lead == 0x12) &&
      offset + 9 <= body.length && body[offset + 2] == 0x02 && body[offset + 3] == 0xfe && body[offset + 6] == 0xfd) {
    return HeapDecodeTier.semantic;
  }
  if (lead == 0x08 || lead == 0x09 || lead == 0x0a || lead == 0x0b) return HeapDecodeTier.semantic; // close
  if (lead == 0x10 || lead == 0x11 || lead == 0x12 || lead == 0x13) {
    if (offset + 4 <= body.length && _isTypeTag(body[offset + 3])) return HeapDecodeTier.semantic; // group open
  }
  if (lead == 0x14 && decodeHeapRef(body, offset) != null) return HeapDecodeTier.semantic; // typed ref
  if (lead == kHeapRecordPrefix) {
    final rec = c4FrameAt(body, offset, sectionTag);
    return (rec != null && rec.kind.isDecoded) ? HeapDecodeTier.semantic : HeapDecodeTier.framed;
  }
  final a = decodeHeapAttr(body, offset);
  if (a != null) {
    if (a.attribute == HeapAttribute.unknown) return HeapDecodeTier.framed;
    return a.attribute.confidence == AttrConfidence.kindOnly ? HeapDecodeTier.valueKindKnown : HeapDecodeTier.semantic;
  }
  if (isTypeDescriptorToken(lead)) return HeapDecodeTier.semantic; // 0x04 type-descriptor grammar (structural)
  final pv = decodeHeapPropertyToken(body, offset);
  if (pv != null) {
    return pv.token.confidence == AttrConfidence.kindOnly ? HeapDecodeTier.valueKindKnown : HeapDecodeTier.semantic;
  }
  return HeapDecodeTier.framed;
}

/// The byte length of the heap record at [i] in [h], or null if [i] is not a
/// recognized record start (the walk stops there). This is the **heap record
/// skip table** — the reverse-engineered framing of every record family known so
/// far. Coverage across the diverse corpus is measured mechanically (the
/// "% deliberately parsed" metric — see corpus/ and tool/coverage.dart), not
/// hand-asserted here; it is the frontier this table extends. Total/bounds-safe.
///
/// Record families (lead byte → framing):
/// - `C4` — length-prefixed: `3 + u8len`, or `5 + u16len` for the `FF` escape.
/// - `84` — fixed 6 bytes (an RGB color tuple).
/// - `10`/`12`/`11`/`0a` — typed-list node: opcode, subop, `u8` count, type tag,
///   then items. Tag `FB` → 2-byte items (`4 + 2*count`); tag `FE`/`FD` → 3-byte
///   items (`3 + 3*count`). `11`/`0a` are 2 bytes when no type tag follows.
/// - `14` — fixed 6 bytes (`14 sub 01 fd|fe s16`).
/// - `08`/`09`/`04` — fixed 2 bytes.
/// - `24` → 3 bytes; `44` → 4 bytes; `64` → 5 bytes (the `64 cb 26` form → 3).
/// - `02` (with `FE`) — fixed 7 bytes.
/// - `25` — a fixed **3-byte** record (the `25 2d` form is NOT a counted list).
/// - attribute nibble-family (opcode low nibble in {4,5,6}): the high nibble sets
///   the value width — `2x`→3, `4x`→4, `6x`→5, `8x`→6, `Ex`→2, `Cx`→`3 + u8len`.
int? recordSkip(Uint8List h, int i) {
  final n = h.length;
  if (i >= n) return null;
  final op = h[i];
  switch (op) {
    case 0xc4:
      if (i + 3 > n) return null;
      final lb = h[i + 2];
      if (lb == 0xff) {
        if (i + 5 > n) return null;
        return 5 + ((h[i + 3] << 8) | h[i + 4]);
      }
      return 3 + lb;
    case 0x84:
      return 6;
    case 0x10:
    case 0x12:
    case 0x11:
    case 0x0a:
      // A typed-list/group when followed by a type tag (FB/FE/FD); otherwise a
      // 2-byte data record. 0x10/0x12 previously hard-stopped the walk on a
      // non-tag byte (unlike 0x11/0x0a) — giving them the same 2-byte resync
      // keeps the walk going and raises coverage.
      return (i + 4 <= n && _isTypeTag(h[i + 3])) ? _typedList(h, i) : 2;
    case 0x14:
      return (i + 4 <= n && h[i + 2] == 1 && (h[i + 3] == 0xfd || h[i + 3] == 0xfe)) ? 6 : null;
    case 0x08:
    case 0x09:
    case 0x04:
      return 2;
    case 0x24:
      return 3;
    case 0x44:
      return 4;
    case 0x64:
      return (i + 3 <= n && h[i + 1] == 0xcb && h[i + 2] == 0x26) ? 3 : 5;
    case 0x02:
      return (i + 2 <= n && h[i + 1] == 0xfe) ? 7 : null;
    case 0x25:
      return 3; // fixed 3-byte record (the `25 2d` form is NOT a counted list)
    case 0xc6:
      // Extended-length blob/string record, same escape form as C4. (Non-escape
      // C6 is unobserved; it falls through to the attribute nibble-family.)
      if (i + 3 <= n && h[i + 2] == 0xff) {
        return (i + 5 <= n) ? 5 + ((h[i + 3] << 8) | h[i + 4]) : null;
      }
  }
  final lo = op & 0x0f;
  if (lo == 4 || lo == 5 || lo == 6) {
    switch (op >> 4) {
      case 2:
        return 3;
      case 4:
        return 4;
      case 6:
        return 5;
      case 8:
        return 6;
      case 0xe:
        return 2;
      case 0xc:
        return (i + 3 <= n) ? 3 + h[i + 2] : null;
    }
  }
  // High-nibble 0/1 opcodes are all the same typed-list/object-node family as
  // the explicit 0x10/0x11/0x12/0x0a cases: a typed sub-list when a type tag
  // (FB/FE/FD) follows the count, else a 2-byte property/field token on the
  // current object. Framing the rest of the family (05/06/15/16/… and the
  // 0x19/0x01/0x00 leads) lifts corpus coverage from ~41% to ~99% — corpus-
  // validated that it advances cleanly to recognized records (no desync). The
  // decoded *meanings* of the high-volume pairs are catalogued in
  // [HeapPropertyToken] (resolve a record with [decodeHeapPropertyToken]).
  final hi = op >> 4;
  if (hi == 0 || hi == 1) {
    return (i + 4 <= n && _isTypeTag(h[i + 3])) ? _typedList(h, i) : 2;
  }
  return null;
}

bool _isTypeTag(int t) => t == 0xfb || t == 0xfe || t == 0xfd;

int? _typedList(Uint8List h, int i) {
  final n = h.length;
  if (i + 4 > n) return null;
  final count = h[i + 2];
  final tag = h[i + 3];
  if (tag == 0xfb) return 4 + 2 * count; // `op subop count FB <count 2-byte items>`
  if (tag == 0xfe || tag == 0xfd) {
    // `op subop count <count items>`; each item is normally 3 bytes
    // (`<tag><hi><lo>`), but an `FD` item whose high value bit is set is a
    // 7-byte escape (`fd 80 00 <u32 value>`).
    var q = i + 3;
    for (var k = 0; k < count; k++) {
      if (q >= n) return null;
      if (h[q] == 0xfd && q + 1 < n && (h[q + 1] & 0x80) != 0) {
        q += 7;
      } else {
        q += 3;
      }
    }
    return q - i;
  }
  return null;
}

/// Sequentially walks a decompressed heap [body] (e.g. a `BDEx` section's bytes)
/// as an ordered record stream, starting after the leading `u32` content-length,
/// using [recordSkip]. Stops at the first opcode it cannot frame and reports how
/// far it got. Total/bounds-safe — never throws.
HeapWalk walkHeapBody(Uint8List body) {
  final spans = <HeapSpan>[];
  final n = body.length;
  if (n < 4) return HeapWalk(spans: spans, coveredBytes: 0, bodyBytes: n < 0 ? 0 : (n - 4).clamp(0, n));
  final bodyBytes = n - 4;
  var i = 4;
  var covered = 0;
  while (i < n) {
    final s = recordSkip(body, i);
    if (s == null || s <= 0 || i + s > n) {
      return HeapWalk(
        spans: spans,
        coveredBytes: covered,
        bodyBytes: bodyBytes,
        stoppedAtOffset: i,
        stoppedLead: body[i],
      );
    }
    spans.add(HeapSpan(offset: i, length: s, lead: body[i]));
    covered += s;
    i += s;
  }
  return HeapWalk(spans: spans, coveredBytes: covered, bodyBytes: bodyBytes);
}

/// Frequency of each `C4` opcode across a VI's heaps — the opcode census that
/// maps the heap's record types (e.g. `0x2D` dominant, `0x2E` = string table).
/// Total.
Map<int, int> heapOpcodeHistogram(Uint8List viBytes) {
  final hist = <int, int>{};
  for (final r in heapC4Records(viBytes)) {
    hist[r.opcode] = (hist[r.opcode] ?? 0) + 1;
  }
  return hist;
}
