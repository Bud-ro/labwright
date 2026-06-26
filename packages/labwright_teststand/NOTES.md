# TestStand reader — format notes & scratch

Clean-room RE notes for NI TestStand files, derived **solely from real `.seq`
binary/text files** (the pinned corpus in `corpus/seq-sources.json`), not from
TestStand itself. Mirrors `apps/labwright_vi_inspector/NOTES.md` for the VI side.
Structure lives here; live metrics belong in tooling (not yet built for seq).

## M0 reconnaissance — what a `.seq` actually is (confirmed on the corpus)

A TestStand 4.0+ sequence file holds the same logical content — sequences, the
set of types it uses, and shared global variables — in one of **three encodings**.
All three were/are offered by NI; which one a file uses is a save-time choice.

| encoding | recognized by | confirmed | notes |
|---|---|---|---|
| **XML** | optional UTF-8 BOM `EF BB BF`, then `<?xml …?>`, root `<teststandfileheader …>` | ✅ M0 | text; the common form in open-source NI examples |
| **binary** | ASCII magic **`TOF1`** at offset 0 | ✅ M0 | NI proprietary flat container; default for size/speed |
| **INI** | INI sections + a TestStand marker | ✅ header + tree + **typed lens** (parseSeqFile→SeqFile) | 58 samples; `seq_ini.dart`; 56/58 → 441 seq / 5515 steps / 2123 module bindings via the shared lens; app rendering + %TYPES resolution TODO |

### XML form (decoded enough to parse next)

```
EF BB BF                                  (UTF-8 BOM, optional)
<?xml version="1.0" encoding="UTF-8"?>
<teststandfileheader type='SequenceFile' fileversion='920' productname='TestStand' ...>
  ... element tree: sequences, steps, properties, types, globals ...
```

- `type` = file kind (`SequenceFile`, `TypePaletteFile`, …).
- `fileversion` = format/engine stamp; corpus shows `920` (TS ~2017) and `962`
  (newer). Attributes use **single quotes**.
- Self-describing → M1 is a straightforward XML tree walk into the typed model.

### Binary form (`TOF1`) — header only, grammar undecoded

```
00  "TOF1"                                magic (NOT OLE2/CFBF — ruled out)
04  6 bytes                               reserved/zero (role TBD)
0A  <NUL-terminated ASCII>                file-type token, e.g. "SequenceFile"
..  "TestStand" … "2019" …               product/version ASCII appear later
```

Offsets past the file-type token are **not yet decoded** — the record grammar is
the work of M1/M2. The header magic + type token are confirmed across real-world
(`caizikun`) and TS2017/2019 example (`joshuaprewitt`, `bienieck`) files.

## Implication for milestones

XML and binary are *two encodings of one model*. Plan: decode the **XML** tree
first (M1) to establish the typed `SeqFile → sequences → steps → properties`
model and the viewer/export against a known-good structure, then map the **binary
`TOF1`** container onto that same model (M2+). This de-risks the model design
before tackling the proprietary binary, and gives a cross-check (the same example
may exist in both encodings).

## M1 — XML decode (done): the PropertyObject schema

A TestStand XML file is one big **PropertyObject tree**. Every node is one
property, serialized as an XML element:

- **name** = the `name=` attribute when present (array elements, and the
  `_NAME_IN_ATTRIBUTE_` placeholder tag used when the name isn't a legal XML
  tag), otherwise the element tag itself.
- **classname** = the value-kind: `Bool`, `Str`, `Number`, `Obj`, `Objs` (object
  array), `Nums`, `ExprValue`, `ArrayDimensions`, …
- **typename` / `xsi:type** = the TestStand type (e.g. a step's `Statement`,
  `MessagePopup`, `SequenceCall`; a custom data type).
- content is exactly one of: a leaf `<value>` (entity-decoded scalar), an array
  (`<value lbound ubound>` wrapping N `<value>` element wrappers), or
  `<subprops>` (named child properties).

File skeleton and the sequence/step path (confirmed on the corpus):

```
<teststandfileheader type='SequenceFile' fileversion='…' productname='TestStand'>
  <typelist> <typedef> <TypeRoot classname='…'> … </typedef> … </typelist>
  <Data> <subprops>
    <Seq classname='Objs'>            # array of sequences
      … <Sequence name='MainSequence'> <subprops>
          <Setup   classname='Objs'>  # array of steps
          <Main    classname='Objs'>
          <Cleanup classname='Objs'>
          <Locals> <Parameters> …
        </subprops> </Sequence> …
  </subprops> </Data>
</teststandfileheader>
```

A **step** is an array element `<Step typename='Statement' name='Pass'>`: its
display **name** is the `name=` attribute, its **type** is `typename`/`xsi:type`.
The step's config (preconditions, looping, pass/fail actions, …) lives under the
step's `TS` sub-container; step-type-specific data under `TS > SData`.

Reader: `parseSeqFile(bytes)` → `SeqFile` (header, `types`, `data`) with a typed
lens `SeqFile.sequences` → `Sequence` → `setup/main/cleanup` → `Step{name, type}`.
The full `SeqProperty` tree is retained for total visibility. XML is tokenized
with `package:xml`; the `SeqProperty` model + typed lens are owned. Corpus:
**20/20 XML files parse, 24 sequences / 121 steps recovered**; binary files
refused (not mis-parsed).

## M2/M3 — step settings & module-adapter binding (done)

- **Step settings** live as scalars under `Step > TS > subprops`: `Mode`
  (run mode: Normal/Skip/Pass/Fail), `LoadOpt` (module load timing), `PreCond`
  (precondition), `LoopType`/`LoopWhile` (looping), `PassAct`/`FailAct` (flow
  actions), `PreExpr`/`PostExpr`/`StatusExpr`. → `Step.settings` (`StepSettings`),
  empty/absent → null. Corpus: all 121 steps expose pass/fail actions + mode.
- **Module-adapter binding** lives under `Step > TS > SData`; the adapter is
  identified by the SData child record:
  - `ViCall` (`VICall`) → LabVIEW VI; target = `VIPath`.
  - `Call` (`ExternalCall`) → C/DLL; target = `LibPath` + `Func` (e.g.
    `kernel32.dll:Sleep`).
  - `PythonCall` (`CPythonCall`) → Python (recognized; target fields not yet decoded).
  - `SeqName`/`SFPath` → Sequence Call (calls another sequence).
  → `Step.module` (`StepModule` + `SeqAdapter` enum). Corpus: 51/121 steps carry
  a recognized binding (the rest are flow-control or NI-measurement-plug-in steps
  whose binding lives outside SData — not yet modeled).
- **Call graph**: a SequenceCall step's `SeqName` (+ `SFPath`, `UseCurFile`)
  names the called sequence. `SeqFile.sequence(name)` looks one up;
  `SeqFile.resolveCall(step)` returns the called sequence when it lives in the
  same file (else it's an external call → `module.sequenceFile`). The dump marks
  `(in this file)` / `(external)`. Corpus: 4 intra-file calls resolved.
- **Variables**: a sequence's `Locals` and `Parameters` are `Obj` containers
  whose sub-properties are the variables (name = tag, kind = `classname`,
  default = scalar). → `Sequence.locals` / `Sequence.parameters` (`SeqVariable`
  {name, type, value}). Corpus: 28 locals; `Parameters` are empty in this corpus
  (so parameter pass-by direction is **not yet observed/recovered**).
- **Coverage metric**: `measureCoverage(SeqFile)` → `SeqCoverage{total, modeled}`
  counts what fraction of `Data`-tree property nodes the typed lens surfaces.
  `tool/coverage.dart` runs it over `corpus/seq` and writes a gitignored
  `corpus/seq/REPORT.md`. Current: **13.5% (1895/14016 nodes)** — the rest (deep
  `TS` step config, `Result`/`Measurement` subtrees) is still raw `SeqProperty`,
  the frontier to grow. The analog of the VI "% semantically decoded".
- **Test limits**: a limit-test step (`NumericLimitTest`, …) carries the
  pass/fail criteria as `Comp` (operator, e.g. `GELE` = low ≤ x ≤ high) +
  `Limits` (`Low`/`High`/`Nominal`/`ThresholdType`, e.g. `PERCENTAGE`) +
  `DataSource` (measured-value expression). → `Step.limits` (`StepLimits`), null
  when the step isn't a limit test; units are not stored here (not fabricated).
  Corpus: 10 limit tests.
- **Viewer (M4)**: `dumpSeqFile(SeqFile)` (`seq_dump.dart`) renders a
  sequence-editor-like text view — header, each sequence's params/locals, then
  Setup/Main/Cleanup steps as `name [type] -> adapter: target (flow; loop; if)`.
  `tool/dump.dart [path]` prints it (auto-picks a corpus file). Honest: shows
  `(none)` / omits null fields, never fabricates.

## Binary TOF1 — reconnaissance (header decoded; body not yet)

> **2026-06 corpus expansion — several "83/83" body claims below are now SUPERSEDED.**
> The corpus grew from **103 → 372 `.seq`** (288 binary / 58 INI / 26 XML) across
> ~28 source repos and TS revisions 575→1022 (was an NI-example-heavy ~10-repo
> set). The wider, real-world sample **falsified** conclusions that were overfit to
> the original 83 binary files — a healthy correction, exactly what the bigger
> corpus is for:
> - **REFUTED — "2nd u32 ∈ {16, 118}" / "layout selector".** Real-world files show
>   `leadingWords[1] ∈ {2, 16, 18, 118, 276, …}`, not a two-valued selector. The
>   `0x10`/`0x76` table below was an artifact of the NI-example subset.
> - **REFUTED — "the fixed 5-entry scaffold `[SequenceFileData,Data,Objs,Seq,[0]]`
>   (82/82)".** Other root shapes occur, e.g. `[SequenceFileData,Data,Attributes,
>   Obj,TestStand]`; and on some files long comment strings leak into the
>   name-table extraction, so the heuristic is imperfect. What still holds is the
>   weaker prefix `[SequenceFileData, Data, …]`.
> - **WEAKENED — object-record triplet.** Real-name qualifying rate fell from
>   97.8% → ~85.7% on the broader corpus (control ~52% still well below, so the
>   signal is real but smaller than first measured).
> - **UPGRADED — INI form.** Previously "not yet verified against a real sample";
>   the corpus now carries **58 real INI `.seq`** (`[__Header__]` + `ProductName =
>   "TestStand"`, versions 143/797/894/920…). INI is a *plaintext* serialization of
>   the **same PropertyObject model** the binary encodes — a readable Rosetta that
>   should directly inform the binary record tree. `detectSeqFormat` already
>   classifies all 58 as `SeqFormat.ini`; all 26 XML still parse with 0 failures.
>
> The corpus-tagged tests are being re-derived against the 372-file corpus; treat
> specific counts below as historical until that lands.

Verified across **all 83** binary files in the corpus (TS2014). Fixed header
slots from offset 0:

```
0x00  "TOF1"                         magic
0x0A  "SequenceFile"                 file-type token (NUL-terminated)
0x40  "TestStand"                    productname   ┐ 50-byte (0x32) NUL-padded
0x72  "2014 SP1 (14.0.1.103)"        productversion │ ASCII slots, fixed stride
0xA4  "14.0.0.0"                     compatibleversion
0xD6  "14.0.0.274"                   buildversion   ┘
```

(`TestStand` is at offset 64 in 83/83 files.) `detectSeqHeader` now recovers the
binary `fileType` (0x0A) and `productName` (0x40). The numeric `fileversion`
(the XML `920`/`962` analog) is **not yet located** in the binary header — the
bytes at 0x3C (`05 03 …`) are a candidate but unconfirmed.

**Body = a single zlib stream** (verified: all 83 files inflate). After the
header/preamble there is one zlib stream (CMF `78 9c`, at offset 0x518 in the
TS2014 corpus) whose inflated bytes hold the **same PropertyObject model** as the
XML form — the names `SequenceFileData`, `Data`, `Sequence`, `MainSequence`,
`Parameters`, `Locals`, `Step`, `StepType`, `Action`, and real variable names
(e.g. `Ref_Seri_No`) appear in the clear inside it. This is the direct analog of
the VI heap's zlib sections. → `inflateBinaryBody(bytes)` locates + inflates it
(83/83 OK); `binaryStrings()` surfaces the printable runs.

The inflated body is a **binary record stream**: it starts with little-endian
u32 fields (counts/ids, e.g. a leading `1c 00 00 00 76 00 00 00 …`) and contains
a **NUL-terminated name pool** — property names packed back-to-back, each
followed by `0x00` (verified: a NUL sits before/after every printable run). The
key model names are recovered cleanly: `Sequence`/`Step`/`Locals`/`Parameters`/
`StepType`/`SequenceFileData` in **83/83** files (`MainSequence` 79/83 — some
rename their main sequence). → `binaryBodyStrings(seqBytes)` returns those
strings with offsets; `tool/dump.dart` shows them for a binary file.

Body layout (recon): a leading **record region** (little-endian u32 fields plus
byte-packed values, peppered with `ff ff ff ff` all-ones *values* — NOT record
delimiters, see below) precedes one or more **packed string tables** (the name/
type table and value/expression tables, each NUL-terminated runs back-to-back).
Records reference strings **by index**, not by byte offset (verified: name
offsets are not referenced as u32). → `binaryStringTable(seqBytes)` returns the
largest contiguous table (names *or* values, depending on the file).

`analyzeBinaryBody(seqBytes)` → `BinaryBodyLayout` frames the inflated body into
the record region + string region and reports `recordRegionLength`,
`stringCount`, `sentinelCount`, and the first few `leadingWords` (LE u32).
**Corpus-verified across all 83 binary files:** every body frames (non-empty
record region before a ≥5-entry table; 83/83 carry ff-sentinels; 50319 strings
total). Leading-word recon (83/83): the **3rd u32 is a constant `1`**, and the
**2nd u32 ∈ {16, 118}** (`0x10` / `0x76`, meaning not yet decoded — a kind/version
tag candidate). The **1st u32 varies** (18 distinct values, mode 27×44) and is
**not** a simple count (it equals neither stringCount nor sentinelCount in any
file). *(Not yet decoded, not "unrecoverable".)*

The string region is **not one table** — it splits into many packed tables
(`binaryStringSegments`, maximal NUL-adjacent run chains). Corpus-verified:
**≥6 segments in 83/83** (range 6–37, mode ~30–31). The early segment sizes look
stable across files (samples start `[~12, ~30, ~37, 57, …]`); a **57-entry
segment appears in 81/83** — a strong candidate for a fixed built-in name/type
table, *not yet confirmed* across all files or labelled.

One segment **is** identifiable by content: the **property-NAME table**. Picking
the segment that matches the most known PropertyObject model tokens (`Sequence`,
`Step`, `Locals`, `Parameters`, `StepType`, …) yields a clean discriminator —
`binaryNameTable`. Corpus-verified across all 83 binary files: such a name table
**always exists (83/83)**, **always carries the core tokens (83/83)**, and is
**never the largest segment (83/83** — the value/expression tables are bigger).
It is the **first segment in 82/83** (a strong tendency, *not* relied on — the
single outlier, `UKTAG_SimpleResultProcessor.seq`, scatters names across early
segments with the densest hit at index 4, so selection is by content, not
position).

The **value/expression tables** (the non-name segments) are **not yet
individually labelled**, and the obvious heuristics were *refuted* across the
corpus:

- "The largest segment is the expression table" is **false** — only **2/83**
  largest segments are >50% expression-like (mean ≈0.32); expressions are spread
  across many segments, not concentrated in one.
- What *does* hold (83/83): **expressions live outside the name table** — every
  file has ≥1 non-name segment containing expression-like strings (`Locals.` /
  `Step.` / quoted literals / operators), and the name table itself is
  near-pure identifiers (0 expression-like entries in **82/83**, the lone
  exception being the same `UKTAG` outlier). So names vs. values *are* separated;
  there just isn't a single "expression table" to point at yet — that needs the
  record grammar.

`leadingWords[1] ∈ {16, 118}` (`0x10` / `0x76`) — **partially decoded: it selects
the record-prefix layout.** It deterministically picks one of two serialization
layouts for the aligned scaffold prefix (82/82 rooted files):

| `leadingWords[1]` | n  | `word[3]` | `word[5]` | `word[7]` |
|-------------------|----|-----------|-----------|-----------|
| `0x76` (118)      | 63 | `2`=Objs  | `4`=`[0]` | `768`     |
| `0x10` (16)       | 19 | (varies)  | `3`=Seq   | `0`       |

It is **not** the engine/save version (both cohorts span header versions
14.0/19.0/21.0), **not** the fileType (all `SequenceFile`), **not** process-model
presence, and **not** the source tool (the same repos produce *both*). The `0x76`
layout also carries more string segments (median 28 vs the `0x10` cohort's 6–15).
*Still open:* **why** a file uses one layout vs the other (a structure
sub-variant?), and the meaning of `leadingWords[0]`.

**XML/binary twins (a decode asset).** Three NI example files exist in *both*
encodings — `nidmmmeasurement_example`, `niscopeacquirewaveform_example`,
`nifgenstandardfunction_example`. They are a partial Rosetta: the file/sequence
names round-trip but only ~3/6 of the long step names match verbatim (the binary
twins look like a slightly different revision, or store long names differently),
so align with care — they're a lead, not yet a clean type-code oracle.

**Value model — strings are a NUL-delimited pool referenced by index, NOT
length-prefixed.** Across all 83 files (48 174 runs of len ≥ 4):

- **0/48174** strings are u32-length-prefixed (the u32 before a run equals its
  length, or length+1, *zero* times; u16 only 0.1%). **Length-prefix framing is
  refuted.**
- **93.2%** of runs are immediately preceded by a `0x00` (the pool is
  NUL-delimited; the rest abut padding).
- **99.8%** of runs live in the *string region* (only 113/48174 fall in the
  record region) — confirming the split: the record region is structure + inline
  scalars + pool-index references, while string *values* are NUL-delimited pool
  entries the records point at by index.

So the per-field model is `{name-index, type, value}` where a string value is a
pool index, not inline bytes. The aligned-prefix words `word[4]`/`word[6]` are
**not** simple counts of the known metrics (`word[6]==nameTableLen` in only
18/63; not segment/string/sentinel count) — still undecoded.

**Scalar/type-tag decode — two angles tried, both inconclusive (still open).**

- *Naive IEEE-754 scan is unusable:* scanning the record region byte-by-byte for
  integer-valued doubles yields ~565/file (47 807 total) but these are
  **zero-padding artifacts** — a small integer like `2.0` is just seven `0x00`
  bytes followed by one `0x40` exponent byte, which the zero-heavy record region
  produces by coincidence (the byte before a "double" is `0x00` 82% of the time).
  No type tag isolates this way.
- *Twins are NOT a numeric oracle:* the distinctive **non-integer** numbers in
  each twin's XML (7/7/6 values) are **absent** as little-endian doubles in the
  binary twin (0 found in all three). Combined with the partial name round-trip,
  this confirms the binary twins are a **different revision** of the example —
  useful for the name-pool structure, useless for value cross-referencing.

Next approach for scalars: locate a binary whose XML twin *truly* matches
(byte-identical names + values), or decode the type tag structurally from a known
container's first scalar field rather than by value search.

**Record framing — first decode (the records index the name pool).** Reading the
record region as LE u32s (`binaryRecordWords`) shows it opens
`[leadingWords[0], leadingWords[1], 1, …]` and the small words that follow are
**0-based indices into the name table** (which is therefore an *ordered string
pool*, not just a bag of names). Concretely, the constant 3rd word `1` selects
`name[1]`, and the name table opens with a fixed PropertyObject **container
scaffold** (`binaryNameScaffold`):

```
name[0]=SequenceFileData  name[1]=Data  name[2]=Objs  name[3]=Seq  name[4]=[0]
```

Corpus-verified: **82/83** files are rooted at `SequenceFileData` (the lone
exception is the `UKTAG` partial plugin file with no file-data root); **82/82**
of those open with the exact 5-entry scaffold, and **82/82** have record
`word[2] == 1` pointing at `name[1] == 'Data'`. Past index 4 the entries are the
file's own sequences/objects (66/82 extend to `…Sequence, MainSequence`). The
indices are **interleaved with binary field values**.

**The records are byte-packed variable-length** (not a u32-aligned array). A
record-region byte histogram across all 83 files shows the common small values
(`0x02`, `0x04`, `0x01`) occur at *all four* u32 byte phases with near-equal
frequency (e.g. `0x02`: 217k / 205k / 205k / 204k across phases 0–3) — they would
cluster at one phase if the region were u32-aligned. So the grammar must be
parsed field-by-field; `binaryRecordWords` (the u32 view) is only useful for the
aligned scaffold prefix, not the body.

The earlier `0x6115` "marker" lead is **refuted**: it occurs in only **3/83**
files (59 times total, always followed by `0x00`, preceded by varying bytes) — it
is file-specific data (a checksum/GUID), *not* a structural record marker. The
dominant record bytes are zero-padding (`00 00 00 00`), `ff ff ff ff` all-ones
values, and the small `0x01/0x02/0x04` values above. The per-field type/length
encoding is **not yet decoded**.

**`ff ff ff ff` is NOT a record/object delimiter (refuted).** A byte-granularity
scan of all 83 files (83 062 maximal `ff ff ff ff` runs) shows: they occur at
**all four byte phases ~uniformly** (21089/20519/21351/20103 for offset%4) — so
they are *not* u32-aligned markers; they **outnumber the named objects by
14–310×** (median 43×; `sentinelCount == nameTableLen` in 0/83); and the u32
*after* a run is a valid name index only **44.7%** of the time. They are best
explained as `0xffffffff` all-ones *values* (−1 / "not set" defaults) inside the
byte-packed records. `BinaryBodyLayout.sentinelCount` is therefore a descriptive
`ff ff ff ff`-dword count, **not** a record boundary. So record boundaries are
*not* marked by a fixed delimiter — the grammar is length/type-driven and must be
walked field-by-field from the root container.

**Object-record shape — strong HYPOTHESIS (worked example, not yet corpus-proven).**
A byte-granularity scan of the simplest file (`QuickDrop.seq`, 12 names) finds
every named object referenced as a recurring **triplet** `[u32 name-index]
[u32 field][u32 count]`, occurring at *all* byte alignments (so the records are
byte-packed, as established). The first clean occurrence of each:

| object (name-idx) | field | count |
|-------------------|-------|-------|
| Sequence (6)      | 0x14  | 1     |
| Start (7)         | 0x14  | 1     |
| Obj (8)           | 0x47  | 3     |
| Parameters (9)    | 0x110 | 1     |
| Locals (10)       | 0x34  | 1     |
| ResultList (11)   | 0x10  | 1     |

6/6 named objects fit `[idx][field][count]`. Since Parameters/Locals/ResultList
are all **Containers** yet their `field` differs (272/52/16), `field` is most
likely a **byte-size of the property's serialized blob**, not a type code; `count`
is the child/element count (note `Obj` → 3, the array element wrapper).

**Corpus-corroborated, but NOT cleanly extractable (real ≫ control).** A
negative-control test over all 83 files compares the triplet match rate for real
name indices (`idx` 5..nameLen-1) vs *fake* control indices just above `nameLen`
(values that are not names), using the same `[idx][field∈1..1e5][count∈1..1e3]`
filter with a `00000000`/`ffffffff` boundary before:

- **real name indices: 97.8%** (1062/1086) have a qualifying triplet;
- **control indices: 52.0%** (565/1086).

The ~46-point gap (asserted: real > 0.9 and real − control > 0.25) confirms the
triplet is a **genuine structural signal**, not an artifact — so the record shape
is real and holds across both layouts and all repos. BUT the 52% control rate
means a naive `[idx][field][count]` scan is **too noisy to *extract* the object
list** (≈half its hits on non-names would be spurious).

*Disambiguation attempts (both refuted), so `field`/`count` semantics stay open:*

- **`field` is NOT a forward byte-size.** If `field` were the blob size, the next
  record/boundary would sit at `i+field` (tried `i+field`, `+4`, `+8`, `+12`).
  Real triplets chain 84.5% but **control chains 88.1%** — no separation (the
  region is dense with `0000`/`ffffffff` boundaries and coincidental starts), so
  this does not distinguish real from noise. The QuickDrop "field=size" reading
  was a small-sample coincidence.
- **`count` is NOT a child count.** Across 1062 real triplets `count == 1` in
  **91%** (969); `field` is usually small (16–255, 89%), not a large size. A
  container like `Locals`/`Parameters` would need count ≥ its child count, so the
  dominant `count==1` argues against that reading — the detector is mostly
  matching leaf-property references, not container headers.

So the triplet is **corroborated structure but not a decoder**, and `field`/
`count` are **not yet decoded**.

- **`field` low byte is not a clean type code either.** Real triplets' field low
  byte is more concentrated than control (top-5 covers 88% vs 68%) and enriched
  in `{0x34, 0x70, 0x74}` — all multiples of 4, hinting `field` is u32-aligned —
  but `0x14` dominates *both* real (35%) and control (39%), so the low byte does
  not separate real records from noise. No usable type set.

**Decode status — statistical byte-RE has plateaued.** The structure is mapped
(header → name-pool indices → byte-packed records → string pool) and the
object-record *triplet* is corroborated, but `field`/`count` semantics and the
true per-record boundary resist purely statistical recovery on this corpus: the
signals are real yet too weak/confounded (best real-vs-control gaps ~46pp on
*existence*, but ~0 on *size-chaining* and on *type-byte*). The honest unblock is
a new input, not more histograms:
1. a **byte-identical XML↔binary Rosetta** (the 3 example twins are a *different
   revision*, so values don't line up) — e.g. save one `.seq` in both formats
   from a TestStand install, or
2. **controlled minimal files** (one property at a time) to isolate each field, or
3. **NI's `PropertyObject` serialization docs** if obtainable.
Until one of those lands, the binary reader stays at: format/header/layout
decoded, **name pool + object names recovered** (surfaced in the inspector),
record tree **not yet decoded**.

The **record grammar** that delimits one record from the next and pairs each name
index with its typed value is **not yet fully decoded**. So `parseSeqFile` still
**refuses** binary (UnsupportedError); the next milestone is that grammar — then
it maps onto the shared SeqProperty model and the whole typed lens + dump +
coverage come along for free. Offsets confirmed on the TS2014 corpus only — treat
as version-specific until other versions are sampled. *(Not yet recovered, not
"unrecoverable".)*

## INI form — plaintext Rosetta for the PropertyObject model

The legacy INI encoding (`SeqFormat.ini`; 58 real samples in the corpus, versions
143/354/797/894/920) is a **human-readable serialization of the same
PropertyObject model** the binary `TOF1` and XML forms encode. `seq_ini.dart`
decodes it (header + sections); confirmed across all 58:

- `[__Header__]` → `Type`/`ProductName`/`Version` (recovered into `SeqFileHeader`;
  this also fixed `detectSeqHeader`, which previously returned nulls for INI).
- `[DEF, <path>]` sections declare each object's **members and their types**
  (`SF = SequenceFileData`, `Seq = Objs`, `%[0] = Sequence`, …) and its `%NAME`.
- `[<path>]` sections carry the **values** (`member = value`) plus directives
  `%FLG:` (flags), `%HI:` (array bounds), `%NAME`, `%INSTOVRD:`/`%INSTFLG:`
  (typed-instance overrides), `%TYPE:`, `%COMMENT:`, `%TIMESTAMP:`.
- Paths nest exactly like the **binary name pool**: `SF` (=`SequenceFileData`,
  the `%OBJROOT` alias) → `SF.Seq` (an `Objs` array) → `SF.Seq[0]` (a `Sequence`,
  `%NAME="MainSequence"`) → `Parameters`/`Locals`/`Main`/`Setup`/`Cleanup`.

**Why this matters for the binary tree (the prize):** the INI path/name/type
structure is the *ground-truth shape* the binary records index. The binary
scaffold we recovered (`SequenceFileData, Data, Objs, Seq, [0], MainSequence, …`)
is exactly this tree. `iniDataTree(IniSeqFile)` now reconstructs it into the
shared [SeqProperty] model (builds 56/58 — the 2 without a `%OBJROOT` root are a
TODO): paths like `SF.Seq[0].Main[0]` become nested objects, `Objs` members
expand to arrays from their `member[i]` element paths, `%NAME` → node name,
declared member type → `className`, value → `scalar`. A real file reconstructs as
`Data → Seq[N sequences] → MainSequence → Parameters/Locals/Main[steps]/Setup/
Cleanup/RTS/Requirements`, matching the XML/binary shape exactly.

`parseSeqFile` now builds a `SeqFile` from INI too (`parseIniSeqFile`), so the
**existing typed lens works on INI for free**: across the corpus's 56 buildable
INI files it recovers **441 sequences, 5515 steps (all typed), 1643 locals, and
2123 module-adapter bindings** — same `Sequence`/`Step`/`StepGroup`/`SeqAdapter`
lens as XML. (A container-discovery pass surfaces objects like a step's `SData`
that are implied only by a deeper section, not listed as a member.)

**INI-as-oracle attack on the binary `count` (2026-06, REFUTED).** With INI fully
decoded we can ask the binary directly: for each object *name* the INI gives the
true member count (median across the corpus: `Data`=11, `MainSequence`=9,
`Parameters`/`Locals`=2, `RTS`=15…). Resolving each binary object-record triplet
`[name-index][field][count]` back to its pool name and comparing: the binary
`count` is **median 1 for every object name** (Data/MainSequence/Parameters/Locals
all 1), so **`count` is NOT the member/child count** — cleanly refuted via the
cross-encoding oracle (corroborates the earlier `count==1 in 91%` hint). `field`
is also not a clean per-name type code (e.g. `Data.field` top value 16 is only
~40%). The real blocker is **locating the authoritative per-object definition
record** (a name-index recurs once per *reference*, and the first boundary-prefixed
triplet isn't the definition) — not the field/count semantics. The INI tree
remains the oracle once record *boundaries* are found. *(Not yet decoded — not
unrecoverable.)*

Next slices: (1) wire the app's `SeqDocument`/dump to render INI (library is
ready; the app still shows INI as Unknown); resolve `[%TYPES]` so type-inherited
defaults (settings/adapter not overridden at the instance) fill in. (2) **use
this concrete per-object member→type→value layout as the oracle for the binary**:
for a given object the INI tells us the exact ordered members, their types, and
values — line that up against the binary record stream (name-index/`field`/`count`
triplets) to finally decode the binary record's field/count/value encoding.
*(Binary record tree not yet decoded — not unrecoverable.)*

## Honest gaps (do NOT model yet)

- **Binary record grammar** past the header — not yet recovered.
- **INI typed lens + app** — `parseSeqFile` builds a `SeqFile` from INI (56/58),
  the shared lens recovers sequences/steps/locals/module bindings, and the
  inspector renders INI via `IniSeqDocument` (a `StructuredSeqDocument`) — the
  app now shows 82 files structured (26 XML + 56 INI). `SeqFile.types` is now
  populated for INI from `[%TYPES]` (`iniTypes`; 2206 types across 56 files).
  Still TODO: the 2 files lacking a `%OBJROOT` root (degrade to Unknown), using
  `[%TYPES]` to fill in **type-inherited** step settings/adapter defaults that an
  instance doesn't override, and instance overrides (`%INSTOVRD`).
- **Config / station files** — `corpus/seq-sources.json` captures `.ini/.cfg/.tsw/.tpj`
  when present, but the open-source corpus is sequence-heavy; type-palette and
  station-config samples are sparse. (CN-IOT's `.ini` files are *localization
  string packs*, not structural config — excluded.)
- **Module-adapter bindings** (which VI/DLL/.NET/expression a step calls, + param
  mapping) — the link to the VI reader; deferred to M3.

Project honesty rule (CLAUDE.md): mark undecoded ranges explicitly; say "not yet
recovered", never "unrecoverable".
