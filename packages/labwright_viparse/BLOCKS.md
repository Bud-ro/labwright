# LabVIEW RSRC block catalog

A developer reference for the 81 resource-block tags Labwright recognises in a
`.vi`, generated from `lib/src/block_catalog.dart` (the authoritative source —
keep this doc in sync with it). Each block is classified by a coarse
**category**, a clean-room **confidence** (`confirmed` = corpus-verified or
self-identifying; `likely` = strong convention; `tentative` = best-effort name,
format not yet decoded), and — where one exists — a **decoder**.

Look up any tag at runtime with `blockInfo(tag)` → `ViBlockInfo`
(`name`, `category`, `confidence`, `note`); `isRecordHeapTag(tag)` is the
load-bearing predicate that gates the C4 heap record-walk.

## Honest limits (what is NOT recovered)

- **Signal wires / node→node dataflow / execution order** are not in the file
  (LabVIEW stores wires as geometry, not endpoints) — never reconstructed.
- **DFDS** (default data space) is serialized per the VCTP type order with no
  self-describing header; decoding needs a full type-size walk — not yet done.
- Many small `tentative` blocks are per-VI opaque blobs (GUIDs / signatures /
  state) whose *value* is opaque even when size/role is known.
- Coverage figures are corpus counts over ~7583 VIs; "not yet decoded" is used,
  never "unrecoverable".

## Decoded blocks (have a decoder)

| Tag | Name | Category | Conf. | Decoder | Notes |
|-----|------|----------|-------|---------|-------|
| FPHb / BDHb | FP / BD heap | recordHeap | confirmed | `walkHeapBody` / `buildDiagram` | C4 record heaps (7568/7568); the object graph |
| FPHc / BDHc | FP / BD heap (variant c) | recordHeap | confirmed | `buildDiagram` | C4 heaps (14/14) |
| VCTP | VI type pool | typeInfo | confirmed | `decodeTypePool` | `[count][type records]`; the VI's data-type dictionary |
| TM80 | Type map (LV 8.0+) | typeInfo | likely | `decodeTypeMap` | short form `[u16 count][u16 field1][count u16]` (~71%); entry semantics open |
| DTHP | Data-type heap | typeInfo | likely | `decodeDataTypeHeap` | 4-byte `[u16][u16]` header (99.45%) + rare `40xx` named-item form |
| CONP | Connector pane | connectorPane | confirmed | `decodeConnectorPane` | u16 **VCTP index** of the conpane type (100% in-range) |
| CPC2 | Connector pane (compiled) | connectorPane | likely | `decodeConnectorPane` | distinct 2-byte ref; resolves as a VCTP index only ~84% (NOT confirmed) |
| icl8 / icl4 / ICON | Legacy icon (8/4/1 bpp) | icon | confirmed | `decodeLegacyIcon` | 32×32 bitmaps (1024/512/128 B); ICON is a real bitmap, not a name table |
| MNGI | PNG image | image | confirmed | (PNG magic) | `89 50 4E 47` |
| STRG | VI description text | text | confirmed | `decodeStringBlock` | `[u32 len][UTF-8]` (100%) |
| HLPT | Help tag/text | text | confirmed | `helpTextFromSections` | same `[u32 len][UTF-8]` as STRG (200/200) |
| HLPP | Help path | helpPath | confirmed | `decodeHelpPath` | PTH0 path (128/128); `decodeHelpPath` also parses DLLP/RTMP PTH0s |
| LVSR | LabVIEW save record | settings | confirmed | `decodeSaveRecord` | version word @0 (==vers 99.95%) + BD password hash @96 (==BDPW) |
| vers | Version record | settings | confirmed | `decodeVersionWord` | `[BCD major][minor<<4\|patch][stage][build]` + ASCII version/title |
| FTAB | Font table | nameTable | confirmed | `decodeFontTable` | `ver@0=1, count@6, u32 nameOffset@8`; metric region (12..nameOffset) is `count*16-4` B = count 12-B metric records interleaved with count-1 u32s (322/322); then packed Pascal font names |
| HIST | Revision history | history | confirmed | `decodeHistory` | 40-byte record: version@0=2, flags@4, entryCount@8, reserved@12/28/32 |
| NUID / SUID / BNID | UID tables | identifier | confirmed | `decodeIdTable` | `[u32 count][count u32 ids]`, len==4+4·count (100%); id values opaque |
| VINS | Embedded sub-VIs | embeddedVi | confirmed | `readEmbeddedVis` | nested RSRC VIs |

## Byte-layout known, framed per-byte in the inspector

These have no standalone viparse *decoder*, but their on-disk byte layout is
corpus-verified and the inspector's hex view frames every byte (the per-block
"% framed" readout). Percentages are corpus shares (vi_diverse, ~7k VIs),
re-verified by an adversarial review:

- **TITL** — VI window title as a Pascal string `[u8 len][ASCII]`; `1+len == sectionLen` in 897/897 nonempty sections (100%).
- **CPST / CPSP** — string-label tables `[u32 count][count × [u8 len][ASCII]]` (boolean / comparison / report labels, e.g. `True`, `Equal (Value)`); parse end-aligned in 56/56 and 53/53 sections; empty slots are len-0 strings.
- **FPTD** — a u16 type index in the 2-byte form (3119/3123 = 99.9%); likely a VCTP index but that mapping is **not** corpus-verified for FPTD, so it is not resolved. The 4 larger forms (290–378 B) have no confident layout.
- **FPSE / BDSE** — section-marker words, one u32 per 4 bytes (4 B in 7155/7173 = 99.75%; a rare 8-byte form carries two). Value role (size/offset/flags) not yet decoded.
- **MUID** — a single u32 (7173/7173 = 100%); opaque unique-id value.

## Identified but undecoded / opaque-value blocks

- **typeInfo/data:** VICD (compiled i386 code, opaque), DFDS (type-directed, deferred), DSIM (near-constant data image), DSTM.
- **icon/image:** PICC (12-byte icon record; the colour RGB icon is via `extractRgbIcon`), PICT (Mac PICT), WEMF (Windows EMF).
- **link/help:** LIvi/LIfp/LIbd/LIds (link info; embed ASCII `LVIN`/`FPHP`/`BDHP`/`VIDS`), LPIN, DLLP (PTH0), HLPU/HLPX/HLPW.
- **text:** STR.
- **security:** BDPW (MD5-style password hash; `d41d8cd9…` = empty password).
- **name tables:** VITS.
- **identifiers/signatures** (size+role known, value opaque): RTSG/OBSG (per-VI 16-byte sigs), CCSG/SCSR (near-constant shared sigs), GCPR (13-byte const), GCDI, OMId/RSID (rare).
- **section markers / small records:** FPEx/BDEx (small near-const), VPDP/DLDR/GCPR (fixed-size byte-constant), CCST, BKMK (bookmarks), CNST (u32-pair table), CPD2 (u16), CPMp, FPTS/BDTS, FPHP/BDHP (rare legacy), `PRT ` (note the trailing space), TRec, BFAL, IPSR, CPTM, GTMI, HBIN, HBUF, COUT (12-byte per-VI), RTMP.

See each tag's `note` in `block_catalog.dart` for the precise corpus evidence.
