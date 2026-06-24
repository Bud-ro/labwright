# LabVIEW `.vi` (RSRC) format — reverse-engineering notes

Clean-room notes derived **solely from `.vi` binary files** (the public Pico
NI-LabVIEW example corpus), not from LabVIEW itself. These document what
`labwright_viparse` + `labwright_videcode` decode today and what blocks full
block-diagram graph recovery.

## Byte-purpose coverage — the honest scorecard ⚖️

Mastery means **every byte accounted for and known for its purpose**. Status for
the `BDEx` block-diagram heap (13.48 MB across the corpus):

| | bytes | share | meaning |
|---|---|---|---|
| **Framed** | 13,480,958 | **100%** | every byte belongs to a sized record; the walker reaches exact EOF on 398/398 |
| **Field-role identified** | 13,480,958 | **100%** | every byte's *role* is known — opcode / subop / id / length / value / flag / coordinate / tag — via the per-record field specs below |
| **Semantically named** | — | **high, not total** | the *meaning* of each field. The dominant records are fully named (bounds, strings, captions, colors, sizes, control params, object kinds/oids). Attribute ids covering **~99% of attribute records by volume** are now named in the [`HeapAttribute`](../packages/labwright_videcode/lib/src/heap.dart) catalog (e.g. `0x28`=background colour, `0xF5`=control min, `0x3A`=element index), each labelled `confirmed`/`inferred`/`kindOnly` for honesty. The residual: a long tail of rare attribute ids and a few opaque cross-namespace `fd` reference targets |

So: 100% framed, 100% field-role accounted, and the bulk semantically named via the
`HeapAttribute` / `HeapOpcode` enum catalogs — the residual is *which named property*
a rare typed value sets, not *what kind of value it is*. Because this is clean-room
RE (no LabVIEW source), inferred names carry an explicit [`AttrConfidence`] label
rather than false certainty. See the **record field reference** below for layout, and
the `HeapAttribute` enum for the per-id name/kind/confidence catalog.

### Record field reference (every record's bytes) 📖

Each `BDEx` record's bytes, by lead opcode (all corpus-validated):
- **`10/11/12 <subop> <u8 count> <items>`** — set property `subop` on the current
  object. Item = `<tag><value>`: `FE`→s16 (kind/enum), `FD`→u16 id/oid (7-byte
  escape if the value's high bit is set), `FB`→u8/u16 flag. **`10 19 02 fe <kind>
  fd <oid>`** = declare a new object (class `kind`, heap id `oid`). subop is a
  property selector scoped to the object's kind.
- **`C4 <op> <u8 len|FF u16 len> <payload>`** — length-prefixed leaf: `2D`=bounds
  rect (4×s16), `1F`=size rect, `2E`=string table, `22`/`27`/`74`/`20`=strings,
  `19`=help text, `A4`=path, `C4`=symbol name, `4A`=type bounds, `5F/4C/D6/62/26`=
  rectangles (role TBD), `44/64/24`=containers (nested `C4`).
- **`24/44/64 <attr-id> <value>`** — attribute set, value width by opcode high
  nibble: `24`→u8, `44`→u16, `64`→u24 (`64 cb 26` is a 3-byte token). Same
  attr-id appears across widths (id `0x22`=packed text, `0x74`=printf format,
  `0x19`=scale magnitude).
- **attribute nibble-family** (`op` low-nibble ∈ {4,5,6}) `<attr-id> <value>` —
  width by high nibble (`2x`→1, `4x`→2, `6x`→3, `8x`→4, `Ex`→0 presence-flag).
  `0x84`=RGB color (`flag·R·G·B`, `0x01000000`=transparent); attr-ids are typed
  color / coord(s16) / size(u16) / enum(u8) / flag.
- **`C5 <attr-id> 08 <f64>`** — IEEE-754 double; numeric-control params
  (min/max/inc/default, ids `F5`–`FA`).
- **`C6 <attr-id> FF <u16 len> <payload>`** — extended string/blob (e.g. VISA
  address, serial, firmware version), attr-id `0x5A`.
- **`84 …`** = color (above); **`14 19 01 fd <oid>`** = child-membership ref;
  **`08/09/0a/0b <tag>`** = typed-group close; **`02 fe <s16> fd <s16>`** = a
  fixed 7-byte coordinate/field record; **`04/08/09 <sub>`** = 2-byte node tokens.

## Container (RSRC) — fully decoded ✅

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

The trailing `0xFFFFFFFF` reliably distinguishes a real section descriptor from
the interleaved name-table rows (which carry `tag→offset` pairs instead). A
section's bytes live at `dataArea + dataOffset` as `[u32 length][bytes]`.
→ `labwright_viparse.readViSections` (validated: 435 corpus VIs, ~20k sections,
0 crashes).

## Section compression — fully decoded ✅

Heap sections are stored as `[u32 decompressedSize][zlib stream]` (CMF byte
`0x78`). `labwright_videcode.inflateSection` inflates them; uncompressed
sections pass through. (Validated: ~2k sections inflate, BDEx 1.2 KB–208 KB,
0 crashes.) Notable blocks: `BDEx` (block-diagram heap), `FPHb` (front panel),
`DTHP`/`VCTP` (data types), `vers` (version+title), `CONP` (connector pane),
`LIvi`/`LIfp`/`LIbd` (sub-VI links), `icl8`/`ICON` (icon).

## `vers` block — decoded ✅

Contains a Pascal version string (`10.0`, `9.0`, …) and a `VIDS` record
(`'VIDS'` + `[u8 len][title]`). → `decodeVersion` (432/435 corpus VIs yield
both).

## Heap body (`BDEx`/`BDHb`) — partially understood, graph recovery BLOCKED ⛔

The decompressed heap is `[u32 contentLen][opcode/object stream]`. The stream is
**not** a simple `[tag][len]` tree; it is LabVIEW's opcode-serialized object
heap. Observed invariants (consistent across the corpus):

- Every BDEx body begins identically: `10 18 02 fe 00 7e fd 00 XX 10 f5 02 fe
  00 4c fd 00 XX 64 cb 01 … 10 55 01 fb …`.
- A 6-byte record `14 19 01 fd <u16>` repeats heavily (hundreds of times) — a
  dominant object/reference kind.
- `0xfd` recurs as a record/field marker; 2-byte values (`02 fe`, `10 f5`,
  `64 cb`, `10 55`, `14 19`, …) look like type/opcode codes.
- Human-readable strings (control labels, help text, value lists) are embedded
  as **contiguous Pascal-string tables**: `[u8 len][chars]` entries packed
  back-to-back, with **no per-string opcode tag** (the byte before a string is
  just the previous entry's last char). Confirmed by corpus analysis (the
  "byte-before-length" distribution is dominated by ASCII letters, not a marker).
  → `extractHeapStrings` therefore extracts only strings that belong to a **run**
  of ≥2 consecutive valid Pascal strings (rejecting coincidental single matches)
  and reads full u8 lengths (≤255). This is the first confirmed heap-object
  framing; growing the opcode map from here is the path toward the graph.

### String tables (the run as a grouped object) — confirmed ✅

Each run is a **string table** belonging to a single owning object (e.g. an
enum/ring control's item labels). The grouping is real structure — these labels
share an owner — so `heapStringTables` exposes them as a typed
`HeapStringTable {sectionTag, offset, strings, framed}` (offset = run start within
the decompressed section). `extractHeapStrings` is just the flattened, deduped
view. Demonstrated on the corpus: a single table recovers a waveform selector's
full item list — `Sine, Square, Triangle, Ramp Up, Ramp Down, Sinc, Gaussian,
Half Sine, White Noise, PRBS, Arbitrary` — as one group. (Validated: 409 corpus
VIs, 0 crashes.)

### `C4 2E` string-table opcode — confirmed ✅ (first true opcode)

Most string tables are introduced by a single 2-byte opcode, framed exactly:

```
C4 2E  <len>  <len bytes of packed [u8 strlen][chars] Pascal strings>
         len = u8  when the table is ≤255 bytes
         len = u16 (big-endian) when the table is >255 bytes
```

This is **structural**, not a content heuristic — and exception-free across the
corpus:
- `0xC4` precedes `0x2E` in **2318/2318** framed tables (100%) — so the opcode is
  the 2-byte `C4 2E`, and requiring `C4` rejects stray `0x2E` (`'.'`) bytes inside
  string content.
- Restricting to clean single tables, `byte[start-1]` (right before the first
  string) equals the table's total byte length in **919/919** cases, each preceded
  by `2E` (0 counter-examples); the tables >255 bytes all carry a matching `u16`.

Parsing structurally from the opcode (match `C4 2E`, read `len`, consume exactly
`len` bytes as packed Pascal strings) yields clean enum/ring item lists, e.g. a
gain selector `2500mV, 1225mV, 625mV, 313mV, 156mV, 78mV, 39mV`. Corpus-wide:
**2908 opcode-framed tables across 263 VIs, 0 crashes** (identical with and
without the `C4` requirement — pure precision gain, no regression). These carry
`HeapStringTable.framed == true` (exact boundary); tables found only by the
heuristic run-scan fallback carry `framed == false`.

What `C4 2E <len>` does **not** yet tell us: which *kind* of object owns the table
(enum vs ring vs caption set) and the object's id — those live in the preceding
preamble (below), still undecoded. But exact boundaries + the confirmed opcode are
a real opcode-table entry and the seed of the heap parser.

### The `C4` opcode family — structural recon 🔬 (candidates, mostly undecoded)

`0xC4` is a **heap opcode-introducer**: the byte after it selects the opcode.
Evidence — `C4 <op>` 2-grams are enriched far above chance in `BDEx` heaps
(349 VIs, 166,716 `0xC4` bytes):

| opcode  | count   | in VIs | enrichment vs random | status |
|---------|---------|--------|----------------------|--------|
| `C4 2D` | 104,714 | 338    | ~650×                | dominant record, undecoded |
| `C4 1F` |  38,371 | 338    | ~240×                | undecoded |
| `C4 22` |  12,216 | 338    | ~76×                 | undecoded |
| `C4 19` |   2,750 | 325    | ~17×                 | text-related, undecoded (see negative below) |
| `C4 2E` |   2,514 | 218    | ~16×                 | **string table — CONFIRMED** (above) |

The dominant ones have **regular fixed-shape payloads**, consistent with being a
single record type each: `C4 2D` is followed by `08 00` in 25,441 cases (then a
small signed byte: `08 ff`, `08 01`, `08 fe`, …), and `C4 1F` likewise by `08 00`
(10,588×). Their **semantics are not yet decoded** (only `C4 2E` is), but the
*framing* is — see next.

### `C4 2D` = object bounds rectangle — confirmed ✅ (first decoded payload)

The dominant heap record, `C4 2D` (always `len == 8`), carries an object's
**bounding rectangle**: four big-endian **signed 16-bit** fields in LabVIEW's
order — `top, left, bottom, right` (pixels). Corpus evidence (103,403 `C4 2D`
records): **99%** satisfy `bottom ≥ top ∧ right ≥ left` and have derived
height/width in `[0, 2000)` px; the 8 payload bytes read exactly as 4× `s16`
(each high byte is `0` / `0xFF` / `0xFE`, i.e. small signed magnitudes), and
samples are unmistakably rectangles (e.g. `(53, 581, 91, 696)` → a 115×38
control; nested edge-sharing rects for containers). This is the **position and
size of every control / node / decoration** — real spatial structure.

→ `HeapRecord.bounds` → `HeapRect {top,left,bottom,right, width,height,isValid}`;
aggregated by `ViModel.objectBounds`. (Validated: 409 corpus VIs, 197,753 rects,
99% valid & sane, 0 crashes.) This is the first *semantic* heap payload decoded —
the seed of a read-only layout/graph view.

### `C4 1F` = origin-anchored size rectangle — confirmed ✅

The #2 record, `C4 1F` (always `len == 8`), uses the **same 4× `s16`
`top,left,bottom,right` layout** but is **origin-anchored**: across the corpus
(37,233 records) `top == left == 0` in 99% and **100%** are valid rectangles —
e.g. `(0, 0, 12, 12)`, `(0, 0, 20, 20)`. So it encodes a **size/extent**
(height×width), not a position. This confirms the 4× `s16` rectangle is a reusable
LabVIEW heap primitive shared across opcodes. → `HeapRecord.sizeRect` (kept
separate from `bounds` so positional layout isn't polluted by these sizes);
`HeapRect.fromPayload` is the shared decoder.

### `C4 22` = caption / control-name string — confirmed ✅

The #3 record, `C4 22`, holds a **single caption string** directly: the payload is
the text, sized by the record's own length byte (no inner prefix — unlike the
`C4 2E` string *table*). Corpus evidence (12,079 records): **97%** are fully
printable ASCII, and the content is unmistakably control/parameter names —
`Conversion time`, `Amplitude (mV)`, `Trigger Source`, `Wave Type`,
`error out`. → `HeapRecord.text`; aggregated by `ViModel.captions`. (Validated:
409 corpus VIs, 16,331 captions across 380 VIs, 0 crashes; the ~3% non-printable
payloads return null.) These are the named inputs/outputs/controls of the VI — a
high-value layer for "what does this VI do".

### `C4 19` = description / help text — confirmed ✅ (heuristic extraction)

`C4 19` holds the VI's **description / tooltip help text**, often HTML-ish
(`<B>…</B>`) and multi-line. Corpus evidence (2,728 records): payloads are
length-prefixed text segments (`<u8 len> <text>`, sometimes several per record);
the readable content is unmistakably documentation — e.g. `<B>error in</B> can
accept error information wired from VIs previously called…`. The inner
multi-segment framing is **not fully decoded**, so `HeapRecord.descriptionText`
recovers the text via length-prefixed printable+whitespace runs (≥6 chars) —
**heuristic** (occasional one-char clipping at segment seams), not exact fields.
→ aggregated by `ViModel.descriptions`. (Validated: 409 corpus VIs, 1,838
descriptions across 371 VIs, 0 crashes; total.)

### `C4 5F` = a rectangle of unclear role — partial 🔬

`C4 5F` (len 8) also decodes as a 4× `s16` rectangle (97% `bottom ≥ top ∧
right ≥ left`), but with **negative coordinates and degenerate points** (e.g.
`(-782,-72,-782,-72)`) — so it is a rectangle primitive whose *semantic role*
(offset? sub-region? connector extent?) is **not yet determined**. Documented, but
deliberately **not modeled** (no accessor) to avoid assigning a false meaning.

### Opcode catalog — `HeapOpcode` + `HeapShape` (one source of truth)

All reverse-engineered opcodes live in one documented place: the `HeapOpcode`
enhanced enum in `labwright_videcode/lib/src/heap.dart`. Each value records the
record's meaning, payload layout, corpus evidence, decoding status, and a
**`HeapShape`** (rectangle / string / stringTable / helpText / none) that drives
the generic decoders on `HeapRecord` (`rect`, `text`). Raw bytes map via
`HeapRecord.kind` / `HeapOpcode.fromByte`.

Current catalog:

| opcode | name | shape | status | accessor |
|--------|------|-------|--------|----------|
| `2D` | bounds | rectangle | decoded | `bounds` (position+size) |
| `1F` | size | rectangle | decoded | `sizeRect` (origin-anchored) |
| `2E` | stringTable | stringTable | decoded | `HeapStringTable` |
| `22` | caption | string | decoded | `text` (control name) |
| `27` | plotName | string | decoded | `text` (e.g. `Plot 0`) |
| `74` | formatString | string | decoded | `text` (e.g. `%020b`) |
| `20` | itemLabel | string | decoded | `text` (e.g. `Line 0`, `<None>`) |
| `C4` | symbolName | string | decoded | `text` (C-function, e.g. `ps2000aRunStreaming`) |
| `A4` | path | path | decoded | `path` (`PTH0` DLL path, e.g. `ps5000.dll`) |
| `19` | description | helpText | decoded* | `descriptionText` (heuristic) |
| `4A` | typeBounds | rectangle | decoded | `rect` (DTHP type/terminal bounds) |
| `44` `64` `24` | container* | container | structural | `children` (nested `C4` records) |
| `5F` `4C` `D6` `62` `26` | rect* | rectangle | structural | `rect` (role TBD) |

The `rect*` opcodes are confirmed 4× `s16` rectangles (≈100% valid) whose
semantic *role* is undetermined → generic `rect` only. The `container*` opcodes
wrap nested `C4` children (bounds + sizes + captions) → `children` recurses the
walker into the payload. New opcodes are added here as confirmed. (Validated: 0
crashes; symbolName 616 across 326 VIs, path 351 across 321 VIs, containers 1,339
with 3,138 children — e.g. a VI's decoded SDK calls `psospaSigGenTrigger…` from
`psospa.dll`.)

`ViModel` surfaces the high-value semantic layers: `symbolNames` (the
Call-Library C functions a VI invokes) and `paths` (the DLLs it links) — i.e.
*what hardware/library calls this VI makes*.

### `C4` records are length-prefixed — confirmed ✅ (the walker seed)

Every `C4` record has the shape:

```
C4  <op>  <u8 len>  <len payload bytes>
```

The byte at `offset+2` is a **payload length**, so a record can be framed and
skipped (`skip = 3 + len`) **without knowing its meaning**. Corpus evidence:
- The length byte is fixed per fixed-size opcode: `C4 2D` → `len == 0x08` in
  **104,714/104,714** (100%; an 11-byte record); `C4 5F`, `C4 D6`, `C4 4C` → `0x08`
  in 100%; `C4 1F` → `0x08` in 98%. (`C4 2E`'s length varies because it is the
  variable-size string table.)
- Skipping `3 + len` from a `C4 2D` lands exactly on the next record's opcode byte
  (`0x10`/`0x84`/`0x25`/`0x44`) in **99.97%** of cases — i.e. the length prefix is
  correct, essentially no garbage.

This is the first **generic record framing** for the heap. `labwright_videcode`
ships it as `heapC4Records` → `List<HeapRecord {sectionTag, offset, opcode,
payload}>` (and `heapOpcodeHistogram`). The walker frames each `C4` record by its
length and skips its payload; non-`C4` records — whose length rules are *not* yet
decoded — are stepped over one byte at a time. (Validated: 409 corpus VIs, 293,461
`C4` records framed, 0 crashes; total over arbitrary bytes.)

**Still open (honest limits):** this is not yet a *complete* sequential walker —
until the non-`C4` opcode lengths (`10 xx`, `84 xx`, `14 19 01 fd`, `64 cb`,
`02 fe`, …) are decoded, a `0xC4` occurring inside a non-`C4` record's payload can
frame a spurious record (the scan resynchronizes after). Decoding those non-`C4`
record lengths is the path to a full walker → the node/wire graph.

### The non-`C4` region is *nested*, not a flat record stream — measured ⛔

How far does the self-describing layer get us? Across the corpus, the `C4`
length-prefixed records cover only **23% of `BDEx` bytes** (2.55 MB of 10.65 MB).
The remaining 77% begins at gaps dominated by **`0x10`** (78,928 gaps) and
**`0x84`** (72,929) records. Two hypotheses for these were tested by building a
*sequential* walker (start at the body, skip each record by its rule, measure how
far it gets before an unknown/invalid skip):
- **Flat length-prefixed** (`10 <u8 len> …`, `84 <u8 len> …`, like `C4`): **0%**
  sequential coverage — stalls on the very first such record.
- **Flat fixed-size** (`10`=2, `02`=4, `fd`=3, `14 19 01 fd`=6, …): also **0%** —
  desyncs within ~30 bytes.

The fixed-size walk reveals *why*: after a `10 XX` record comes `01 fb` / `02 fe`
/ `01 fe` — a **`<u8 count> <type-opcode>` sub-list**, i.e. the heap beyond the
`C4` leaves is a **nested, count-prefixed object tree**, not a flat opcode stream.
A correct walker must model that nesting (object → typed field lists → leaf
values), so a flat opcode-length table is provably insufficient. This is the same
wall `pylabview` hit. **We therefore do not ship a sequential walker** (it would
desync and mislead).

What this means for the graph: the reliably-decodable layer is the `C4` leaves —
string tables (labels), and the `C4 2D`/`1F` value records — plus their order.
The IR (Stage 4) will be built from those leaves with **honest partial fidelity**,
not from a fabricated full graph; cracking the nested object/type model is the
long-tail effort that would raise fidelity over time.

### Nesting tree + absolute coordinates — ✅ solved (the keystone)

The heap is a **balanced typed-group tree**, and the rule that makes it balance
(the earlier blocker) is: a **group opens** at a high-nibble-1 opcode
`10/11/12/13 <tag>` *only when the byte after the count is a type tag*
(`FB`/`FE`/`FD`) — this includes object headers (`10 19 02 fe …`) **and** typed
lists (`10 55 01 fb …`); a 2-byte record like `11 10` (non-tag) is *not* a group.
A **group closes** at any high-nibble-0 opcode (`08/09/0a/0b`), **popped
positionally** (the close need not tag-match — some classes close with a different
tag). With this rule the `BDEx` body balances to depth 0 at EOF in **398/398**
bodies, single root in **398/398** (root kind `0x7e`).

The object tree is read off this stack (parent = nearest enclosing object header).
Absolute coordinates compose down the object-ancestor chain: `abs_origin(child) =
abs_origin(parent) + (child localTop, localLeft)`. → `buildDiagram` now sets
`ViHeapObject.parentOid` + `absBounds` + `ViDiagram.roots`/`children(oid)`.
Validated: 398 diagrams, 163,227 objects, **99.7% parented**, 132k with absolute
bounds, single-root 100%, 0 crashes. Terminal-center-inside-parent ≈100% for the
node layer (73% across *all* terminal classes — structure-frame terminals use a
different, already-absolute bounds convention).

**Important correction (this supersedes an earlier claim).** The previously-shipped
"`0x68` = wire, 2,672 wire connections, 100% edge resolution" was an **artifact of
the flat scan**: in the correct tree, `0x68` holds **zero** `14 19 01 fd` refs and
is a **terminal**, not a wire. Those `14 19 01 fd` references are **child-membership
lists** owned by **structure/diagram containers** (`0x53`: 13,163 refs, `0x4c`:
4,425) — i.e. "which oids live in this frame", not signal endpoints. Actual
**dataflow wires are not stored with oid endpoints**, so node→node dataflow edges
are **not** recoverable from ids — an honest negative that replaces the earlier
over-claim. (The wire-segment record itself is unidentified: a quick probe ruled
out `C4 5F` — it is 89% 2-D rects, not 1-D line segments — so a prior "wires are
`C4 5F` bboxes" guess does not hold.)

### `CONP` / `CPC2` — VI interface — partial 🔬

- **`CPC2` = the VI's top-level description** (`[u32 len][ASCII]`), e.g. "This
  example demonstrates how to stream data…". → `cpc2Description` / `ViModel.description`.
  (Validated: 256/409 VIs, 0 crashes.) The non-description `CPC2` variants are a
  compiled cache.
- **`CONP` = connector-pane pattern stub**: a pattern id (`0x3C` = the standard
  4-2-2-4 12-terminal template, constant across this corpus) + a table of MD5/GUID
  **link hashes** — **no per-terminal list**. So the VI's input/output↔control
  binding is **not** recoverable from `CONP`/`CPC2` (it lives in the `FPSE` panel
  heap, not yet decoded). Documented negative.

### Structure sub-diagrams — partial 🔬

Diagram containers (root `0x4c`, frames) carry an explicit **child reflist**
`10 55 01 fb <u16 N> N×(14 19 01 fd <oid>) 08 55` — a **valid forest** (0 duplicate
placements, 17,609 entries) listing ~74% of placeable objects (nodes 100%,
terminals 60–95%; wires/sub-parts/decoration 0%). The **structure→its-frame**
pointer is **not** explicit (only document-adjacency heuristic, ~71%); per-frame
grouping for multi-frame case/sequence is not encoded. Family split: `0x53` =
loop family, `0x52` = case/sequence family (via the `64 cb` subtype nibble);
human labels (While vs For, Case vs Sequence) not pinned without ground truth.

### Block-diagram graph — ✅ recovered (objects + nesting tree)

`buildDiagram(body)` segments the `BDEx` record stream into a nesting tree of
`ViHeapObject {oid, kind, offset, bounds?, absBounds?, parentOid?, label?, refs,
termCount, category, typeKind}`, exposed via `ViDiagram {objects, byId, roots,
children(oid), nodes}` and `ViModel.diagrams`. Objects begin at
`10/11/12 <tag> 02 fe <u16 kind> fd <u16 oid>` (`oid` unique per VI); records
attach to the innermost object: `C4 2D` → bounds/absBounds, `C4 22` → label,
`14 19 01 fd <id>` → a child-membership ref. (See the "Nesting tree" section above
for the validated bracket rule + the correction that `0x68` is a terminal and the
`14 19 01 fd` refs are child-membership, not wire endpoints.)

**Object class catalog — ✅ classified (~97%).** The header `kind` maps to a
structural category (`classifyObject` / `ViObjectKind`): `0x0c`=node
terminal-cluster, `0x12`=node body, `0x53/52/09/7e/4c/11c`=structure/diagram
container, `0x68`+`0x50/51/57/4f/5b`+`0x0a/0b/0d/e0`=terminal, `0x8f/e7/d2`=
decoration. Corpus (correct tree, 163,227 objects): terminal 87,550, structure
47,118, terminalCluster 19,326, node 4,425, decoration 630, **unknown ~2.6%**.

**Object data-type kind — ✅ payload-grounded (`ViTypeKind`).** From attached `C4`
records (`inferTypeKind`): `C4 74` numeric format → numericInt/numericFloat (by
printf conv char), `C4 2E` → enumRing, `C4 A4`→path, `C4 C4`→CLN node. Corpus
(BDEx): enumRing 3,476, numericFloat 295, numericInt 61 (numerics are sparse on
the diagram; CLN/path live in `DTHP`).

**Honest limits (documented negatives):**
- **Dataflow wires are not recoverable as oid edges.** Signal wires are stored as
  *geometry* (no oid endpoints; the wire-segment record is unidentified — `C4 5F`
  was probed and ruled out, being 89% 2-D rects), so node→node dataflow
  edges cannot be resolved from ids. (The `14 19 01 fd` refs are child-membership,
  not wire endpoints — see the nesting section's correction.)
- **functionNode vs subViNode** and **control vs indicator** terminal are *not*
  separable from `BDEx` alone (the subVI symbol lives in a separate name resource;
  both surface as one `kind`).
- bool/string/array/cluster have no payload type signal (frame-`kind` heuristics
  only) — not inferred.
- *(Resolved, was a limit:)* object-local coordinate frames — now composed into
  **absolute coordinates** via the nesting tree (`absBounds`); see above.

### Sequential heap walker — ✅ 100% of `BDEx` decoded (the mastery milestone)

The non-`C4` record families have now been decoded well enough to **walk a `BDEx`
body sequentially** as an ordered record stream. `walkHeapBody(body)` starts after
the leading `u32` content-length and frames each record via `recordSkip` (the
reverse-engineered skip table), stopping only at an opcode it can't frame.

**Result (validated independently on the corpus): mean coverage 100.00%, with full
exact-EOF walks on 398/398 `BDEx` bodies, 0 crashes.** Every completed walk ends
*exactly* at the body length — strong evidence the skip table is correct (no rule
over- or under-consumes). This is the heart of format mastery: the heap went from
~23% understood (the `C4` leaves) to fully traversable. (It reached 93.3% with the
first family pass, then 100% after three more fixes — see below.)

Decoded record families (see `recordSkip` for the exact rules):
- **`C4`** length-prefixed, incl. the **extended-length escape** `C4 <op> FF <u16
  len>` (header 5 bytes) for payloads > 255 — *also fixed in the `C4` scanner and
  string-table parser, which previously mis-framed escaped records*.
- **`84`** = fixed 6-byte RGB color tuple.
- **`10`/`12`/`11`/`0a`** = typed-list nodes (`<op><subop><u8 count><typetag>
  <items>`; tag `FB`→2-byte items, `FE`/`FD`→3-byte items).
- **`14`** = fixed 6-byte (`14 sub 01 fd s16`); **`08`/`09`/`04`** = 2-byte;
  **`24`** = 3, **`44`** = 4, **`64`** = 5 (`64 cb 26`→3); **`02 FE`** = 7.
- **attribute nibble-family** (opcode low-nibble ∈ {4,5,6}): the high nibble sets
  the value width (`2x`→3 … `8x`→6, `Ex`→2, `Cx`→`3+u8len`).

**The final 3 fixes to 100%:** (1) `0x25` is a fixed 3-byte record (the `25 2d`
form is not a counted list); (2) the `FD` value-escape inside `10` typed-lists (an
`FD` item with the high value bit set is 7 bytes, not 3); (3) `0xC6` extended
records use the same `FF → u16` escape as `C4`. With these the walk reaches exact
EOF on every corpus `BDEx`.

### Non-`C4` record families — anchored-decode results 🔬

Using confirmed `C4` record boundaries as **anchors** (the byte right after a
framed `C4` record is a guaranteed record start), the two dominant non-`C4`
families were decoded — validated by skipping the computed size and confirming it
lands on a valid next record:

- **`0x84` = fixed 6-byte record** (`84 <subop> <flag> <r> <g> <b>`), payload is an
  **RGB color triplet** for most subops (canonical LabVIEW palette values
  recovered). Skip = **6, unconditional**. Anchored validation: **91,963/91,963
  (100%)** land on a valid next record. ~16.9% of `BDEx` bytes.
- **`0x10` = typed-list record** (`10 <subop> <u8 count> <typetag> <count items>`):
  typetag `fb` → 2-byte items (size `4 + 2·count`); the `8d`-form `fe` → items
  `02 58 <24|44> 1f …` (flag `24`→5 / `44`→6 bytes). **100,626/100,641 (99.99%)**
  of post-`C4` `0x10` anchors resolve with **0 mismatches**. ~6.5% of `BDEx`.

Combined with `C4` (≈24%), these cover ~47% of a `BDEx` body. **Not yet wired into
a sequential walker** because the body's *first* record is a `10 18 …` `fe`-form
variant not in the validated subset (a from-offset-0 walk stalls there); these
skip rules are confirmed and queued for integration once the leading form +
neighbor families (`08`/`09`/`11`/`14`/`64 cb`) are decoded.

### Front panel (`FPHb`) + type heap (`DTHP`) — map 🔬

- **`FPHb` (front panel)** is **uncompressed** and uses **no `C4` records** — a
  different encoding. In this (sub-VI-heavy) corpus most panels are empty: a shared
  1246-byte template (324 files) = "empty FP"; a 12-byte compact pane form
  `[u16 w0=12][u16 count=1][s16×4 rect]`; and a full form
  `[u32][u32 typeFlags][u32][s16×4 rect]…[Pascal name]` (only ~3 corpus VIs have
  real content). **`FPSE`** carries the per-control record (name + bounds).
  Confirming multi-control panel framing needs a richer corpus (top-level VIs).
- **`DTHP` (type heap) DOES use the `C4` record format** — and holds the
  per-control **type data**: type bounds (`C4 4A`), Call-Library symbol names
  (`C4 C4`), DLL paths (`C4 A4`), and type-descriptor token streams (the
  `08/09/10/11/14/C5` opcodes — a distinct, still-undecoded DTHP grammar). This is
  where front-panel control *types* live and reuse our existing `C4` decoder.

**Type-pool probe — negative (control *type kind* still undecoded):** the classic
flat LabVIEW `VCTP` type-descriptor pool (`[u16 len][u16 typecode]…`) does **not**
exist here — in these compiled VIs `VCTP` is a **4-byte stub in 380/380** files.
Type kind (numeric/bool/string/cluster/…) lives only inside the `DTHP` nested
token grammar (the `02 fe 00 XX` field is *not* a clean type code), so per-control
type recovery needs that grammar cracked — not yet done.

**Front-panel object record (corpus-thin but confirmed):** an object-form
`FPHb`/`FPSE` record is a **fixed 72-byte header then a `u32`-length ASCII name**
to section end: `u32 _, u32 typeFlags @4, u32 _, s16×4 rect @0x0C, …, u32 nameLen
@0x48, name`. `FPSE` carries the per-control name + bounds; the 1246-byte `FPHb`
template is an embedded *pixmap*, not controls. Only ~3 corpus VIs have real
panels, so multi-control framing and the `typeFlags`→kind mapping remain
unconfirmed (needs a top-level-VI corpus).

### Negatives / artifacts (do not model)

`C4`-prefixed opcodes `08 09 10 11 14 C5` are DTHP type-descriptor **token
streams** (nested grammar, no flat field) — left raw. `0x23` is an 8-byte flag
pair (2× `u32`), **not** a rectangle. `0x71`/`0x50`/`0x00`/`0x72` are scan
artifacts / section-local opaque data and are **not** surfaced as records.

*(The non-`C4`, `FPHb`/`DTHP`, and remaining-`C4`-opcode results above were
produced by parallel disjoint reverse-engineering agents and cross-checked against
the corpus.)*

**Preamble probes — partial / negative results (do not over-claim):**
- `C4 19` (2,750×) sits next to multi-line text (help/descriptions) but is **not**
  a simple length-prefixed text field: the text blob that follows has no `u8`/`u16`
  /`u32` length immediately before it in **2,503/2,503** sampled cases. Multi-line
  text contains newlines (`0x0A`), so the Pascal-table scanner fragments it — these
  appear only as low-quality `framed == false` runs. A clean text-field framing is
  **not yet decoded**; we do not ship a guessed one.
- The string *count* is **not** stored adjacent to the table (the length field is
  in *bytes*, not entries). A `u8`/`u16` equal to the run's string count appears at
  *no* offset in an 8-byte window before the run: 0/694 runs (0/158 long runs).
- The bytes *before* `C4` fall into ≥2 recurring families — `…09 2d c4` (dominant)
  and `…24 90 0X c4` (with `X` = 1–9) — strong evidence of distinct owning-object
  framings. But they do **not** cleanly predict the table's content kind (enum vs
  sentence): e.g. `25 09 2d c4` covers both short-label and mixed tables. So the
  owning-object *type code* is **not yet decoded**; `HeapStringTable` records the
  offset to correlate later rather than guessing a kind.
- The `14 19 01 fd <u16>` record's `u16` is **not** a 0-based index (0 VIs show a
  0,1,2,… sequence); values cluster like assigned object IDs. Unconfirmed without
  a cross-reference target, so it is **not** modeled.

**Blocker:** decoding the stream into a node/wire/terminal graph requires the
per-opcode payload-length table (LabVIEW's heap object semantics). Without it the
cursor can't be advanced generically, so the records other than the obvious
repeats can't be reliably framed.

**Empirically confirmed (corpus probes):**
- The stream is **not** a self-describing TLV. Walking it as `[u16 type][u16 len]
  [len payload]` overruns the buffer almost immediately (consumed 115,856 of
  78,579 bytes in only 18 "records") — i.e. bytes 2–3 are not a length.
- The visible `14 19 01 fd <u16>` record is **not** dominant: ~110 occurrences,
  ~0.8% of the body (longest aligned run 24). Framing it alone covers almost
  nothing, and because lengths are type-specific, a "frame-known / skip-unknown"
  walker desyncs at the first unknown opcode.
- Bytes following `0xfd` vary widely (no single record-start marker).

So opcode lengths are **type-specific**: a reliable walk needs the opcode table,
which only emerges from correlating many VIs against known node patterns. We
therefore do not ship a heap walker (it would desync and mislead). This is the same wall `pylabview` hit — even
after years it does not recover executable logic. We therefore **do not
fabricate a graph**; we extract what is reliably framed (version, title,
strings, component sizes) and treat opcode-table recovery as a future,
incremental effort (cross-referencing many VIs and known node patterns).

### Object assembly: bounds ↔ label — confirmed ✅ (first graph-level synthesis)

The ordered `C4` record stream lets labeled objects be assembled: **a labeled
object emits its bounds (`C4 2D`) immediately followed by its label table
(`C4 2E`)**. Corpus evidence: of the framed label tables (2E, ≥2 strings),
**100%** have a `C4 2D` bounds within ±5 records and **99.8%** have it
*immediately preceding* (record-distance −1). (The reverse is only ~15%: most
bounds are unlabeled decorations/nodes/wire segments — expected.)

A bounds object is named by **either** form, both immediately following it:
- a `C4 2E` string *table* (enum/ring items) — 99.8% of tables follow a bounds;
- a `C4 22` *caption* (control/parameter name) — 99.4% of captions follow a
  bounds (100% within ±5 records, distance −1 dominant).

→ `ViModel.objects` → `List<ViObject {sectionTag, bounds, caption, labels, name,
…}>`, assembled by `assembleObjects` (pair each `C4 22` caption or framed `C4 2E`
table with the `C4 2D` within 3 preceding records; one bounds → one name).
Validated: 409 corpus VIs, **27,436 named objects** across 401 VIs (24,561 by
caption + 2,875 by label table), 0 crashes — e.g. positioned controls
`"Trigger Source"`, `"sigGenEnabled"`, `"General AWG Settings"` each with their
`HeapRect`. **Partial and honest**: only *named* objects are assembled (not
unlabeled nodes/wires), so this is a named-control/positioned-item layer, not yet
the full block-diagram graph.

## Stage 4 IR seed — `ViModel` (partial fidelity)

`buildViModel(viBytes) → ViModel` is the single read-only entry point and the
**plug-in point for a future VI→Dart auto-translator** (Stage 5): the translator
consumes a `ViModel`, not raw bytes, so every new heap-decoding result enriches
translation by enriching this model. It aggregates the corpus-validated layers:

```
ViModel { version, title, components[], stringTables[], heapRecords[], labels }
```

Fidelity is **deliberately partial and honest**: because the nested object tree
(~77% of `BDEx`) is undecoded, `ViModel` contains **no node/wire graph** — only
what is provable today (block sizes, version/title, grouped labels, `C4` leaf
records). Typed nodes/wires/terminals are added here as the heap opcode model is
confirmed, never fabricated. (Validated: 409 corpus VIs, 0 crashes; 409 yield a
version, 405 labels, 409 `C4` records.)

## What the layers expose today

- `labwright_viparse`: container summary (`parseVi`) + raw sections (`readViSections`).
- `labwright_videcode`:
  - `decodeSections`/`inflateSection` (decompressed bytes),
  - `decodeVersion` (version+title), `blockComponents` (per-block sizes),
  - `heapStringTables` (grouped, located string tables) / `extractHeapStrings`
    (their flattened view),
  - `heapC4Records` / `heapOpcodeHistogram` (the `C4` length-prefixed record
    stream),
  - `buildViModel` → `ViModel` (the Stage 4 IR seed aggregating the above).

  Decoding the nested non-`C4` object tree into a node/wire graph is the next
  stage; `ViModel` is the structure that graph will land in.
