# labwright_videcode

The decode layer for LabVIEW VI block contents, on the way to a read-only graph
and IR. **Stage 1:** given the raw block sections from `labwright_viparse`,
`decodeSections` / `inflateSection` inflate the compressed RSRC heap sections
(`BDEx`, `DTHP`, `vers`, …) — stored as `[u32 decompressedSize][zlib]` — into
their decompressed bytes, passing uncompressed sections through untouched.
Pure-Dart zlib (via `package:archive`), web-safe, and total: container corruption
raises `ViFormatException`, a bad/short stream falls back to the raw bytes, never
a crash — validated across **435 real VIs** (20k sections, ~2k inflated, ~25 MB
decompressed, zero crashes). The heap-tree parser, VI graph model, and IR /
Dart-codegen layers build on top.

Part of the Labwright monorepo · BSD-3-Clause.
