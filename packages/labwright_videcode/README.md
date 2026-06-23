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

**Stage 2** reads what's *reliably framed*: `decodeVersion` (LabVIEW version + VI
title), `cpc2Description` (VI description), and grouped/located heap strings —
control labels, captions, help text, plot/format strings, plus the embedded
**library paths** and **Call-Library C-function names** a VI invokes.

**Stage 3 — the heap is decoded.** The block-diagram heap (`BDEx`) is LabVIEW's
opcode-serialized object format; it is now reverse-engineered (clean-room, from the
public sample corpus only) to a high degree:
- a confirmed opcode catalog (`HeapOpcode`) + a record **walker** (`recordSkip` /
  `walkHeapBody`) that covers **100%** of every corpus `BDEx` body;
- `buildDiagram` → a **`ViDiagram`** graph of objects with a **nesting tree**
  (`parentOid`, `roots`/`children`) and **absolute coordinates** (`absBounds`),
  each object **classified** (`ViObjectKind`: node / terminal / structure /
  decoration) and **typed** (`ViTypeKind`: numeric / enum / path / CLN node);
- aggregated by `buildViModel` → **`ViModel`** — the read-only IR a future
  VI→Dart translator plugs into.

Everything is **honest and total**: validated across the corpus (0 crashes), and
the genuine limits are documented, not faked — e.g. signal **wires are geometry
only** (no recoverable node→node edges), and `function`-vs-`subVI` is not
separable from `BDEx` alone. See `docs/vi-rsrc-and-heap-format.md` for the full
reverse-engineering record.

Part of the Labwright monorepo · BSD-3-Clause.
