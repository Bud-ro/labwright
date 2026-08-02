import 'dart:typed_data';

import 'decode.dart';

/// The byte that introduces a length-prefixed heap record (`C4 op len payload`).
/// See [HeapOpcode] for the opcode catalog.
///
/// HEADER MODEL: every heap record opens with a 2-byte node header
/// `byte0 = sizeSpec(3b)<<5 | hasAttrList(1b)<<4 | scope(2b)<<2 | tagHi(2b)`,
/// `byte1 = tagLo` — a **10-bit raw tag id** (`tagHi:tagLo`), a scope
/// (0 = open, 1 = leaf, 2 = close), an optional attribute list, and a data
/// size selector (0 → no data/false, 1–4 → that many bytes, 6 → a `u8`
/// length prefix with the `FF → u16` escape, 7 → no data/true). `0xC4` is the
/// leaf/sizeSpec-6/tagHi-0 corner of that grid. The model reproduces every
/// framing rule in [recordSkip] and is corroborated by the tag catalog of the
/// open-source pylabview project (whose tag ids equal `rawTagId - 31`, with
/// negative system tags: raw `0x19` = `arrayElement`, the object headers);
/// every adopted tag name below is additionally verified against this corpus.
const int kHeapRecordPrefix = 0xc4;

/// The section tags whose decompressed bodies are opcode-record heaps (walkable
/// by [walkHeapBody]): the block-diagram and front-panel heaps plus the
/// data-type heap. The single tag set used by the heap coverage metrics
/// (`tool/coverage.dart` and its regression test).
const Set<String> kHeapSectionTags = {'BDHb', 'BDHP', 'FPHb', 'FPHP', 'DTHP'};

/// The object-header lead opcodes: `10/11/12` open an object header
/// (`<lead> <tag> 02 fe <u16 kind> fd <u16 oid>`). See [heapObjectHeaderAt].
const Set<int> kHeapObjectHeaderLeads = {0x10, 0x11, 0x12};

/// The group-open lead opcodes of the balanced typed-group tree: a
/// high-nibble-1 lead (`10/11/12/13`) whose byte after the count is a type tag
/// ([isHeapTypeTag]) opens a group — an object when the header shape matches
/// ([heapObjectHeaderAt]), otherwise an anonymous group.
const Set<int> kHeapGroupOpenLeads = {0x10, 0x11, 0x12, 0x13};

/// The high-nibble-0 group-close opcodes (`08/09/0a/0b`), popped positionally
/// against the [kHeapGroupOpenLeads] opens.
const Set<int> kHeapGroupCloseLeads = {0x08, 0x09, 0x0a, 0x0b};

/// Whether [tagByte] is a typed-list type tag (`FB`/`FE`/`FD`) — the byte after
/// the count in a typed-list record `<op> <subop> <count> <tag> <items>`.
bool isHeapTypeTag(int tagByte) => tagByte == 0xfb || tagByte == 0xfe || tagByte == 0xfd;

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
  /// extent rather than a position. Corpus: ~99% are 8-byte (≈99.6% origin-anchored
  /// when 8-byte). Decoded by [HeapRecord.sizeRect].
  size(0x1f, HeapShape.rectangle, isDecoded: true),

  /// `0x2E` — **string table** (decoded). The only variable-length confirmed
  /// opcode: the payload is `len` bytes of packed `[u8 strlen][chars]` Pascal
  /// strings (a `u16` length is used when the table exceeds 255 bytes). Holds a
  /// group of related labels (enum/ring items, captions). Decoded by
  /// [HeapStringTable] / the string-table parser.
  stringTable(0x2e, HeapShape.stringTable, isDecoded: true),

  /// `0x22` — **caption** (decoded). A single control / parameter name; the
  /// payload *is* the text, sized by the record's own length byte. Corpus: 97% of
  /// bytes printable (≈92% of records fully printable; [HeapRecord.text] returns
  /// null on the rest). Decoded by [HeapRecord.text].
  caption(0x22, HeapShape.string, isDecoded: true),

  /// `0x27` — **plot / legend name** (decoded). A single string naming a plot or
  /// series, e.g. `Plot 0`, `Plot 1`. Same single-string payload as [caption]
  /// (≈99% of records fully printable). Decoded by [HeapRecord.text].
  plotName(0x27, HeapShape.string, isDecoded: true),

  /// `0x74` — **numeric format string** (decoded). A single string holding a
  /// display format specifier, e.g. `%020b`, `%016b`, `%#_6g`. Single-string
  /// payload, 96% of bytes printable (≈79% of records fully printable — format
  /// specifiers carry control bytes; [HeapRecord.text] returns null on the rest).
  /// Decoded by [HeapRecord.text].
  formatString(0x74, HeapShape.string, isDecoded: true),

  /// `0x20` — **item / label string** (decoded). A single identifier or
  /// enum/ring item label, e.g. `Line 0`..`Line 7`, `stringLength`, `<None>`.
  /// Single-string payload (≈99% of records fully printable). Decoded by
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

  /// `0x4A` — **type / terminal bounds rectangle** (decoded). ~99% are an 8-byte
  /// 4× `s16` rectangle (100% valid when 8-byte), in the `DTHP` type heap — the
  /// bounds of a terminal / type element. Decoded by the generic [HeapRecord.rect].
  typeBounds(0x4a, HeapShape.rectangle, isDecoded: true),

  /// `0x44` — **composite container** (structural). ~74% of records hold nested
  /// `C4` children (bounds `2D` + origin/size `1F` + caption `22`, interleaved
  /// with non-`C4` style/color tuples) — a control/decoration cluster; the rest
  /// carry non-`C4` payloads (the container role is inferred, not universal).
  /// Children via [HeapRecord.children].
  container44(0x44, HeapShape.container),

  /// `0x64` — **composite container** (structural). Like [container44] but richer
  /// (~96% hold nested `C4`: bounds + captions + format strings + type tokens).
  /// Children via [HeapRecord.children].
  container64(0x64, HeapShape.container),

  /// `0x24` — **composite container** (structural). A bounds-rect-dominant cluster
  /// with captions; ~72% hold nested `C4` children (the rest carry non-`C4`
  /// payloads). Children via [HeapRecord.children].
  container24(0x24, HeapShape.container),

  /// `0x5F` — **document bounds rectangle** (decoded; matches OF__docBounds):
  /// 4× `s16`, 97% valid, negatives allowed; scope pane `0x11C` 78% + supC
  /// `0x4C` 21% (35,207 records) — a pane's document/content bounds.
  /// Readable via the generic [HeapRecord.rect].
  docBounds(0x5f, HeapShape.rectangle, isDecoded: true),

  /// `0x4C` — **display bounds rectangle** (decoded; matches OF__dBounds):
  /// 100% valid, often all-zero/negative; exactly one per heap section on the
  /// panel/diagram root. Readable via [HeapRecord.rect].
  dBounds(0x4c, HeapShape.rectangle, isDecoded: true),

  /// `0xD6` — **panel bounds rectangle** (decoded; matches OF__pBounds): 100%
  /// valid, frequently origin-anchored; exactly one per heap section on the
  /// panel/diagram root (paired with [dBounds]). Readable via [HeapRecord.rect].
  pBounds(0xd6, HeapShape.rectangle, isDecoded: true),

  /// `0x62` — **dynamic bounds rectangle** (decoded; matches OF__dynBounds):
  /// 100% valid; scope scale `0x8F` at 100.00% (FPHb) — a scale's dynamic
  /// bounds. Readable via [HeapRecord.rect].
  dynBounds(0x62, HeapShape.rectangle, isDecoded: true),

  /// `0x26` — **rectangle, role undetermined** (structural). ~74% are an 8-byte
  /// 4× `s16` rectangle (100% valid when 8-byte); the rest are larger
  /// variable-length payloads of unknown shape. Readable via [HeapRecord.rect].
  rect26(0x26, HeapShape.rectangle),

  /// `0x23` — **rectangle, role undetermined** (structural). 99.5% of payloads
  /// are 8 bytes and decode as 4× `s16` rectangles; scoped to select/case
  /// structures. Readable via [HeapRecord.rect].
  rect23(0x23, HeapShape.rectangle),

  /// A heap opcode that is not (yet) catalogued. Its [byte] is -1; use
  /// [HeapRecord.opcode] for the actual byte value.
  unknown(-1, HeapShape.none)
  ;

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
  static HeapOpcode fromByte(int opByte) => _byByte[opByte] ?? unknown;
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
/// the carrying opcode (see [HeapAttrWidth]); for the length-prefixed `Cx` forms
/// [HeapAttr.kind] refines the kind from that width at decode time (a
/// `C5 <id> 08` payload resolves to [controlParam], a `C6 <id> FF` blob to
/// [stringBlob], and so on).
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
  /// scale), carried as `C5 <id> 08 <f64>`. See [HeapAttribute.stdNumMin] etc.
  controlParam,

  /// Inline display text / style field.
  text,

  /// A length-prefixed string/blob (`C6 <id> FF <u16 len> <u32 strlen><ascii>`),
  /// e.g. a VISA resource name, serial, or firmware version.
  stringBlob,

  /// A 4× `s16` pixel rectangle carried in a length-prefixed `Cx <id> 08`
  /// payload — NOT every `Cx …08` is an `f64`; the `08` is a payload-length byte
  /// and a few tags (e.g. raw `0x129`) store a rectangle there. See
  /// [HeapAttribute.termBounds].
  rectangle,

  /// A packed pair of big-endian `s16` halves `(y|rows, x|cols)` carried in a
  /// 4-byte value (e.g. [HeapAttribute.origin], [HeapAttribute.minPaneSize]).
  /// Decoded by [HeapAttr.asPoint].
  point,

  /// An opaque length-prefixed `C5 <id> <len>` **container** (the raw-`0x1E7`
  /// [HeapAttribute.compressedWireTable] payload) — framed but its interior
  /// packing is not decoded (only ~38% re-walks as a record sub-stream; it is
  /// a packed table, not a record stream). [HeapAttr.value] is the leading
  /// byte. See [HeapAttrWidth.container].
  container,

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

  /// Zero value bytes — a bare boolean: the `Ex` form carries true (1), the
  /// `0x` form (sizeSpec 0) carries false (0).
  flag,

  /// `C5 <id> 08` — eight-byte big-endian IEEE-754 double.
  f64,

  /// `C6 <id> FF <u16 len>` — a length-prefixed string/blob.
  blob,

  /// `C5/C6 <id> 08` whose 8-byte payload is a 4× `s16` rectangle rather than an
  /// `f64` (the `08` is a length byte, not an f64 marker). See [HeapAttrKind.rectangle].
  rect,

  /// `C5 <id> <len>` whose payload is an opaque length-prefixed container (e.g.
  /// `0xE7`) — framed, not decoded. See [HeapAttrKind.container].
  container,
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

/// The catalog of known LabVIEW heap **attribute tags**, keyed by the 10-bit
/// **raw tag id** `((op & 3) << 8) | idByte` of a leaf attribute record
/// `<op> <id> <value>` (see the header model on [kHeapRecordPrefix]): the op's
/// high nibble sets the value width (`2x`→u8, `4x`→u16, `6x`→u24, `8x`→u32,
/// `Ex`→none/true, `0x04..0x06`→none/false, `Cx`→length-prefixed) and the op's
/// LOW TWO BITS are tag bits 8–9 — so `44 E7` (raw `0x0E7`) and `C5 E7`
/// (raw `0x1E7`) are DIFFERENT tags, and the same tag stores its value at the
/// smallest sufficient width (verified for raw `0x0CB` at 100%: width tracks
/// value magnitude). NOTE: `C5/C6 <id> 08` is NOT universally an `f64` — the
/// `08` is a payload-LENGTH byte; the payload is an `f64` only for the
/// numeric/scale parameter tags, a rectangle for the rect tags, or an opaque
/// container (see [decodeHeapAttr] / `_f64PayloadRaws` / `_rectPayloadRaws`).
/// `C6 <id> FF` is a length-prefixed blob.
///
/// Each entry documents its [kind], assigned name, [confidence], and the
/// corpus evidence (measured over the 7,524-VI corpus by
/// `tool/probe_tag_census.dart` unless noted).
/// A tag not catalogued maps to [HeapAttribute.unknown]; resolve a raw tag id
/// with [HeapAttribute.fromRaw] and decode a record with [decodeHeapAttr].
///
/// HONESTY: this is clean-room RE. `confirmed` names are pinned by a decisive
/// signal (RGB triples, the transparent sentinel, monotone orderings, ASCII,
/// a structural identity such as value == child count); `inferred` names give
/// the defensible direction from corpus scope + value shape, cross-checked
/// against the open-source pylabview tag catalog (tag id = raw − 31);
/// `kindOnly` names are pure value-kind labels. Class codes in the evidence
/// notes are the object-header `SL__class` values (0x0A = label, 0x09 = cosm,
/// 0x0B/0x0C = multi/bigMultiCosm, 0x12 = fPDCO, 0x13 = bDConstDCO,
/// 0x17 = signal, 0x1B = diag, 0x20 = forLoop, 0x2C = select, 0x2F = prim,
/// 0x30 = parm, 0x31 = iUse, 0x52 = indArr, 0x64 = typeDef, 0x8C = propNode,
/// 0xA9 = invokeNode, 0x110 = propItemInfo, 0x11C = pane).
enum HeapAttribute {
  /// Raw `0x01F` (tag 0) — **relative coordinate / offset** (`s16`, ≈99.96%
  /// high-bit-set as `u16` → a relative/negative position; scope: cosm/label
  /// part classes). The single highest-volume attribute. The tag is unnamed in
  /// the pylabview catalog (its field table starts at 1); the same tag also
  /// carries the `C4 1F` size rect ([HeapOpcode.size]) and the `14 1F`
  /// owner reference ([HeapRefKind.ownerRef]).
  relativeOffset(0x01f, HeapAttrKind.coordinate, 'relativeOffset', AttrConfidence.inferred),

  /// Raw `0x000` / `0x001` — **absolute coordinate X / Y** (`s16`, small with
  /// negatives; low-volume; TODO: re-probe scope on the raw-tag axis).
  coordX(0x000, HeapAttrKind.coordinate, 'coordX', AttrConfidence.inferred),
  coordY(0x001, HeapAttrKind.coordinate, 'coordY', AttrConfidence.inferred),

  /// Raw `0x019` (system tag −6, `arrayElement`) — an **array element value**:
  /// the inline integer forms of the same tag that opens the object headers
  /// (`10 19 02 fe <class> fd <uid>`) and carries the `14 19` element
  /// references. Grammar-confirmed by the header model; the int widths hold
  /// small element values (23% zero), the `C4 19` lp form holds byte payloads
  /// (see [HeapOpcode.description]).
  arrayElemValue(0x019, HeapAttrKind.numeric, 'arrayElementValue', AttrConfidence.confirmed),

  /// Raw `0x0DF` — **part id** (`u8`/`u16`; matches OF__partID = 192): which
  /// *part* of a composite object the enclosing object is.
  /// Full-corpus evidence (`tool/probe_part_role.dart`, [walkHeapObjects], 7524
  /// VIs): 1,573,913 records, every one inside an object scope (0 outside), and
  /// the value→dominant-enclosing-kind mapping holds at **97.14%** purity across
  /// 88 distinct values. Values **<8000** name common control parts —
  /// 16→label `0x0A` (335,878/335,898), 66→annex `0x68`
  /// (280,711/280,747 = 99.99%), 15→control sub-part `0x0B` (100,504/100,507),
  /// 9→cosm `0x09` (97.5%), 28→cosm `0x09` (98.7%), 10→numeric display
  /// `0xE0` (74,148/74,167), 22/12→enum item list `0x0D` (100%). Values
  /// **≥8000** are control-scoped: 8002→numeric control `0x50`
  /// (12,801/12,817 = 99.9%), 8019→boolean/cluster `0x4F` (2,444/2,444); the
  /// exception is 8010, which spans 13 control-terminal/container kinds
  /// (`0x53`/`0x57`/`0x50`/`0x55`/…) — a cross-kind role, not a kind alias.
  /// NOTE: this is a distinct value space — it is NOT the same as the `u16`
  /// `SL__class` header code; the two do not index into each other.
  partRole(0x0df, HeapAttrKind.enumValue, 'partRole', AttrConfidence.inferred),

  /// Raw `0x0AF` — **master part id** (`u8`/`u16`; matches OF__masterPart):
  /// the [partRole] value of the part this part is slaved to. Corpus evidence
  /// (corpus-wide, 918,340 records): values live in the
  /// partRole value space (9/28/21/8010/30…), scope is the part classes
  /// (label/cosm/multiCosm 85%+), and for **97.29%** an object in the same
  /// parent scope carries a [partRole] equal to the value (own-object equality
  /// is 0.02%, so it points at a *sibling* part, not itself). The earlier
  /// "objectSubKind" enclosing-kind axes were refuted (purity <48%) — the
  /// sibling-part axis is the one that holds.
  masterPart(0x0af, HeapAttrKind.enumValue, 'masterPart', AttrConfidence.inferred),

  /// Raw `0x13A` — **type-descriptor index** (`u16` via `45 3A`; matches
  /// OF__typeDesc): the object's index into the VI's type table, strictly
  /// sequential 1..n per heap (771k records, BDHb).
  typeDescIndex(0x13a, HeapAttrKind.ordinal, 'typeDescIndex', AttrConfidence.inferred),

  /// Raw `0x03A` — **clump number** (`u24`/`u32`; matches OF__clumpNum): an
  /// execution-clump word on BD node classes (sRN/prim/iUse/nMux…, 49 classes,
  /// BDHb only). Values are `(n << 16) | 3` with sequential `n` — the packed
  /// low half (constant 3) is not yet explained, so inferred, not confirmed.
  clumpNum(0x03a, HeapAttrKind.ordinal, 'clumpNum', AttrConfidence.inferred),

  /// Raw `0x089` — **grow behaviour flags** (`u8`/`u16`; matches OF__howGrow):
  /// on the part classes (cosm/label 60%+); values are sparse flag words
  /// (240, 4096, 4104, 12288…), not sizes.
  howGrow(0x089, HeapAttrKind.numeric, 'howGrow', AttrConfidence.inferred),

  /// Raw `0x0F8` — **size / extent** (`u16` via the nibble form; values
  /// cluster on pixel-ish extents). The `C5 F8 08 <f64>` form is a distinct tag
  /// (raw `0x1F8` = [scaleDIncr]), not a wider reading of this one.
  sizeExtent(0x0f8, HeapAttrKind.size, 'sizeExtent', AttrConfidence.inferred),

  /// Raw `0x129` — **terminal bounds rectangle** carried as
  /// `C5 29 08 <4× s16>` (NOT an f64 — see [decodeHeapAttr]; matches
  /// OF__termBounds). Corpus-confirmed *shape*: 100% valid rectangles
  /// (219,845/219,892), dims clustering on small glyph/terminal cells (8×8,
  /// 8×16, 9×9); the f64 reading is decisively garbage (0% sane doubles).
  /// Exactly 0/1 per object. ~1.0M records, the highest-volume `Cx` tag.
  /// The rect is **relative to the carrier's enclosing frame** (its nearest
  /// bounded positional ancestor; LabVIEW < 8.6 stores that era's absolute
  /// space instead), and on a carrier whose `14 19` childRefs name a
  /// signal-endpoint DCO it is the wire's attach point — a structure tunnel /
  /// shift register / selector terminal square; the anchoring census lives on
  /// `ViDiagram.endpointTerminalBounds` (graph.dart).
  termBounds(0x129, HeapAttrKind.rectangle, 'termBounds', AttrConfidence.inferred),

  /// Raw `0x029` — the `84 29` u32 form (a different tag than [termBounds]):
  /// an opaque colour-shaped value; meaning not pinned on any corpus axis.
  color29(0x029, HeapAttrKind.numeric, 'value29', AttrConfidence.kindOnly),

  /// Raw `0x0DC` — **parameter index** (`u8`, strictly sequential 1..n;
  /// matches OF__paramIdx): scope iUseDCO `0x33` at 96.0% (sub-VI call
  /// parameter DCOs, 450k records, BDHb only). Confirmed by the strict
  /// sequence + scope.
  paramIdx(0x0dc, HeapAttrKind.ordinal, 'paramIdx', AttrConfidence.confirmed),

  /// Raw `0x231` — **property-item name** string, carried inline as
  /// `C6 31 <len> <raw ASCII>` (the whole payload is the text — see
  /// [_inlineStringRaws]; matches OF__PropItemName). Corpus-confirmed 100%
  /// printable: property-node item names ("Scale", "FP.State", "Data
  /// Access:VISA resource name") and structural/aggregate-member names
  /// ("AllObjs[]", "Panes[]", "Diagram", "OwningVI").
  propItemName(0x231, HeapAttrKind.stringBlob, 'propItemName', AttrConfidence.confirmed),

  /// Raw `0x26C` — **BD constant value** (matches OF__ConstValue). This entry
  /// owns the record census (pinned by the `bd_const_values` corpus-snapshot
  /// section): the corpus' decoded top-level FP/BD heaps hold **54,801**
  /// records, every one innermost-scoped to a `0x13` bDConstDCO (BDHb only),
  /// exactly one per constant. The value is the constant's flattened data:
  /// small ints ride the `u8..u32` widths (1/0/2/−1…), strings ride the
  /// `C6 6C <u8len> <u32 strlen><ascii>` form ("%f", "ps2000aRunStreaming";
  /// validity-gated per record — see [_u32StringRaws]) and the `C6 6C FF` blob
  /// (gated at ≥90% printable); non-validating payloads are type-dependent
  /// flattened data and stay framed-inside-the-record rather than fabricated.
  constValue(0x26c, HeapAttrKind.stringBlob, 'constValue', AttrConfidence.inferred),

  /// Raw `0x163` / `0x164` — a **paired rectangle block** carried as
  /// `C5 63|64 08 <4× s16>` (NOT f64; match OF__totalBounds / OF__srcRect).
  /// Corpus-confirmed shape: 100% valid rectangles, 0% sane f64; the two
  /// appear together with identical rects (75×75, 768×432) plus a colour.
  totalBounds(0x163, HeapAttrKind.rectangle, 'totalBounds', AttrConfidence.inferred),
  srcRect(0x164, HeapAttrKind.rectangle, 'srcRect', AttrConfidence.inferred),

  /// Raw `0x1E7` — **compressed wire table** (matches
  /// OF__compressedWireTable): scope signal `0x17` at **100.00%** (426,397
  /// records, BDHb only), in the per-signal chain `25 15 → C5 E7 → 44 9F`
  /// ([signalState] → this → [lastSignalKind]). The `C5 E7 <len>` form is the
  /// packed table payload (framed container — packed data, not a record
  /// stream); tables of 1/2/4 bytes ride the scalar `25 E7`/`45 E7`/`85 E7`
  /// widths (a 2-byte straight-wire table is a u16 scalar). The packed
  /// layout IS decoded — the two-endpoint stored route polyline
  /// (`decodeWireRoute`/`ViWireRoute`) and the extended multi-endpoint
  /// branching tree (`decodeWireBranchRoute`/`ViWireBranchRoute`), both in
  /// graph.dart, which own the grammar and the corpus census.
  compressedWireTable(0x1e7, HeapAttrKind.numeric, 'compressedWireTable', AttrConfidence.inferred),

  /// Raw `0x09F` — **last signal kind**: the signal's **wire-type word**
  /// (`u16`; matches OF__lastSignalKind): scope signal `0x17` at **99.99%**
  /// (428,089 records, BDHb only), closing the signal chain. Decoded —
  /// `[flags][structural depth][element type code]` in the VCTP TypeCode
  /// space (e.g. 33616 = `0x8350` a cluster wire, 560 = `0x230` a string
  /// wire, 16944 = `0x4230` string with flag bit 14); layout, census and
  /// oracle validation live on `ViSignalType` (graph.dart).
  lastSignalKind(0x09f, HeapAttrKind.numeric, 'lastSignalKind', AttrConfidence.inferred),

  /// Raw `0x115` — **signal state** (`u8` bit-flag values 1/33/17/49; matches
  /// OF__state): scope signal `0x17` at **99.99%** (428,093 records), opening
  /// the signal chain.
  signalState(0x115, HeapAttrKind.numeric, 'signalState', AttrConfidence.inferred),

  /// Raw `0x061` — **data-space word** (`u16`, power-of-two values
  /// 4096/512/2048/1024; matches OF__dsw): scope bDConstDCO `0x13` 55% +
  /// parm `0x30` 18%. The bit meanings are not decoded.
  dsw(0x061, HeapAttrKind.numeric, 'dsw', AttrConfidence.inferred),

  /// Raw `0x106` — **short count** (`u8`, small even-dominant ints 1/2/4/6/8;
  /// matches OF__shortCount): scope the BD node classes (sRN/prim/iUse/…,
  /// 59 classes, BDHb only; 223,646 records).
  shortCount(0x106, HeapAttrKind.numeric, 'shortCount', AttrConfidence.inferred),

  /// Raw `0x286` — **mouse-wheel support** (`u8` enum {0, 2, 3}; matches
  /// OF__MouseWheelSupport): scope the FP control DCO classes
  /// (stdString/stdNum/stdBool/stdClust…, 211,232 records).
  mouseWheelSupport(0x286, HeapAttrKind.enumValue, 'mouseWheelSupport', AttrConfidence.inferred),

  /// Raw `0x072` — **first node index** (`u8`/`u16` small ints; matches
  /// OF__firstNodeIdx): scope diag `0x1B` at **99.03%** (51,444 records,
  /// BDHb only).
  firstNodeIdx(0x072, HeapAttrKind.ordinal, 'firstNodeIdx', AttrConfidence.inferred),

  /// Raw `0x17B` — **annex DDO flag** (`u8`, value 2 at 99.89%; matches
  /// OF__annexDDOFlag): scope annex `0x68` at **100.00%** (38,560 records).
  annexDDOFlag(0x17b, HeapAttrKind.numeric, 'annexDDOFlag', AttrConfidence.inferred),

  /// Raw `0x08A` — **element index "i"** (`u8`, sequential 1,2,3…; matches
  /// OF__i): scope nmxDCO `0x62` at **100.00%** (25,814 records, BDHb).
  elementI(0x08a, HeapAttrKind.ordinal, 'i', AttrConfidence.inferred),

  /// Raw `0x048` — **connector terminal map** (`u8`/`u16`; matches
  /// OF__connectorTM): scope iUse `0x31` 87% + dynIUse `0x104` (sub-VI call
  /// nodes; 37,620 records, BDHb only).
  connectorTM(0x048, HeapAttrKind.numeric, 'connectorTM', AttrConfidence.inferred),

  /// Raw `0x023` — a `u8`-dominant field on select structures `0x2C` (65%)
  /// with small-int values plus a `0x40000002` flag form; no corpus axis pins
  /// a meaning, so kindOnly. Distinct from the `C4 23` rect opcode.
  field23(0x023, HeapAttrKind.numeric, 'field23', AttrConfidence.kindOnly),

  /// Raw `0x0EA` — **primitive resource id** (`u16` values clustering
  /// 1000..2100; matches OF__primResID): scope prim `0x2F` at **99.95%**
  /// (46,479 records, BDHb only).
  primResID(0x0ea, HeapAttrKind.numeric, 'primResID', AttrConfidence.inferred),

  /// Raw `0x0E9` — **primitive index** (`u8`/`u16`; matches OF__primIndex):
  /// scope parm `0x30` 75% + prim `0x2F` 22% (205,679 records, BDHb only).
  primIndex(0x0e9, HeapAttrKind.numeric, 'primIndex', AttrConfidence.inferred),

  /// Raw `0x0DE` — **parameter index** (`u8` small ints; matches
  /// OF__parmIndex): scope parm `0x30` at **100.00%** (114,327 records,
  /// BDHb only).
  parmIndex(0x0de, HeapAttrKind.ordinal, 'parmIndex', AttrConfidence.inferred),

  /// Raw `0x0CB` — **object flags** (`u8`/`u16`/`u24`/`u32`, stored at the
  /// smallest sufficient width — width tracks value magnitude at 100%; matches
  /// OF__objFlags): a per-object packed flags word. Corpus evidence
  /// (`tool/probe_gap_census.dart`, 3,745,810 records): it is the FIRST record
  /// of its object scope at **99.99%** (position-0 invariant; the record
  /// before it is the object header), values decompose as sparse-bit words,
  /// and every alternative identity is refuted (== bounds width/height ≤
  /// 0.07%, == oid 0.01%, == caption length 0.01%, sibling monotonicity 9.9%).
  /// The per-bit meanings are not decoded.
  objFlags(0x0cb, HeapAttrKind.numeric, 'objFlags', AttrConfidence.inferred),

  /// Raw `0x05E` — **large numeric / packed pair** (`u32`, ~0.85M..3.9M).
  /// Low-volume; not re-probed on the raw-tag axis (TODO).
  packedPair(0x05e, HeapAttrKind.numeric, 'packedPairOrId', AttrConfidence.inferred),

  /// Raw `0x0DA` — **pane flags** (`u24` bitfield, dominant `0x040101`;
  /// matches OF__paneFlags): scope pane `0x11C` 78% + supC `0x4C` 21%
  /// (35,207 records). Bit meanings not decoded.
  paneFlags(0x0da, HeapAttrKind.numeric, 'paneFlags', AttrConfidence.inferred),

  /// Raw `0x028` — **background / fill colour** (u32 RGB with the flag byte;
  /// ~27% transparent, ~24% white; matches OF__bgColor = 9): on the part
  /// classes (label/cosm/multiCosm…). The `u8` narrow form (162k records,
  /// value 1/2 dominant) does not carry colour-shaped values and is kept
  /// value-kind-only by [heapDecodeTier].
  backgroundColor(0x028, HeapAttrKind.color, 'backgroundColor', AttrConfidence.confirmed),

  /// Raw `0x024` — **content / area colour** (u32 RGB; ~58% transparent,
  /// ~28% white; scope label 77% / numLabel 13%).
  contentColor(0x024, HeapAttrKind.color, 'contentColor', AttrConfidence.confirmed),

  /// Raw `0x06F` — **foreground colour** (u32 RGB; greys + ~36% transparent;
  /// matches OF__fgColor = 80): on the part classes (label/cosm 68%+).
  fgColor(0x06f, HeapAttrKind.color, 'fgColor', AttrConfidence.confirmed),

  /// Raw `0x020` — a **class-polymorphic** tag (pylabview tag 1): in the cosm
  /// part classes at u32 width it is a **foreground/frame colour** (class
  /// bigMultiCosm `0x0C` at 99.38% of u32 records; greys/black); in the label
  /// classes at u16/u24 it carries text-style FLAG words (0x200/0x600/0x8000 —
  /// not colours); on select structures at u8 it is a small index (0..3,
  /// consistent with OF__activeDiag). [heapDecodeTier] counts only the
  /// cosm-scoped u32 form as a decoded colour; the narrow/label forms stay
  /// value-kind-only.
  cosmFgColor(0x020, HeapAttrKind.color, 'cosmFgColor', AttrConfidence.inferred),

  /// Raw `0x021` — **class-polymorphic** like [cosmFgColor] (pylabview tag 2):
  /// a **second cosm colour** at u32 in the cosm classes (60.7% of u32
  /// records; greys/white), but label-class u32/u24/u16 records carry
  /// text-mode words (0x814404/0x14404/0x4404 patterns — not colours).
  /// [heapDecodeTier] counts only the cosm-scoped u32 form as a colour.
  ///
  /// Label-word census (423,717 label-class `0x0a` records, full corpus):
  /// one 32-bit word whose leading zero bytes drop with the stored width
  /// (u16 `0x4404` / u24 `0x01_4404` / u32 `0x81_4404` share the constant
  /// low core `0x4404`; case-selector `0x95` labels carry `0x4501`,
  /// 17,085/17,094). Bits `0x080000` (6,325), `0x040000` (43) and `0x01`
  /// (543) appear ONLY on caption-less parent-owned labels — never with a
  /// caption string. Every low-nibble variant (`0x10`/`0x20` set) occurs
  /// on labels the 46 snippet references render in the one default
  /// face/size/weight, so none of the varying bits maps to a visible
  /// size or style there, and the word does not track the FTAB font
  /// tables (identical word sets appear beside 13/15/17 px tables).
  /// Field meanings not decoded. // TODO(labwright)
  cosmColorB(0x021, HeapAttrKind.color, 'cosmColorB', AttrConfidence.inferred),

  /// Raw `0x02A` — **plot / graph colour** (u32 RGB; scope stdGraph `0x5E`
  /// 100% of the re-probed u32 records, FPHb; the LabVIEW plot palette
  /// #FF4242/#0EFF00/… appears). Role inferred, not pinned.
  plotColor(0x02a, HeapAttrKind.color, 'plotColor', AttrConfidence.inferred),

  /// Raw `0x02B` — **border colour** (u32; 73% zero = black, hued minority;
  /// matches OF__borderColor = 12): scope stdGraph/treeControl, FPHb.
  borderColor(0x02b, HeapAttrKind.color, 'borderColor', AttrConfidence.inferred),

  /// Raw `0x0D0` — **origin** (u32 as a packed `(s16 y, s16 x)` point, NOT a
  /// colour; matches OF__origin = 177): scope pane `0x11C` 60% / panel root;
  /// 99.82% decode as plausible small points, mostly small negatives like
  /// (−4,−4) — a scroll origin. The packed-point decomposition (not a colour)
  /// is what the value shape supports.
  origin(0x0d0, HeapAttrKind.point, 'origin', AttrConfidence.inferred),

  /// Raw `0x0B7` — **minimum pane size** (u32 as packed `(s16, s16)`; matches
  /// OF__minPaneSize = 152): scope pane `0x11C` 78% + supC `0x4C` 21%;
  /// dominant value `0x00010001` = (1,1), then (35,35); 82.8% positive size
  /// pairs — a packed size point, not a colour.
  minPaneSize(0x0b7, HeapAttrKind.point, 'minPaneSize', AttrConfidence.inferred),

  /// Raw `0x022` — **short label text** (pylabview textHair tag 3 = text): the
  /// scalar-width sibling of the `C4 22` caption opcode ([HeapOpcode.caption],
  /// same tag, length-prefixed), carrying a 1-4 character caption with the text
  /// BYTES magnitude-encoded big-endian ("y", "x", "Idx", "XOR?"; 0 = empty).
  /// [HeapAttr.asciiText] exposes the reading; the caption consumer accepts it
  /// only when it is a well-formed token — every stored byte a printable ASCII
  /// glyph (`0x20..0x7e`, so control codes and high-bit Latin-1 stay numeric)
  /// AND the text filling the whole stored width (a null leading byte means a
  /// number, not an N-char caption, which occupies the N-byte width). Corpus
  /// scope of the captured tokens: label class `0x0A` 96.9% (98% across the
  /// text-label classes `0x0A`/`0x95`), the rest the enum/selector carriers.
  /// Distinct from raw `0x222` ([stdNumInc]).
  shortText(0x022, HeapAttrKind.text, 'shortText', AttrConfidence.inferred),

  /// Raw `0x074` — **printf-format style** (RGB-width with style byte `0x25`,
  /// or a `u16`). Distinct from the `C4 74` format-string opcode (same tag,
  /// lp width — the format text itself).
  formatStyle(0x074, HeapAttrKind.text, 'formatStyle', AttrConfidence.inferred),

  /// Raw `0x158` — **terminal-list length** (`u8`; matches
  /// OF__termListLength): scope fPDCO `0x12` at 99.98%, and the value equals
  /// the enclosing object's direct child-object count at **97.56%**
  /// (40,644/41,660) — a structural identity.
  termListLength(0x158, HeapAttrKind.ordinal, 'termListLength', AttrConfidence.confirmed),

  /// Raw `0x044` — **connector-pane terminal number** (`u8`; matches
  /// OF__conNum): scope fPDCO `0x12` at **99.98%**; values are small terminal
  /// ordinals (82% < 40) with the `255` = unwired sentinel (17.8%). Distinct
  /// from the `C4 44` container opcode.
  conNum(0x044, HeapAttrKind.ordinal, 'conNum', AttrConfidence.inferred),

  /// Raw `0x059` — **reserved / near-always-zero flag** (`u8`; ~99.9% zero).
  reservedFlag(0x059, HeapAttrKind.flag, 'reservedFlag', AttrConfidence.inferred),

  /// Raw `0x05A` — a **u8 flag** (the narrow sibling of what was once thought
  /// one dual-use id; the identity-string blob is the separate raw `0x25A` =
  /// [defaultData]).
  flag5A(0x05a, HeapAttrKind.flag, 'flag5A', AttrConfidence.inferred),

  /// Raw `0x25A` — **control default data** (matches OF__DefaultData): scope
  /// fPDCO `0x12` 71% + xTunnel/indArr; the value is the control's flattened
  /// default value — small ints ride the integer widths (1/0/−1/15000…),
  /// strings (VISA resource names, serials) ride the validity-gated `C6 5A FF`
  /// blob; non-validating payloads are type-dependent flattened data and are
  /// not fabricated into strings.
  defaultData(0x25a, HeapAttrKind.numeric, 'defaultData', AttrConfidence.inferred),

  /// Raw `0x1F5`..`0x1FA` — the **scale data parameter family**
  /// (`C5 F5..FA 08` + f64; match OF__scaleDMin/scaleDMax/scaleDStart/
  /// scaleDIncr/scaleDMinInc/scaleDMultiplier): the corpus orderings that pinned the old
  /// controlMin/Max/FineIncrement/Unit names carry over — `F5 ≤ F7` ≈90%
  /// (min ≤ start), `F9 ≤ F8` 257/257 (minInc ≤ incr, confirmed), `FA` = 1.0
  /// constant 257/257 (multiplier, confirmed).
  scaleDMin(0x1f5, HeapAttrKind.controlParam, 'scaleDMin', AttrConfidence.inferred),
  scaleDMax(0x1f6, HeapAttrKind.controlParam, 'scaleDMax', AttrConfidence.inferred),
  scaleDStart(0x1f7, HeapAttrKind.controlParam, 'scaleDStart', AttrConfidence.inferred),
  scaleDIncr(0x1f8, HeapAttrKind.controlParam, 'scaleDIncr', AttrConfidence.inferred),
  scaleDMinInc(0x1f9, HeapAttrKind.controlParam, 'scaleDMinInc', AttrConfidence.confirmed),
  scaleDMultiplier(0x1fa, HeapAttrKind.controlParam, 'scaleDMultiplier', AttrConfidence.confirmed),

  /// Raw `0x220` / `0x221` / `0x222` — **numeric-control minimum / maximum /
  /// increment** (match OF__StdNumMin/StdNumMax/StdNumInc; the
  /// `C6 20|21|22 08` + f64 forms, with small values riding the integer widths). The old
  /// corpus evidence carries over: min 100% sane with the `−inf` = "no min"
  /// sentinel, max 98.8% sane with `+inf`, inc 99.2% sane with dominant 0.0
  /// (= no increment). The catalog name pins 0x222 as the increment, not a
  /// default value.
  stdNumMin(0x220, HeapAttrKind.controlParam, 'stdNumMin', AttrConfidence.inferred),
  stdNumMax(0x221, HeapAttrKind.controlParam, 'stdNumMax', AttrConfidence.inferred),
  stdNumInc(0x222, HeapAttrKind.controlParam, 'stdNumInc', AttrConfidence.inferred),

  /// Raw `0x120` — **table flags** (`u16` bitfield 0x2610/0x2E10…; matches
  /// OF__tableFlags): scope treeControl/listbox/tableControl at 100.00%
  /// (416 records, FPHb). Bit meanings not decoded.
  tableFlags(0x120, HeapAttrKind.numeric, 'tableFlags', AttrConfidence.inferred),

  /// Raw `0x114` — **timestamp** (`u32` seconds in the LabVIEW 1904 epoch;
  /// matches OF__stamp): scope typeDef `0x64` at **100.00%**, and 4,005/4,005
  /// values fall in the 1995..2030 window — a type-definition edit stamp.
  stamp(0x114, HeapAttrKind.numeric, 'stamp', AttrConfidence.confirmed),

  /// Raw `0x0C4` — **node name** (matches OF__nodeName): scope propNode
  /// `0x8C` 67% + invokeNode `0xA9` 24%; the integer widths carry short
  /// VI-server class names as magnitude-encoded ASCII ("VI", "App" — 100%
  /// printable, 5,920/5,920), longer names ride the lp form (see also
  /// [HeapOpcode.symbolName], the same tag's `C4 C4` form).
  nodeName(0x0c4, HeapAttrKind.text, 'nodeName', AttrConfidence.inferred),

  /// Raw `0x0C9` — **object-manager id** (`u16`; matches OF__oMId): scope
  /// propNode/invokeNode 92% (10,945 records, BDHb).
  oMId(0x0c9, HeapAttrKind.numeric, 'oMId', AttrConfidence.inferred),

  /// Raw `0x0CE` — **OMId type descriptor** (`u8`/`u16`; matches
  /// OF__omidTypeDesc): scope propItemInfo `0x110` at **100.00%**; values sit
  /// one below the co-occurring [dataTypeDesc] values (85 vs 86, 63 vs 64).
  omidTypeDesc(0x0ce, HeapAttrKind.ordinal, 'omidTypeDesc', AttrConfidence.inferred),

  /// Raw `0x15B` — **data type descriptor** (`u8`/`u16` type-table index;
  /// matches OF__dataTypeDesc): scope propItemInfo `0x110` at **100.00%**.
  dataTypeDesc(0x15b, HeapAttrKind.ordinal, 'dataTypeDesc', AttrConfidence.inferred),

  /// Raw `0x232` — **property item code** (`u16`/`u32` codes like 104013824;
  /// matches OF__PropItemCode): scope propItemInfo `0x110` at **100.00%**.
  propItemCode(0x232, HeapAttrKind.numeric, 'propItemCode', AttrConfidence.inferred),

  /// Raw `0x043` — **connection id** (`u16` values 4800..4834; matches
  /// OF__conId): scope conPane `0x7F` at **100.00%** (7,504 records, FPHb) —
  /// the connector-pane pattern resource id.
  conId(0x043, HeapAttrKind.numeric, 'conId', AttrConfidence.inferred),

  /// Raw `0x04D` — **displayed frame index** of a stacked multi-frame
  /// structure (`u8`..`u32` with bit 31 as a flag; matches OF__dIdx): scope
  /// select `0x2C` at 89.7% (case structures, BDHb), the remainder on the
  /// other stacked kinds. Captured onto `ViHeapObject.dIdx` and read via
  /// `visibleFrameIndex` (absent = frame 0).
  dIdx(0x04d, HeapAttrKind.ordinal, 'dIdx', AttrConfidence.inferred),

  /// Raw `0x051` — a `u16`/`u8` word on structure classes (lpTun/selTun/lCnt…;
  /// values 512/4096/515; matches OF__dcoFiller, which does not pin a
  /// meaning). kindOnly.
  dcoFiller(0x051, HeapAttrKind.numeric, 'dcoFiller', AttrConfidence.kindOnly),

  /// Raw `0x090` — **index** (`u8` sequential 1,2,3…; matches OF__index):
  /// scope multiLabel/multiCosm/bigMultiCosm 98% (19,709 records).
  index90(0x090, HeapAttrKind.ordinal, 'index', AttrConfidence.inferred),

  /// Raw `0x097` — **inplace-ness** (`u8` small ints; matches OF__inplace):
  /// scope parm `0x30` 79% + overridableParm `0x14B` 21% at 100.00% combined.
  inplace(0x097, HeapAttrKind.numeric, 'inplace', AttrConfidence.inferred),

  /// Raw `0x09A` — **instrument style** (`u8`, value 31 at 99.94%; matches
  /// OF__instrStyle): scope the panel root (2 records/VI: FPHb + BDHb roots).
  instrStyle(0x09a, HeapAttrKind.numeric, 'instrStyle', AttrConfidence.inferred),

  /// Raw `0x0C0` — **visible item count** (`u8`, value 10 at 99.7%; matches
  /// OF__nVisItems): scope selLabel `0x95` at **100.00%** (BDHb).
  nVisItems(0x0c0, HeapAttrKind.numeric, 'nVisItems', AttrConfidence.inferred),

  /// Raw `0x0BF` / `0x0CA` — **row/column counts and origin** (u32 as packed
  /// `(s16, s16)` pairs; match OF__nRC / OF__oRC): scope indArr `0x52` at
  /// 99.9% — an index-array DCO's dimensions (nRC values like (1,0)/(2,0))
  /// and origin (negatives allowed).
  nRC(0x0bf, HeapAttrKind.point, 'nRC', AttrConfidence.inferred),
  oRC(0x0ca, HeapAttrKind.point, 'oRC', AttrConfidence.inferred),

  /// Raw `0x128` — **terminal bitmap selector** (`u8`; matches OF__termBMPs):
  /// scope the loop/case terminal classes with a value↔class pairing
  /// (caseSel `0x2E`→5, lCnt `0x24`→1, lSR `0x27`→3, rSR `0x28`→4,
  /// lMax `0x26`→2, lTst `0x25`→192) — which glyph the terminal shows.
  termBMPs(0x128, HeapAttrKind.enumValue, 'termBMPs', AttrConfidence.inferred),

  /// Raw `0x127` — a `u8` offset-like field across many classes (values 255 /
  /// small ints; matches OF__tdOffset but no corpus axis pins it). kindOnly.
  tdOffset(0x127, HeapAttrKind.numeric, 'tdOffset', AttrConfidence.kindOnly),

  /// Raw `0x12D` — **text record field** (`u8`/`u16` small ints; matches
  /// OF__textRec): scope label classes 96%+ (label/numLabel/multiLabel). The
  /// same tag's open form (`10 2D …`) is the text-record group inside labels.
  textRecField(0x12d, HeapAttrKind.numeric, 'textRecField', AttrConfidence.inferred),

  /// Raw `0x1C0`..`0x1C3` — the **fixed-point parameter quadruple** on
  /// overridable parms (`0x14B`, verified 100% for 0x1C0; the four co-occur
  /// with equal populations): word length (constant 64), override, overflow,
  /// quantize (match OF__maxWordLength/override/overflow/quantize).
  maxWordLength(0x1c0, HeapAttrKind.numeric, 'maxWordLength', AttrConfidence.inferred),
  fxpOverride(0x1c1, HeapAttrKind.numeric, 'override', AttrConfidence.inferred),
  fxpOverflow(0x1c2, HeapAttrKind.numeric, 'overflow', AttrConfidence.inferred),
  fxpQuantize(0x1c3, HeapAttrKind.numeric, 'quantize', AttrConfidence.inferred),

  /// Raw `0x0DD` — **parameter table offset** (`u16`/`u24`; matches
  /// OF__paramTableOffset): scope iUse `0x31` 78% + dynIUse (sub-VI calls).
  paramTableOffset(0x0dd, HeapAttrKind.numeric, 'paramTableOffset', AttrConfidence.inferred),

  /// Raw `0x254` / `0x255` / `0x266` — **case-selector fields** on select
  /// structures `0x2C` (97..98.7%): the default-case index (255 = none;
  /// matches OF__SelectDefaultCase), the selector right-type enum (matches
  /// OF__SelectNRightType), and the selector-label flags word (matches
  /// OF__SelectSelLabFlags).
  selectDefaultCase(0x254, HeapAttrKind.enumValue, 'selectDefaultCase', AttrConfidence.inferred),
  selectNRightType(0x255, HeapAttrKind.enumValue, 'selectNRightType', AttrConfidence.inferred),
  selectSelLabFlags(0x266, HeapAttrKind.numeric, 'selectSelLabFlags', AttrConfidence.inferred),

  /// Raw `0x25C` / `0x271` / `0x277` — **for-loop fields** on forLoop `0x20`
  /// (98.7%): parallel-for index distribution, debugging-enabled, and
  /// output-instance-number-from-P (all observed only at their zero/false
  /// encodings; match OF__ParForIndexDistribution / OF__DebuggingEnabled /
  /// OF__OutputInstanceNumberFromP).
  parForIndexDistribution(0x25c, HeapAttrKind.numeric, 'parForIndexDistribution', AttrConfidence.inferred),
  debuggingEnabled(0x271, HeapAttrKind.flag, 'debuggingEnabled', AttrConfidence.inferred),
  outputInstanceNumberFromP(0x277, HeapAttrKind.flag, 'outputInstanceNumberFromP', AttrConfidence.inferred),

  /// Raw `0x27F` — **default tunnel type** (`u8` enum {1, 2}; matches
  /// OF__DefaultTunnelType): scope lpTun `0x22` at **100.00%**.
  defaultTunnelType(0x27f, HeapAttrKind.enumValue, 'defaultTunnelType', AttrConfidence.inferred),

  /// Raw `0x280` / `0x291` — **FPGA fields on index-array DCOs** (`0x52` at
  /// 99.95%): implementation bool and enable-bounds-mux bool (match
  /// OF__FpgaImplementation / OF__FpgaEnableBoundsMux).
  fpgaImplementation(0x280, HeapAttrKind.flag, 'fpgaImplementation', AttrConfidence.inferred),
  fpgaEnableBoundsMux(0x291, HeapAttrKind.flag, 'fpgaEnableBoundsMux', AttrConfidence.inferred),

  /// Raw `0x28F` — **default value matches control VI** (boolean; matches
  /// OF__kSLHDefaultValueMatchesCtlVI): scope typeDef `0x64` at 99.97%.
  defaultValueMatchesCtlVI(0x28f, HeapAttrKind.flag, 'defaultValueMatchesCtlVI', AttrConfidence.inferred),

  /// Raw `0x1B3` — **cell position column** (`u8` with 254/255 sentinels;
  /// matches OF__cellPosCol): scope treeControl/listbox 97% (FPHb).
  cellPosCol(0x1b3, HeapAttrKind.ordinal, 'cellPosCol', AttrConfidence.inferred),

  /// Raw `0x275` — **saved size rectangle** (`C6 75 <8>`; matches
  /// OF__savedSize): 35,079/35,079 payloads are 8 bytes and decode as valid
  /// rectangles (100.00%); scope stdClust `0x53` 78% + panel root 21%.
  savedSize(0x275, HeapAttrKind.rectangle, 'savedSize', AttrConfidence.inferred),

  /// Raw `0x159` / `0x15A` — **reference-list length / grow-node-list length**
  /// (`u8`, 99.7%+ zero; match OF__refListLength / OF__hGrowNodeListLength,
  /// the tags adjacent to [termListLength]): scope annex `0x68` at **99.98%**
  /// (218k records each), and the 0x159 value equals the object's `14 19` ref
  /// count at **99.88%** (0x15A at 99.71%) — a structural identity, degenerate
  /// only in that both are usually zero.
  refListLength(0x159, HeapAttrKind.ordinal, 'refListLength', AttrConfidence.inferred),
  hGrowNodeListLength(0x15a, HeapAttrKind.ordinal, 'hGrowNodeListLength', AttrConfidence.inferred),

  /// Raw `0x25E` — **minimum button size** (u32 packed `(s16, s16)`; matches
  /// OF__MinButSize): scope stdBool `0x4F` at **100.00%** (34,889 records);
  /// dominant value (20, 20).
  minButSize(0x25e, HeapAttrKind.point, 'minButSize', AttrConfidence.inferred),

  /// Raw `0x12A` — **terminal hot point** (u32 packed `(s16, s16)`, negatives
  /// allowed, 100.00% plausible points; matches OF__termHotPoint, adjacent to
  /// [termBounds]): on the loop/shift-register terminal classes.
  termHotPoint(0x12a, HeapAttrKind.point, 'termHotPoint', AttrConfidence.inferred),

  /// Raw `0x27E` — **tunnel type** (`u8` enum {1, 2}; matches OF__TunnelType,
  /// adjacent to [defaultTunnelType]): scope lpTun `0x22` at **100.00%**.
  tunnelType(0x27e, HeapAttrKind.enumValue, 'tunnelType', AttrConfidence.inferred),

  /// Raw `0x263` — **parallel-for static worker count** (`u8`, 99.2% zero;
  /// matches OF__ParForNumStaticWorkers): scope forLoop `0x20` at **100.00%**.
  parForNumStaticWorkers(0x263, HeapAttrKind.numeric, 'parForNumStaticWorkers', AttrConfidence.inferred),

  /// Raw `0x144` — **window flags** (u32, value 1 at 99.87%; matches
  /// OF__winFlags): scope the panel root `0x7E` at **100.00%**.
  winFlags(0x144, HeapAttrKind.numeric, 'winFlags', AttrConfidence.inferred),

  /// Raw `0x119` — **structure colour** (u32 RGB, greys #7F7F7F/#B3B3B3;
  /// matches OF__structColor): on loop/tunnel/shift-register classes.
  structColor(0x119, HeapAttrKind.color, 'structColor', AttrConfidence.inferred),

  /// Raw `0x0E0` — **part order** (`u8` values 1..3; matches OF__partOrder):
  /// scope cosm `0x09` 50% + stdNum `0x50` 48%.
  partOrder(0x0e0, HeapAttrKind.ordinal, 'partOrder', AttrConfidence.inferred),

  /// Raw `0x0E8` — **preferred instance index** (`u8` with the 255 = none
  /// sentinel at 57%; matches OF__preferredInstIndex): scope polyIUse `0xC5`
  /// at **100.00%** — a polymorphic sub-VI call's selected instance.
  preferredInstIndex(0x0e8, HeapAttrKind.ordinal, 'preferredInstIndex', AttrConfidence.inferred),

  /// Raw `0x1B2` — **cell position row** (`u8` with 254/255 sentinels; matches
  /// OF__cellPosRow, pairing with [cellPosCol]): scope treeControl/listbox.
  cellPosRow(0x1b2, HeapAttrKind.ordinal, 'cellPosRow', AttrConfidence.inferred),

  /// Raw `0x1B8` — **item flags** (`u8` bitfield 128/191/16/8; matches
  /// OF__flags): scope treeControl/listbox (co-occurring with [cellPosRow]).
  /// Bit meanings not decoded.
  itemFlags(0x1b8, HeapAttrKind.numeric, 'flags', AttrConfidence.inferred),

  /// Raw `0x25D` — **XNode state data** (length-prefixed payloads; matches
  /// OF__StateData): scope xNode `0x105` at 91.2% (small population). The
  /// payload encoding is not decoded.
  stateData(0x25d, HeapAttrKind.numeric, 'stateData', AttrConfidence.inferred),

  /// Raw `0x02E` — the integer widths of the string-buffer tag (u32 form,
  /// 89.9% zero; the `C4 2E` lp form is the decoded string table,
  /// [HeapOpcode.stringTable]). Meaning of the numeric form not pinned.
  bufValue(0x02e, HeapAttrKind.numeric, 'bufValue', AttrConfidence.kindOnly),

  /// An attribute tag that is not (yet) catalogued. Its [raw] is -1.
  unknown(-1, HeapAttrKind.unknown, 'unknown', AttrConfidence.kindOnly)
  ;

  const HeapAttribute(this.raw, this.kind, this.attrName, this.confidence);

  /// The 10-bit raw tag id (`((op & 3) << 8) | idByte`); -1 for [unknown].
  final int raw;

  /// The intrinsic value kind for this attribute's *primary* (integer/RGB) form.
  /// Width-dependent forms resolve their effective kind via [HeapAttr.kind].
  final HeapAttrKind kind;

  /// The human-assigned name. See [confidence] for how grounded it is.
  final String attrName;

  /// How well-grounded [attrName] is (clean-room honesty).
  final AttrConfidence confidence;

  static final Map<int, HeapAttribute> _byRaw = {
    for (final attribute in values)
      if (attribute != unknown) attribute.raw: attribute,
  };

  /// Maps a 10-bit raw tag id to its [HeapAttribute], or [unknown] if not
  /// catalogued.
  static HeapAttribute fromRaw(int raw) => _byRaw[raw] ?? unknown;
}

/// A single decoded attribute record (`<op> <id> <value>`): the catalog
/// [attribute], the storage [width], and the typed [value]
/// (`int` | `double` | `String`). Produced by [decodeHeapAttr].
class HeapAttr {
  const HeapAttr({
    required this.attribute,
    required this.id,
    required this.rawTag,
    required this.width,
    required this.value,
    required this.length,
    this.rawValueBytes,
  });

  /// The catalog entry (or [HeapAttribute.unknown] for an uncatalogued tag).
  final HeapAttribute attribute;

  /// The raw attribute id byte (the record's second byte; valid even when
  /// [attribute] is unknown). The low 8 bits of [rawTag].
  final int id;

  /// The 10-bit raw tag id (`((op & 3) << 8) | id`) — the catalog key.
  final int rawTag;

  /// How the value was stored.
  final HeapAttrWidth width;

  /// The typed value: `int` (numeric/coord/size/enum/flag, or packed RGB for
  /// colours), `double` (f64 control params), `String` (C6 blobs), or [HeapRect]
  /// (rectangle-payload ids like `0x29`).
  final Object value;

  /// The total byte length of the record (so a walker can advance by it).
  final int length;

  /// For the widths whose typed [value] is a **lossy** or partial reading —
  /// [HeapAttrWidth.blob] (printable-filtered [String]), [HeapAttrWidth.f64]
  /// (an IEEE-754 [double] whose re-encode is not guaranteed bit-identical), and
  /// [HeapAttrWidth.container] (only the leading byte is exposed) — the exact
  /// stored payload bytes after the record's framing header, retained verbatim so
  /// the record re-emits byte-exact. Null for the integer / rectangle widths,
  /// whose [value] reconstructs their bytes exactly. Never printable-filtered.
  final Uint8List? rawValueBytes;

  /// The *effective* value kind, resolving width-dependent forms:
  /// `f64`→[HeapAttrKind.controlParam], `blob`→[HeapAttrKind.stringBlob],
  /// `rect`→[HeapAttrKind.rectangle], `container`→[HeapAttrKind.container];
  /// every other width returns the catalog [kind].
  HeapAttrKind get kind => switch (width) {
    HeapAttrWidth.f64 => HeapAttrKind.controlParam,
    HeapAttrWidth.blob => HeapAttrKind.stringBlob,
    HeapAttrWidth.rect => HeapAttrKind.rectangle,
    HeapAttrWidth.container => HeapAttrKind.container,
    _ => attribute.kind,
  };

  /// The value as an `int`, or null if it is not integer-stored.
  int? get asInt => value is int ? value as int : null;

  /// The value as a `double`, or null if it is not an `f64` control param.
  double? get asDouble => value is double ? value as double : null;

  /// The value as a `String`, or null if it is not a blob.
  String? get asString => value is String ? value as String : null;

  /// For a magnitude-encoded **text** tag ([_asciiIntRaws]:
  /// [HeapAttribute.shortText] / [HeapAttribute.nodeName]), the integer [value]'s
  /// magnitude bytes read as ASCII (`0x50616765` → `"Page"`), or null when the
  /// tag is not one of those text tags, the value is not integer-stored, or any
  /// magnitude byte is non-printable. The numeric [value] / [asInt] is preserved
  /// — this is a separate reading, never an overwrite. It is the *printable*
  /// reading only: a value with all-printable low bytes but a null leading byte
  /// yields a string SHORTER than the stored [width] (`0x00424242` at u32 →
  /// `"BBB"`), which is width-inconsistent and is a number, not a caption, so
  /// callers treating this as text must additionally require the length to
  /// equal the stored scalar width.
  String? get asciiText => _asciiIntRaws.contains(rawTag) && value is int ? _asciiFromInt(value as int) : null;

  /// The value as a [HeapRect], or null if it is not a rectangle-payload id.
  HeapRect? get asRect => value is HeapRect ? value as HeapRect : null;

  /// For a [HeapAttrKind.point] value carried at the full 32-bit
  /// ([HeapAttrWidth.rgb]) width, the packed `(s16, s16)` halves
  /// (`(value >> 16, value & 0xFFFF)`, sign-extended); null otherwise. A
  /// narrower (`u8`/`u16`/`u24`) or truncated record has no full point to
  /// unpack, so it returns null rather than fabricating one.
  ({int a, int b})? get asPoint => kind == HeapAttrKind.point && width == HeapAttrWidth.rgb && value is int
      ? (a: ((value as int) >> 16).toSigned(16), b: ((value as int) & 0xffff).toSigned(16))
      : null;

  /// For a [HeapAttrKind.color] value, the 24-bit `0xRRGGBB` (drops the flag).
  int? get rgb => kind == HeapAttrKind.color && value is int ? (value as int) & 0xffffff : null;

  /// For a colour, whether it is the transparent sentinel (flag `0x01`, RGB 0).
  bool get isTransparent => rgb == 0 && (value as int) >>> 24 == 0x01;
}

/// Raw tag ids whose `C5/C6 <id> 08` 8-byte payload is a 4× `s16` rectangle
/// rather than an `f64`. Corpus-validated at 100% rectangle / 0% sane-f64:
/// [HeapAttribute.termBounds], the [HeapAttribute.totalBounds] /
/// [HeapAttribute.srcRect] pair, and [HeapAttribute.savedSize].
const Set<int> _rectPayloadRaws = {0x129, 0x163, 0x164, 0x275};

/// Raw tag ids whose `Cx <id> 08` 8-byte payload is a genuine IEEE-754 `f64`
/// (corpus-validated ≈99–100% sane doubles): the scale-data family
/// (`C5 F5..FA` = raw `0x1F5..0x1FA`) and the numeric-control min/max/inc
/// (`C6 20/21/22` = raw `0x220..0x222`). Every OTHER tag at `…08` is NOT
/// assumed to be an f64 — blindly reading e.g. raw `0x1E7` (a container) as a
/// double yields garbage, so uncatalogued `…08` records are left
/// framed-but-undecoded (return null).
const Set<int> _f64PayloadRaws = {0x1f5, 0x1f6, 0x1f7, 0x1f8, 0x1f9, 0x1fa, 0x220, 0x221, 0x222};

/// Raw tag ids whose `C6 <id> <len> <payload>` is a raw inline ASCII string
/// (the whole payload is the text — no `FF`/`u32-strlen` wrapper): raw `0x231`
/// property-item names ("Scale", "Maximum", "FP.State"). Corpus-validated at
/// 100% printable. See [HeapAttribute.propItemName].
const Set<int> _inlineStringRaws = {0x231};

/// Raw tag ids whose `C6 <id> <u8 len>` (len ∉ {0x08, 0xFF}) form carries a
/// `<u32 strlen><ascii>` string — the short-length sibling of the `C6 …FF`
/// blob. Raw `0x26C` ([HeapAttribute.constValue]) uses it for string-constant
/// values ("ps2000aRunStreaming", "%f"). Only ~50% match cleanly (the rest is
/// non-string flattened data), so [decodeHeapAttr] per-record-validates
/// (strlen fits, not a big-slack 1-char false positive, fully printable) and
/// leaves the rest framed — never fabricating a string.
const Set<int> _u32StringRaws = {0x26c};

/// Raw tag ids whose integer-width values are magnitude-encoded **short ASCII
/// strings** ([HeapAttribute.shortText], 95.3% of nonzero values all-printable;
/// [HeapAttribute.nodeName], 5,920/5,920). The record keeps its numeric
/// [HeapAttr.value]; [HeapAttr.asciiText] exposes the ASCII reading separately,
/// and only when every magnitude byte is printable — a genuinely-numeric record
/// is never overwritten with a fabricated text token.
const Set<int> _asciiIntRaws = {0x022, 0x0c4};

/// Whether [c] is a printable ASCII byte (`0x20..0x7e`).
bool _isPrintableAscii(int byte) => byte >= 0x20 && byte < 0x7f;

/// The magnitude bytes of a positive int [v] decoded as ASCII, or null when
/// any byte is non-printable (see [_asciiIntRaws]). Total.
String? _asciiFromInt(int v) {
  if (v <= 0) return null;
  final chars = <int>[];
  for (var x = v; x > 0; x >>= 8) {
    final b = x & 0xff;
    if (!_isPrintableAscii(b)) return null;
    chars.add(b);
  }
  return String.fromCharCodes(chars.reversed);
}

/// Value-byte count of the attribute **nibble family** by the opcode's high
/// nibble — the header's `sizeSpec:hasAttrList` bits (`0x`→0/false, `2x`→1,
/// `4x`→2, `6x`→3, `8x`→4, `Ex`→0/true); the record is `2 + value bytes` long.
/// The `Cx` form is length-prefixed and framed separately. Shared by
/// [decodeHeapAttr] and [recordSkip] so decode and skip framing cannot drift.
const Map<int, int> _attrNibbleValueBytes = {0x0: 0, 0x2: 1, 0x4: 2, 0x6: 3, 0x8: 4, 0xe: 0};

/// Decodes an attribute-style record at [offset] in a heap [body], or returns
/// null if the byte there does not introduce a known attribute form. Handles
/// the `0x/2x/4x/6x/8x/Ex` nibble family (zero-byte widths decode as booleans:
/// `0x`→0, `Ex`→1), `C5`/`C6 …08` (a rectangle for [_rectPayloadRaws], an `f64`
/// for [_f64PayloadRaws], else undecoded), `C6 …FF` (string blob), and the
/// generic `C5`/`C6 <id> <len>` container fallback for every other length-
/// prefixed leaf. The catalog key is the 10-bit raw tag id
/// `((op & 3) << 8) | id` ([HeapAttribute.fromRaw]).
HeapAttr? decodeHeapAttr(Uint8List body, int offset) {
  if (offset + 2 > body.length) return null;
  final op = body[offset];
  final id = body[offset + 1];
  final raw = ((op & 3) << 8) | id;

  if (op == 0xc6 && offset + 3 <= body.length && _inlineStringRaws.contains(raw) && body[offset + 2] != 0xff) {
    final len = body[offset + 2];
    if (offset + 3 + len <= body.length) {
      final text = String.fromCharCodes(body.sublist(offset + 3, offset + 3 + len).where(_isPrintableAscii));
      return HeapAttr(
        attribute: HeapAttribute.fromRaw(raw),
        id: id,
        rawTag: raw,
        width: HeapAttrWidth.blob,
        value: text,
        length: 3 + len,
        rawValueBytes: Uint8List.sublistView(body, offset + 3, offset + 3 + len),
      );
    }
  }

  if ((op == 0xc5 || op == 0xc6) && offset + 11 <= body.length && body[offset + 2] == 0x08) {
    if (_rectPayloadRaws.contains(raw)) {
      final rect = HeapRect.fromPayload(body.sublist(offset + 3, offset + 11));
      if (rect != null) {
        return HeapAttr(
          attribute: HeapAttribute.fromRaw(raw),
          id: id,
          rawTag: raw,
          width: HeapAttrWidth.rect,
          value: rect,
          length: 11,
        );
      }
    }
    if (_f64PayloadRaws.contains(raw)) {
      final value = ByteData.sublistView(body, offset + 3, offset + 11).getFloat64(0);
      return HeapAttr(
        attribute: HeapAttribute.fromRaw(raw),
        id: id,
        rawTag: raw,
        width: HeapAttrWidth.f64,
        value: value,
        length: 11,
        rawValueBytes: Uint8List.sublistView(body, offset + 3, offset + 11),
      );
    }
    // Other tags at `…08` fall through to the generic data fallback below.
  }

  if (op == 0xc6 && offset + 5 <= body.length && body[offset + 2] == 0xff) {
    final len = (body[offset + 3] << 8) | body[offset + 4];
    final end = offset + 5 + len;
    if (end <= body.length && len >= 4) {
      final strLen = ByteData.sublistView(body, offset + 5, offset + 9).getUint32(0);
      final from = offset + 9, to = (from + strLen) <= end ? from + strLen : end;
      final bytes = body.sublist(from, to);
      final chars = bytes.where(_isPrintableAscii).toList();
      if (bytes.isNotEmpty && chars.length / bytes.length >= 0.9) {
        return HeapAttr(
          attribute: HeapAttribute.fromRaw(raw),
          id: id,
          rawTag: raw,
          width: HeapAttrWidth.blob,
          value: String.fromCharCodes(chars),
          length: 5 + len,
          rawValueBytes: Uint8List.sublistView(body, offset + 5, offset + 5 + len),
        );
      }
    }
    // Non-validating blobs fall through to the generic data fallback below.
  }

  if (op == 0xc6 && offset + 3 <= body.length && _u32StringRaws.contains(raw)) {
    final len = body[offset + 2];
    if (len != 0xff && len != 0x08 && len >= 5 && offset + 3 + len <= body.length) {
      final payloadStart = offset + 3;
      final strLen = ByteData.sublistView(body, payloadStart, payloadStart + 4).getUint32(0);
      final slack = len - (strLen + 4);
      if (strLen >= 1 && slack >= 0 && !(strLen <= 2 && slack >= 8)) {
        final bytes = body.sublist(payloadStart + 4, payloadStart + 4 + strLen);
        if (bytes.every(_isPrintableAscii)) {
          return HeapAttr(
            attribute: HeapAttribute.fromRaw(raw),
            id: id,
            rawTag: raw,
            width: HeapAttrWidth.blob,
            value: String.fromCharCodes(bytes),
            length: 3 + len,
            rawValueBytes: Uint8List.sublistView(body, offset + 3, offset + 3 + len),
          );
        }
      }
    }
  }

  // Generic length-prefixed data fallback for the remaining C5/C6 leaf forms:
  // the tag and the payload boundary are grammar-known even when no typed
  // reading validates — a [HeapAttribute.constValue]/[HeapAttribute.defaultData]
  // payload of non-string flattened data, an opaque length-prefixed container
  // (e.g. the raw-`0x1E7` [HeapAttribute.compressedWireTable] packed payload,
  // whose interior is NOT decoded), or an uncatalogued tag. [HeapAttr.value]
  // exposes the leading payload byte. Framed exactly as [recordSkip] frames
  // these leads (a C5 length byte is literal — only C6 has the FF -> u16
  // escape); the payload bytes are NOT interpreted.
  if (op == 0xc5 || op == 0xc6) {
    if (offset + 3 > body.length) return null;
    var headerLen = 3;
    var len = body[offset + 2];
    if (op == 0xc6 && len == 0xff) {
      if (offset + 5 > body.length) return null;
      headerLen = 5;
      len = (body[offset + 3] << 8) | body[offset + 4];
    }
    if (offset + headerLen + len > body.length) return null;
    return HeapAttr(
      attribute: HeapAttribute.fromRaw(raw),
      id: id,
      rawTag: raw,
      width: HeapAttrWidth.container,
      value: len > 0 ? body[offset + headerLen] : 0,
      length: headerLen + len,
      rawValueBytes: Uint8List.sublistView(body, offset + headerLen, offset + headerLen + len),
    );
  }

  final lo = op & 0xf, hi = op >> 4;
  if (lo == 4 || lo == 5 || lo == 6) {
    final valueBytes = _attrNibbleValueBytes[hi];
    if (valueBytes == null) return null;
    // Zero-size leads 0x05/0x06 are framed by [recordSkip] as typed lists when
    // a type tag follows; only decode the plain 2-byte reading in the other
    // case so decode and skip stay aligned (0x04 is always 2 bytes there).
    if (hi == 0x0 && op != 0x04 && offset + 4 <= body.length && isHeapTypeTag(body[offset + 3])) {
      return null;
    }
    final valEnd = offset + 2 + valueBytes;
    if (valEnd > body.length) return null;
    HeapAttrWidth width;
    Object value;
    switch (hi) {
      case 0x0:
        width = HeapAttrWidth.flag;
        value = 0;
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
      default: // 0xE
        width = HeapAttrWidth.flag;
        value = 1;
    }
    return HeapAttr(
      attribute: HeapAttribute.fromRaw(raw),
      id: id,
      rawTag: raw,
      width: width,
      value: value,
      length: 2 + valueBytes,
    );
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
/// Note on confidence: the *framing* is confirmed; each opcode's decode status
/// lives on its [HeapOpcode] entry. [opcode] is the raw selector byte;
/// [payload] is the raw operand bytes — no semantic interpretation is applied
/// here.
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

  /// If this is any single-string opcode ([HeapShape.string]: caption, plot name,
  /// format string, item label, symbol/C-function name, or VI-Server method name),
  /// the payload decoded as text — the whole payload is the string (no inner
  /// prefix); else null. Null when empty or not fully printable ASCII.
  ///
  /// This is a **display** reading: it drops the record on any non-printable byte.
  /// For the exact bytes (re-emission, byte accounting) use [rawText].
  String? get text {
    if (kind.shape != HeapShape.string || payload.isEmpty) return null;
    // Multi-line captions (free-standing comments) carry CR/LF; tabs occur in
    // aligned comment text. Any other control byte marks a non-text payload.
    if (payload.any((b) => (b < 32 && b != 0x09 && b != 0x0a && b != 0x0d) || b >= 127)) {
      return null;
    }
    return String.fromCharCodes(payload).replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  }

  /// If this is any single-string opcode ([HeapShape.string]), the string's
  /// **byte-faithful** content — the whole payload verbatim, every byte retained;
  /// else null. The single-string opcodes carry the string as their entire
  /// payload (no inner prefix), so these bytes are the string itself.
  ///
  /// The retention counterpart to the printable-filtered [text]: [text] is for
  /// display and drops non-printable bytes, [rawText] keeps them, so a record
  /// with control bytes (e.g. a `%016b` format specifier) re-emits exactly. Never
  /// filtered, never null for a non-empty string payload.
  Uint8List? get rawText => kind.shape == HeapShape.string && payload.isNotEmpty ? payload : null;

  /// If this is a [HeapOpcode.description] record, the embedded help/tooltip text
  /// (often HTML-ish, multi-line); null if none. The dominant form is raw text
  /// from byte 0 (no length prefix), returned verbatim when the payload is mostly
  /// printable; otherwise it falls back to recovering length-prefixed text
  /// segments. **Heuristic** — the inner multi-segment framing is not fully
  /// decoded, so this recovers readable text, not exact fields. Total.
  String? get descriptionText {
    if (kind != HeapOpcode.description) return null;
    bool isTextByte(int byte) => (byte >= 32 && byte < 127) || byte == 9 || byte == 10 || byte == 13;

    if (payload.isNotEmpty) {
      final printable = payload.where(isTextByte).length;
      if (printable / payload.length >= 0.9) {
        return String.fromCharCodes(payload.where(isTextByte)).trim();
      }
    }

    final runs = <String>[];
    var i = 0;
    while (i < payload.length) {
      final len = payload[i];
      if (len >= 6 && i + 1 + len <= payload.length && payload.sublist(i + 1, i + 1 + len).every(isTextByte)) {
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
    final bytes = payload;
    if (bytes.length < 12 || bytes[0] != 0x50 || bytes[1] != 0x54 || bytes[2] != 0x48 || bytes[3] != 0x30) {
      return null;
    }
    final nComp = (bytes[10] << 8) | bytes[11];
    final parts = <String>[];
    var i = 12;
    for (var componentIndex = 0; componentIndex < nComp && i < bytes.length; componentIndex++) {
      final len = bytes[i];
      if (i + 1 + len > bytes.length) break;
      final part = bytes.sublist(i + 1, i + 1 + len);
      if (part.any((byte) => byte < 32 || byte >= 127)) break;
      parts.add(String.fromCharCodes(part));
      i += 1 + len;
    }
    return parts.isEmpty ? null : parts.join('/');
  }

  /// If this is a [HeapOpcode.path] record, the path's **byte-faithful** bytes —
  /// the whole `PTH0` payload verbatim (`'PTH0' <u32 len> <u16 type> <u16 nComp>`
  /// then the packed components); else null. The retention counterpart to the
  /// printable-filtered [path] (which is a display join and stops at the first
  /// non-printable component), so a path record re-emits byte-exact regardless of
  /// its component bytes. Never filtered.
  Uint8List? get rawPathBytes => kind == HeapOpcode.path && payload.isNotEmpty ? payload : null;

  /// If this is a [HeapShape.container] record (e.g. a `C4 44` cluster), the
  /// nested `C4` child records inside its payload (offsets relative to this
  /// record's payload); otherwise empty. Total.
  List<HeapRecord> get children =>
      kind.shape == HeapShape.container ? scanC4Records(payload, sectionTag) : const <HeapRecord>[];
}

/// Frames the `C4 <op> <u8 len> <payload>` records in [h] (a decompressed heap or
/// a container payload), tagging each with [sectionTag]. Non-`C4` bytes are
/// stepped over one at a time. Total/bounds-safe.
List<HeapRecord> scanC4Records(Uint8List heapBytes, String sectionTag) {
  final out = <HeapRecord>[];
  final length = heapBytes.length;
  var i = 0;
  while (i < length) {
    final frame = c4FrameAt(heapBytes, i, sectionTag);
    if (frame != null) {
      out.add(frame);
      i += frame.byteLength;
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
HeapRecord? c4FrameAt(Uint8List heapBytes, int offset, String sectionTag) {
  final length = heapBytes.length;
  if (offset + 3 > length || heapBytes[offset] != kHeapRecordPrefix) return null;
  final op = heapBytes[offset + 1];
  final lenByte = heapBytes[offset + 2];
  int headerLen;
  int len;
  if (lenByte == 0xff) {
    if (offset + 5 > length) return null;
    headerLen = 5;
    len = (heapBytes[offset + 3] << 8) | heapBytes[offset + 4];
  } else {
    headerLen = 3;
    len = lenByte;
  }
  if (offset + headerLen + len > length) return null;
  return HeapRecord(
    sectionTag: sectionTag,
    offset: offset,
    opcode: op,
    payload: Uint8List.sublistView(heapBytes, offset + headerLen, offset + headerLen + len),
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
    final view = ByteData.sublistView(payload);
    return HeapRect(top: view.getInt16(0), left: view.getInt16(2), bottom: view.getInt16(4), right: view.getInt16(6));
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
List<HeapRecord> heapC4RecordsFromDecoded(Iterable<DecodedSection> decoded) => [
  for (final decodedSection in decoded) ...scanC4Records(decodedSection.bytes, decodedSection.tag),
];

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
  /// item carries the value, returned as a raw `u16` (`FE`/`FB`) or an object id
  /// (`FD`) — not sign-extended; all observed `FE` values are small positive.
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
/// heap walks (measured on a dated 8,360-VI snapshot, not a live count),
/// restricted to object-scoped tokens. The
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
  /// — it must not be read as the object header's first u16 (a diverse class
  /// code, not a constant 0x258) — so the name states only the value kind.
  smallValueProperty(0x10, 0x19, PropTokenForm.taggedList, 'smallValueProperty', AttrConfidence.kindOnly),

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
  viewportSlot2(0x11, 0x14, PropTokenForm.selector, 'viewportSlot2', AttrConfidence.inferred),

  /// `15 4B` — **wizard-data marker** (bare selector; raw tag `0x14B`, matches
  /// OF__wizID): scope label `0x0A` at **100.00%** (32,338 records, BDHb) —
  /// flags the label as wizard-owned. The bytes after the marker are the
  /// label's own attribute records (typically `24 DF`, its partRole), not an
  /// attribute list of this node.
  wizIdMarker(0x15, 0x4b, PropTokenForm.selector, 'wizID', AttrConfidence.inferred)
  ;

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
    for (final token in values) (token.op << 8) | token.subop: token,
  };

  /// The catalogued token for an `(op, subop)` pair, or null if uncatalogued.
  static HeapPropertyToken? lookup(int op, int subop) => _byKey[(op << 8) | subop];
}

/// Whether a byte is the `op == 0x04` lead of a bare two-byte `04 SS` token.
/// These appear in FPHb/BDHb (the `SS` subop is dominated by the attribute/
/// property family `0x1f`/`0x20`/`0x22`). Their `04 SS 00 00` payload has no
/// corpus-confirmed grammar, so they are treated as framed-but-undecoded (NOT
/// credited as semantic). Used only for a hex-viewer label. Distinct from
/// [HeapPropertyToken].
bool isTypeDescriptorToken(int op) => op == 0x04;

/// Whether the bytes at [offset] are an object-header signature
/// `10/11/12 02 fe <kind> fd <oid>` — an object declaration, not a property.
/// The `<oid>` field is a `u16` for object ids below `0x8000` and a 32-bit
/// escape `80 00 <u32>` for ids at/above it (see [heapObjectHeaderAt]); both
/// share this 7-byte prefix (`… fd`).
bool _isObjectHeader(Uint8List body, int offset) =>
    offset + 9 <= body.length &&
    kHeapObjectHeaderLeads.contains(body[offset]) &&
    body[offset + 2] == 0x02 &&
    body[offset + 3] == 0xfe &&
    body[offset + 6] == 0xfd;

/// Decodes the object header at [offset] — the
/// `10/11/12 <tag> 02 fe <u16 kind> fd <oid>` shape — into its class code,
/// object id, and total byte [length], or null if the bytes there are not an
/// object header. Total/bounds-safe.
///
/// The `SL__uid` field after `fd` carries the object id in one of two forms,
/// the same `u16`/`u32`-escape split the [_typedList] framing applies to an
/// `fd` item: the **compact** `fd <u16 oid>` (9-byte record, ids `< 0x8000`),
/// and the **32-bit escape** `fd 80 00 <u32 oid>` (13-byte record) used once the
/// id reaches `0x8000` and the high bit would otherwise collide with the escape
/// marker. [length] is 9 or 13 accordingly; [oid] is the full id in both forms.
/// Corpus: 80,177 escaped headers, every one `fd 80 00 <u32>` with an id up to
/// `0x3a0bd`, reconstructing byte-exact from ([kind], [oid]).
({int kind, int oid, int length})? heapObjectHeaderAt(Uint8List body, int offset) {
  if (!_isObjectHeader(body, offset)) return null;
  final kind = (body[offset + 4] << 8) | body[offset + 5];
  // A `u16` oid slot with the high bit set is the 32-bit escape `80 00 <u32>`
  // ([_typedList] frames the record at 13 bytes to match).
  if ((body[offset + 7] & 0x80) != 0 && offset + 13 <= body.length) {
    final oid = (body[offset + 9] << 24) | (body[offset + 10] << 16) | (body[offset + 11] << 8) | body[offset + 12];
    return (kind: kind, oid: oid, length: 13);
  }
  return (kind: kind, oid: (body[offset + 7] << 8) | body[offset + 8], length: 9);
}

/// A decoded property token at an offset: the catalogued [token] and, for a
/// [PropTokenForm.taggedList], the first item's [value] (the property value).
class HeapPropertyValue {
  const HeapPropertyValue({required this.token, required this.value, required this.length});

  /// The catalogued token.
  final HeapPropertyToken token;

  /// The first item's value for a tagged sub-list — a raw `u16` or object id (not
  /// sign-extended) — or null for a bare [PropTokenForm.selector] or a count==0 list.
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
  if (_isObjectHeader(body, offset)) return null;
  final op = body[offset], subop = body[offset + 1];
  final token = HeapPropertyToken.lookup(op, subop);
  if (token == null) return null;
  if (token.form == PropTokenForm.selector) {
    return HeapPropertyValue(token: token, value: null, length: 2);
  }
  if (offset + 4 > body.length || !isHeapTypeTag(body[offset + 3])) return null;
  final len = _typedList(body, offset);
  if (len == null) return null;
  final count = body[offset + 2];
  final tag = body[offset + 3];
  int? value;
  if (count == 0) {
    // No first item — reading past offset+4 would fall into the next record.
    value = null;
  } else if (tag == 0xfd && offset + 5 <= body.length && (body[offset + 4] & 0x80) != 0) {
    // 7-byte FD escape `fd 80 00 <u32 value>`: the u32 follows `80 00`.
    value = offset + 10 <= body.length
        ? (body[offset + 6] << 24) | (body[offset + 7] << 16) | (body[offset + 8] << 8) | body[offset + 9]
        : null;
  } else if ((tag == 0xfb || tag == 0xfe || tag == 0xfd) && offset + 6 <= body.length) {
    value = (body[offset + 4] << 8) | body[offset + 5];
  }
  return HeapPropertyValue(token: token, value: value, length: len);
}

/// Catalog of the **typed-reference leaf family** — the 6-byte
/// `14..17 <sub> 01 fd <u16 oid>` records (a leaf node whose single attribute
/// is the system `SL__uid` = `fd`) that form the heap's object graph. Each is
/// a typed link from the current object to another object (by id); the 10-bit
/// raw tag id `((lead & 3) << 8) | sub` selects the *relationship*.
///
/// Corpus-validated resolve rates: [childRef]/[ownerRef] ~100% in the same heap;
/// [dcoRef] 90.1% same heap + 9.8% in the sibling heap (≈100% total — BD
/// terminals referencing FP DCOs cross the heap boundary); [ddoRef] **100%
/// (2,048/2,048) in the sibling heap** (0% same heap — it links a BD node to
/// its FP display object); the named `15xx` refs resolve 100% each. Resolve a
/// record with [decodeHeapRef].
enum HeapRefKind {
  /// Raw `0x019` (`14 19`, system tag `arrayElement`) — **element / child
  /// membership** reference (the members of a loop / case structure /
  /// cluster). The highest-volume link; resolves ~100%.
  childRef(0x019, 'childRef', AttrConfidence.confirmed),

  /// Raw `0x04F` (`14 4f`; matches OF__dco) — **DCO reference**: a terminal /
  /// list owner naming its data-carrying object. Resolves 90.1% in the same
  /// heap and 9.8% in the sibling heap (≈100% total).
  dcoRef(0x04f, 'dcoRef', AttrConfidence.inferred),

  /// Raw `0x01F` (`14 1f`) — **owner / back-reference** (resolves 100%).
  ownerRef(0x01f, 'ownerRef', AttrConfidence.confirmed),

  /// Raw `0x050` (`14 50`; matches OF__dcoAgg) — **aggregate-DCO / peer**
  /// reference (resolves 100%).
  dcoAggRef(0x050, 'dcoAggRef', AttrConfidence.inferred),

  /// Raw `0x053` (`14 53`; matches OF__ddo) — **cross-heap display-object
  /// reference**: the uid resolves in the OTHER heap of the same VI at
  /// **100.00%** (2,048/2,048; 0% in its own heap) — a BD node naming its
  /// front-panel display object.
  ddoRef(0x053, 'ddoRef', AttrConfidence.inferred),

  /// Raw `0x113` (`15 13`; matches OF__srcDCO) — **source-DCO reference** on
  /// array nodes (aIndx/aInit/aReshape 100%; resolves 3,854/3,854).
  srcDCORef(0x113, 'srcDCORef', AttrConfidence.inferred),

  /// Raw `0x1BD` (`15 bd`; matches OF__loopLimitDCO) — **loop-limit DCO
  /// reference** on for-loops (`0x20` 98.6%; resolves 5,158/5,158).
  loopLimitDCORef(0x1bd, 'loopLimitDCORef', AttrConfidence.inferred),

  /// Raw `0x1D0` (`15 d0`; matches OF__dataValRefDCO) — **data-value-ref DCO
  /// reference** on decompose nodes (`0x153` 100%; resolves 1,466/1,466).
  dataValRefDCORef(0x1d0, 'dataValRefDCORef', AttrConfidence.inferred),

  /// Raw `0x1E2` (`15 e2`; matches OF__tunnelLink) — **tunnel link** on
  /// select tunnels (`0x2D` 100%; resolves 1,054/1,054).
  tunnelLinkRef(0x1e2, 'tunnelLinkRef', AttrConfidence.inferred),

  /// Raw `0x1CF` (`15 cf`; matches OF__poser) — **poser reference** on
  /// decompose nodes (resolves 2,080/2,080).
  poserRef(0x1cf, 'poserRef', AttrConfidence.inferred),

  /// Raw `0x28A` (`16 8a`; matches OF__attachment) — **attachment reference**
  /// from a label (`0x0A` 100%) to its attached object (resolves
  /// 17,182/17,182). Pairs with [attachedObjectRef].
  attachmentRef(0x28a, 'attachmentRef', AttrConfidence.inferred),

  /// Raw `0x289` (`16 89`; matches OF__attachedObject) — **attached-object
  /// back-reference** on attachment objects (`0x177` 100%; resolves
  /// 1,395/1,395).
  attachedObjectRef(0x289, 'attachedObjectRef', AttrConfidence.inferred),

  /// A typed object reference whose raw tag is not individually named but
  /// which still carries the `01 fd <oid>` uid attribute. [raw] is -1 (the
  /// catch-all returned by [fromRaw]).
  objectRef(-1, 'objectRef', AttrConfidence.inferred)
  ;

  const HeapRefKind(this.raw, this.refName, this.confidence);

  /// The 10-bit raw tag id; -1 for the [objectRef] catch-all.
  final int raw;

  /// The human-assigned relationship name.
  final String refName;

  /// How well-grounded [refName] is.
  final AttrConfidence confidence;

  static final Map<int, HeapRefKind> _byRaw = {
    for (final refKind in values)
      if (refKind != objectRef) refKind.raw: refKind,
  };

  /// The relationship for a reference-leaf raw tag id: a named kind, or the
  /// generic [objectRef] for any other (still a typed reference).
  static HeapRefKind fromRaw(int raw) => _byRaw[raw] ?? objectRef;
}

/// A decoded typed reference: its [kind] and the [targetOid] it links to.
class HeapRef {
  const HeapRef({required this.kind, required this.targetOid, required this.length});

  /// The relationship type.
  final HeapRefKind kind;

  /// The referenced object's id. NOTE: [HeapRefKind.ddoRef] (and ~10% of
  /// [HeapRefKind.dcoRef]) resolve in the VI's sibling heap (FPHb ↔ BDHb),
  /// not the heap the record lives in.
  final int targetOid;

  /// Total bytes the record occupies: 6 for the compact `fd <u16 oid>` form,
  /// 10 for the 32-bit escape `fd 80 00 <u32 oid>` form.
  final int length;
}

/// Decodes the `14..17 <sub> 01 fd <oid>` typed reference at [offset], or
/// null if the bytes there are not such a record. The lead may be any of the
/// leaf-with-attribute-list forms `0x14..0x17` (tag high bits ride the lead's
/// low 2 bits); only the single-`fd`-attribute shape is a reference — the
/// `… 01 fe` form carries a class-code literal, not an oid. Mirrors
/// [recordSkip]'s framing of the family.
///
/// The `SL__uid` oid takes the same `u16`/`u32`-escape split as an object
/// header ([heapObjectHeaderAt]): the compact `fd <u16 oid>` (6-byte record)
/// for ids `< 0x8000`, and the 32-bit escape `fd 80 00 <u32 oid>` (10-byte
/// record) at/above it. Corpus: 45,599 escaped refs across leads
/// `0x14`/`0x15`/`0x16`, all `fd 80 00 <u32>`, reconstructing byte-exact.
HeapRef? decodeHeapRef(Uint8List body, int offset) {
  if (offset + 6 > body.length) return null;
  final lead = body[offset];
  if (lead < 0x14 || lead > 0x17) return null;
  if (body[offset + 2] != 0x01 || body[offset + 3] != 0xfd) return null;
  final raw = ((lead & 3) << 8) | body[offset + 1];
  // An fd item with the value high bit set is the 10-byte `fd 80 00 <u32>`
  // escape ([_typedList] frames it at 10 bytes to match).
  if ((body[offset + 4] & 0x80) != 0) {
    if (offset + 10 > body.length) return null;
    final oid = (body[offset + 6] << 24) | (body[offset + 7] << 16) | (body[offset + 8] << 8) | body[offset + 9];
    return HeapRef(kind: HeapRefKind.fromRaw(raw), targetOid: oid, length: 10);
  }
  return HeapRef(kind: HeapRefKind.fromRaw(raw), targetOid: (body[offset + 4] << 8) | body[offset + 5], length: 6);
}

/// How fully a heap record's bytes are understood — the basis of the honest
/// three-tier coverage metric (see `tool/coverage.dart` + `corpus/README.md`).
enum HeapDecodeTier {
  /// We know what the bytes **mean AND what they hold**: an object header
  /// (`kind`+`oid`), a bracket-tree group open/close, a typed object reference,
  /// a decoded `C4` opcode, or a *named* attribute/property-token of
  /// confirmed/inferred confidence whose value is decoded. A catalogued role
  /// alone is NOT enough: a container-width record with a known role but an
  /// undecoded payload interior grades only its header/framing bytes here (see
  /// [HeapTierGrade.valueKindPayloadBytes]).
  semantic,

  /// The value's **kind/width/extent** is known but its meaning or content is
  /// not — a `kindOnly` catalog entry (a value-kind label, not a decoded role)
  /// or the unpacked payload interior of a role-catalogued container record.
  valueKindKnown,

  /// Only the record **boundary** is known (it was framed); its content is not
  /// interpreted at all.
  framed,
}

/// The byte-accounted tier grade of one heap record: every byte of the record
/// grades [tier], EXCEPT the trailing [valueKindPayloadBytes] payload bytes,
/// which grade [HeapDecodeTier.valueKindKnown]. Produced by [heapDecodeTier].
///
/// [valueKindPayloadBytes] is nonzero only for a container-width attribute
/// record ([HeapAttrWidth.container]) whose role is catalogued
/// (confirmed/inferred) but whose length-prefixed payload interior is not
/// decoded: the header/framing bytes count semantic (the role IS known), the
/// undecoded interior does not — knowing a record's role never makes its
/// unpacked payload bytes semantic.
class HeapTierGrade {
  const HeapTierGrade(this.tier, {this.valueKindPayloadBytes = 0});

  /// The grade of the record's bytes (minus [valueKindPayloadBytes]).
  final HeapDecodeTier tier;

  /// Trailing payload bytes downgraded to [HeapDecodeTier.valueKindKnown]
  /// because their interior is not decoded; 0 for every non-split record.
  final int valueKindPayloadBytes;
}

/// The cosm(etic) part classes (`SL__cosm` / `SL__multiCosm` /
/// `SL__bigMultiCosm`) in whose scope the class-polymorphic colour tags raw
/// `0x020`/`0x021` carry colours (see [HeapAttribute.cosmFgColor]).
const Set<int> kCosmClassKinds = {0x09, 0x0b, 0x0c};

/// Grades the record at [offset] in a heap [body] (whose lead byte is [lead],
/// living in section [sectionTag]) into a byte-accounted [HeapTierGrade]. The
/// single source of truth shared by the coverage tool and its regression test
/// so they cannot drift. Assumes [offset] is a record start as produced by
/// [walkHeapBody].
///
/// [enclosingKind] is the innermost enclosing object's class code (−1 when
/// unknown / outside any object); it decides the class-polymorphic colour tags
/// raw `0x020`/`0x021`, which count as decoded colours only inside
/// [kCosmClassKinds] (their label/select-class populations carry text-flag
/// words and indices instead — see [HeapAttribute.cosmFgColor]).
HeapTierGrade heapDecodeTier(Uint8List body, int offset, int lead, String sectionTag, {int enclosingKind = -1}) {
  const semantic = HeapTierGrade(HeapDecodeTier.semantic);
  const valueKindKnown = HeapTierGrade(HeapDecodeTier.valueKindKnown);
  const framed = HeapTierGrade(HeapDecodeTier.framed);
  if (_isObjectHeader(body, offset)) return semantic;
  if (kHeapGroupCloseLeads.contains(lead)) return semantic;
  if (kHeapGroupOpenLeads.contains(lead) && offset + 4 <= body.length && isHeapTypeTag(body[offset + 3])) {
    return semantic;
  }
  if (lead >= 0x14 && lead <= 0x17) {
    if (decodeHeapRef(body, offset) != null) return semantic;
    // A leaf whose system-attribute list parses (`fb`/`fe` literal or the
    // 7-byte `fd` escape): the structure/value is known, the tag meaning not.
    if (offset + 4 <= body.length && isHeapTypeTag(body[offset + 3])) return valueKindKnown;
  }
  if (lead == kHeapRecordPrefix) {
    final rec = c4FrameAt(body, offset, sectionTag);
    if (rec == null) return framed;
    // Every decoded C4 opcode decodes its VALUE (rect/string/string-table/
    // help-text/path), so the whole record is semantic — there is no
    // role-known-but-payload-opaque decoded C4 form to split.
    if (rec.kind.isDecoded) return semantic;
    // A structural or even uncatalogued C4 opcode still has a grammar-known
    // length-prefixed payload — boundary and data extent known, meaning not.
    return valueKindKnown;
  }
  final attr = decodeHeapAttr(body, offset);
  if (attr != null) {
    if (attr.width == HeapAttrWidth.container) {
      if (attr.attribute.confidence == AttrConfidence.kindOnly) return valueKindKnown;
      // Role catalogued (confirmed/inferred) but the length-prefixed payload
      // interior is NOT decoded: only the header/framing bytes are semantic;
      // the payload bytes grade value-kind-known (extent known, content not).
      final headerLen = body[offset] == 0xc6 && body[offset + 2] == 0xff ? 5 : 3;
      return HeapTierGrade(HeapDecodeTier.semantic, valueKindPayloadBytes: attr.length - headerLen);
    }
    // An uncatalogued tag still has a fully-known value kind/width from the
    // record header grammar — boundary AND value known, meaning not.
    if (attr.attribute == HeapAttribute.unknown) return valueKindKnown;
    if (attr.attribute.confidence == AttrConfidence.kindOnly) return valueKindKnown;
    if (attr.attribute.kind == HeapAttrKind.color) {
      if (attr.width != HeapAttrWidth.rgb && attr.width != HeapAttrWidth.f64) {
        return valueKindKnown;
      }
      if ((attr.rawTag == 0x020 || attr.rawTag == 0x021) && !kCosmClassKinds.contains(enclosingKind)) {
        return valueKindKnown;
      }
    }
    return semantic;
  }
  final pv = decodeHeapPropertyToken(body, offset);
  if (pv != null) {
    return pv.token.confidence == AttrConfidence.kindOnly ? valueKindKnown : semantic;
  }
  // An uncatalogued bare 2-byte selector (`1x <sub>`, a zero-size leaf slot):
  // boundary and (empty) value known, tag meaning not.
  if (lead >> 4 == 1 && recordSkip(body, offset) == 2) return valueKindKnown;
  return framed;
}

/// Per-section decode-tier byte totals: the section's [walk] plus the bytes of
/// its spans classified [HeapDecodeTier.semantic] and
/// [HeapDecodeTier.valueKindKnown]. Framed-but-uninterpreted bytes are
/// `walk.coveredBytes - semanticBytes - valueKindBytes`. Produced by
/// [measureHeapTiers].
class HeapTierTotals {
  const HeapTierTotals({required this.walk, required this.semanticBytes, required this.valueKindBytes});

  /// The section walk ([walkHeapBody]) the totals were computed over — carries
  /// the framed-byte totals ([HeapWalk.coveredBytes] / [HeapWalk.bodyBytes]),
  /// completeness, and the spans.
  final HeapWalk walk;

  /// Bytes graded [HeapDecodeTier.semantic] (a split container record
  /// contributes only its header/framing bytes here — see [HeapTierGrade]).
  final int semanticBytes;

  /// Bytes graded [HeapDecodeTier.valueKindKnown], including the undecoded
  /// payload interiors of role-catalogued container records.
  final int valueKindBytes;
}

/// Walks one heap section [body] and totals its bytes per [HeapDecodeTier] —
/// the per-section arithmetic behind the coverage metrics, shared by
/// `tool/coverage.dart` and the corpus coverage regression test so the two
/// cannot drift. Tracks the balanced group tree inline (the same open/close
/// discipline as [walkHeapObjects]) so [heapDecodeTier] receives each record's
/// innermost enclosing object class. Total/bounds-safe.
HeapTierTotals measureHeapTiers(Uint8List body, String sectionTag) {
  final walk = walkHeapBody(body);
  final length = body.length;
  var semantic = 0, valueKind = 0;
  // The enclosing innermost-class in effect *before* each currently-open frame.
  // A close restores its frame's saved value in O(1), so there is no upward
  // rescan of the group stack (an object frame saves the class it shadowed; a
  // group-open frame saves the unchanged current class).
  final enclosingBeforeOpen = <int>[];
  var innermost = -1;

  for (final span in walk.spans) {
    final offset = span.offset;
    final lead = span.lead;
    final header = heapObjectHeaderAt(body, offset);
    if (header != null) {
      enclosingBeforeOpen.add(innermost);
      innermost = header.kind;
      semantic += span.length;
      continue;
    }
    if (kHeapGroupOpenLeads.contains(lead) && offset + 4 <= length && isHeapTypeTag(body[offset + 3])) {
      enclosingBeforeOpen.add(innermost);
      semantic += span.length;
      continue;
    }
    if (kHeapGroupCloseLeads.contains(lead)) {
      if (enclosingBeforeOpen.isNotEmpty) innermost = enclosingBeforeOpen.removeLast();
      semantic += span.length;
      continue;
    }
    final grade = heapDecodeTier(body, offset, lead, sectionTag, enclosingKind: innermost);
    switch (grade.tier) {
      case HeapDecodeTier.semantic:
        semantic += span.length - grade.valueKindPayloadBytes;
        valueKind += grade.valueKindPayloadBytes;
      case HeapDecodeTier.valueKindKnown:
        valueKind += span.length;
      case HeapDecodeTier.framed:
        break;
    }
  }
  return HeapTierTotals(walk: walk, semanticBytes: semantic, valueKindBytes: valueKind);
}

/// The byte length of the heap record at [i] in [h], or null if [i] is not a
/// recognized record start (the walk stops there). This is the **heap record
/// skip table** — the reverse-engineered framing of every record family known so
/// far. Coverage across the diverse corpus is measured mechanically (the
/// "% deliberately parsed" metric — see corpus/ and tool/coverage.dart), not
/// hand-asserted here. Total (never throws).
///
/// CONTRACT: the returned length is the record's NOMINAL size and may exceed the
/// remaining buffer for a truncated record — callers MUST validate `i + len <=
/// length` before reading (as [walkHeapBody] does, stopping the walk there).
///
/// Record families (lead byte → framing):
/// - `C4` — length-prefixed: `3 + u8len`, or `5 + u16len` for the `FF` escape.
/// - `84` — fixed 6 bytes (an RGB color tuple).
/// - `10`/`12`/`11`/`0a` — typed-list node: opcode, subop, `u8` count, type tag,
///   then items. Tag `FB` → 2-byte items (`4 + 2*count`); tag `FE`/`FD` → 3-byte
///   items (`3 + 3*count`). `11`/`0a` are 2 bytes when no type tag follows.
/// - `14` — fixed 6 bytes (`14 sub 01 fd|fe s16`).
/// - `08`/`09`/`04` — fixed 2 bytes.
/// - `24` → 3 bytes; `44` → 4 bytes; `64` → 5 bytes. (An earlier `64 cb 26`→3
///   special case was refuted corpus-wide: under it only 42.7% of affected
///   sections stay open/close-balanced at EOF, vs 99.95% with the uniform
///   5-byte reading — `tool/probe_tag_census.dart`.)
/// - `02` (with `FE`) — fixed 7 bytes.
/// - `25` — a fixed **3-byte** record (the `25 2d` form is NOT a counted list).
/// - attribute nibble-family (opcode low nibble in {4,5,6}): the high nibble sets
///   the value width — `2x`→3, `4x`→4, `6x`→5, `8x`→6, `Ex`→2, `Cx`→`3 + u8len`.
int? recordSkip(Uint8List heapBytes, int offset) {
  final length = heapBytes.length;
  if (offset >= length) return null;
  final op = heapBytes[offset];
  switch (op) {
    case 0xc4:
      if (offset + 3 > length) return null;
      final lenByte = heapBytes[offset + 2];
      if (lenByte == 0xff) {
        if (offset + 5 > length) return null;
        return 5 + ((heapBytes[offset + 3] << 8) | heapBytes[offset + 4]);
      }
      return 3 + lenByte;
    case 0x14:
      // Defer to _typedList so an FD item with the value high-bit set is read as
      // the 7-byte escape (`fd 80 00 <u32>`), not a hardcoded 6 (which desynced
      // the walk); non-escape items still return 6.
      return (offset + 4 <= length &&
              heapBytes[offset + 2] == 1 &&
              (heapBytes[offset + 3] == 0xfd || heapBytes[offset + 3] == 0xfe))
          ? _typedList(heapBytes, offset)
          : null;
    case 0x08:
    case 0x09:
    case 0x04:
      return 2;
    case 0x02:
      return (offset + 2 <= length && heapBytes[offset + 1] == 0xfe) ? 7 : null;
    case 0xc6:
      if (offset + 3 <= length && heapBytes[offset + 2] == 0xff) {
        return (offset + 5 <= length) ? 5 + ((heapBytes[offset + 3] << 8) | heapBytes[offset + 4]) : null;
      }
  }
  final lo = op & 0x0f;
  // hi-nibble-0 leads (0x04..0x06) fall through to the hi==0 branch below so
  // their legacy typed-list-aware framing is preserved.
  if ((lo == 4 || lo == 5 || lo == 6) && op >> 4 != 0) {
    if (op >> 4 == 0xc) return (offset + 3 <= length) ? 3 + heapBytes[offset + 2] : null;
    final valueBytes = _attrNibbleValueBytes[op >> 4];
    if (valueBytes != null) return 2 + valueBytes;
  }
  final hi = op >> 4;
  if (hi == 0 || hi == 1) {
    return (offset + 4 <= length && isHeapTypeTag(heapBytes[offset + 3])) ? _typedList(heapBytes, offset) : 2;
  }
  return null;
}

int? _typedList(Uint8List heapBytes, int offset) {
  final length = heapBytes.length;
  if (offset + 4 > length) return null;
  final count = heapBytes[offset + 2];
  final tag = heapBytes[offset + 3];
  if (tag == 0xfb) {
    // `op subop count FB <count 2-byte items>` — only if the whole record fits.
    final end = offset + 4 + 2 * count;
    return end <= length ? end - offset : null;
  }
  if (tag == 0xfe || tag == 0xfd) {
    // `op subop count <count items>`: items are normally 3 bytes (`<tag><hi><lo>`),
    // but an `FD` item with its high value bit set is a 7-byte escape
    // (`fd 80 00 <u32 value>`).
    var pos = offset + 3;
    for (var itemIndex = 0; itemIndex < count; itemIndex++) {
      final isEscape = pos + 1 < length && heapBytes[pos] == 0xfd && (heapBytes[pos + 1] & 0x80) != 0;
      final step = isEscape ? 7 : 3;
      if (pos + step > length) return null;
      pos += step;
    }
    return pos - offset;
  }
  return null;
}

/// Sequentially walks a decompressed heap [body] (e.g. a `BDEx` section's bytes)
/// as an ordered record stream, starting after the leading `u32` content-length,
/// using [recordSkip]. Stops at the first opcode it cannot frame and reports how
/// far it got. Total/bounds-safe — never throws.
HeapWalk walkHeapBody(Uint8List body) {
  final spans = <HeapSpan>[];
  final length = body.length;
  if (length < 4) return HeapWalk(spans: spans, coveredBytes: 0, bodyBytes: 0);
  final bodyBytes = length - 4;
  var i = 4;
  var covered = 0;
  while (i < length) {
    final step = recordSkip(body, i);
    if (step == null || i + step > length) {
      return HeapWalk(
        spans: spans,
        coveredBytes: covered,
        bodyBytes: bodyBytes,
        stoppedAtOffset: i,
        stoppedLead: body[i],
      );
    }
    spans.add(HeapSpan(offset: i, length: step, lead: body[i]));
    covered += step;
    i += step;
  }
  return HeapWalk(spans: spans, coveredBytes: covered, bodyBytes: bodyBytes);
}

/// Walks a decompressed heap [body] as its **balanced typed-group tree**,
/// tracking which object each record belongs to.
///
/// The tree is delimited by group opens — a [kHeapGroupOpenLeads] lead whose
/// byte after the count is a type tag ([isHeapTypeTag]) — and positional
/// group closes ([kHeapGroupCloseLeads]). A group open that is an **object
/// header** ([heapObjectHeaderAt]) opens an object scope: [onObjectOpen] is
/// called with its span, class code, object id, and the innermost enclosing
/// object's client value (null at the root), and its return value becomes the
/// new scope. A non-object group open pushes a **null** scope so the positional
/// closes stay balanced without changing the enclosing object. Every other
/// record span is delivered to [onRecord] with the innermost enclosing object's
/// value (null outside any object); group open/close spans are consumed by the
/// tree bookkeeping and are not delivered. Total/bounds-safe.
void walkHeapObjects<T extends Object>(
  Uint8List body, {
  required T Function(HeapSpan span, int kind, int oid, T? parent) onObjectOpen,
  void Function(HeapSpan span, T? enclosing)? onRecord,
}) {
  final stack = <T?>[];
  T? innermost() => stack.lastWhere((scope) => scope != null, orElse: () => null);
  final length = body.length;
  for (final span in walkHeapBody(body).spans) {
    final offset = span.offset;
    final lead = span.lead;
    final header = heapObjectHeaderAt(body, offset);
    if (header != null) {
      stack.add(onObjectOpen(span, header.kind, header.oid, innermost()));
      continue;
    }
    if (kHeapGroupOpenLeads.contains(lead) && offset + 4 <= length && isHeapTypeTag(body[offset + 3])) {
      stack.add(null);
      continue;
    }
    if (kHeapGroupCloseLeads.contains(lead)) {
      if (stack.isNotEmpty) stack.removeLast();
      continue;
    }
    onRecord?.call(span, innermost());
  }
}

/// Frequency of each `C4` opcode across a VI's heaps — the opcode census that
/// maps the heap's record types (e.g. `0x2D` dominant, `0x2E` = string table).
/// Total.
Map<int, int> heapOpcodeHistogram(Uint8List viBytes) {
  final hist = <int, int>{};
  for (final record in heapC4Records(viBytes)) {
    hist[record.opcode] = (hist[record.opcode] ?? 0) + 1;
  }
  return hist;
}
