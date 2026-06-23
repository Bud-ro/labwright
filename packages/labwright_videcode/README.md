# labwright_videcode

The decode layer for LabVIEW VI block contents, on the way to a read-only graph
and IR. **Stage 1:** given the raw block sections from `labwright_viparse`,
`decodeSections` / `inflateSection` inflate the compressed RSRC heap sections
(`BDEx`, `DTHP`, `vers`, …) — stored as `[u32 decompressedSize][zlib]` — into
their decompressed bytes, passing uncompressed sections through untouched.
Pure-Dart zlib (via `package:archive`), web-safe, and total: container corruption
raises `ViFormatException`, a bad/short stream falls back to the raw bytes, never
a crash — validated across **435 real VIs** (20k sections, ~2k inflated, ~25 MB
decompressed, zero crashes).

**Stage 2** reads what's *reliably framed* in the decoded blocks: `decodeVersion`
recovers the **LabVIEW version + VI title** from the `vers` block (432/435 corpus
files), and `extractHeapStrings` pulls the human-readable **labels / help text /
value lists** embedded in the heaps (best-effort, deduplicated). The full
block-diagram graph is *not* faked here: the heap body is LabVIEW's opcode-based
object serialization (the genuinely hard format), so structural graph recovery is
the explicit next stage rather than something invented from these bytes.

Part of the Labwright monorepo · BSD-3-Clause.
