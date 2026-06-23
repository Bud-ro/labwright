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
`HeapStringTable {sectionTag, offset, strings}` (offset = run start within the
decompressed section). `extractHeapStrings` is just the flattened, deduped view.
Demonstrated on the corpus: a single table recovers a waveform selector's full
item list — `Sine, Square, Triangle, Ramp Up, Ramp Down, Sinc, Gaussian, Half
Sine, White Noise, PRBS, Arbitrary` — as one group. (Validated: 409 corpus VIs,
9054 tables, 0 crashes.)

**Run-header probes — negative results (do not assume a count):**
- The string count is **not** stored adjacent to the table. A `u8`/`u16` equal to
  the run's string count appears at *no* offset within an 8-byte window before the
  run start: 0/694 runs (and 0/158 long runs ≥4) match. So a table is located by
  its content (the run), not by a length prefix we can read directly.
- Tables *are* preceded by a **byte-identical preamble** that recurs across VIs —
  e.g. every 7-string table is preceded by `…08 19 08 25 09 2d c4 2e 2a`. This is
  strong evidence each table belongs to a fixed object kind, but the preamble's
  field semantics are **not yet decoded**, so `HeapStringTable` records the offset
  (to correlate later) without interpreting those bytes.
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

## What the layers expose today

- `labwright_viparse`: container summary (`parseVi`) + raw sections (`readViSections`).
- `labwright_videcode`: `decodeSections`/`inflateSection` (decompressed bytes),
  `decodeVersion` (version+title), `heapStringTables` (grouped, located string
  tables) / `extractHeapStrings` (their flattened view), `blockComponents`
  (per-block sizes). Heap-graph parsing is the next stage, pending the opcode
  table.
