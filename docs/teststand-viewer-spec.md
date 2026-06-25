# TestStand reader & viewer — specification (draft for review)

## Why

Most of the existing test infrastructure relies on **NI TestStand**, not LabVIEW.
TestStand sequence files (`.seq`) and the related station/config files encode the
*actual* test orchestration: the sequence of steps, their types, parameters,
limits, flow control, and bindings to code modules (LabVIEW VIs, DLLs, .NET,
expressions). To migrate off NI we must first *understand and extract* that
content. This reader plays the same role for TestStand that the VI reader plays
for LabVIEW:

1. **Visibility** — surface every hidden attribute and field, byte-accurate, the
   way the VI inspector does for `.vi` (a clickable view where every byte maps to
   a known purpose).
2. **Faithful display** — render a view as close as possible to what the TestStand
   Sequence Editor showed: the sequence list (Setup / Main / Cleanup), each
   step's name/type/properties, the step settings, and the variable/parameter
   tables.
3. **Logic export** — emit the recovered sequence as readable Dart (mirroring the
   VI→IR→Dart scaffold): steps → calls, flow control → Dart control flow, with
   honest `TODO` stubs where semantics aren't yet recovered.

There is far less *visual/geometric* information than in a VI block diagram (no
wires, no freeform 2-D canvas — a sequence is essentially a typed, ordered tree),
so this should be **more tractable** than the VI work. The hard part is the
proprietary on-disk format, not the rendering.

## Honest unknowns (resolve by probing real files — do NOT assume)

The on-disk `.seq` format is proprietary and under-documented. Before any
structural claim, the agent MUST gather real sample files and probe them. Open
questions to answer empirically in **Milestone 0**:

- **Container format.** Is `.seq` a Microsoft Compound File Binary (OLE2/CFBF,
  magic `D0 CF 11 E0`)? a flat proprietary binary? XML? a versioned mix across
  TestStand releases? (TestStand has offered binary and XML-ish file options over
  its history — confirm against the corpus, per version.)
- **Type system.** TestStand is built on a property/type model (containers,
  arrays, named types, references). How are custom data types and the standard
  step types serialized?
- **Step model.** How are Setup/Main/Cleanup groups, step type, step properties
  (limits, comparison, looping, preconditions, post actions), and the **module
  adapter** binding (which VI/DLL/.NET method + parameter mapping) stored?
- **Related files.** `.config`/station files, type palettes (`.ini`?), process
  models — which are needed to fully resolve a sequence, and what are their
  formats?

Apply the project honesty rules (CLAUDE.md): mark undecoded ranges explicitly,
"not yet recovered" never "unrecoverable", probe the full sample set before
quoting a percentage.

## Architecture (mirror the VI reader)

New workspace package(s):

- `packages/labwright_teststand` — clean-room parser + model:
  - container layer (e.g. an OLE2/CFBF reader if that's the format, or the
    relevant binary/XML reader), analogous to viparse's RSRC layer;
  - a typed object model: `SeqFile` → sequences → steps → properties, plus the
    variable/parameter/type tables — every field typed (no raw blobs left
    unlabeled), with confidence labels like the VI block catalog;
  - decoders per record/property kind, each corpus-verified + tested.
- Logic export (`…/lib/src/seq_to_dart.dart`) — an honest sequence→Dart scaffold,
  analogous to `generateDartScaffold`, with a no-fabrication marker.
- Viewer — surface in a Flutter app (extend `apps/labwright_vi_inspector` into a
  shared inspector, or a sibling `apps/labwright_teststand_inspector`; decide once
  the model exists): sequence tree, per-step settings panel, variables/params
  tables, a **byte inspector** with the same "% framed" per-record coverage metric
  the VI hex view has, and a Generated-Dart tab.

Reuse what already exists: the byte-inspector/coverage-metric pattern, the
confidence-enum pattern, and the IR→Dart scaffold shape are all directly
transferable.

## Corpus

Mirror the VI corpus approach: a pinned, reproducible set of **real `.seq`
files** (NI example sequences ship with TestStand; open-source TestStand repos on
GitHub; the maintainer may supply representative in-house sequences — sanitized).
Add a `teststand` source catalog + a fetcher (reuse the `fetch_corpus.dart`
pattern) writing to a gitignored `corpus/seq/`. Drive corpus processing through
the **single-VM bounded-concurrency** harness (CLAUDE.md), not `-j 1`.

## Milestones

- **M0 — Format reconnaissance.** Acquire a diverse `.seq`/`.config` sample set;
  identify the container format(s) and version variance; write a probe that dumps
  structure; document findings honestly. Gate: we know what we're parsing.
- **M1 — Container + skeleton.** Parse the container; enumerate the top-level
  objects/streams; recover the sequence list and step names/types for the common
  case. Totality + fuzz tests (never throw on arbitrary bytes).
- **M2 — Step & property decode.** Decode step properties (limits, comparison,
  flow control, preconditions/post-actions) and the variable/parameter/type
  tables; per-record coverage metric climbing toward 100%.
- **M3 — Module-adapter bindings.** Recover each step's code-module binding (VI /
  DLL / .NET / expression) and parameter mapping — the link from sequence to
  implementation (this is where it connects to the VI reader).
- **M4 — Viewer.** Faithful sequence-editor-like view + byte inspector +
  variables/params tables.
- **M5 — Logic export.** Sequence→Dart scaffold with honest stubs.

## Definition of done (per milestone)

Corpus-verified claims (with %s), `dart analyze` clean, tests green (totality +
fuzz + per-format invariants + a coverage ratchet), and every byte of a parsed
record accounted for (named field or explicit "undecoded" span). No fabricated
fields; unknowns labeled.
