# VI (`.vi` / RSRC) coverage — what "done" means

The goal (see `CLAUDE.md`) is **total understanding of every byte of every VI**.
That single goal is split into independent, measurable axes. Each is a real
**0–100 %** where **100 % means that axis is genuinely finished** — and the whole
set is listed here up front, so hitting 100 % on one axis is never a surprise
"okay, now part 2". 

> **A VI is fully understood IFF every axis below reads 100 %.**

Some axes refine others (the heap axes zoom into the heap blocks counted by
`blockBytesDecoded`); those are marked, and they only ever *add* detail — the
top-level set still sums to the whole.

All numbers are produced by `tool/coverage.dart` over the **whole** corpus
(`corpus/vi`), written to `corpus/baseline.json` (the regression floor the test
ratchets) and `corpus/vi/REPORT.md` (the human scorecard). Nothing here is
hand-maintained.

## The axes

| Axis | Definition | 100 % means | Latest |
|---|---|---|---|
| `parseOk` | VIs whose RSRC container parses without error / all VIs | the container reader is total over the corpus | 100.0 % |
| `decodeOk` | VIs whose compressed sections all inflate / all VIs | every VI's sections decompress | 100.0 % |
| `containerExact` | VIs whose `ViContainer.parse(b).toBytes() == b` / all VIs | the container wrapper (header, info area, block list, descriptors, name table) is **byte-exactly** understood | 100.0 % |
| `blocksIdentified` | block instances with a catalogued tag / all block instances | every block is identified by type (no unknown tags) | 100.0 % |
| **`blockBytesDecoded`** | inflated block-content bytes in a block type that has a decoder / all block-content bytes | every block has decode logic (byte-weighted) — **the headline "how much is left"** | **69.6 %** |
| `heapFramed` *(refines heap blocks)* | heap body bytes inside a deliberately-framed record / heap body bytes | every heap record's boundaries are recognized | 97.6 % |
| `heapSemantic` *(refines heap blocks)* | heap body bytes in a record with a typed meaning / heap body bytes | every heap record's meaning is decoded | 82.5 % |
| `heapComplete` *(refines heap blocks)* | heaps walked exactly to EOF / heaps | no heap has an undecodable tail | 99.7 % |

`valueKindKnown` (13.5 %) is reported alongside `heapSemantic` as an intermediate
tier — bytes whose value *kind* is known but whose meaning is not. `heapSemantic +
valueKindKnown = classified` (96.1 %) is the "we at least know what shape this is"
figure; only `heapSemantic` counts as done.

## How to read it today

`parseOk`, `decodeOk`, `containerExact`, `blocksIdentified` are already ~100 %:
the **wrapper and inventory are understood**. The remaining work lives entirely in
**`blockBytesDecoded` (69.6 %)** — ~30 % of block bytes sit in blocks with no
decoder yet (e.g. `VICD` compiled code, `DFDS` default data space) — and, within
the decoded heap blocks, in **`heapSemantic` (82.5 %)**. Those two are the
frontier; everything else is a finished axis to *defend*, not advance.

## Notes / tracked work

- Corpus currently lives at repo-root `corpus/vi`. Moving it under this package
  (so VI and Seq corpora are siloed) is tracked with the corpus-slimming work, not
  here.
- `blockBytesDecoded` credits a block as decoded if its type has a decoder; it does
  not yet verify the decoder consumes every byte of every instance. Tightening it
  to true per-instance byte accounting is the natural next refinement (it can only
  move the number down, never up).
