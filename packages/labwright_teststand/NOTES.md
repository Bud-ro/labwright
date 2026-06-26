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
| **INI** | INI sections + a TestStand marker | 🔬 inferred | legacy (TS 3.x); NI deprecating; no sample in corpus yet |

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

- **Step settings** live as scalars under `Step > TS > subprops`: `PreCond`
  (precondition), `LoopType`/`LoopWhile` (looping), `PassAct`/`FailAct` (flow
  actions), `PreExpr`/`PostExpr`/`StatusExpr`. → `Step.settings` (`StepSettings`),
  empty/absent → null. Corpus: all 121 steps expose pass/fail actions.
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
- **Variables**: a sequence's `Locals` and `Parameters` are `Obj` containers
  whose sub-properties are the variables (name = tag, kind = `classname`,
  default = scalar). → `Sequence.locals` / `Sequence.parameters` (`SeqVariable`
  {name, type, value}). Corpus: 28 locals; `Parameters` are empty in this corpus
  (so parameter pass-by direction is **not yet observed/recovered**).
- **Coverage metric**: `measureCoverage(SeqFile)` → `SeqCoverage{total, modeled}`
  counts what fraction of `Data`-tree property nodes the typed lens surfaces.
  `tool/coverage.dart` runs it over `corpus/seq` and writes a gitignored
  `corpus/seq/REPORT.md`. Current: **11.8% (1653/14016 nodes)** — the rest (deep
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

The **record tree** that links names to values is **not yet parsed** (the u32
record framing around the pool is still being worked out). So `parseSeqFile` still
**refuses** binary (UnsupportedError); the next milestone is that record grammar —
then it maps onto the shared SeqProperty model and the whole typed lens + dump +
coverage come along for free. Offsets confirmed on the TS2014 corpus only — treat
as version-specific until other versions are sampled. *(Not yet recovered, not
"unrecoverable".)*

## Honest gaps (do NOT model yet)

- **Binary record grammar** past the header — not yet recovered.
- **INI form** — not yet verified against a real sample (heuristic detection only).
- **Config / station files** — `corpus/seq-sources.json` captures `.ini/.cfg/.tsw/.tpj`
  when present, but the open-source corpus is sequence-heavy; type-palette and
  station-config samples are sparse. (CN-IOT's `.ini` files are *localization
  string packs*, not structural config — excluded.)
- **Module-adapter bindings** (which VI/DLL/.NET/expression a step calls, + param
  mapping) — the link to the VI reader; deferred to M3.

Project honesty rule (CLAUDE.md): mark undecoded ranges explicitly; say "not yet
recovered", never "unrecoverable".
