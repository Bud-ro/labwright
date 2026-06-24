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

  /// Maps a raw opcode byte to its [HeapOpcode], or [unknown] if not catalogued.
  static HeapOpcode fromByte(int b) {
    for (final op in values) {
      if (op != unknown && op.byte == b) return op;
    }
    return unknown;
  }
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
  /// `0x1F` — **relative coordinate / offset** (`s16`, observed 100% negative as
  /// `u16` → a relative position). The single highest-volume attribute.
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

  /// `0xB7` — **fixed style colour** (RGB, constant `(1,0,1)` across the corpus).
  styleColor(0xb7, HeapAttrKind.color, 'styleColor', AttrConfidence.confirmed),

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

  /// `0x59` — **reserved / always-zero flag** (`u8`, all 0 across the corpus).
  reservedFlag(0x59, HeapAttrKind.flag, 'reservedFlag', AttrConfidence.inferred),

  /// `0x5A` — **flag (u8) OR instrument-identity string (C6)** — *dual-use*: a
  /// `u8` flag via the nibble form, or a VISA resource / serial / firmware string
  /// via `C6`. [HeapAttr.kind] resolves it by width.
  flagOrIdentity(0x5a, HeapAttrKind.flag, 'flagOrIdentityString', AttrConfidence.confirmed),

  /// `0xF5` — numeric-control **range minimum** (`f64`; `f5 ≤ f7` in 125/125
  /// groups).
  controlMin(0xf5, HeapAttrKind.controlParam, 'controlMin', AttrConfidence.confirmed),

  /// `0xF7` — numeric-control **range maximum** (`f64`; pairs with [controlMin]).
  controlMax(0xf7, HeapAttrKind.controlParam, 'controlMax', AttrConfidence.confirmed),

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

  /// Maps a raw attribute id to its [HeapAttribute], or [unknown] if not
  /// catalogued. Note ids `0xF8`/`0x5A` are dual-use (see [HeapAttr.kind]).
  static HeapAttribute fromId(int id) {
    for (final a in values) {
      if (a != unknown && a.id == id) return a;
    }
    return unknown;
  }
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
  /// colours), `double` (f64 control params), or `String` (C6 blobs).
  final Object value;

  /// The total byte length of the record (so a walker can advance by it).
  final int length;

  /// The *effective* value kind, resolving dual-use attributes by [width]:
  /// an `f64` payload is always a [HeapAttrKind.controlParam] and a `blob` is
  /// always a [HeapAttrKind.stringBlob]; otherwise the catalog [kind].
  HeapAttrKind get kind {
    if (width == HeapAttrWidth.f64) return HeapAttrKind.controlParam;
    if (width == HeapAttrWidth.blob) return HeapAttrKind.stringBlob;
    return attribute.kind;
  }

  /// The value as an `int`, or null if it is not integer-stored.
  int? get asInt => value is int ? value as int : null;

  /// The value as a `double`, or null if it is not an `f64` control param.
  double? get asDouble => value is double ? value as double : null;

  /// The value as a `String`, or null if it is not a blob.
  String? get asString => value is String ? value as String : null;

  /// For a [HeapAttrKind.color] value, the 24-bit `0xRRGGBB` (drops the flag).
  int? get rgb => kind == HeapAttrKind.color && value is int ? (value as int) & 0xffffff : null;

  /// For a colour, whether it is the transparent sentinel (flag `0x01`, RGB 0).
  bool get isTransparent => kind == HeapAttrKind.color && value is int && ((value as int) >>> 24) == 0x01 && ((value as int) & 0xffffff) == 0;
}

/// Decodes an attribute-style record at [offset] in a heap [body], or returns
/// null if the byte there does not introduce a known attribute form. Handles the
/// `2x/4x/6x/8x/Ex` nibble family, `C5` (f64 control param), and `C6` (string
/// blob). The id is looked up in the [HeapAttribute] catalog.
HeapAttr? decodeHeapAttr(Uint8List body, int offset) {
  if (offset + 2 > body.length) return null;
  final op = body[offset];

  // C5 <id> 08 <f64> — numeric-control parameter.
  if (op == 0xc5 && offset + 11 <= body.length && body[offset + 2] == 0x08) {
    final id = body[offset + 1];
    final v = ByteData.sublistView(body, offset + 3, offset + 11).getFloat64(0);
    return HeapAttr(attribute: HeapAttribute.fromId(id), id: id, width: HeapAttrWidth.f64, value: v, length: 11);
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

/// The byte length of the heap record at [i] in [h], or null if [i] is not a
/// recognized record start (the walk stops there). This is the **BDEx record
/// skip table** — the reverse-engineered framing of every record family known so
/// far, validated by sequential walking (≈93% mean body coverage; full,
/// exact-EOF walks on the majority of corpus VIs). Total/bounds-safe.
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
      return _typedList(h, i);
    case 0x11:
      return (i + 4 <= n && _isTypeTag(h[i + 3])) ? _typedList(h, i) : 2;
    case 0x0a:
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
