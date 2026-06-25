# VI inspector — format notes & scratch

Working notes for the LabVIEW `.vi` (RSRC) reader: durable, corpus-validated
structural facts plus scratch space for in-progress reverse engineering. This is
**clean-room** RE — everything here was derived from `.vi` *binary files* (the
public Pico NI-LabVIEW example corpus), never from LabVIEW itself.

**Read this for structure; read the tool for numbers.** Live coverage figures
("% framed", "% semantically decoded", per-source breakdown) are *not* written
here by hand — they drift. They are produced by
`packages/labwright_videcode/tool/coverage.dart` (prints a table, writes
`corpus/baseline.json`, and a gitignored `vi-corpus/REPORT.md` scorecard) and
guarded by the corpus ratchet tests. If you want a current number, run the tool.

Two layers do the work: `labwright_viparse` (RSRC container + raw sections) and
`labwright_videcode` (section inflate, heap walk, object graph, IR seed).

---

## RSRC container — decoded

A `.vi`/`.ctl`/`.llb` is an RSRC container, big-endian:

```
0x00  "RSRC\r\n"                     magic
0x06  u16   format version (e.g. 3)
0x08  4s    file type   (LVIN = VI, LVCC = control/typedef)
0x0c  4s    creator     (LBVW)
0x10  u32   info-section offset      (the resource map, near EOF)
0x14  u32   info-section size
0x18  u32   data-section offset      (= 0x20; the block data area)
0x1c  u32   data-section size
```

Layout is `[32-byte header][data area][info/resource-map]`. The info section
repeats the header, then at `info+0x2c` holds a u32 offset (relative to `info`)
to the **block list**:

```
block list:  u32 count, then `count` entries of { 4s tag, u32 n1, u32 n2 }
             n1 = sectionCount - 1 ; n2 = offset (rel to info) to the section descriptors
```

Each block owns `n1+1` **section descriptors**, 20 bytes each:

```
u32 index, u32 dataOffset, u32, u32, u32 = 0xFFFFFFFF   (sentinel)
```

The trailing `0xFFFFFFFF` distinguishes a real section descriptor from the
interleaved name-table rows (which carry `tag→offset` pairs). A section's bytes
live at `dataArea + dataOffset` as `[u32 length][bytes]`.
→ `labwright_viparse.readViSections`.

## Section compression — decoded

Heap sections are stored as `[u32 decompressedSize][zlib stream]` (CMF byte
`0x78`). `labwright_videcode.inflateSection` inflates them; uncompressed sections
pass through. Notable blocks: `BDHb`/`BDEx` (block-diagram heap), `FPHb` (front
panel), `DTHP`/`VCTP` (data types), `vers` (version+title), `CONP` (connector
pane), `LIvi`/`LIfp`/`LIbd` (sub-VI links), `icl8`/`ICON`/`PICC`/`DSIM` (icon).

## `vers` block — decoded

A Pascal version string (`10.0`, `9.0`, …) plus a `VIDS` record (`'VIDS'` +
`[u8 len][title]`). → `decodeVersion`.

---

## Heap body grammar (`BDHb`/`BDEx`)

The decompressed heap is `[u32 contentLen][record stream]`. It is **not** a flat
`[tag][len]` TLV — it is LabVIEW's opcode-serialized object heap, a **nested,
count-prefixed typed-group tree**. `walkHeapBody(body)` frames it as an ordered
record stream via the `recordSkip` table (the reverse-engineered per-opcode skip
rules); `buildDiagram(body)` segments that stream into the object tree.

### Record families (see `recordSkip` for the exact rules)

- **`C4 <op> <u8 len> <payload>`** — length-prefixed leaf. Extended form
  `C4 <op> FF <u16 len>` (header 5 bytes) for payloads > 255. Decoded leaves:
  - `2D` = **bounds rectangle** (4× s16 `top,left,bottom,right`, px) — position+size
  - `1F` = **size rectangle** (same layout, origin-anchored extent)
  - `2E` = **string table** (packed `[u8 len][chars]` Pascal strings) — enum/ring item lists
  - `22` = **caption** / control name (e.g. `Trigger Source`, `Wave Type`)
  - `27`=plot name, `74`=printf format, `20`=item label, `C4`=symbol name
    (Call-Library C function), `A4`=path (`PTH0` DLL path), `19`=description/help (heuristic),
    `4A`=type bounds, `44/64/24`=containers (nested `C4` children)
  - `5F/4C/D6/62/26` = confirmed 4× s16 rectangles whose *role* is undetermined
    (generic `rect` only — deliberately not assigned a false meaning)
- **`84 <subop> <flag> <r> <g> <b>`** — fixed 6-byte **RGB color** (`0x01000000` = transparent).
- **`10`/`11`/`12`/`13 <subop> <u8 count> <typetag> <items>`** — typed-list /
  object header. `10 19 02 fe <kind> fd <oid>` declares a new object (class `kind`,
  heap id `oid`). Tag `FB`→2-byte items, `FE`/`FD`→3-byte items, with an `FD`
  value-escape (`80 00 <u32>`) when the value's high bit is set.
- **`14 <sub> 01 fd <oid>`** — child-membership ref (6 bytes). `08`/`09`/`04` = 2-byte;
  `24` = 3, `44` = 4, `64` = 5 (`64 cb 26` = 3); `02 FE …` = 7-byte coordinate record.
- **attribute nibble-family** (opcode low-nibble ∈ {4,5,6}): high nibble sets value
  width (`2x`→3 … `8x`→6, `Ex`→2, `Cx`→`3+u8len`). Typed color / coord(s16) /
  size(u16) / enum(u8) / flag.
- **`C5 <attr-id> 08 <f64>`** — IEEE-754 double (numeric-control min/max/inc/default).
- **`C6 <attr-id> FF <u16 len> <payload>`** — extended string/blob (VISA address, serial, …).

The opcode catalog with per-id name/kind/confidence lives in one place — the
`HeapOpcode` / `HeapAttribute` / `HeapObjectClass` enhanced enums in
`packages/labwright_videcode/lib/src/heap.dart`. Inferred names carry an explicit
`AttrConfidence` (`confirmed`/`inferred`/`kindOnly`) — never false certainty.

### Nesting tree rule (the keystone)

The body is a **balanced typed-group tree**:
- a **group opens** at a high-nibble-1 opcode `10/11/12/13 <tag>` *only when the
  byte after the count is a type tag* (`FB`/`FE`/`FD`) — covers object headers
  (`10 19 02 fe …`) and typed lists (`10 55 01 fb …`); a bare 2-byte `11 10` is not a group.
- a **group closes** at any high-nibble-0 opcode (`08/09/0a/0b`), **popped
  positionally** (the close need not tag-match).

With this rule the body balances to depth 0 at EOF with a single root (kind
`0x7e`). The object tree is read off this stack (parent = nearest enclosing
object header); absolute coordinates compose down the ancestor chain
(`abs_origin(child) = abs_origin(parent) + child.localOrigin`).
→ `buildDiagram` sets `ViHeapObject.parentOid` + `absBounds` + `ViDiagram.roots`/`children(oid)`.

### Object model

`buildDiagram` → `ViDiagram {objects, byId, roots, children(oid), nodes}` of
`ViHeapObject {oid, kind, offset, bounds?, absBounds?, parentOid?, label?, refs,
termCount, category, typeKind}`. The header `kind` maps to a structural category
(`classifyObject` / `ViObjectKind`): terminal-cluster (`0x0c`), node body (`0x12`),
structure/diagram container (`0x53/52/09/7e/4c`), terminal (`0x68`+`0x50/51/57/4f/5b`+…),
decoration (`0x8f/e7/d2`). Data-type kind (`ViTypeKind`) is inferred from attached
`C4` records (`74`→numericInt/Float by printf conv, `2E`→enumRing, `A4`→path, `C4`→CLN node).

`assembleObjects` pairs each `C4 22` caption (or framed `C4 2E` table) with the
`C4 2D` bounds immediately preceding it → `ViModel.objects` (named, positioned
controls). `buildViModel(viBytes)` aggregates the read-only layers into `ViModel`
— the plug-in point for a future VI→Dart translator.

---

## Honest negatives (do NOT model these — not yet recovered)

- **Dataflow wires are not recoverable as oid edges.** Signal wires are stored as
  *geometry*, not oid endpoints, and the wire-segment record is still unidentified
  (`C4 5F` was probed and ruled out — it's 89% 2-D rects, not 1-D segments). The
  `14 19 01 fd` refs are **child-membership** lists owned by structure/diagram
  containers ("which oids live in this frame"), **not** wire endpoints. So
  node→node dataflow edges cannot be resolved from ids today. *(This supersedes an
  early, wrong "0x68 = wire" claim that was an artifact of a flat scan.)*
- **functionNode vs subViNode** and **control vs indicator** terminal are not
  separable from the BD heap alone (the subVI symbol lives in a separate name resource).
- **bool/string/array/cluster** have no payload type signal on the diagram (frame-kind heuristics only).
- **Per-control type kind** lives in the `DTHP` nested token grammar (the
  `08/09/10/11/14/C5` opcode streams), not in `VCTP` — which is a 4-byte stub in
  these compiled VIs. That grammar is not yet cracked.
- **`CONP`** is a pattern stub + link-hash table (no per-terminal list), so the
  input/output↔control binding isn't recoverable from it. `CPC2` does hold the
  VI's top-level description (`[u32 len][ASCII]`).
- **Front panel (`FPHb`)** is uncompressed and uses a *different* encoding (no
  `C4` records). In this sub-VI-heavy corpus most panels are empty templates; rich
  multi-control panel framing needs a top-level-VI corpus to confirm.

Project honesty rule (CLAUDE.md): mark undecoded byte ranges explicitly, say
"not yet recovered" — never "unrecoverable" (NI generates this data, so we can too).

---

## Scratch / next

- Wiring stretch goal: wire *geometry* is parseable; *connectivity* would be
  spatial inference validated against tutorial-VI screenshots — never claim
  dataflow/execution-order (not in the file). See the wiring-recovery note.
- Remaining framing tail: embedded image blobs after `0xc6` records and the
  variant-c heaps (`FPHc`/`BDHc`) at stop leads `0x2d`/`0x4a`.
- Live coverage + regression floor: `tool/coverage.dart` → `corpus/baseline.json`
  + gitignored `vi-corpus/REPORT.md`; per-VI feature presence: `corpus/snapshot.json`.
</content>
</invoke>
