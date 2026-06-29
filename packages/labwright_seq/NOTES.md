# labwright_seq — decode notes

Findings that don't have a natural home in code. The XML and INI readers reach the typed
`SeqFile` model; the **binary TOF1** record grammar is the open frontier (see below).
Counts are corpus-probed (288 binary, 26 XML, 58 INI at last fetch); re-probe before
relying on an exact figure.

## Binary TOF1 record grammar — current recon (still undecoded)
The body inflates and the string pools / name table / object names / module paths / ID#
refs / expressions / literals all extract, but the **record grammar that links them into
the hierarchical PropertyObject model is not yet decoded**. What is known:

- `leadingWords[2]` (3rd u32) is a **constant 1** across all 288 binary files. The record
  stream opens by referencing the name pool by index: `word[2]==1` selects `name[1] == 'Data'`.
- `leadingWords[1]` is **not** a two-valued `{16,118}` layout selector (that earlier
  hypothesis was overfit to the small NI-example set and is refuted). It takes many values
  (16, 18, 20, 118, 256, 272, 276, …). The record-prefix structure past the header is
  undecoded; `leadingWords[0]`'s meaning is likewise open.
- Name pool: the name table is **never reliably the largest** segment, and the largest
  segment is **not reliably the expression table** (both refuted). Expression-like strings
  live in a segment other than the name table.
- The name scaffold `[SequenceFileData, Data, Objs, Seq, [0]]` is dominant (>95%) but **not
  universal** — other roots occur, e.g. `[…, Data, Attributes, Obj, TestStand]`.
- Candidate record shape: an object-record triplet `[u32 name-index][u32 field][u32 count]`
  preceded by a `0x00000000`/`0xffffffff` boundary. It is a real but **noisy** signal —
  real-name indices match ~86% vs a ~40% control — so it corroborates the record shape but
  is not yet clean enough to extract objects byte-exactly.

### Record-region structure (Rosetta alignment, `tool/rosetta_probe.dart`)
**Two classes of Rosetta pair** (`tool/fetch_rosetta_pairs.sh`):
- **Structural twins** — the same NI measurement workflow saved by the LabVIEW (binary) vs
  Python (XML) toolchains: `NIDmm`/`NIFgen`/`NIScope` (TS 2021 SP1) and `DmmHAL`/`SmuFAL`
  (TS 2023 Q4, from NI's abstraction-layer plugin). **Not byte-identical content** — e.g.
  NIScope's binary uses different step names than its XML twin ("Update pin map" matches, but
  "Acquire a waveform…"/"Destroy and unregister…" exist only in the XML). These validate
  *structure* (sequence/section/step counts, the standard property set), not exact content.
- **Content-exact twin** (`OutputVoltage_BIN.seq` / `OutputVoltage_XML.seq`) — the *same
  file* (`OutputVoltageMeasurement_example.seq` in ni/measurement-plugin-python) that git
  history shows re-saved binary→XML in one commit (PR #1258). This is the real decode
  **oracle**: the binary name table walks in exact XML-tree order
  (`SequenceFileData → Data → Objs → Seq → [0] → Sequence → MainSequence → Obj → Parameters
  → Locals → ResultList → …`). The *only* known content delta is a bundled Python version
  bump (3.9→3.10), so expect one or two differing leaf strings. Found via a web/GitHub
  research sweep; no other content-exact public twin was located, and NI's own binary format
  is publicly undocumented with no open-source TOF1 parser in any language. We deliberately
  do **not** use TestStand product-install dumps or
  unlicensed third-party test programs — only NI's MIT-licensed example repos.

Aligning the NIScope binary against its XML twin established more of the encoding (verified
on the bytes, not yet a full grammar):
- **Names are cited by string-region-relative byte offset**, not by index. A record word
  whose value equals `name.offset - recordRegionLength` references that name (e.g. word
  value `22` → `Objs` at rel-offset 22). This is the reference scheme the working
  `binaryNamedScalarRecords` / `binaryNamedRecords` decoders already use.
- **The record region is BYTE-PACKED, not u32-aligned** — this is the real reason a
  fixed-stride walk desyncs. Hard evidence: the type-def marker `0x6259ecd3` occurs 15×,
  but **8 of the 15 sit at non-u32 byte offsets** (e.g. NIScope: `@93` (b1), `@359` (b3),
  `@3210` (b2), `@16614` (b2)). Fields are a mix of u32, **u16** pairs (e.g. the
  `18 00 48 00 18 00 48 00` runs of `(0x18, 0x48)`), and 8-byte little-endian **f64**
  values, packed back-to-back with no alignment padding. The grammar must be walked
  byte-by-byte with per-record length, not as a flat u32 array.
- **Layer boundary**: the 15 type-def records run from byte 24 to the last marker at
  byte ~16614 (NIScope, `rr`=29602), with byte sizes (inter-marker gaps) 24…9997; the
  object-instance layer follows. Type-defs are byte-identical across same-template files
  (so the 15-record type layer is shared boilerplate).
- **Object names**: reused property/container names (`Parameters`, `Locals`, …) are cited
  from the shared pool by rel-offset; a step's own name is in the pool too but is not cited
  the same way (no u32 rel-offset reference to it appears in the records — it is reached
  by some other index/inline mechanism still to be decoded).
- **Verified value record**: at the `Parameters` container, the name-offset word is
  followed two words later by an inline f64 — e.g. NIScope carries `8192.0` as
  `00 00 00 00 00 00 c0 40` immediately after the `Parameters` reference. This is the shape
  `binaryNamedScalarRecords` recovers.
- **Two layers, type-defs then objects**: the stream emits a TYPE-DEFINITION layer
  (structural names the XML hides — `ArrayClusterEls`, `TEResult`, `StepType`, with fixed
  following type words like `0x1200`/`0x1300`) separately from the OBJECT-INSTANCE layer, so
  the binary name order does **not** match the XML DFS order. Recurring record markers:
  a `1c 00 00 00` (=28) record tag and an `18 00 4d 00` (`u16 0x18, u16 0x4d`) type
  descriptor before string-valued/typed slots.
- **Type-definition record marker `0x6259ecd3`** (a global constant, the same in every file
  — NOT per-file): it prefixes each type-definition record's fixed header
  (`…, 0x6259ecd3, 0, 23, 18, 19, 0x02000004, …`). It occurs **exactly 15×** in each of the
  three Rosetta binaries, with **byte-identical inter-occurrence gaps** (min 69, max 9997)
  across all three — i.e. the 15 standard type definitions are byte-identical in files built
  from the same NI plugin template. This delimits the type-def layer and is the most
  promising anchor for a desync-free record walk. (`tool/magic_probe.dart` checks this.)
- **Still open** — the blocker is the **byte-level per-record length** so the byte-packed
  records can be walked without desync. Concrete next step: walk the 15 type-def records
  from byte 24 (each delimited by `0x6259ecd3`) to learn the type→field-layout table, then
  use it to size object records in the instance layer and reconstruct the PropertyObject
  tree, validating *structure* against the Rosetta twins (counts, not exact names). Until
  that walk is byte-exact, `parseSeqFile` keeps **refusing** binary rather than emitting a
  fabricated partial tree. (`tool/annotate_probe.dart` dumps the annotated stream;
  `tool/magic_probe.dart` lists the type-def record sizes.)

## INI reader
- `_IniBuilder.build` produces members in a deterministic order: instance `DEF` declarations
  first (authoritative + typed), then value-only members, then members implied by deeper
  sections, then members inherited from the type but never mentioned.
- The `if (eq < 0) continue;` in `parseIniSeq` is purely defensive: no section line lacks a
  ` = ` separator in any corpus INI file (verified and guarded by a corpus test).
