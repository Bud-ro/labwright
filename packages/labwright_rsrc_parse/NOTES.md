# labwright_rsrc_parse — decode notes

Format/decode findings that don't have a natural home in code (the corpus-percentage
floors live in the test assertions; named constants and per-field meanings live in the
`///` docs). This file is for the cross-cutting observations and the still-undecoded
edges. Percentages are corpus-probed; re-probe before relying on an exact figure.

## Heap record walk
- The hi-nibble 0/1 typed-list/token family in `recordSkip` is what lifts whole-corpus
  heap-walk coverage from ~41% to ~99% (framing those records advances cleanly with no
  desync). The ~0.36% of heap sections that stop early do so on diverse lead bytes (no
  single dominant opcode — consistent with an upstream record-size desync) and can leave
  a large tail, so aggregate heap *byte* coverage is ~93%.
- `heapDecodeTier`: group-close brackets are ~9% of semantic bytes; the close
  interpretation is inferred from open/close family pairing, not independently pinned
  per record.

## Block diagram object classes (`graph.dart`)
- `0x53` is the only genuinely dual-role class: ~5745 BD loops that own a `0x11c`
  viewport **and** ~21993 FP containers. A section-blind "Loop" label would mislabel the
  ~22k FP objects.
- `0x12` and `0x4c` appear 0 times in decoded BD object trees, so their legacy BD names
  ("function node" / "diagram frame") are misattributions — label only the observed FP role.
- `0x52` owns no `0x11c` viewport on either section (flat-container profile like `0x64`),
  so it is section-consistent, not dual-role.
- Structural node fallback reclassifies ~1953 still-unknown objects across ~22
  low-frequency BD-node kinds (gate: drawable, parent `0x1b`, has `0x15`, no `0x68`,
  under the structure-area cap `_structureAreaCap`).
- Help-text up-propagation: ~97% of help-bearing objects have a drawable ancestor; ~25%
  of landings are on a non-control drawable (predominantly a `0x53` structure) — intentional,
  since the walk takes the *nearest* drawable.

## Sections still partly undecoded
- **FTAB**: the per-font metric region is exactly `count*16 - 4` bytes across all corpus
  FTABs — a 12-byte metric record per font plus a u32 between adjacent fonts (`count-1` of
  them). The inner metric fields and that u32 value are not yet decoded.
- **FPTD**: overwhelmingly a 2-byte u16 (3119/3123 corpus). It likely indexes the VCTP
  type pool, but — unlike CONP — that mapping is NOT corpus-verified for FPTD.
- **TM80**: the large (non-short) form appears to be a `count==0` form seen in VIs without
  a VCTP. Entry semantics remain undecoded. (Low confidence.)
- **DTHP**: the name-table `headerValue`'s exact meaning is still TBD; only the bound
  (`< dataSize`) is locked, so a misread surfaces.

## Container layout
- `meta.dart` `_FramedTable.headerLen` is measured from the introducing `C4` byte and is
  **3 or 5** (5 for the `C4 2E FF <u16>` extended form) — not "2 or 3".
- `ViInfoArea.parse` caps the descriptor-span scan at `infoArea.length ~/ 20` records and
  breaks on the first out-of-range descriptor, so a hostile `sectionCountMinus1`
  (e.g. `0xFFFFFFFF`) can't spin ~4e9 times.
- **LIBN** (owning-library name) and **VINS** (embedded sub-VI) descriptors carry `@16 == 0`
  rather than `0xFFFFFFFF`, so `readViSections` does not extract their section bytes — use
  `readEmbeddedSections`. They still appear in the block inventory.

## Wire geometry (block diagram) — open frontier

The one thing the BD render cannot yet draw honestly. Corpus-refuted
hypotheses (see `tool/probe_wires.dart` + `tool/probe_wire_blobs.dart`):

- **Terminal typed-refs**: 0/2699 sampled `0x68` terminal objects carry any
  ref (typed or raw) — connectivity is not stored on terminals.
- **C4 point-list records**: 0/22557 BD C4 records read as >=3 plausible
  i16 coordinate pairs — wire polylines are not framed C4 payloads.
- **Blob attributes**: BD heap blob attrs surface only printable text; no
  binary point runs.

**RESOLVED — wires found.** The rect-aliased-segment candidate was right:
class `0x1d` is the wire-segment object. Corpus evidence (7584 VIs):

- 61673 `0x1d` instances, **BD-only** (0 FP);
- 61396/61396 rect records attached at the object's own level are
  **degenerate lines** (top == bottom — one horizontal Manhattan run each);
- a multi-segment wire is a run of consecutive `0x1d` siblings whose
  endpoints chain (4741 exact end-to-start links measured in one source);
  the vertical connector between consecutive runs is implicit;
- the earlier "heap-framed 2.4% gap" candidate dissolved: it is ONE file
  (an embedded bitmap row pattern), not wires.

Catalogued as [HeapObjectClass.bdWire] → `ViObjectKind.wire`; the inspector
draws each segment plus the implicit connectors. Still not decoded:
- the wire's **datatype** (for LabVIEW's per-type wire colors/patterns);
- the **endpoint→terminal binding** (which terminal each wire end attaches to);
- the **absolute-coordinate anchoring**: visually verified renders show some
  wire runs landing far outside the diagram when composed like object
  bounds, so wire coords are relative to a different ancestor frame — probe
  which one before trusting wire positions.
