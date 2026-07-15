# Primitive-node identity

How block-diagram primitive nodes are identified, what distinguishes two
nodes of the same class, and how icon-asset keys must be built so that no
two different-looking nodes ever share an asset. Numbers are full-corpus
censuses (7,524 VIs plus the two snippet repos); the parser-side decode and
its pinned laws live in `packages/labwright_rsrc_parse`
(`lib/src/blocks/growable_prims.dart`, `test/growable_prim_test.dart`).

## Two identity systems

* **primResID prims** (class `0x2F`): the node's identity is the `0x0EA`
  primResID attribute; the box is a fixed 32x32 icon per id. Identity is
  one number — assets key as `prim<id>`.
* **Class-identified growable prims**: no primResID; the *class* is the
  operation and the node grows by terminal rows. The class alone is NOT
  the full visual identity — see below.

## Growable classes: the identity table

Every corpus `0x15` terminal wrapper under these nodes holds either the
class-paired DCO or (Bundle's passthrough slot only) nothing — zero foreign
children corpus-wide. Names are corpus node labels (LabVIEW's default node
name), cross-checked against the open-source pylabview class-tag catalog.

| class | paired DCO | op | corpus labels | pylabview tag |
|---|---|---|---|---|
| 0x34 | 0x35 | Bundle | ×26 | mux / mxDCO |
| 0x36 | 0x37 | Unbundle | ×25 | demux / dmxDCO |
| 0x3A | 0x3B | Build Array | ×74 | aBuild / aBuildDCO |
| 0x3E | 0x3F | Concatenate Strings | ×32 | concat / concatDCO |
| 0x44 | 0x45 | Index Array | ×27 | aIndx / aIDCO |
| 0x48 | 0x49 | Array Subset | ×1 | subset / subsetDCO |
| 0x6C | 0x6D | Compound Arithmetic | ×14 | cpdArith / cpdArithDCO |
| 0x93 | 0x91 | Format Into String | ×37 | printf / printfArg |
| 0xB9 | 0xBA | Replace Array Subset | ×10 | aReplace / aRepDCO |
| 0xBD | 0xBE | Delete From Array | ×7 | aDelete / aDelDCO |
| 0x114 | 0x115 | Initialize Array | ×3 | aInit / aInitDCO |
| 0x172 | 0x173 | Merge Errors | ×113 | mergeErrors / mergeErrorsDCO |

Related but not growable:

* `0x153` (pylabview `decomposeDataValRefNode`, 1,466 nodes, fixed 32x32,
  three `0x155` DCO terminals): comes in two halves balanced in every
  carrying VI (733/733 overall, equal counts in all 556 VIs) — node
  objFlags `0x10000` set pairs exactly with the terminal `0x800000` bit
  on the input, clear with that bit on both outputs. A read/write pair of
  one construct; which half is which is not yet recovered. An asset for
  it must key on the node's `0x10000` bit.
* `0x185`: a single corpus instance (41x49, a `0x52` index-array child, a
  `Size: 0` label); not in the pylabview catalog. Not yet identified.

## Can same-class, same-terminal-count nodes look different? YES

Reference-pixel proof (snippet PNGs are LabVIEW's own 1:1 render; node
boxes cut after registration, compared byte-exact):

* **Build Array t3** has THREE distinct arts — (array-glyph row, element
  row), (element, array), (element, element) — matching the input DCOs'
  `0x10000` objFlags bit 1:1 (witness snippets: ClassChildren,
  GenerateTree, Excel_Variant_Elements, Config_Dump2, …).
* **Index Array t4** (one 2D row group) has two arts: index rows with the
  `0x10000` bit render the hollowed (un-indexed dimension) glyph and the
  output-row glyph follows (witness: Excel_Cell_to_Value). Corpus-wide the
  flagged index rows are exactly the unwired ones.
* **Format Into String t6** has three-plus arts with IDENTICAL flags: the
  growable input row renders the wired TYPE's glyph — `DBL`, `TF`, the
  path glyph (witnesses: example, Page1). Row art is type-composed, not
  fixed per class.
* **Compound Arithmetic** carries a 3-bit mode field in the node's
  objFlags (`(flags >> 17) & 7`). Mode 4 renders the `+` glyph (Add;
  witness: MD5). Observed modes 1/5/6 are unnamed until a reference render
  witnesses their glyphs (5 dominates, on almost-exclusively boolean
  terminals; 1 is boolean-only; 6 numeric). Input DCOs also vary their
  `0x10000` bit (24% of inputs; the invert bubble is the un-verified
  candidate).

Bits proven art-NEUTRAL (byte-identical reference boxes across both
values): `0x40000` on Concatenate-Strings inputs; `0x80000` on the Index
Array node and its index DCOs; the node-level `0x10000` on Build Array /
Initialize Array (it shadows "any row flagged", with 110 corpus
exceptions — the row bits are the truth).

## Variant keys

`growablePrimVariantKey` (parser) renders the identity as one char per
terminal wrapper in heap order — `o` output, `i` input, `p` DCO-less
placeholder, `I` input with the row-mode bit — prefixed `m<mode>_` for
Compound Arithmetic. Corpus census of the key space:

| class | op | nodes | distinct variant keys | top keys (count) |
|---|---|---|---|---|
| 0x34 | Bundle | 1662 | 17 | `opii` (639), `opiii` (473), `opiiii` (177), `opi` (168) |
| 0x36 | Unbundle | 1088 | 17 | `ioo` (394), `iooo` (269), `ioooo` (187), `io` (157) |
| 0x3A | Build Array | 3721 | 60 | `oIi` (1439), `oi` (641), `oII` (492), `oii` (339) |
| 0x3E | Concatenate Strings | 2067 | 10 | `oii` (1230), `oiii` (592), `oiiii` (91), `oi` (58) |
| 0x44 | Index Array | 3527 | 23 | `ioi` (2837), `ioioi` (427), `ioioioioi` (58), `ioioioi` (56) |
| 0x48 | Array Subset | 241 | 2 | `Ioii` (205), `Ioiiii` (36) |
| 0x6C | Compound Arithmetic | 1110 | 45 | `m5_oiI` (333), `m5_oii` (219), `m5_oiii` (167), `m5_oIi` (98) |
| 0x93 | Format Into String | 1584 | 12 | `IIoIoi` (1030), `IIoIoii` (360), `IIoIoiii` (110), `IIoIoiiii` (43) |
| 0xB9 | Replace Array Subset | 377 | 5 | `ioii` (332), `ioiii` (26), `ioiIi` (9), `ioiiI` (8) |
| 0xBD | Delete From Array | 654 | 3 | `oiioi` (633), `oiioiI` (13), `oiioIi` (8) |
| 0x114 | Initialize Array | 419 | 2 | `ioi` (374), `ioii` (45) |
| 0x172 | Merge Errors | 1423 | 11 | `oii` (1077), `oiii` (153), `oi` (137), `oiiii` (31) |

Notes on reading the keys: Index Array's row grouping is visible in the
char sequence itself (2D = consecutive `i` index rows after one `o`;
twice-1D interleaves `o i o i`), so the `0x200000`/`0x400000`
dimension-bracket bits need not appear in the key. Array Subset's
`0x80000`/`0x20000` per-pair variation is not yet decoded (TODO:
art-correlate when the snippet corpus witnesses both values); until then
its keys under-split and the multi-art tripwire below is the guard.

## Asset naming scheme

Replace `class<code>_t<count>` with:

```
class<code>_<variantKey>.png        e.g. class58_oIi.png, class108_m4_oiiii.png
```

* `<code>` stays decimal (matching the existing `class58`/`class68`
  filenames).
* The terminal count is the key's length — `t<count>` is redundant and,
  as Index Array t4 vs t5 shows (both 32x35, different arts even at equal
  height), was never the identity.
* The **multi-art tripwire stays**: two or more disagreeing web-safe
  border-exact rect groups on ONE key = the key under-splits (fail, ship
  nothing). It is the guard for every bit not yet proven art-relevant
  (Array Subset's pair bits, Compound Arithmetic's input `0x10000`).
* **Type-composed rows** (proven for Format Into String; expected for
  Bundle/Unbundle element rows — not yet reference-verified): a monolithic
  asset per key is wrong whenever row art tracks the wired type. For
  those classes the box must be composed (fixed chrome + per-row type
  glyph cells) or the asset key must additionally carry the resolved
  row-type vector; an asset extracted from one sample must never stamp
  onto a node whose row types differ.
* Unwitnessed variants get NO asset (an absent icon beats a wrong one);
  the manifest lists them as identities without a usable asset.

## Soft-edged (non-rect) primResID icons

`prim1052` (Multiply), `prim1070` (Random Number), `prim1112`
(Empty String/Path?) and the other triangle/dice glyphs have anti-aliased
edges: on the white diagram ground an edge pixel is icon-colour blended
over white. Border-exact extraction cannot apply (no rectangular ring),
and opaque trimming bakes wires and halo into the asset. The recovery that
matches the evidence:

1. **White-matte unmixing**: treat each pixel as `art OVER white`;
   `alpha = 1 - min(r,g,b)/255` for dark-on-white art (exact for the grey
   AA fringe of black strokes), colour = `(pixel - (1-alpha)*white) /
   alpha`. Ship straight-alpha PNGs; the painter already composites.
2. **Ink-inside-box gate**: after unmixing, any pixel with `alpha > 0`
   outside the node's model box (+1 px AA slack) is wire/neighbour
   contamination — erase if wire-thin, else fail the key.
3. **Per-pixel validation**: recomposing the shipped asset over white must
   reproduce the reference crop byte-exact on every sample that voted for
   it.

## primResID naming status

250 distinct primResIDs observed corpus-wide; 129 catalogued in `PrimOp`
(basis: corpus label, palette-run adjacency, or icon glyph read off the
snippet reference render — see the `prim_ops.dart` library doc). Corpus
label mining is exhausted: zero uncatalogued ids carry a default-name
label. Remaining hypotheses that do NOT meet the evidence bar (kept here,
not shipped): 1056 measures as the only 2-in/2-out integer arithmetic op
(Quotient & Remainder's shape); 8083's icon is a folder-with-listing
pictogram (List Folder's shape, but the measured 4-in/4-out arity is not
the documented 3/2).
