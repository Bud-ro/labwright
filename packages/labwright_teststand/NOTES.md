# TestStand reader — format notes & scratch

Clean-room RE notes for NI TestStand files, derived **solely from real `.seq`
binary/text files** (the pinned corpus in `corpus/seq-sources.json`), not from
TestStand itself. Mirrors `apps/labwright_vi_inspector/NOTES.md` for the VI side.
Structure lives here; live metrics belong in tooling (not yet built for seq).

## STATE OF RECOVERY (authoritative status — read this first)

One `.seq` holds the same model in **three encodings**; recovery differs by form:

- **XML — COMPLETE.** `parseSeqFile`→`SeqFile`; the typed lens surfaces every
  clean corpus-confirmed field. Model coverage **49.5%** (9373/18932 `Data`-tree
  nodes over 26 files); the unmodeled remainder is off-limits NI numeric
  type/option codes + empty default scaffolding (modeling them would be
  fabrication — see the off-limits list in "Status & honest gaps"), not missing
  instance data. This is the honest ceiling, not a frontier.
- **INI — COMPLETE via the same lens.** 58/58 parse; coverage **33.3%**
  (52276/157107 over 39 files ≤300KB). Lower % than XML only because each INI
  step inlines its full step-TYPE definition (XML centralizes these in
  `<typelist>`); no per-step instance data is missing. Quoted values are
  C-style-unescaped to match the XML form.
- **BINARY (`TOF1`) — recon mature; record grammar PARTIALLY decoded via the Rosetta
  near-twins (active 2026-06).** Decoded & shipped: header, zlib body, string pool,
  **name table**, per-file datums (object names, module call-targets, step refs,
  expressions, literals); the **named-property record HEADER** `⟨tag⟩⟨name-offset⟩⟨type⟩`
  where names are cited by **string-region byte offset** [5fc9e9e,7f68c40]; the **scalar
  record's reliable 5-word core** `⟨tag⟩⟨name-offset⟩⟨type⟩⟨f64-lo⟩⟨f64-hi⟩` — recovered
  numeric values surfaced via `binaryScalarDoubles`/`binaryNamedScalarRecords` and the
  consistency-gated `binaryNamedRecords` header census [c3866c6,9e0161c,6bee76b], all
  shown in the text `dumpBinaryRecon` [ebd70c9] and the inspector GUI [9412e92,b8f6599,
  d937639]; the record stream's **template-fixed prefix** that diverges at the
  instrument-specific boundary [afe89d5,c55848a,8227938]. **Still NOT decoded:** the
  **value-string linkage** (an opaque per-object save-time handle, not any body/table byte
  offset — refuted across all bases [225d95f]: an honest **plateau**); the general
  **record-boundary grammar** for splitting arbitrary variable-length records (only the
  reliable 5-word scalar core + cross-file diff localize boundaries; record sizes carry no
  inline length [afe89d5]); the scalar record's variable trailing words and the 2nd 8-word
  shape's internals [8227938,c55848a]. ⟹ `parseSeqFile` **still refuses binary** (honest)
  — we recover values + the property skeleton, not yet the full step tree. Inputs:
  **Rosetta near-twins** (`tool/fetch_rosetta_pairs.sh`, tiny 4-step ~7.5KB binaries with
  known XML twins — the differential leverage the full-corpus statistical attack lacked).

**Deliverables (PLAN's TestStand goals — substantially met for XML+INI):**
expose hidden data ✓, render close to the original ✓ (the inspector's Sequences
outline with flow nesting), **export the sequence logic ✓** —
`exportSequenceLogic(SeqFile)` renders each sequence as readable nested
pseudocode (function-style per-sequence signature header + flow blocks +
conditions, per-step preconditions/limits/loops/jumps/in-&-external call
targets), surfaced both as the
dump's `=== Sequence logic ===` section and a dedicated read-only **Logic tab**
in the app.

**Recommendation:** the binary record-grammar decode is now ACTIVE on the Rosetta
near-twins (see the dated blocks at the top of this file) — differential
inference against the known XML tree, one confirmed record-grammar fact per pass.

## M0 reconnaissance — what a `.seq` actually is (confirmed on the corpus)

A TestStand 4.0+ sequence file holds the same logical content — sequences, the
set of types it uses, and shared global variables — in one of **three encodings**.
All three were/are offered by NI; which one a file uses is a save-time choice.

| encoding | recognized by | confirmed | notes |
|---|---|---|---|
| **XML** | optional UTF-8 BOM `EF BB BF`, then `<?xml …?>`, root `<teststandfileheader …>` | ✅ M0 | text; the common form in open-source NI examples |
| **binary** | ASCII magic **`TOF1`** at offset 0 | ✅ M0 | NI proprietary flat container; default for size/speed |
| **INI** | INI sections + a TestStand marker | ✅ header + tree + **typed lens** (parseSeqFile→SeqFile) | 58 samples; `seq_ini.dart`; **58/58** → 449 seq / 5664 steps / type-inherited run-mode+looping for every step / recognized module bindings via the shared lens (%OBJROOT + older %OBJECTS root aliases) |

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
  {name, type, value}). Corpus: 28 locals; sequence-level `Parameters` are empty
  across the whole corpus (no `Seq[N].Parameters[M]` member exists in any of the
  58 INI files, matching the XML) — so a *sequence's own* declared parameter list
  carries nothing to surface here.
- **Module call arguments**: a step's code-module call binds its arguments under
  the adapter's `Parameters` list — `SData.Call.Parameters` (ActiveX/C adapter)
  or `SData.PythonCall.Parameters` (Python adapter). Each is a `Name`, a bound
  value expression (the C adapter's `ArgVal` *or* the Python adapter's
  `ArgumentValue`, e.g. `FileGlobals.UserToAutoLogin`, `ThisContext`), and — C
  adapter only — a `DisplayType` (`String`, `User (Object Reference)`) and a
  `Direction` code. → `StepModule.callParameters` (`CallParameter` {name,
  boundExpression, displayType, directionCode, direction}); `boundExpression`
  reads `ArgVal ?? ArgumentValue`. `direction` maps the standard TestStand codes
  (`1`=in, `2`=out, `3`=in/out; a `Return Value` reads `2`, inputs read `1`);
  an unrecognized code stays raw in `directionCode` rather than guessed (Python
  params carry no `Direction`). The dump appends `{args: name dir←expr; …}`.
  Corpus: 44 C-adapter call-parameter entries (ini, e.g. ni_nitsm-python
  `FrontEndCallbacks`) + **31 Python steps / 53 params (22 with a bound value)**
  in the XML corpus. So argument pass-by *direction* **is** recovered at the C
  call site — distinct from the empty sequence-level parameter list above.
- **Coverage metric**: `measureCoverage(SeqFile)` → `SeqCoverage{total, modeled}`
  counts what fraction of `Data`-tree property nodes the typed lens surfaces.
  `tool/coverage.dart` runs it over **both** the XML and the legacy **INI** `.seq`
  files in `corpus/seq` (reported separately) and
  writes a gitignored `corpus/seq/REPORT.md`. Current: **49.5% (9373/18932
  nodes)** over 26 XML files (incl. `Step.id`=`TS.Id`, and the boolean step flags
  `StepFCSeqF`/`IgnoreRTE`/`ResultOption` → `StepSettings.failureCausesSequence-
  Failure`/`ignoresRunTimeErrors`/`recordsResult`, plus the **Additional Results
  recording spec** below) — the rest (`Result`/`Measurement` subtrees; the
  cluster-field type descriptors `Type`/`NumType` scattered in value subtrees;
  the `Flags`/`CheckedState` metadata on result entries) is still raw
  `SeqProperty`, the frontier to grow. `measureCoverage` credits the call-argument
  (`Call.Parameters`) and recorded-`Result.Units` nodes the lens surfaces, and
  the full set of `TS` step-settings `StepSettings` reads — run mode, module
  load/**unload**, the four **loop expressions**, pre/post/status expressions,
  pass/fail actions **and their jump targets**, and the step icon (previously the
  metric undercounted these even though the lens already surfaced them).
  The analog of the VI "% semantically decoded".
- **Test limits**: a limit-test step (`NumericLimitTest`, …) carries the
  pass/fail criteria as `Comp` (operator, e.g. `GELE` = low ≤ x ≤ high) +
  `Limits` (`Low`/`High`/`Nominal`/`ThresholdType`, e.g. `PERCENTAGE`) +
  `DataSource` (measured-value expression). → `Step.limits` (`StepLimits`), null
  when the step isn't a limit test. Corpus: 10 limit tests.
- **Recorded units**: the measurement unit lives on the step's `Result`
  sub-object (a sibling of `TS`, instance-level): `Result.Units` — real strings
  like `V`, `A`, `mA`, `uS`, `nS`. → `Step.resultUnits`; the dump folds it into
  the limits chip (`{limits GELE [9, 11] mA}`). (Earlier notes said units weren't
  stored — they are, just under `Result`, not `Limits`.) Corpus: 125 `Units`
  values across the INI files.
- **Result outcome record**: the step's `Result` slot (sibling of `TS`) carries
  its per-step outcome: `Status` (`Passed`/`Failed`/…), `ReportText`, and an
  `Error` sub-object `{Code, Msg, Occurred}` (plus `Common`, and the `Units` /
  numeric value already handled above). → `Step.result` (`StepResult`:
  `status`/`reportText`/`errorCode`/`errorMessage`/`errorOccurred`,
  `hasRecordedOutcome`). **Honest framing**: in a sequence *file* these are
  compile-time defaults for an un-run step — corpus-probed, **87/87 steps hold
  empty `Status`/`ReportText`, `Error.Occurred=false`, `Code=0`** (0 recorded
  outcomes). The lens recognizes the structure (self-evident names) and the dump
  shows a `{result: status …; error …; report …}` chip *only* when
  `hasRecordedOutcome` is true (so a file shows nothing misleading). Real values
  appear once a run/report is recorded. Coverage marks `Result`+`Status`+
  `ReportText`+`Common`+`Error`+`Code`/`Msg`/`Occurred` (+966 nodes → the
  40.0 %→45.1 % bump — the Result slot is on nearly every step).
- **Step mutex synchronization**: a step can serialize a shared resource with a
  mutex — `TS.UseMutex` (Bool) + `TS.MutexNameOrRef` (the mutex name/reference
  expression). → `StepSettings.usesMutex` / `mutexName`; the dump adds a
  `mutex <name>` note only when the step actually locks one. **Honest framing**:
  corpus-probed **87/87 steps have `UseMutex=false` and an empty `MutexNameOrRef`**
  (no step uses one) — a standard per-step setting at its default, self-evident
  name, execution-affecting (same class as the custom-condition trio). Coverage
  marks the two `TS` keys (+282 nodes → the 45.1 %→46.6 % bump). The remaining
  per-step `TS` options (OperationOrder/ConnectionLifetime/BatchSyncOpt/Switch*/
  RouteGroup*/MulticonnectMode/CanEdit*/… — numeric codes & editor-permission
  bools) are left raw: their value semantics aren't corpus-confirmable, so
  modeling them would be fabrication. `Result.Common` is an empty container.
- **Data source**: a step's `DataSource` expression is what it measures /
  evaluates — the measured value for a numeric limit test (`Locals.A.High_Value`)
  or the pass/fail criterion for a `PassFailTest` (`Step.Result.PassFail`).
  `StepLimits.dataSource` already carried it for limit tests, but a `PassFailTest`
  has no `Comp`/`Limits` → no `StepLimits`, so its criterion was dropped. →
  `Step.dataSource` (general); the dump shows `{data-source …}` for non-limit
  steps. Corpus: 113 steps set `DataSource` without limits (94 `PassFailTest`).
- **Additional Results recording spec**: a step's `AdditionalResults` container
  (classname `Obj`) holds the extra values it logs to the report. It attaches to
  a module-call parameter; each entry is named for the recorded slot — the
  parameter direction `Input`/`Output` (classname `PythonParameterResult` /
  `CommonCParameterResult`) — and carries `{Condition (ExprValue), Flags (Num),
  CheckedState (Num)}`. → `Step.additionalResults` (`AdditionalResult`): walks the
  step subtree for every container, exposing each entry's `name`, `kind`
  (classname), and `condition` (the gating `ExprValue`; null = always-on). The
  dump folds it into a `{+results: Input, Output if <cond>}` chip. **Honest scope:
  `Condition` only** — `Flags` (always `8192` here) and `CheckedState` (`1`/`2`)
  are left raw, meaning *not yet decoded*. Corpus (probed full): **14 XML files,
  55 containers, 110 entries**, all `*ParameterResult`, and every `Condition`
  empty/always-on so far. Coverage marks container+entries+`Condition` (+350
  nodes → the 25.9 %→27.7 % bump).
- **Measurement-step parameters**: an NI measurement step carries its formal,
  typed parameters under `Measurement > Parameters` (an `Objs` array, sibling of
  `TS`/`Result`). Each entry is fully self-describing: `Name` (`voltage_level`),
  `Type` (the TestStand type token `TypeDouble`/`TypeString`/`TypeEnum`/
  `TypeInt32`/`TypeBool`/`TypeUint32`/`TypeUint64`), `Direction` (`In`/`Out`),
  `Dimension` (`0` scalar / ≥1 array), `ArgumentValue` (the bound expression,
  e.g. `6`), plus raw `ID`/`Log`/`TypeSpecialization`/`MessageType`/
  `EnumDefinition`. → `Step.measurementParameters` (`MeasurementParameter`:
  `name`/`dataType`/`direction`/`value`/`isArray`/`typeSpecialization`/`logged`);
  the dump folds it into a `{params: voltage_level in TypeDouble = 6; pin_map out
  TypeString (IOResource)[] [not logged]}` chip. `typeSpecialization` (`Type-
  Specialization`) refines the type — `IOResource`/`Path`/`Pin`/`Enum`, null for
  the common `None` — and `logged` (`Log`) is the per-param report-logging flag.
  Corpus: of 147 params, **34 are specialized** (IOResource 19 / Enum 10 / Path 4
  / Pin 1) and **7 are not logged** (`Log=false`). For a `TypeEnum` param,
  `enumValues` recovers the enum's allowed values from `EnumDefinition` — each
  element is a named constant whose scalar is its integer code (`NONE=0`,
  `DC_VOLTS=1`, …); the dump folds the first few into a `{NONE=0, DC_VOLTS=1, …}`
  chip. Corpus: **all 10 `TypeEnum` params populated, 74 values total**. The
  numeric `ID` and empty `MessageType` siblings are left raw.
  Distinct from `StepModule.callParameters` (the ActiveX/C + Python adapter
  argument lists). Corpus (probed full): **17 XML files, 147 typed params**, all
  carry `Type` + `Direction`. Coverage marks container+`Parameters`+each param+
  `Name`/`Type`/`Direction`/`Dimension`/`ArgumentValue` (+994 nodes → the
  27.7 %→33.0 % bump). The biggest single XML cluster recovered to date.
- **Viewer (M4)**: `dumpSeqFile(SeqFile)` (`seq_dump.dart`) renders a
  sequence-editor-like text view — header, each sequence's params/locals, then
  Setup/Main/Cleanup steps as `name [type] -> adapter: target (flow; loop; if)`.
  `tool/dump.dart [path]` prints it (auto-picks a corpus file). Honest: shows
  `(none)` / omits null fields, never fabricates.

## Binary TOF1 — reconnaissance (header decoded; body not yet)

> **2026-06 — Rosetta pairs + controlled-minimal binaries OBTAINED (decode unblocked).**
> The record-grammar attack was blocked for lack of a binary file whose content we
> already understand. That input now exists, fetched from NI's *own* public
> measurement-plugin example repos by `tool/fetch_rosetta_pairs.sh` into the
> gitignored `corpus/seq/rosetta/`:
> - **`ni/measurement-plugin-labview`** commits its NI example measurements in
>   MIXED encodings — `NIDmmMeasurement` / `NIFgenStandardFunction` /
>   `NIScopeAcquireWaveform` as **BINARY (TOF1)**; `NIDCPowerSourceDCVoltage` /
>   `NIDigitalSPI` / VISA / Keysight as **XML**. Same author, TS version, and
>   authoring conventions → the XML examples are a structural template for the
>   binary ones.
> - **`ni/measurement-plugin-python`** commits the *same* example measurements
>   (`NIDmmMeasurement`, …) as **XML**. So each labview BINARY example has an XML
>   twin of the same NI measurement.
> - **Confirmed pairing (NIDmm):** the XML twin is a 4-step sequence (update pin
>   map → register sessions → measure → cleanup); the binary twin recovers the
>   same skeleton — module paths `NIDmmMeasurement.lvlib\…\Initialize and Register
>   Sessions.vi` / `Unregister and Close Sessions.vi`, literal
>   `NIDmmMeasurement.pinmap`, and a **fully recovered name table**
>   `[SequenceFileData, Data, Objs, Seq, [0], Sequence, MainSequence, Obj,
>   Parameters, Locals, ResultList]` matching the XML structure. The two differ
>   only by adapter (Python-plugin call vs LabVIEW-plugin call) — a near-twin, not
>   byte-identical, but the PropertyObject scaffolding is shared.
> - **Why this is the unlock:** the binaries are **tiny (4 steps, ~7.5KB)** —
>   controlled-minimal inputs, vs the 905KB monsters in the wider corpus — and we
>   independently know their logical tree from the XML twin. That gives the
>   differential constraints (known names + known structure ↔ raw record bytes)
>   the full-corpus statistical attack lacked. NEXT decode push: align the binary
>   record stream of `NIDmm_labview_BIN.seq` against the known tree to work out how
>   a record references a name-pool entry and its value. For a *byte-identical*
>   twin (perfect Rosetta), NI's `SequenceFileConverter.exe` converts a `.seq`
>   between binary/INI/XML in place — needs Windows+TestStand, a future option.

> **2026-06 — record→name linkage CONFIRMED on the minimal Rosetta binaries.**
> Working the tiny NIDmm/NIFgen/NIScope labview binaries (4 steps, ~7.5KB,
> 11-entry name pool) against their XML twins:
> - **CONFIRMED — the record region references name-pool entries by integer
>   index.** Scanning the record region as u32 LE and counting values that fall in
>   `[1, poolSize)`: **every** non-root structural name is referenced — NIDmm &
>   NIFgen **10/10**, NIScope **9/10** (only the empty `ResultList` absent) — with
>   structurally-sensible frequencies: `Objs` 187–205× (array container, the most
>   nested), `[0]` 77–82× (array element key), `Data` 70–80×, `MainSequence`/`Obj`/
>   `Parameters` mid, leaf `Locals`/`ResultList` 1–2×. Not chance (a flat
>   small-int distribution wouldn't cover the pool with this shape). And the
>   object-record *headers* cite indices in tree order — consecutive records lead
>   with `3 → 5 → 6` = `Seq → Sequence → MainSequence`, exactly the known path
>   `Data > Seq > [0] > Sequence(MainSequence)`. This generalizes the earlier
>   single anchor (`recordWords[2] == 1 → name[1] == "Data"`) to the whole stream.
>   *Caveat (next step):* small integers are ambiguous — some counted "refs" may be
>   incidental small-int data (counts/flags ≤ pool size). Pinning the exact record
>   fields that ARE name references (vs incidental) is the next decode step;
>   `parseSeqFile` still refuses binary until that lands.
> - **REFUTED (as universal) — `0x6259ECD3` (1650060499) is NOT the object-record
>   marker.** It recurs 7×/file in all three labview sibling binaries but **0×** in
>   six other corpus binaries (TestStand_Main_v3, the Aktif_Güç family) — so it is
>   a file-family / TS-version constant, not a general delimiter. Object-record
>   boundaries must be found another way (the per-record header shape, not a magic
>   word).

> **2026-06 — FIRST scalar VALUE-DATA recovery from the binary record stream.**
> Scanning the record region for clean inline doubles (low 32 bits == 0 to kill
> coincidence; finite; sane magnitude) and decoding f64 LE:
> - **Recovered values: `1.0, 2.0, 4.0, 6.0, 8192.0, −1.0, −2.0`** (7 distinct),
>   **byte-identical set across NIDmm & NIScope** (they share the measurement
>   step-type definitions, so the same numeric defaults appear).
> - **Layout confirmed:** the 8-byte LE IEEE-754 double sits exactly **2 words
>   after a name-offset** — record = `⟨tag⟩ ⟨name-offset⟩ ⟨type-code⟩ ⟨f64-lo⟩
>   ⟨f64-hi⟩` (the double = words 3–4; attribution finds the name-offset @−2w from
>   the f64's low word, matching the prior `w3:w4` double placement). The
>   name-offset is predominantly `Parameters`.
> - **Honest scope:** these are **step-TYPE parameter default values** (the twin's
>   own sequence carries 0 params), not per-step instance overrides — but they are
>   genuine recovered numeric data, the first concrete *values* pulled from the
>   binary record stream (previously only names/strings were recovered). Decoding
>   each value's exact leaf property (vs the enclosing Parameters container) is the
>   next refinement.
> Next: locate per-step *instance* values / limits and tie a recovered double to a
> specific step's field via the twin.
>
> *Shipped:* `binaryScalarDoubles(seqBytes)` in `seq_binary.dart` codifies this —
> scans the record region, decodes clean inline f64 (low-word-0 filter), returns the
> distinct recovered values; tested (synthesized TOF1 + recovers the NIDmm set). The
> corpus ratchet test excludes `corpus/seq/rosetta/` (separately-fetched decode aid)
> so its pinned counts stay stable.
>
> *Refuted (leaf attribution):* pairing each clean f64 with the name-offset 2 words
> before it does **not** give the value's leaf property name — **every** such pair
> collapses to the single enclosing container `Parameters` (17/19, 21/22, 17/19
> across NIDmm/NIFgen/NIScope), never a distinct leaf. (NIFgen carries extra
> defaults `3.0, 8.0` — its standard-function step type differs from DMM/Scope.)
>
> *Value table has NO per-entry header (pure packed strings).* Examined the bytes
> between consecutive value-table strings: the inter-string gap is **1 byte (just the
> NUL) in 272/273 entries** (one 3-byte anomaly). So there is **no per-entry header /
> length prefix / back-pointer** beside value strings — the value table is
> structurally **identical to the name table** (both are NUL-packed string pools).
> The two differ *only* in how records reference them, not in internal layout. ⟹ the
> value→property linkage lives entirely in the **record region**.
>
> *Value-table-relative offset REFUTED — value linkage is NOT a body/table byte offset
> (honest plateau on value strings).* Tested the last untested base: for every
> distinctive value string (the `NationalInstruments.MeasurementLink.TestStandMeasurement
> Client.dll` path, "Acquire Measurement", "Measurement Type", "Update pin map") computed
> offset = strAbs − valueTableStart and counted byte-granular occurrences in the record
> region — across **u32-LE, u32-BE, and u16**, and re-confirmed string-region-relative
> and absolute too. **Result: 0 hits on every string, every base, every width, all 3
> files.** The probe's counter is sound (validated same run: name-offsets 79/61/72 →
> 32/145/41 hits, exactly the confirmed ResultList/Parameters/Locals counts). ⟹ value
> strings are **not referenced by any byte offset** into the body (not string-region-rel,
> not value-table-rel, not absolute) in any width/endianness. Combined with the earlier
> refutations (entry-index inconclusive — single-use; no per-entry header), the
> value→property link is an **opaque per-object handle/index assigned at save time**, not
> a recoverable body offset. This is the honest **plateau on value-string linkage**;
> next pushes pivot to **consolidating/shipping what IS decoded** (tested named-scalar
> record surfacing, richer binary recon) rather than re-probing offsets.
>
> *SHIPPED `binaryNamedScalarRecords()` — the named-property scalar records.* First
> consolidation push after the value-linkage plateau: a tested helper that surfaces each
> inline scalar `double` sitting in a decoded named-property record, paired with the
> property name it is filed under + the raw (unmodeled) tag/type words. Scans the record
> region for the confirmed header shape `⟨tag⟩⟨name-offset⟩⟨type-code⟩⟨f64⟩`: a word
> resolving (as a string-region-relative offset) to a real name-table entry, immediately
> followed by a type word and a **clean** inline double (same low-word-0/finite/range gate
> as `binaryScalarDoubles`). Verified on all 3 Rosetta binaries: **17 / 21 / 17** records,
> **every one** resolving to `Parameters` tag=0 with **zero coincidental name pollution**
> (the clean-f64 gate + exact name-offset match suppress false hits); values match the
> confirmed scalar set ({-1,1,2,4,6,8192}; NIFgen adds 3,8). `rawTag`/`rawTypeCode` carry
> the NI tag/type words **verbatim, NOT modeled** (the type codes vary per slot: 62,64,78,
> 94,171,…; mapping them to NI's enum would be fabrication). It is the
> **structurally-attributed subset** of `binaryScalarDoubles` (ties each value to a
> property-name reference). +2 unit tests via the `_tof1` helper; package suite **172**
> green.
>
> *SURFACED named scalars in the user-visible recon (inspector app).* Threaded
> `namedScalars` through the single-inflate path: `BinaryAnalysis.namedScalars`
> (computed once in `analyzeBinary`, no re-inflate) → `BinarySeqDocument.namedScalars` →
> a new **"Named scalar values"** section in the inspector's binary recovery view
> (`binaryRecoverySections`), each item rendered `Name = value  (raw type N, not
> modeled)`. Verified end-to-end on all 3 Rosetta binaries: analyzeBinary == direct
> helper == parsed document (17/21/17). The corpus equivalence test now also asserts
> `analyzeBinary.namedScalars == binaryNamedScalarRecords` across the whole binary
> corpus; +1 app test for the section + formatting. package **172** / app **65** green,
> both analyzers clean.
>
> *SURFACED the full inline-numeric set too.* Threaded `scalarDoubles` (the distinct
> superset of the named scalars' values — includes numbers not yet tied to a named
> record, e.g. `-2.0` in NIDmm) through the same single-inflate path:
> `binaryScalarDoubles` gained a body-core `_scalarDoublesFromBody`,
> `BinaryAnalysis.scalarDoubles`/`BinarySeqDocument.scalarDoubles` carry it, and the
> inspector recon now shows an **"Inline numeric values"** section plus `Inline
> numbers`/`Named scalars` count rows in `binaryHeaderRows`. Verified end-to-end on the
> 3 Rosetta binaries (analyze == helper == doc): **7 / 9 / 7** distinct doubles (vs
> 17/21/17 named records — confirming superset). Corpus equivalence test extended; app
> test asserts both sections + count rows. package **172** / app **65** green.
>
> *SHIPPED `dumpBinaryRecon()` — a text recon report for binary files.* The non-GUI
> analogue of `dumpSeqFile` (which only handles parsed XML/INI): a pure
> `String dumpBinaryRecon(Uint8List)` in seq_dump.dart, built from a single
> `analyzeBinary`. Emits `=== … ===` blocks — a header + Layout summary (record region /
> string region @ / sentinels / strings / tables / leading words) then sections for
> object names, module call-targets, step references, expressions, quoted literals,
> inline numeric values, and named scalar values (`Name = value  (raw type N, not
> modeled)`), each capped at 40 with an honest "… and N more". Closes with the explicit
> honesty line *"record links not yet decoded: …the variable-length record grammar tying
> each to its step tree is not yet recovered"*; returns `(not a binary TOF1 file)` for
> non-binary input. Verified on the 3 Rosetta binaries (NIDmm 2961 chars: 6 object names,
> 2 module targets, 7 step refs, 18 expressions, 7 inline numbers, 17 named scalars).
> +1 package test (synthetic `_tof1` with a Parameters scalar record). package **173**
> green.
>
> *SHIPPED `binaryNamedRecords()` — the consistently-tagged named-record header census.*
> The structural skeleton beyond the scalar slots: for every record word resolving (as a
> string-region-relative offset) to a name-like string, group by name and keep only those
> referenced **≥2×** with a **single consistent preceding tag** (offset 0 = root
> `SequenceFileData` excluded — every zero word would match it; value strings — quoted
> literals/expressions/module-paths/`ID#:` — excluded since they're confirmed NOT
> offset-referenced, so any match is coincidence). **The per-name tag consistency IS the
> evidence** a chance collision can't fake. Result on the 3 Rosetta binaries: a clean,
> cross-file-stable set of REAL TestStand identifiers — `Parameters` ×35/32/22 (tag 0),
> `[0]` ×16/16/20 (tag 0), `ResultList` ×10/9/10 (tag 2), `NI_DotNetParameterResult` ×3,
> `DescriptionFormat` ×2/2/5, NIScope adds `ArrayClusterEls` ×8 — with the inconsistent
> noise (`Locals`, `Seq`, `Data`, `MainSequence`, version strings, the spurious empty
> `""`) correctly dropped. `rawTag` carried verbatim, NOT modeled; the per-record TYPE
> isn't summarized (it varies per member). Threaded through `BinaryAnalysis.namedRecords`
> (single-inflate; corpus equivalence test extended) and surfaced as a **"Named-record
> headers"** section in `dumpBinaryRecon`. +2 package tests (consistent kept / inconsistent
> dropped). package **175** green, analyze clean. (Records→step-tree link still not
> decoded — this is a header census, not a parse.)
>
> *SURFACED named-record headers in the inspector GUI.* Threaded `namedRecords` through
> `BinarySeqDocument` → a **"Named-record headers"** section in `binaryRecoverySections`
> (each `name ×count  (raw tag N, not modeled)`) + a `Named records` count row in
> `binaryHeaderRows`. Verified doc.namedRecords == binaryNamedRecords on the 3 Rosetta
> binaries (5/5/6). +app-test coverage (section + count row); package **175** / app **65**
> green. The decoded binary structural skeleton is now fully surfaced in BOTH the text
> dump (`dumpBinaryRecon`) and the GUI: object names, module call-targets, step refs,
> expressions, quoted literals, inline numeric values, named scalar values, named-record
> headers.
>
> *Named-record counts are TYPE-DEFINITION-driven, NOT instance-driven (differential vs
> twin).* Cross-checked `binaryNamedRecords` counts against each XML twin's parsed
> structure. **All 3 twins are structurally IDENTICAL** — 1 sequence (MainSequence), **4
> steps, 0 params, 1 local, 23 types** — yet the binary header counts **differ**:
> `Parameters` 35/32/22, `ResultList` 10/9/10, `[0]` 16/16/20 (NIDmm/NIFgen/NIScope). ⟹
> the record multiplicity is **NOT** a function of the logical instance tree (it would be
> constant if it were); it scales with the **step-TYPE definitions**, which differ per
> instrument (DMM vs Fgen vs Scope step types carry different parameter/result counts).
> This **confirms the binary embeds the full step-TYPE definitions inline** (the same
> structural fact already established for the INI form, where each step inlines its full
> step-type definition; XML centralizes these in `<typelist>`). So the
> per-step/per-sequence multiplicity hypothesis is **REFUTED** — counts can't be mapped to
> 4-steps/1-local without first separating type-def records from the 4 instance records,
> which needs the not-yet-decoded record-boundary grammar. Notable **invariant**:
> `NI_DotNetParameterResult` = **3 in all 3 files** (a fixed element of the standard
> measurement-plugin template), unlike the type-varying counts — an observation, not yet
> modeled. No code change (verification tick).
>
> *`ID#:` step GUIDs are TEMPLATE-assigned, not per-file-random — and not a step
> enumerator.* Toward the record-boundary frontier (separating type-def from instance
> records), checked the binary's `ID#:` GUIDs against the twin steps. Twin: **4 steps**
> across **3 groups** — Setup `[Update pin map, Create and register … Sessions]`, Main
> `[Perform/Generate/Acquire …]`, Cleanup `[Destroy and unregister …]`. Binary: **7**
> `ID#:` GUIDs (≠ 4). Cross-file: **3 GUIDs are byte-identical across ALL 3 instruments**
> (`j5wyx+k17RGnWgDgQ7lGAD`, `MS2zjF1W7BGpWXoj8F8wtC`, `O2wIzH+P7hGvWQAVXQFaAA`);
> NIDmm/NIFgen share **6 of 7** (differ by exactly one — the instrument-specific Main
> step); NIScope shares only the 3 universal ones. ⟹ TestStand `ID#:` GUIDs in these
> example files are **fixed by the measurement-plugin template** (boilerplate steps reuse
> identical GUIDs across instruments), **not** freshly randomized per save. And since
> **7 ≠ 4**, `ID#:` count is **NOT a step-instance enumerator** — IDs tag steps *and*
> other Id-bearing objects (substeps / sequence / result objects), so the instance↔type-def
> split can't be read off the ID count. The boundary still needs an actual byte
> delimiter/length in the record region (next lead). No code change (probe tick).
>
> *RECORD STREAM has a TEMPLATE-FIXED PREFIX with a precise divergence point
> (differential, all 3 files).* Located every confirmed header by anchor — ResultList
> `⟨2⟩⟨79⟩⟨4⟩⟨0x0b⟩⟨0⟩` and Parameters `⟨0⟩⟨61⟩⟨type⟩` — and compared their word
> positions across instruments. **The leading headers occupy IDENTICAL word positions in
> all 3 files**: ResultList at words **709, 1144, 1929, 2753, 3011, 3494, 4053, 4920**
> (first **8** identical; inter-header word-gaps `435,785,824,258,483,559,867` identical),
> diverging only at the 9th (gap 1270/534/1596 for NIDmm/NIFgen/NIScope). Parameters
> likewise identical for the first **11** headers (gaps `8,128,1035,8,1141,735,281,745,5,7`
> identical), diverging at the 11th (769/1516/1664). ⟹ the record region is **byte-position
> identical across instruments for a leading boilerplate prefix** (the shared template
> steps — pin-map update + session create, identical across plugins) and **diverges at a
> precise, observable point** = the template→instrument-specific boundary. This is the
> instance/type-def split localized by cross-file diff (couldn't be read off the ID count).
> *Also confirmed:* dense scalar **Parameter records pack at a FIXED 8-word / 32-byte
> stride** (the run of gap-8 headers), each `⟨0⟩⟨61⟩⟨type⟩⟨0⟩⟨f64-hi⟩…` with the inline
> double (e.g. `…62,0,1086324736` = type 62, high word of 8192.0). *Honest caveat:* the
> non-dense gaps are **irregular** (435,785,824,…) — **no fixed record stride and no inline
> length field** found in the header, so arbitrary variable records still can't be split by
> length; the boundary is currently localizable only by the cross-file diff. No code change
> (probe tick).
>
> *8-WORD SCALAR PARAMETER RECORD layout decoded (+ a 2nd 8-word shape; validates the
> f64 gate).* Dumped every 8-word-stride Parameters record positionally (record starts at
> the tag word). The **scalar-f64** shape (8 words / 32 bytes):
> `⟨W0 tag=0⟩⟨W1 name-offset=61⟩⟨W2 type:raw⟩⟨W3 f64-low⟩⟨W4 f64-high⟩⟨W5⟩⟨W6⟩⟨W7⟩` — the
> inline double occupies **W3+W4 = record byte +12** (right after tag/name/type), e.g. the
> 8192.0 default = `0, 61, 62, 0, 1086324736, 63, 0, 2` (W5/W6/W7 = 63/0/2 vary per
> record, **not yet decoded**). This is byte-identical at the template-prefix positions
> (w248, w1419) across all 3 files. **BUT the 8-word stride is NOT uniformly scalar-f64**:
> a **2nd shape** occupies the same stride — `⟨0⟩⟨61⟩⟨type 255,256,257,258,259,260⟩⟨W3=2⟩
> ⟨W4=1,2,3,4,5,6⟩⟨0⟩⟨0⟩⟨W7=2050⟩` (NIScope @w5116…5156): an **incrementing type + counter**
> run, likely array/enum element records, where **W3≠0**. ⟹ the **low-word-0 f64 gate** in
> `binaryNamedScalarRecords` correctly **rejects shape B** and keeps only true scalars —
> this differential **validates the shipped helper's gate** on a real confounder. (f64
> position +12 also re-confirms the helper's `⟨tag⟩⟨name-offset⟩⟨type⟩⟨f64⟩` doc.) No code
> change (probe tick; helper already correct).
>
> *Trailing words W5/W6/W7 are NOT a stable record field — reliable scalar core is 5
> words.* Tabulated (value, type, W5, W6, W7) for every clean-f64 record across all 3
> files. The dominant trailing is `W5=0 W6=2 W7=0`, but with many exceptions
> (`8192.0→63,0,2`; `2.0/type64→0,128,0`; `1.0/type94→5046296,0,66`). **Decisive
> refutation:** `val=1.0 type=64` carries **W7 = 3584/3584/5632** for NIDmm/NIFgen/NIScope
> — *same value, same type, different W7 across files* ⟹ W7 is **not** a function of
> (value,type); it reads into following content / a file-specific word, not a fixed
> trailing field. ⟹ the **reliably-decoded scalar record is the 5-word core**
> `⟨tag⟩⟨name-offset⟩⟨type⟩⟨f64-lo⟩⟨f64-hi⟩`; the earlier "8-word" size is a **dense-packing
> artifact**, not a universal record with 3 stable trailing fields. This **bounds** the
> record decode honestly and **confirms `binaryScalarDoubles`/`binaryNamedScalarRecords`
> read only the reliable 5-word core** (they never touch W5/W6/W7). Splitting arbitrary
> records still needs the record-boundary grammar (the f64-core is reliable regardless).
> No code change (probe tick).
>
> *2nd 8-word "array-element" shape is INSTRUMENT-SPECIFIC (NIDmm only) — corrects an
> earlier impression.* Listed every Parameters record of the array shape (W3==2) per file.
> **NIDmm: 13 contiguous records** `@w5110…5204` — `counter (W4) = 0,1,2,…,12` and
> `type = 254 + counter` in **lockstep** (254/0 … 266/12), 8-word elements (the counter-0
> element is 6 words to the next, possibly an array header/length; the rest +8), `W7 ∈
> {2050,0}`. **NIFgen: 0. NIScope: 0.** ⟹ this is an **instrument-specific array** in the
> DMM step-type defs (a ~12-element config/options/limits table unique to the DMM
> measurement), **NOT a universal record shape** — which **corrects** the [c55848a] note
> that implied the shape appeared in NIScope (it was always NIDmm's; misattributed). The
> `W3==2` (vs scalar `W3==0`) re-confirms why `binaryNamedScalarRecords`' low-word-0 f64
> gate correctly excludes all 13. (type values 254-266 cited only as evidence of lockstep
> increment — their NI meaning stays unmodeled, OFF-LIMITS.) No code change (probe tick).
>
> *Step recovery REFUTED via name-offset; a structural/user-content boundary.*
> Parsed the twin's 4 step names per file (e.g. "Update pin map", "Create and
> register NI-DMM Sessions", "Perform a measurement using an NI DMM", "Destroy and
> unregister NI-DMM sessions"). In the binary: **only "Update pin map"** appears as a
> literal string (value table, rel ~4600, **0 offset-references**); the **other 3
> step names are absent** as NUL-bounded literals — they are **generated/localized**
> (the binary carries `DefaultNameFormat`/`ResStr(...)` name-format expressions, not
> the resolved display names the twin XML shows). ⟹ step names are **not recoverable
> via the name-offset mechanism**.
> **Boundary (meta):** the decoded offset mechanism cleanly recovers the
> **structural property-name skeleton** (the container names Parameters / Locals /
> ResultList / Step / Seq …, offset-referenced) plus inline scalar doubles — but
> **user-facing content** (step display names, expressions, string values) lives in
> the **value table** whose linkage is undecoded (this is now the 3rd consecutive
> value-table blocker: not byte-offset, not table-index, and step names are
> additionally name-format-generated). NOT a dead end — next angles: the value
> table's *internal* structure (does each entry carry a header / back-pointer to its
> owning record?), or a byte-identical twin via NI SequenceFileConverter.exe.
>
> *Inconclusive (value-table ENTRY-INDEX not confirmed either):* tested whether
> value/expression strings are referenced by entry index into their packed table
> (global index, or value-table-local index). Distinctive value strings show only
> **1–3** record-region occurrences of their index — at noise level for ints in
> [200,250]; the lone larger count (local-index 70 → 33×) is just the common small
> int `70`, coincidental. Root cause: these value strings are **single-use** (each
> referenced ~once), so no high-count signature can confirm any index scheme.
> ⟹ value-string linkage stays **undecoded** — neither byte-offset (refuted) nor
> demonstrably table-index. Value strings remain recovered *sets* (`binaryExpressions`
> / `binaryModulePaths` / `binaryQuotedLiterals`); per-property value linkage is a
> later target. Pivot: the next tractable goal is **step recovery** (step names ARE
> in the name table → reachable via the decoded name-offset mechanism).
>
> *Refuted (string values use a DIFFERENT linkage than names):* the
> `(name → string-value)` recovery via "two string-region offsets in one record"
> fails for value strings. Byte-granular check on NIDmm: name-table strings ARE
> offset-referenced (`Main` rel 44 → 6 refs, `ResultList` rel 79 → 32 refs), but
> value/expression-table strings are **not referenced at all** —
> `NI_MeasurementParameter` (rel 3514), the `…TestStandMeasurementClient.dll`
> module path (rel 2997), `"Measurement Type"` (rel 3811), `"Acquire Measurement"`
> (rel 3647) each get **0 refs** as string-region-relative *and* 0 as absolute body
> offset. ⟹ the body holds (≥)two string tables with **different linkage**: the
> **NAME table** is referenced by string-region-relative byte offset (confirmed),
> the **VALUE/expression table** is linked by a yet-undecoded mechanism (a separate
> per-table index, not a body offset). So a property's string *value* is **not**
> recoverable by the offset scheme; the recon *set* helpers (`binaryExpressions`,
> `binaryModulePaths`, `binaryQuotedLiterals`) remain the honest granularity for
> value strings until the value-table index is decoded.
>
> *Resolved (scalars are POSITIONAL):* scanning the **nearest** preceding
> name-offset for every clean f64 (back up to 12 words) still yields the `Parameters`
> container @−2w (17/19, 20/22) — there is **no closer leaf-parameter name** between
> the header and the value. ⟹ scalar values are stored **positionally** within the
> `Parameters` container record; per-value leaf names are *not* inline-adjacent —
> they live in the step-TYPE definition / parameter order (exactly how TestStand
> separates type from instance). So the right model is an **ordered scalar value
> list under `Parameters`**, not a `(leaf-name → value)` map; `binaryScalarDoubles`
> (the value set) is the correct granularity until the type-definition parameter
> order is parsed. Next: parse the step-TYPE parameter order to label positional
> values — or pivot to recovering string-valued properties.

> **2026-06 — named-member records are TYPE-DEPENDENT (the array header does NOT
> generalize); Parameters records embed IEEE-754 doubles.** Dumping Parameters
> (relOffset 61) and Locals (72) records like ResultList (3 files):
> - **Refuted:** Parameters (**0/145**) and Locals (**0/41**) do **not** carry the
>   inline `⟨4⟩⟨0x0b⟩` element descriptor. So ResultList's 5-word array header is
>   **array-property-specific**, not a universal named-member layout.
> - **Parameters record** = `⟨tag=0⟩ ⟨name-offset=61⟩ ⟨type-code⟩ …` and **embeds
>   8-byte little-endian IEEE-754 doubles**: w3:w4 = `0`:`0x3ff00000` (×33 = **1.0**)
>   and `0`:`0x40000000` (×11 = **2.0**) — inline scalar default values (genuine
>   recoverable value data, distinct from OFF-LIMITS type codes; these come from the
>   step-TYPE default-valued numeric params, the twin's own Parameters being empty).
> - **Locals record** = a third shape: preceded by a `0x00XX0000` flags word (not a
>   clean `0` tag), dense with `0xXX0000`-form packed words; stride ~7 words
>   (`"Locals"` reappears at w7).
> ⟹ a named property's record layout depends on its **value type** (array vs scalar
> vs container) — there is no single universal body; the `⟨tag⟩⟨name-offset⟩` header
> is shared, the body that follows is type-specific. Next: pin the scalar-double
> property body (where exactly the 8-byte value sits relative to the name-offset).

> **2026-06 — ResultList array-property record fully pinned: 5-word/20-byte fixed
> header `⟨2⟩ ⟨name-offset⟩ ⟨[0]=4⟩ ⟨0x0b⟩ ⟨0⟩` + payload; unifies the `[0]/0x0b`
> token as the inline array-element descriptor.** Dumping the ResultList record
> (selected by the confirmed `⟨2⟩⟨79⟩⟨4⟩` header) from the tag onward, 32/32
> occurrences, byte-identical across all 3 files:
> - **w0..w4 are single-valued (the fixed header):** `2`, `79=ResultList`, `4`,
>   `0x0b`, `0`. w5 is the first variable column.
> - **Unification:** w2..w3 = **`⟨4=[0]⟩⟨0x0b⟩`** — the *same* token pinned earlier
>   as the `[0]` array-element record. So that token is the **array-element-type
>   descriptor inlined immediately after an array property's name**: an array
>   property is `⟨tag⟩ ⟨name-offset⟩ ⟨[0]⟩ ⟨0x0b⟩ ⟨0⟩ …`. *Corrects* the prior
>   "post-name word = opaque code" reading: the `4` after `ResultList` is the `[0]`
>   name-index that starts the element descriptor, not a standalone type code.
> - **Value/child slot = w5:** `0` in **24/32** (empty array), a flag-word
>   (`0x48001800`, …) when populated — and 24/32 empty matches `ResultList` being
>   typically empty in the twin. (Payload code values past w5 are NI type/flag
>   codes — OFF-LIMITS; only the layout + the empty/populated distinction asserted.)
> Next: confirm the same 5-word array-property header on another array (Parameters/
> Locals) and locate the array's element-count or end.

> **2026-06 — the word AFTER the name-offset is a type/class CODE, NOT a
> value/child pointer; header refined to `⟨tag⟩ ⟨name-offset⟩ ⟨code⟩ …`.**
> Classifying the post-name-offset word over each member's occurrences (3 files):
> - **`ResultList` → always `4`** (32/32, constant small int).
> - **`Parameters` → repeated small ints** (78×22, 339×19, 62×8, 234, …); only
>   4–7/145 coincidentally resolve to a clean string, so it is **not** a string
>   reference.
> - **`Locals` → packed `0x00XX0000` words** (0xc0000, 0xee0000, 0x800000, …) —
>   flag/type words, not offsets/counts.
> - **Refuted:** the post-name word is **not** a value/child pointer — a unique
>   per-instance child pointer could not repeat 22–32×, and it is not a clean
>   string-region offset (Parameters) nor a small count (Locals' high-bit words).
> - **Confirmed (structure):** it is a **property-type-dependent code field** that
>   immediately follows the name-offset, so the named-property record is
>   **`⟨tag⟩ ⟨name-offset⟩ ⟨code⟩ …`**; the value/children sit *after* this code,
>   not in it. (Code values are NI type/class codes — OFF-LIMITS to interpret.)
> Next: scan past the code word for the value/child reference (or the record's end).

> **2026-06 — named-property record header shape pinned: `⟨tag⟩ ⟨name-offset⟩ …`
> with a fixed per-property tag (and this proves the refs are genuine).** Scanning
> the record region for each member-name's string offset and histogramming the
> word immediately before/after (3 files):
> - **`ResultList`** (relOffset 79): the surrounding words are **byte-exact in
>   32/32 occurrences, all three files** — `⟨2⟩ ⟨79=ResultList⟩ ⟨4⟩`. Tag-before = 2
>   (100%), word-after = 4 (100%).
> - **`Parameters`** (relOffset 61): tag-before = **`0` in 145/145 (100%)**, all
>   three files (word-after varies — the property's value/children).
> - **`Locals`** (relOffset 72): tag-before is a `0x0018xxxx`-family word in 40/41
>   (less clean — its one populated local puts value data adjacent).
> ⟹ two results: (1) the **named-property record header is `⟨tag⟩ ⟨name-offset⟩ …`**,
>   the tag a fixed per-property constant (differs by property: 0, 2, …) sitting
>   immediately before the offset; (2) this **resolves the prior chance caveat** —
>   a 100%-fixed preceding word (Parameters→0 ×145, ResultList→2 ×32) is impossible
>   for coincidental offset hits, so the high-multiplicity member-name offsets ARE
>   genuine references. (The tag values are NI type/class codes — OFF-LIMITS to
>   interpret; only the fixed-position structure is asserted.) Next: read the
>   word(s) AFTER the name-offset as the property's value/child pointer.

> **2026-06 — string-offset reference mode is REAL & PREVALENT, but the
> discriminator is multiplicity, not the raw exact-start test.** Mapping every
> record `u32` against the set of exact string-start offsets (rel. to
> `stringRegionStart`):
> - **Tempering caveat (honest):** the *raw* "points at an exact string start" test
>   is **not** a clean discriminator. The string region is dense (~410 starts in
>   ~7 KB), so ~6% of in-range ints hit a start by chance — **399 hits vs ~385
>   expected, enrichment ×1.0**. Most individual exact-start hits are coincidence.
> - **Strengthening signal:** the *distribution* is massively non-random — only
>   **~32 distinct** strings are referenced, and they are **genuine member names**
>   with huge multiplicities: **`Parameters`×145, `[0]`×79, `Locals`×41,
>   `ResultList`×32, `Seq`×14, `Main`×7, `MainSequence`×6**, plus `DescriptionFormat`,
>   `TEResult`, `DefaultNameFormat`, `Expression`, `ExprValue`,
>   `BlockStartTypes`/`BlockEndTypes`, `NI_Measurement`, `Step`, `Obj`. A single
>   offset value recurring 145× is not chance — and `Parameters`/`Locals`/
>   `ResultList` recurring per-object is exactly the standard step/sequence member
>   set. (NIScope adds `ArrayClusterEls`×25, `Setup`×14.)
> ⟹ the string-offset reference mode is confirmed & prevalent (real member names
> recovered), but a real ref must be identified by **concentration** (a high-
> multiplicity member-name offset), not by the exact-start test alone; the singleton
> tail mixes real names with coincidences. Next: tie a specific record FIELD POSITION
> to its member-name offset (not just "the value appears somewhere").

> **2026-06 — SECOND reference mechanism CONFIRMED: record fields cite strings by
> string-region-relative byte offset.** Testing record-stream integers as offsets
> from the string-region start (`= recordRegionLength`), two resolve to **exact
> string starts** (NUL-preceded, NUL-terminated, byte-identical across all three
> siblings — not mid-string coincidences):
> - **`79` → "ResultList"** — and `79 == offset(ResultList) − stringRegionStart`,
>   so this is the exact member name (also reachable as scaffold name-index 10).
> - **`102` → "Main"** — semantically the `MainSequence` "Main" step-group name.
> ⟹ the binary uses (at least) **two reference modes**: small **indices** for the
> fixed scaffold/container names (Data=1, Objs=2, [0]=4 — finding above), **and
> string-region-relative byte offsets** for member/value names. This is a real
> grammar unlock: a record's member name can be recovered by following its
> string-region offset. (Distinguishing which record fields are index-refs vs
> offset-refs vs type codes is the next step.)
> - *Refuted (narrower):* the specific `⟨Objs⟩0⟨Objs⟩⟨n⟩` motif's `n` (70, 174) is
>   **not** itself a string offset — both land mid-string (`70`→"…s", `174`→a
>   GUID-interior). So that motif's `n` is a type/other code, not the member-name
>   reference; the name-offset reference sits in a different record field.

> **2026-06 — container does NOT encode child-count in a fixed preceding word;
> but a `⟨Objs⟩ 0 ⟨Objs⟩ ⟨n⟩` motif precedes small `[0]`-runs.** Grouping
> consecutive `⟨[0]⟩⟨0x0b⟩` element headers into runs (byte-adjacency, gap ≤ 72)
> gives 59/59/67 runs with a near-identical length histogram (len1×29, len2×10,
> len3×3, **len4×1**, len5×1, len6×2, len10–12, len17×2):
> - **Refuted:** the array-container record does **not** carry its element count as
>   a `u32` in a fixed slot immediately before the run. Only **16/59** runs (27%)
>   have their length anywhere in the 8 preceding words, and the canonical
>   **len-4 run (@1084) has no `4`** in its preceding 8 words. ⟹ child-count is
>   absent there / encoded indirectly, or byte-adjacency runs ≠ logical arrays
>   (likely: complex elements aren't byte-adjacent, so an adjacent `[0]` run is an
>   array of *empty/scalar* elements, not e.g. the 4 steps).
> - **Observed (candidate, positive):** small `[0]`-runs are frequently immediately
>   preceded by the motif **`⟨Objs=2⟩ 0 ⟨Objs=2⟩ ⟨rising int⟩`** — `2 0 2 70`
>   (@698, @1084), `2 0 2 174` (@5897); the rising int looks like a string-table
>   offset/ID. A container-declaration shape to pin next. (Run offsets / histogram /
>   preceding bytes are byte-identical across the three siblings — shared scaffold.)

> **2026-06 — Rosetta twin ground-truth + Objs=2 is NOT a standalone record
> anchor (count-field hunt refuted for now).**
> - **Verified twin structure** (parsing the XML twins with `parseSeqFile`): all
>   three NI examples are **1 sequence `MainSequence`, 4 steps, 1 local, 0 params**
>   → the only array sizes present are **{0, 1, 4}**. This is the ground-truth a
>   binary element-count field would have to match.
> - **Refuted approach:** a whole-value histogram over `u32 == 2` does **not**
>   yield a clean fixed-column Objs record or an element-count field. The value 2
>   is heavily *incidental* (802/783/856 occurrences — it also appears as the
>   `Objs` back-reference inside `[0]`-element payloads and as ordinary flag/field
>   bytes), so — unlike the self-delimiting `⟨[0]⟩⟨0x0b⟩` token — `Objs=2` is not a
>   standalone record anchor. Counts like 4 are far too rare to surface in a
>   histogram of a polluted value. ⟹ the array-container record must be located by
>   *structural position* (e.g. the bytes preceding a run of `[0]` elements), not
>   by the bare name value; that is the next angle.

> **2026-06 — the `[0]` array-element record: 2-word header + 28-byte minimal
> length.** Mapping the `⟨4=[0]⟩⟨0x0b⟩` token's shape (8 `u32` columns captured at
> each of its 233/233/243 occurrences, per-column histogram):
> - **Columns 0–1 are 100% constant** — `⟨4=[0]⟩` then `⟨0x0b⟩` — a fixed 2-word
>   record header.
> - **The minimal record is 28 bytes (7 u32 words).** The dominant
>   consecutive-occurrence stride is **28 B (78×, identical NIDmm/NIFgen)**, and
>   col7 (the word at offset +28) is `[0]` in **exactly those 78** cases — i.e. it
>   is the *next* record's header. So a minimal `[0]` element spans words 0..6.
>   Longer records carry extra payload (strides 49/65/33/222 B — variable-length,
>   as already established).
> - **Columns 2–6 are the payload** (semi-variable: col2 79% `0`, col3 ~48% `0`),
>   and frequently carry **name-pool back-references** — `Data` (1) and `Objs` (2)
>   recur in cols 2/3/5 — i.e. the element's parent/child links into the object
>   tree. (The non-name payload values, e.g. `0x0b`, `0xffffff00`, `512`, are NI
>   type/class/flag codes — OFF-LIMITS to model; only the layout is asserted.)

> **2026-06 — successor-word distribution disambiguates genuine name-index
> citations from incidental small ints.** For each value `v ∈ [1..10]` appearing
> as a `u32 LE` at *any* byte offset in the (post-scaffold) record region, tabulate
> the immediately-following `u32` over the three minimal binaries:
> - **`[0]` (index 4) → constant code-word `11` (0x0b)** in ~72% of occurrences,
>   with a **file-stable count: 234 / 234 / 244** (NIDmm / NIFgen / NIScope). This
>   `⟨4⟩⟨0x0b⟩` pair is the first concretely-pinned **record token** — a genuine
>   array-element-key (`[0]`) citation followed by a fixed code-word. (234 ≡ 234
>   matches the NIDmm/NIFgen shared-template finding; ~244 for NIScope.)
> - **`Objs` (index 2) → `0`** dominates (~67–70%; 536/802, 527/783, 598/856),
>   with stable secondary successors `70`×33 and `79`×32 in all three.
> - By contrast **`Data` (1)** and **`Obj` (7)** *scatter* — ≥23 distinct
>   successors, top-share ≤0.36; many successors are large structured values
>   (`0x02000000`, `0x80000000`), i.e. most of their `u32` occurrences are
>   incidental field bytes, not clean name citations.
> ⟹ **successor concentration is a reliable name-ref discriminator**, and the
> high-concentration values (2, 4) are real recurring record tokens. The code-words
> themselves (`0x0b`, `70`, `79`, …) are NI type/class codes — OFF-LIMITS to model;
> only the structural pairing is asserted here.

> **2026-06 — leading record frame is a FIXED container scaffold; records are
> byte-granular / variable-length.** Comparing the three minimal binaries'
> *inflated record regions* directly:
> - **The record region opens with a fixed 17-word (68-byte) frame that is
>   three-way byte-identical** across NIDmm/NIFgen/NIScope:
>   `[28, 16, ⟨1=Data⟩, 21, 22, ⟨3=Seq⟩, 0x6259ECD3, 0, 23, 18, 19, 0x02000004,
>   0, 0xFFFFFFFF, 0, 0, 0]`. So the first name reference sits at a **fixed
>   position** — word[2], immediately after the 2-word `[28, 16]` opener
>   (these are `leadingWords[0..1]`) — and cites name-index **1 = Data**; word[5]
>   cites **3 = Seq**. The `0x6259ECD3` family-constant occupies word[6] of this
>   frame (consistent with it being scaffold boilerplate, not a delimiter — see
>   the refutation below).
> - **The first per-file-specific field is at byte 69 — NOT u32-aligned**
>   (`u32 LE` = 1 for NIDmm/NIFgen, 3 for NIScope). An off-by-non-multiple-of-4
>   divergence point **confirms the record stream is byte-granular and
>   variable-length** — name-index fields can land at any byte offset, so a flat
>   `recordWords` u32 scan is a recon aid, not the grammar.
> - **NIDmm and NIFgen are byte-identical for 12403 bytes** of the inflated record
>   region (≈44%); they diverge only in later content/module paths. NIScope
>   diverges at byte 69. ⟹ a large fixed scaffold/boilerplate prefix precedes the
>   per-file differentiating content — the decode should target the *post-scaffold*
>   region, anchored by the byte-69 divergence.
> - *Not yet confirmed (next pass):* the per-record shape appears to be
>   `⟨name-index⟩ ⟨code-word⟩ …` (e.g. idx 4→0x0b, idx 5/3→0x14, idx 6→0x74),
>   but those code words are NI numeric type/class codes (OFF-LIMITS to model);
>   confirming which fields are name-refs vs incidental small ints via the
>   code-word successor distribution is the next step.

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
**Record LOCATION / ORDER attack (2026-06, mostly REFUTED; one positive).**
After the oracle refuted `count`, the blocker became *locating* each object's
definition record. Probed on all 288 binary files:
- **REFUTED — record order == name-pool order.** The first-occurrence order of
  the boundary-prefixed triplet name-indices is strictly monotonic (== pool
  order) in only **16% (46/288)** of files — not a usable alignment. (Scanning
  *all* u32s instead of just triplets gives 0% — pure noise from small ints.)
- **REFUTED — `00000000`/`ffffffff` u32s delimit object records.** Their count is
  ~**247× the name count** (median) — far too frequent to be per-object
  delimiters; they are intra-value padding/alignment.
- **POSITIVE — near one triplet per name.** In **87.8% (253/288)** of files
  (almost) every pool name appears as a boundary-prefixed triplet (distinct
  triplet-names / nameLen median **1.00**) — i.e. the triplet IS a roughly
  complete per-name record set; it's just not in pool order (likely tree-traversal
  order, which the pool order doesn't preserve).
- **Unblock unchanged:** aligning triplets to the tree needs a byte-identical
  INI↔binary twin (the corpus has none — its XML/binary twins are different
  revisions), or the NI serialization layout. The INI oracle gives the expected
  tree; only the binary record *boundaries/order* remain. *(Not yet decoded — not
  unrecoverable.)*

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

- **Full-corpus flat-index reconfirmation (2026-06, all 288 files).** Re-tested
  the "record region is an array of name-table indices" hypothesis at full scale
  (prior run/order analyses were on the 83-file ≤-size subset): of **7.52M record
  u32 words, 39.5% are valid name indices** (`< nameLen`) and record words touch
  **91.6% of name-table entries** — but both figures are **chance-level**, not
  signal: name tables are tiny (13–23 entries) so most small u32s are `< nameLen`
  coincidentally, and with ~15–20k record words per ~20 names nearly every index
  0..N appears somewhere. Record regions are ~15–20k words for only ~20 names →
  **records are large byte-packed structs, not a flat index array** (else the
  valid ratio would be ~100%, not 40%). Reconfirms the plateau below: more
  statistical scanning does not unblock the grammar.

**INI (legacy 3rd encoding) — covered by the shared lens; now measured (2026-06).**
Probed the 39 INI `.seq` files ≤300KB (**187 sequences, 1476 steps** — a much
larger step corpus than the 26 XML files' 214 steps; all parse cleanly, 0
failures). The typed lens populates the same per-step INSTANCE data it does for
XML: modules (labView 128 / sequenceCall 461 / cModule 105 / none 782), limits,
flow, expressions, additional-results (435 steps). `params`/`py`/`plugins` = 0 as
expected — INI predates the measurement-plug-in and Python adapters. Coverage on
INI is **33.3% (52276/157107)** — lower than XML's 49.5% **not** because instance
data is missing, but because each INI step **inlines its full step-TYPE
definition** (`DescriptionFormat`/`DefaultNameFormat`/`ItemName`/`CodeTemplates`/
`Group`/`Menu`/`Substeps`/`CanBeSubstepType…`, exactly once per step) which the
XML form keeps centralized in `<typelist>` (already modeled via [SeqType]). The
rest of the INI unmodeled tree is the SAME off-limits content as XML — the
TS-option cluster (`CanEdit*`/`LoopOpt`/`WindowActivation`/`BatchSyncOpt`/
`Switch*`/`RouteGroup*`, ~1387–1475× each) and empty scaffolding
(`AdditionalResultsHints`/`Requirements`→`Links`/`Category`). `tool/coverage.dart`
now reports INI alongside XML. **Conclusion: no INI-only per-step instance data is
unmodeled; the gap is inlined type boilerplate + off-limits codes** (modeling the
inlined type defs would just duplicate the `<typelist>` recovery as per-step
boilerplate — declined).

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
- **Quoted string values are C-style escaped** (`_unescapeIni`, applied in
  `_unquote` 2026-06): NI writes `\\`→`\`, `\"`→`"`, `\n`→newline, `\t`/`\r`
  inside quoted values. Corpus-verified the only escape targets are `" n t r \`
  (3702 quoted values w/ a backslash: `\"`×10474, `\\`×1232, `\n`×1113, `\r`×14,
  `\t`×1) — and NI **always doubles** a literal backslash, so a lone `\n` is
  unambiguously a newline, not a path separator → decoding is reversible/safe.
  This makes INI string scalars match the XML form (XML entities) so both decode
  to the same logical text: e.g. a condition `Locals.M != \"S001\"` now reads as
  `Locals.M != "S001"` in the lens/dump/logic-export/app, not the raw escaped
  form. Only quoted values are decoded; bare tokens (numbers/enums) and the raw
  `IniSection.members` map are untouched. Unknown `\x` kept verbatim (defensive).
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
**existing typed lens works on INI for free**: across **all 58/58** corpus INI
files it recovers **449 sequences, 5664 steps (all typed), locals**, and — after
type inheritance (below) — **run-mode + looping for every step** and the
recognized module-adapter bindings (labView/cModule/sequenceCall; no-module steps
are honest `SeqAdapter.none`) — same `Sequence`/`Step`/`StepGroup`/`SeqAdapter`
lens as XML. (A container-discovery pass surfaces objects like a step's `SData`
that are implied only by a deeper section, not listed as a member.)

**Root-objects alias `%OBJECTS` (older versions) — 56/58 → 58/58 (2026-06, DONE).**
The 2 INI files that briefly failed (`FormatException: no reconstructable data
root`) are **older TestStand** (versions 127 and 143): they declare their
top-level objects under `[DEF, %OBJECTS]` instead of the newer `[DEF, %OBJROOT]`,
but the sequence-file root is still `SF = SequenceFileData`. `dataRootPath` now
tries both aliases (in order), so both files parse — KernelTestSequence v143 (1
seq / 61 steps) and flexc_parameter_tests v127 (7 seq / 88 steps). The corpus
tests assert **every** INI file builds a tree and a `SeqFile` (no `threw`).

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

**Type inheritance — instance inherits from its `[DEF, <Type>]` (2026-06, DONE).**
A step instance usually stores only the members it *overrides*; its run-mode,
looping and adapter **defaults** live in the step's TYPE definition (e.g.
`[DEF, Action]` → `TS = "TYPE, TEInf"`, and `[Action.TS]` carries `Mode`/`LoopType`).
`_IniBuilder.build` now resolves each member's declared type from the type def
(even for members the instance only implies via a deeper section, like `TS`) and,
when the instance is silent, takes the value from the type's own default subtree —
**instance-wins**, bounded against type cycles by a `visiting` guard, with
inherited default subtrees cached. Measured on the full corpus (56 buildable INI):
run-mode recovered for **5515/5515** steps (was 210 — the 210 instance `Skip`
overrides plus 5305 type-default `Normal`), looping for **5515/5515** (was 38).
Sequence/step counts unchanged (441/5515 — no structural regression). Values are
only ever *copied* from a type definition present in the same file; nothing is
fabricated.

**Empty inherited `SData` ⇒ `SeqAdapter.none` (2026-06, DONE).** Type inheritance
gives every step a `TS.SData` container; for flow-control/no-module step types
that inherited `SData` is **empty**. A full-corpus probe confirmed this exactly:
of the 3463 steps that briefly read as `SeqAdapter.unknown`, **all 3463 had an
empty `SData`** (`nullSData=0, emptySData=3463`), every one a no-module step type —
`Statement` (966), `NI_Flow_End` (686), `Label` (476), `NI_Flow_If` (351),
`NI_Flow_Else`/`For`/`While`/`Case`/`ForEach`, `NI_Wait` (101), `NI_Lock` (50), …
So `StepModule.fromSData` now treats an empty `SData` (not just a null one) as
`none`. `unknown` is reserved for an `SData` *with* members we can't parse, and
the corpus test asserts `unknown == 0` to catch a future regression.

**Older direct-`ViPath` LabVIEW adapter (2026-06, DONE).** When the 2 older-version
files (127/143) started parsing (the `%OBJECTS` fix below), their VI steps surfaced
61 `unknown` SData of the shape `{ViPath, PassInBuf, PassInvocInfo}` — the LabVIEW
adapter as it was stored before the `ViCall` sub-object existed (the VI path is a
*direct* `SData.ViPath` member). `fromSData` now recognizes that too. Current
adapter distribution across all **5664** INI steps: **sequenceCall 1624 · none
3478 · labView 443 · cModule 119 · unknown 0**.

**Instance overrides `%INSTOVRD` (2026-06, DONE — first slice).** A value section's
`%INSTOVRD: <member> = <flags>` marks a member the object overrides relative to its
base type; a bare `%INSTOVRD = <flags>` marks the whole object. The flags are a
bitmask not yet decoded; presence is the signal. The reader keeps the raw flags as
a `%INSTOVRD` attribute on the built `SeqProperty` and exposes
`SeqProperty.isInstanceOverride`. Recovered across **all 58/58** INI files —
**13072** override markers total. (In the corpus these sit overwhelmingly on type
objects, i.e. custom step/data types overriding their base type — e.g. in one file
all 234 were in type/global sections, 0 in step-instance sections — so this is
primarily a type-derivation signal today.) The app's property tree now shows a
subtle "⋄ overridden" marker on these nodes (`PropertyNode.isInstanceOverride`).

The flags are a TestStand **property-flags bitmask, not yet decoded** — deriving
bit meanings from values alone would be guessing (needs NI's PropFlags enum). The
corpus value distribution is concentrated: `5046297` (6883×), `5177369` (2648×),
`5046296` (2564×), `4718616` (1880×), `4194304`=`0x400000` (1789×, also a common
standalone value), … ~18 distinct values. Recorded for a future decode if NI docs
surface; **not** interpreted yet.

**Multi-line value continuation `KEY LineNNNN` (2026-06, DONE).** Values past a
line-length cap are serialized across continuation lines whose key is the base
member/directive name plus a 4-digit ` LineNNNN` suffix (`Line0001`, `Line0002`,
…), each holding a *separately-quoted* fragment. Before this fix the parser stored
each fragment as its own spurious member, so long values (step descriptions, VI
paths, expressions, comments) were truncated to their first ~uncapped chunk. The
reader now rejoins fragments, in numeric order, into the single base key — inner
text concatenated with **no separator** and rewrapped in one pair of quotes
(`"…Descrip"` + `"tion…"` → `"…Description…"`). Verified across the full corpus:
**19820 fragments collapsed across 28 base keys in all 58 INI files, 0 residual**;
every fragment was quoted, every group contiguous from `0001`, and a fragment
group never coexisted with a bare base key (clean replacement). Top base keys: `VI`
(14593), `PostExpr`, `StatusExpr`, `DescriptionFormat`, `%COMMENT`, `CodeTemplates`,
`ValueToLog`. Applies to both members and `%`-directives (e.g. `%COMMENT`, `%NAME`).
Single-line values never match the suffix and are untouched.

**Step free-text comments `%COMMENT` (2026-06, DONE).** A step's editor note is
stored as a `%COMMENT` directive on the step instance section (genuine prose, e.g.
`"Lock sequence"`, login explanations) — previously parsed but dropped during the
INI build (only `%NAME`/`%INSTOVRD` were carried). The reader now carries it,
unquoted, onto the built `SeqProperty` as a `%COMMENT` attribute, and the shared
lens exposes it as `Step.comment`. Recovered across the corpus: **667 of 5664 INI
steps** carry a non-empty comment (long ones arrive pre-joined by the continuation
fix above). XML steps in the corpus store **none** (no comment attribute/subprop),
so `Step.comment` is null for them — the getter is on the shared `Step` and returns
whatever each encoding holds. The app step view now shows the comment as a dim
italic line under the step name. *(Note: `DescriptionFormat` is a step-**type**
format template, not a per-step description, and the per-step `Description` member
is empty for all but 1 corpus step — so step comment, not description, is the
meaningful human text here.)*

**Sequence free-text comments `%COMMENT` (2026-06, DONE).** Sequences carry the
same `%COMMENT` note as steps — often substantial prose on callbacks/entry points
(e.g. *"This entry point is executed only once, when … is started. Put here the
code for general system initialization…"*). Since the INI builder now carries
`%COMMENT` onto every object generically, the data already lands on the sequence
`SeqProperty`; this slice exposes it on the shared lens as `Sequence.comment` and
the app shows it as a dim italic line at the top of the expanded sequence (and
includes it in the sequence filter). Recovered across the corpus: **102 of 449 INI
sequences**; XML sequences in the corpus carry none (their only attribute is
`name`), so `Sequence.comment` is null for them.

**Variable free-text comments `%COMMENT` (2026-06, DONE).** Locals/parameters can
carry the same `%COMMENT` note as steps/sequences, describing what the variable
holds (e.g. *"InfoTableRC: [row][col]"*, *"Off: AND together values for multiple
lights"*). Exposed on the shared lens as `SeqVariable.comment` (the data already
lands via the generic `%COMMENT` carry); the app appends it to the variable row as
` // comment`. Recovered across the corpus: **37 of 2514 variables**. This
completes the free-text-comment recovery story: steps (667), sequences (102), and
variables (37). XML variables in the corpus carry none.

**Module load/unload timing (2026-06, DONE).** A step's code-module lifecycle is
stored in `TS.LoadOpt` / `TS.UnloadOpt` — readable enums: load `PreloadWhenExecuted`
(default) / `DynamicLoad`; unload `UnloadWithFile` (default) /
`UnloadAfterStepExecution` / `UnloadAfterSequenceExecution`. `loadOption` existed
on the lens but was shown nowhere; added the symmetric `StepSettings.unloadOption`
and surfaced both as `load …`/`unload …` notes in the app step view and the text
dump **only when non-default**. Recovered: **63 INI steps** carry non-default
load/unload timing. *(TS.Adapter — the human adapter label like "G Std Prototype
Adapter"/"DLL Flexible Prototype Adapter", 149 steps — is readable but redundant
with the SData-derived [StepModule.adapter]; not surfaced separately.)*

**Step editor icon `TS.Icon` (2026-06, DONE).** A step's editor glyph is stored as
an icon resource path in `TS.Icon` (e.g. `FlowControl\NI_While.ico`,
`Measurement\Measurement.ico`, `MsgBox.ico`). Exposed on the shared lens as
`StepSettings.icon` — a readable basename with the folder and `.ico` stripped
(`NI_While`, `Measurement`, `MsgBox`), null for the default blank (`ni_blank`).
The text dump shows it as `{icon <name>}`. This is an **XML-only** signal in the
corpus: **59** XML steps carry a named icon (top: Measurement 20, ni_UpdateMapping
19, Statement 8, ni_hourglass 5, SeqAdp 4, MsgBox/NI_While/NI_End 1 each); **every
INI step uses `ni_blank`** (0 named), so `StepSettings.icon` is null for INI here.

**XML `typecategory` — opaque enum (2026-06, probed, not surfaced).** XML typedefs
carry `typecategory` but its value is a bare numeric code (`3`×505, `1`×93,
`2`×4), not a readable name; without NI docs the codes can't be named. Recorded,
not surfaced (no guessing). *(INI adapter distribution re-verified unchanged:
none 3478 · sequenceCall 1624 · labView 443 · cModule 119.)*

**`<typelist>` typedef structure — recovered & surfaced (2026-06, DONE).**
Coverage-neutral *format* recovery (the metric counts the `Data` tree only). Each
`<typedef>` wraps one type root; previously the lens exposed only a bare
`f.types.length` count. Probed the full corpus: **475 typedefs across 21 ≤300KB
XML files** — every typedef carries a `name` + base class (the root `classname`),
and **370 of them declare ≥1 field** (3649 fields total, 25 distinct base
classes). Most are NI's *internal* type system (`NI_PropertyObjectType`,
`NI_CustomResult`, `CommonResults`, `StepTypeMenu`, step-type defs, `Error`,
`Expression`), alongside user/cluster types. Added `SeqType` (`name`, `baseClass`,
`fields` = ordered `(name, type-token)` pairs) and `SeqFile.typeDefs`; the text
dump now prints a `Types (N):` section listing each type's base class and fields.
This surfaces **recovered names/structure only** — the *semantics* of a field's
NI-internal attributes (`ValueType`/`IsObject`/`Representation`/`CanBeSubstepType`
…) are NI-internal machinery and are **not yet decoded**, so no meaning is
claimed. (`f.types` stays the raw `List<SeqProperty>`; `typeDefs` is the typed
1:1 view over it.)

**Coverage-ceiling composition — honest accounting (2026-06, CORRECTS A PRIOR
CLAIM).** Replicated `measureCoverage`'s exact marking to build the modeled
identity set, then classified **every** unmodeled `Data`-tree node (over the 21
≤300KB XML files: 11311 nodes, 50.2% modeled, **5637 unmodeled** — note this is
the ≤300KB subset; the headline 46.6% is over all 26 XML). The remainder breaks
down as:
- **module (`SData`) subtree descriptors — 2957 nodes = 52.5%** (the *largest*
  bucket): the per-step adapter/module-call data below what the lens already
  pulls (paths, funcs, `Parameters`/call-args). This is the parameter-type-system
  machinery inside a module call — the genuine remaining frontier, possibly
  partly recoverable, **not yet decoded**.
- **per-step `TS` option cluster — 1462 nodes = 25.9%**: the flat option leaves
  (`OperationOrder`/`ConnectionLifetime`/`BatchSyncOpt`/`Switch*`/`RouteGroup*`/
  `MulticonnectMode`/`WaitForDebounce`/`VirtualDeviceName`/`WindowActivation`/
  `LoopOpt`/`PrecondIntExe`/`CanEdit*`/`CanSpecifyModule`) — numeric codes +
  editor-permission bools; semantics unconfirmable → modeling = fabrication.
- **other — 1218 nodes = 21.6%**: dominated by **empty/default scaffolding** —
  `Requirements→Links [Strs]` (empty array, no links stored in this corpus),
  `MessageType` (empty in all 147), `CustomResults`/`AdditionalResultsHints`
  (empty Objs), plus opaque constants (`Priority` = the single value
  `2953567917` across all 21) and per-sequence entry-point editor metadata
  (`EP*`, e.g. `EPNameExpr="Unnamed Entry Point"`).

**Correction:** earlier notes/mandate said the unmodeled remainder is "dominated
by the per-step TS-option cluster." That is **wrong** — the module (`SData`)
subtree is the largest gap (52.5%), the TS-option cluster is second (25.9%). The
honest highest-value frontier is the module call-data subtree, not the TS
options (which remain unconfirmable and off-limits to modeling).

**LabVIEW VI-call descriptor + connector pane — recovered & surfaced (2026-06,
DONE; +1.9pt coverage).** Acting on the ceiling accounting above, attacked the
biggest unmodeled bucket: the per-step `SData` module subtree. Probed it across
the corpus — node concentration is **FGModule (LabVIEW ViCall) 2210 nodes/10
steps** ≫ CPythonModule 1238/31 ≫ FCModule 70/2. The LabVIEW `ViCall` record is
richly self-describing, so modeled the parts that need **no** interpretation:
- **Call descriptor** on `StepModule`: `viNamespace` (`ViCall.Namespace`, the
  owning `.lvlib`/`.lvclass`, e.g. `NIDCPowerSourceDCVoltage.lvlib`),
  `viProjectPath` (`.lvproj`), `viCallName`, `viDescription`, `showsFrontPanel`
  (`ShowFrnPnl`). (`viPath` was already recovered.)
- **Connector pane**: `StepModule.viParameters` reads `ViCall.Parms` — each a
  [CallParameter] exposing `name` (now also reads `Label`, the VI-param name),
  `displayType` (`DisplayType`, a **human-readable** type like `Object
  Reference`/`Container` — no code-guessing), `boundExpression` (`ArgVal`, the
  wired expression, e.g. `ThisContext`, `Step.Result.Error`), and
  `connectorNumber` (`ConnectorNumber`, the connector-pane terminal index).
Dump shows `{vi: lib …, proj …}` + `{conn: #11 sequence context (Object
Reference)←ThisContext; …}`. Corpus: **10 VI-call steps, 25 connector params,
every one with a DisplayType and a connector index, 15 bound, 10 with a library
namespace.** Coverage **46.6% → 48.5%** (9174/18932). Left raw (not yet decoded):
the numeric `Type`/`NumType`/`ArrayType`/`ClusterType`/`ReferenceType` codes and
`Direction` (ViCall `Parms` use a `0`-based encoding distinct from the
`Parameters` `1/2/3`; `direction` returns null, `directionCode` stays raw). Next
SData targets: the CPythonModule call descriptor (`FunctionOrAttributeName`,
`PythonVersion`, `ModulePath`, `ClassName` — all self-evident) and the FCModule
`Call.Parms` C descriptor.

**Python (CPythonModule) call descriptor — recovered & surfaced (2026-06, DONE;
+0.8pt coverage).** Continued the SData frontier into the second-biggest bucket
(CPythonModule, 1238 nodes/31 steps). Probed `SData.PythonCall` (classname
`CPythonCall`) across the corpus — every one of the 31 steps carries clean,
self-evident fields, so modeled on `StepModule`: `pythonFunction`
(`FunctionOrAttributeName`, the called fn, e.g. `create_instrument_sessions`),
`pythonModulePath` (`ModulePath`, the `.py` file), `pythonClassName`
(`ClassName`, null when the call is module-level — empty across this corpus),
`pythonVersion` (`PythonVersion`, e.g. `3.9`), `pythonVenvPath`
(`PythonVirtualEnvironmentPath`). `StepModule.fromSData` now sets the Python
`target` to the (class-qualified) callee instead of leaving it
`(target not yet recovered)`. Dump: `-> python: create_instrument_sessions
{python: mod …\test.py, py 3.9}`. Corpus: **31 Python steps, all naming a
function + module + interpreter version, 23 distinct functions.** Coverage
**48.5% → 49.3%** (9339/18932). Left raw (not yet decoded): the numeric
`OperationType`/`OperationScope`/`InterpreterSessionScope`/
`DefaultParamCategoryForArray` codes and the adapter-config bools. Remaining big
SData target: the FCModule `Call.Parms` C descriptor (only 2 steps — low reach).

**Measurement plug-in resource set — recovered & surfaced (2026-06, DONE;
+0.2pt).** A file-level lens: `SeqFile.measurementPlugIns` reads
`Data > FileGlobalDefaults > MeasurementPlugIns` into a [MeasurementPlugIns] with
the **pin map** (`PinMapPath`) and the STS file lists `specificationFiles`/
`levelsFiles`/`timingFiles`/`patternFiles` (each a `*FilePaths` `Strs` array) plus
`monitoringEnabled`. These are the external test-program files a sequence depends
on — all clean paths, self-evident. Dump prints a `Measurement plug-ins:` section
(also visible in the app's Dump tab). Corpus: **11 files declare the block, 1
carries the full pin-map + specs/levels/timing/pattern set** (most are a bare
`EnableMonitoring` default). Coverage **49.3% → 49.5%** (9372/18932). Also
surfaced structurally in the app: a green "Measurement plug-ins" header card at
the top of the Sequences tab (`SeqOutline.plugins` / `MeasurementPluginsOutline`),
not just the Dump tab.

**FCModule `Call.Parms` — probed, NOT modeled (no real data, 2026-06).** The last
SData module remnant. Probed across the corpus: **2 steps, 2 params, both the
function `Return Value` with an empty `ArgVal`** — only `Name` ("Return Value")
and a `StrSize` constant (`1024`) are non-empty; everything else
(`Type`/`NumType`/`ObjType`/`ResultAct`/`Flags`) is a numeric code. There is no
meaningful bound-argument data to recover here, so modeling it would add a lens +
dump + app surface for ~zero signal. Deliberately **left unmodeled** (honest: no
fabrication of a feature where the corpus carries none). Completes the honest
finding that the XML module-call recovery is done (ViCall + Python carry the real
data; C-module calls in this corpus pass no inputs).

**CEILING RE-PROBED after ViCall/Python/plug-ins (2026-06) — frontier largely
reached.** Re-ran the exact-marking classifier (21 ≤300KB XML, now 53.4% on that
subset, 5272 unmodeled). The remainder is now **dominated by off-limits content**,
not clean data:
- **SData/ViCall ~37%** — per-connector-param numeric type codes
  (`Type`/`NumType`/`ArrayType`/`ClusterType`/`ReferenceType`/`WireRequirement`)
  + empty containers (`ArrayClusterEls`, per-param `AdditionalResult`/`Condition`)
  + ViCall `Override*`/`Node*` call-level fields (mostly empty/flags). Unconfirmable.
- **TS ~31%** — the per-step TS-option cluster (numeric codes + editor-permission
  bools), unconfirmable → off-limits.
- **`AdditionalResults` `Flags`/`CheckedState`** (110 each = `8192`/`1`) — numeric
  codes, not yet decoded.
- **`Measurement.MessageType`** (147) — empty in every case.
- **file/seq-level "other"** — empty/default scaffolding (`Requirements→Links`,
  `RTS`, `FileGlobalDefaults` empties), opaque constants (`Priority`,
  `FailureAction`, `Type`), entry-point editor metadata (`EP*`), and per-step
  font/display config (`FontColor`/`Bold`/…).
The clean, self-evident remnants are now small: the file `Version` (mostly
`0.0.0.0`) and the FCModule `Call.Parms` C descriptor (2 steps). **Honest take:
the high-value XML recovery frontier is essentially exhausted; further coverage
gains would require decoding NI's numeric type/option codes (no corpus-internal
evidence → would be fabrication), so they stay raw.**

**Step-id resolution `ID#:` → step name (2026-06, DONE).** Each step's `TS.Id` is
a unique id in `ID#:<uid>` form (e.g. `ID#:HWpAiIXA8BG5VlB7nf4f8B`). Flow-action
targets that reference a step do so by that id. The custom-condition targets
(`CustTrueActTarget`/`CustFalseActTarget`) hold **12** such `ID#:` references across
the corpus — and **all 12 resolve** (same file, in fact same sequence) to a step's
`TS.Id`. Added `SeqFile.stepNameForId(idRef)` (a cached `TS.Id`→name index,
tolerant of the `ID#:` prefix) plus `StepSettings.customTrueTarget`/
`customFalseTarget`; the app step view and text dump now show
`cust-false→<stepName>` instead of the opaque uid (bookmarks like `<Cleanup>` left
verbatim). The pass/fail flow targets themselves are all `<…>` bookmarks (0 `ID#:`),
so resolution only changes the custom-condition targets today — but the resolver is
general (any `ID#:` step reference can now be named).

**Step flow-action jump targets (2026-06, DONE).** A step's on-pass/on-fail flow
action can jump rather than fall through (`PassAct`/`FailAct = "Goto"`); the
destination is stored in `PassActTarget`/`FailActTarget` as a TestStand
string-literal expression — e.g. the special bookmark `\"<Cleanup>\"` or a step
reference `\"ID#:…\"`. The shared lens now exposes `StepSettings.passActionTarget`
/`failActionTarget` (surrounding/escaped quotes unwrapped → `<Cleanup>`) and a
composable `StepSettings.flowSummary` (`Next/Goto→<Cleanup>`) used by both the app
step view and the text dump. Recovered across the corpus: **58 of 5664 INI steps**
carry a flow target (PassAct/FailAct = Next on the rest). Action values seen: `Next`
(majority), `Goto` (57). Targets are mostly `<Cleanup>` (jump to cleanup) with some
`ID#:…` step references; resolving an `ID#:` target to the destination step's name
(via the step `Id` member) is a possible future enhancement — shown verbatim for
now (honest, not yet name-resolved).

**Custom-condition flow fields (2026-06, DONE).** Beside the pass/fail flow
actions, each step carries the *custom-condition* trio: `CustExpr` (the
expression evaluated to choose a branch — the custom-condition counterpart to
`PreCond`), and `CustTrueAct`/`CustFalseAct` (the per-branch actions, same
vocabulary as `PassAct`: `Next`, `GotoStep`, …). Their jump targets were already
modeled (`CustTrueActTarget`/`CustFalseActTarget` → `customTrueTarget`/
`customFalseTarget`); this completes the feature with `StepSettings.custom-
Expression`/`customTrueAction`/`customFalseAction`. The dump shows `cust-cond
<expr>` before the branch targets. Corpus: **87 steps carry `CustTrueAct`/
`CustFalseAct`** (all the default `Next`) and **0 set a non-empty `CustExpr`** —
the corpus uses preconditions, not custom conditions, so these are standard flow
fields sitting at their defaults (the same class as the mostly-`Next`
`PassAct`/`FailAct`). Coverage marks the three `TS` keys (+423 nodes → the
34.0 %→36.3 % bump).

**Text dump completeness (2026-06, DONE).** `dumpSeqFile` (the editor-like text
view behind the app's Dump tab) now surfaces the recovered detail it had been
omitting: sequence/step/variable free-text comments (as ` // comment`) and variable
container sizes (` [N]` array / ` {N fields}` object), matching the structured view.
*(XML carries no comments — see below — so this only adds content for INI files.)*

**XML stores no comments (2026-06, verified).** Confirmed the comment getters'
null-for-XML behaviour is correct, not a gap: the token "comment" does **not appear
anywhere** in any of the 26 XML `.seq` files (case-insensitive raw-text scan). XML
simply does not serialize the editor's free-text notes, so `Step/Sequence/
SeqVariable.comment` are legitimately null for XML — nothing to wire up.

**Exact-count regression guards (2026-06).** The corpus decode outputs are
deterministic (verified identical across repeated runs), so the most valuable
corpus assertions are pinned to exact counts rather than loose `>0` — XML: 26
files / 33 seqs / 214 steps / 124 module bindings / 10 limit tests / 7 intra-file
calls / 288 binary bodies; INI: 58 files / 449 seqs / 5664 steps / 1662 locals /
2242 types / 2186 recognized + 3478 none adapters / 13072 overrides / comments
667+102+37 / 95 object-var fields / 58 flow targets / 12 resolved ID#: targets /
19820 continuation fragments across 28 base keys. A silent decode regression (or a
corpus change) now fails with the delta. Inheritance-driven counts (typed/run-mode/
looping) stay loose since they track type-def handling, not a fixed feature count.

**INI parser drops no data lines (2026-06, verified + guarded).** Audited every
non-blank, non-section line across all 58 INI files against the parser's only skip
path (`eq < 0`, a line lacking ` = `): **0 lines skipped** — every in-section line
is a real `key = value`, so no data is silently dropped. Locked in as a corpus
regression guard so a future file introducing a new line shape is caught, not
quietly lost.

**Variable container sizes (2026-06, DONE).** Locals/parameters that are
objects/clusters or arrays now report their size via the shared lens
(`SeqVariable.isArray` + `SeqVariable.containerCount`): the field count for an
object/cluster, the element count for an array (0 for an empty default array,
distinct from a scalar's null). The app's variable rows show it as ` {N fields}`
for objects and ` [N]` for arrays, alongside the existing `name : type[= value]`.
Recovered across the corpus: **95 INI object/cluster variables expose a non-zero
field count** (e.g. `Limits_DUT : Obj {15 fields}`); arrays are mostly empty
defaults (only ~8 carry stored elements), shown honestly as `[0]`.

**Step `ResultOption` / parameter direction — probed, not surfaced (2026-06).**
`TS.ResultOption` is present on 5609 steps but its value is a bare `1` (5033×) /
`0` (576×) — a binary flag whose semantics aren't readable without NI docs (likely
record-results on/off, but not asserted; no guessing). Parameter **direction**
(in/out/inout) is **not stored as a readable member** — probed `Direction`/
`ParamDirection`/`Dir`/`IOType` on all 751 params: zero hits; only the value-kind
className is present (already shown via the lens `type`). Both recorded, neither
surfaced rather than guessing a bitmask.

**Type base/parent — NOT cleanly stored (2026-06, probed, no slice).** Checked
whether a type def records a derivation/base-type pointer. INI `[DEF,<Type>]`
sections carry `%ROOT_TYPE` on **all 2242** type defs but its value is the boolean
`True` (an "is a root/named type" flag, not a parent name); the `Type` member is
sparse (`Num`/`Str`/a single `NI_PropertyObjectType` ref) and not a base link. XML
typedefs expose `isroottypedef`/`typecategory`/`typeflags` — again flags, not a
named parent. So a "type extends Base" relationship is **not recoverable** from
these fields as stored in this corpus; not pursued (would be guessing). *(Type
inheritance from instance→type IS modelled — see "Type inheritance" above — that's
a different relationship than type→base-type.)*

**XML↔INI lens parity — audited, at parity (2026-06).** Ran the shared typed lens
over all **26/26** XML `.seq`: 33 sequences · 214 steps (**all typed**) · adapters
recognized=124 / none=90 / **unknown=0** (python 33, cModule 69, labView 15,
sequenceCall 7) · 141 steps with run-mode+looping · 10 limit tests · 101 locals ·
602 types. So XML recovers the same dimensions as INI with no `unknown` adapters —
**no lens gap**. The two apparent differences are genuine, not bugs: `params=0`
(these example MainSequences define no parameters — their `Parameters` is an empty
`Obj`) and `overrides=0` (`%INSTOVRD` is an INI-only inheritance directive; XML
serializes every value inline). The XML corpus test now asserts all-steps-typed
and `unknown==0` as a parity regression guard.

**Corpus repo-search is now low-yield (2026-06).** A validated batch (4 `gh search
repos` queries → 20 deduped candidates, fork-filtered, tree+signature checked)
found **no new authentic sources**: the only two with `.seq` were
`liyan295/grpc-teststand-api` (identical 6 ExampleFiles → a content-dup of the
already-listed `ni/grpc-teststand-api`) and `kellyrael/VibeCodedTestStand` (root tag
`<TSSequenceFile>`, **not** NI's `<teststandfileheader>` — almost certainly
AI-generated, not authentic NI TestStand; not added). With 36 pinned sources the
gh-discoverable space is largely mined; bigger growth needs a different channel
(org-scoped crawls, dataset dumps) or accepting the binary-heavy long tail.

Next slices: (1) decode any further non-empty unrecognized `SData` shape if/when
the corpus grows one (.NET/HTBasic/NI plug-in). (2) **use this concrete per-object
member→type→value layout as the oracle for the binary**:
for a given object the INI tells us the exact ordered members, their types, and
values — line that up against the binary record stream (name-index/`field`/`count`
triplets) to finally decode the binary record's field/count/value encoding.
*(Binary record tree not yet decoded — not unrecoverable.)*

## PropertyFlags (`%FLG`) — type-level options, recovered raw; bits partly mapped

Each property in the INI form carries a `%FLG: <member> = <bitmask>` directive on
its owning object's section (value **and** DEF sections). Differential analysis
over the full corpus shows the mask is **~constant per property *name***: of 62
property names with ≥20 samples, all hold a single dominant mask ≥90% of the time
(most 100%, e.g. `SData` 1601/1601, `ReportText` 909/909, the EP*/Show* family
441/441). A value that is fixed by *name* and independent of the instance is the
property's **type-level PropertyFlags** (its stored options), not instance data.

Recovered and surfaced verbatim as `SeqProperty.propertyFlags` (raw `int?`,
threaded from `%FLG: <member>` exactly like `%INSTOVRD`); XML-sourced trees and
inherited-only members read `null`. **Bit *functions* are not yet decoded** (they
need NI's `PropFlags` enum); only the per-bit *membership* below is corpus-fact.

Bit → property-name membership (dominant mask, ≥90%/n≥20 properties):
- **bit22 `0x400000`** — near-universal (39 names): `Setup` `Main` `Cleanup`
  `Locals` `Priority` `Status` `Error` `ReportText` `Result` `Parameters`
  `RecordResults` `Links` the whole `EP*`/`Show*` family … ⇒ a general "stored"
  flag. **NOT** "report column" (it is set on structural members too).
- **bit21 `0x200000`** (5): `ActualArgs` `ArrayClusterProto` `ComplexParts`
  `SData` `UserData` — all object/aggregate sub-data holders.
- **bit3 `0x8`** (10): `BatchSync` `FailureAction` `LoadOpt` `UnloadOpt`
  `ModelFile` `ModelOption` `Version` `RTS` `RecordResults` `SFGlobalsScope` —
  model/execution-option members.
- **bit17 `0x20000`** (3): `CanEditCode` `CanEditModulePrototype`
  `CanSpecifyModule` — module-edit capability members.
- **bit2 `0x4`**, **bit18 `0x40000`**, **bit26 `0x4000000`**, **bit0 `0x1`** —
  smaller/mixed clusters, function not yet decoded.

Hypotheses **disproven** on the corpus (recorded to prevent regressions):
- bit22 ≠ "report column" — set on `Setup`/`Main`/`Cleanup`/`Locals` too.
- bit21 ≠ "is a container" — `Locals`/`Result`/`Parameters` are containers but
  carry bit22, not bit21.

### `%FLG` vs `%INSTFLG` vs `%INSTOVRD` — the override delta (bit16 decoded)

Three flag directives co-exist; differential analysis pins their relationship:
- `%FLG: <m>` — the member's **type-level** PropertyFlags (39400 samples).
- `%INSTFLG: <m>` — the instance's **effective** flags (18910); ≈ `%FLG` (the base).
- `%INSTOVRD: <m>` — the flags on an **instance-override** record (19859 member-
  scoped + 343 bare). It is the base flags **OR-ed** with override-only bits, e.g.
  `SData` base `0x200000` → override `0x6D0019` (= `0x200000 | 0x4D0019`).

**Decoded: bit16 (`0x10000`) is an override-set bit, never a type flag.** It is set
in **14133 / 19859** member-scoped `%INSTOVRD` masks but in **0 / 18910** `%INSTFLG`
and **0 / 39400** `%FLG` masks (0 / 58310 base total, and 0 / 343 bare overrides) —
so the engine sets it when a member is instance-overridden, it is not part of the
property's stored type flags. It skews to leaf **value** overrides (`ResultAct`,
`StatusExpr`, `LoopWhile`, `Flags`, `Links`) over container/metadata members (`TS`,
`Substeps`, `Common`, `DescriptionFormat`); the exact value-vs-structural trigger
that leaves the other 29% clear is **not yet fully decoded**. Surfaced typed as
`SeqProperty.instanceOverrideFlags`.

## Structured sequence-logic export — flow-control nesting recovered (2026-06, DONE)

The PLAN's stated TestStand goal is to "export the sequence **logic**". The flat
per-step dump didn't convey control flow, so `exportSequenceLogic(SeqFile)`
(`seq_dump.dart`, also wired into `dumpSeqFile` as a `=== Sequence logic ===`
section) now renders each sequence as **nested, readable pseudocode** — built
entirely from already-recovered fields, no new decode.

The `NI_Flow_*` step types form **balanced structured blocks**: each opener
(`NI_Flow_If`/`While`/`DoWhile`/`For`/`ForEach`) is closed by a matching
`NI_Flow_End`; `NI_Flow_Else`/`ElseIf` are mid-block continuations; `Break`/
`Continue` are statements. Modeled as `FlowControl` + the `FlowKind` enum (each
kind owns `opensBlock`/`closesBlock`/`isContinuation`) with `Step.flowControl`.
Nesting is derived purely by counting open/close (the numeric `Offset`/`Block*`
bookkeeping is unpopulated/not needed); `_emitLogic` clamps depth so a malformed
block can't underflow.

**Field locations — corpus-verified, all flat DIRECT children of the step** (NOT
under a child object named after the construct, which an earlier draft wrongly
assumed): `If`/`ElseIf`/`While` → `ConditionExpr`; `For` → `InitializationExpr`/
`ConditionExpr`/`IncrementExpr`; `ForEach` → `ArrayExpr`/`ArrayElementExpr`
(+ optional `OffsetExpr`). Each renders as real logic, e.g.
`if (Locals.X > 0) {`, `for each (Locals.Item in Locals.Items) {`,
`while (StationGlobals.DebugPanelActive) {`. Non-flow steps render as
`name → call-target  [if precond]  [limits]  [on fail → <target>]`.

**Pass/fail jump annotation (2026-06).** `_logicStepLine` now appends a step's
non-default pass/fail jump (`_jumpAnnotation`): a `Goto`/non-`Next` PassAct/FailAct
with its target, e.g. `[on fail → <Cleanup>]`. An `ID#:` target resolves to the
destination step's name (via `SeqFile.stepNameForId`); a bookmark like
`<Cleanup>` shows verbatim. Fall-through (`Next`/`Next`) steps — the overwhelming
majority — get nothing. Corpus: **47 non-default actions (46 fail:Goto, 1
pass:Goto) across 8 files**, every one annotated in the export (the other 1615
pass / 1570 fail actions are `Next`). The step's own precondition is already
shown inline as `[if …]`. NI_Flow_* steps carry no own pass/fail action.

**Per-sequence header — signature + summary (2026-06).** Each sequence header in
`exportSequenceLogic` reads like a function declaration:
`sequence <name>(<param>: <Type> = <default>, …):  // N steps, L locals`.
`_paramSignature` renders the declared parameters (name + type + optional default)
— corpus: **109/220 sequences parameterized, 280 params, 100% typed**; empty
parens omitted for parameterless sequences. `_seqSummary` adds the step count
(always) and local count (when non-zero), correctly pluralized; the param count
moved into the signature so it isn't duplicated. All from the lens
(`Sequence.parameters/steps/locals` → `SeqVariable`), no fabrication.

**External SequenceCall cross-reference (2026-06).** A `SequenceCall` whose
target sequence isn't in this file (`SeqFile.resolveCall` returns null and the
step has a `SFPath`) now renders `→ <seq> in <file>` in the logic line, making
the cross-file dependency explicit. Corpus: **330 external calls across 17
files** (vs 138 in-file self/intra-file calls, which show just `→ <seq>`), every
external one marked. In-file calls stay unmarked (the app's outline already shows
a "go to sequence" jump for those).

**Looping-step annotation (2026-06).** A non-flow step can itself loop (the step
repeats under its `LoopType`); `_loopAnnotation` appends e.g.
`[loop FixedNumLoops while RunState.LoopIndex < 10]` — the loop type plus the
loop-while termination condition when set (init/increment/status stay in the
fuller per-step dump). Corpus: **65 looping non-flow steps across 8 files**
(PassFailCount 30, Custom 20, FixedNumLoops 15), each annotated; the other 1308
non-flow steps don't loop. So a non-flow logic line now reads
`name → target [if precond] [limits] [loop … while …] [on fail → <target>]`.

**App surfacing (inspector).** The structured outline (`sequence_outline.dart` →
`sequences_view.dart`) now reflects control flow: each `StepOutline` carries a
`flowHeader` (the construct header) + a `flowDepth` (nesting level, computed by
the same balanced open/close walk as `_emitLogic`), so the sequence tree indents
its blocks and shows a teal flow-construct chip (`if (…)`, `for each (…)`,
`end`, …). The header is searchable. The dump view already carried the
`=== Sequence logic ===` section. A **dedicated read-only "Logic" tab**
(`main.dart`, 2026-06) renders `exportSequenceLogic(file)` on its own as
selectable monospace pseudocode (with copy-to-clipboard) for any parsed file —
the full recovered control flow at a glance, distinct from the structured
outline and the raw Dump. Tab order: Dump · Logic · Sequences · Properties ·
Types (Logic..Types only for a parsed file). Binary files have no Logic tab.

Corpus evidence (XML+INI ≤300KB, `recovers structured flow-control logic`):
**141 openers / 141 ends (balanced), 42/42 flow-bearing sequences nest cleanly**;
82 if/while + 12 for → **94/94 conditions populated**; 12/12 for init+incr;
**53/53 for-each array+element bindings**. 100% population where applicable — the
sequence's actual control logic, recovered. Coverage credits these fields
(`seq_coverage.dart`): XML 49.3%→**49.5%** (only 1 conditional opener in the XML
corpus), INI 33.1%→**33.3%** (+277 nodes, 315 flow steps). Off-limits numeric
`Block*`/`Offset` codes left raw.

## Status & honest gaps

**INI decode — COMPLETE (58/58).** `parseSeqFile` builds a `SeqFile` from every
INI file (58/58 built, 0 threw), the shared lens recovers
sequences/steps/locals/parameters/module-bindings, and the inspector renders INI
via `IniSeqDocument` — the app shows **84 files structured (26 XML + 58 INI)**.
`SeqFile.types` is populated from `[%TYPES]`. Recovered and surfaced (see the
per-feature DONE notes above): type inheritance (run-mode/looping/adapter
defaults, instance-wins); empty-SData → `SeqAdapter.none` (`unknown` == 0);
`%INSTOVRD` override markers (13072, shown via the app's ⋄ marker); free-text
comments on steps/sequences/variables (667/102/37, searchable); variable container
sizes; multi-line `LineNNNN` continuations (19820 reassembled); flow-action jump
targets + `flowSummary`; `ID#:` step-reference resolution; step editor icon (59
XML); module load/unload timing (63 INI). XML is at lens parity (26/26).

**Empty/placeholder members (probed, nothing to surface):** a step's `Substeps`
container is present on all 5663 INI steps but is **always empty** in the corpus
(0 with child content) — a structural placeholder (edit-time pre/post substeps),
no per-step data to recover here.

**Binary string-region recovery (record grammar still undecoded, but data is
recoverable).** Beyond the property-name table (`binaryNameTable` /
`binaryObjectNames`), two high-value datums are now read straight from the packed
string pool, honestly, without the record grammar:
- **Module call-targets** (`binaryModulePaths` + the `isBinaryModulePath`
  predicate) — the LabVIEW VIs / DLLs / sub-sequences / libraries a binary `.seq`
  invokes (path-separated, `.vi`/`.dll`/`.seq`/`.llb` suffix). Corpus: **190/288
  files expose ≥1 (1599 total, 113 with accented chars)**; the rest make no
  external calls. *What* is called, not yet *from which step*. (The string scanner
  is Latin-1-aware — `isBinaryPrintable` includes `0xa0..0xff` — so accented paths
  like `…\4_Aktif_Güç.vi` stay intact instead of fragmenting at the accent; this
  added +103 complete paths over ASCII-only with no garbage.)
- **`ID#:` step references** (`binaryStepReferences`) — the same unique step-ID
  tokens the text encodings resolve to links. Corpus: **285/288 files expose ≥1**.
- **Expressions** (`binaryExpressions` + the `isBinaryExpression` predicate) — the
  sequence's actual *logic*: limit/condition comparisons, `RunState`/`Locals`/
  `Step` member access, ternaries, and known expression functions (`Abs(`,
  `ResStr(`, …). Disjoint from module paths / `ID#:` refs by construction. Corpus:
  **285/288 files expose ≥1 (15910 distinct total)** — *which* expressions a file
  evaluates, not yet *attached to a specific step/field* (record grammar).
- **Quoted literals** (`binaryQuotedLiterals` + `isBinaryQuotedLiteral`) — constant
  values (instrument resource strings, expected values, captions). Whole-entry
  `"..."`, excluding quoted entries that are really expressions, so it stays
  disjoint from the four above. Corpus: **288/288 files, 2883 distinct**.

**Binary record region — probed, structural wins exhausted (needs external input).**
Full-corpus probing of `binaryRecordWords` (233 rooted files) established what the
record stream's leading words are: `w[2]` is always name-pool index 1 (`"Data"`,
the root object) — 233/233, 0 counterexamples (the first record→name anchor; also
noted on `binaryRecordWords`). `w[1]` is a layout/version selector taking several
values (118×179, 16×38, 20×12, plus 18/272/276) — not a 2-way split. `w[0]` is
**not** a simple count (≠ name-pool size / object count / record-word count /
segment count). Beyond `w[2]`, constant positions are layout-specific, not
universal. The variable-length record grammar that ties a name to its record/value
needs a byte-identical INI↔binary twin (absent) or NI docs — not more probing.

**Genuine gaps (need external inputs — do NOT guess):**
- **Binary record grammar** past the header — not yet recovered (see above). The
  string *content* (names, module paths, step refs, expressions, literals) is
  recoverable; the *records* that tie strings to a parsed step tree are not.
- **Flag/enum bitmasks** whose *values* are stored but whose *meaning* needs NI's
  enums: the type-level `%FLG` PropertyFlags (now recovered as
  `SeqProperty.propertyFlags` + bit *membership* mapped — see the PropertyFlags
  section above — but bit *functions* still undecoded); the `%INSTOVRD`
  instance-override bitmask; the step `ResultOption` 1/0 flag; the XML
  `typecategory` numeric code. Recorded verbatim, not interpreted.
- **Config / station files** — `corpus/seq-sources.json` captures
  `.ini/.cfg/.tsw/.tpj` when present, but the open-source corpus is
  sequence-heavy; type-palette and station-config samples are sparse. (CN-IOT's
  `.ini` files are *localization string packs*, not structural config — excluded.)
- **VI-reader cross-link** — a step's adapter *binding* is decoded (which VI/DLL/
  sequence path it calls); resolving that path to the actual parsed VI in the VI
  reader (+ parameter mapping) is the deferred cross-tool link.

Project honesty rule (CLAUDE.md): mark undecoded ranges explicitly; say "not yet
recovered", never "unrecoverable".
