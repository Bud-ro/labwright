# LabVIEW `.vi` (RSRC) format — reverse-engineering notes

Clean-room notes derived **solely from `.vi` binary files** (the public Pico
NI-LabVIEW example corpus), not from LabVIEW itself. These document what
`labwright_viparse` + `labwright_videcode` decode today and what blocks full
block-diagram graph recovery.

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
