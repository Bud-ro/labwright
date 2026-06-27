# Agent Instructions

Labwright is an open, cross-platform, **Dart**-based ecosystem of tools aimed at
understanding and replacing the National Instruments (NI) suite of tools, namely
**LabVIEW and TestStand**.

The repo was heavily pruned: a lot of speculative early scaffolding was deleted
so the tree is small and understandable. The work going forward is in small,
reviewable PRs, not large unfocused pushes.

## Current Focus

1. **VI reader** (`packages/labwright_vi_parse`,
   `apps/labwright_vi_inspector`) — a clean-room reader for LabVIEW `.vi` (RSRC)
   files: parse every resource block, walk the FP/BD object heaps, and present a
   high-visibility inspector. The goal is *full understanding of every single byte*.
   On top of byte/record-viewing, fully accurate block-diagram views along with 
   front panel views are in scope. The goal is a no compromise viewer that fully
   matches what users would see in the original programming (apart from styling).
2. **TestStand reader** (`packages/labwright_teststand`, `apps/labwright_teststand_inspector`)
   — the same role for NI **TestStand** `.seq` (and related `.config`/station files): expose
   hidden attributes/data, render a view as close as possible to the original
   tool, and export the sequence **logic**. TestStand is what most of the existing
   test infra actually relies on, so this is high-value.

Both are **clean-room** (own the parser; do not glue NI/third-party libraries
into the core) and corpus-driven.

## Repository layout

- `packages/labwright_vi_parse` — clean-room LabVIEW `.vi` reader: RSRC container
  + resource-block parse, heap decode → object graph / VI→IR / Dart scaffold.
- `packages/labwright_teststand` — clean-room TestStand `.seq` reader (XML/INI
  typed model + binary `TOF1` recon).
- `packages/labwright_tdms` — TDMS read/write.
- `apps/labwright_vi_inspector` — Flutter VI inspector (hex view, render, IR/Dart tabs).
- `apps/labwright_teststand_inspector` — Flutter TestStand `.seq` inspector.
- `example/e2e` — `e2e_test`: example authoring API for hardware end-to-end tests
  as ordinary Dart tests (device-under-test, plugs, phases, limit-checked
  measurements, TDMS records).
- `corpus/` — pinned VI/`.seq` corpus catalog + metrics (`sources.json`, `baseline.json`).
- It's a **pub workspace** (root `pubspec.yaml` `workspace:` list) — add new
  packages there. SDK `^3.11.0`. Branch: **develop**.
- The owned NI-DAQmx Dart wrapper lives on its own branch/PR (`feat/nidaqmx-wrap`),
  not yet on `develop`. Reverse-engineering cDAQ/native support is deferred
  indefinitely (declared a novelty).

## Corpus (test data)

- The `.vi` and `.seq` corpus are **not committed** (clean-room + licensing). Fetch it with
  `dart run packages/labwright_vi_parse/tool/fetch_corpus.dart` → the gitignored
  **`corpus/vi/`** at the repo root (≈7.5k VIs from 20 pinned repos).
- **Processing the corpus must use single-VM bounded-concurrency with a memory
  cap** — a reusable worker pool that streams files so peak memory ≈ poolSize ×
  per-VI working set. Do **NOT** use `dart test -j 1` (too slow over 7.5k files)
  and do **NOT** let the runner spawn many suite isolates that each iterate the
  whole corpus (that OOMs). A shared `tool/corpus_run.dart` harness is the
  intended home for this; corpus tests/probes should drive the corpus through it.
- Corpus tests are tagged `@Tags(['corpus'])` and **self-skip** when `corpus/vi/`
  is absent, so CI/the default unit run stays green without it.

## Conventions (binding)

- **Privacy:** NEVER put the maintainer's real name in source, comments, commit
  messages, or docs. Refer to "the maintainer" / "the user" / "review feedback".
- **Honesty (load-bearing):** probe the FULL corpus before any factual claim
  about a format; mark undecoded byte ranges explicitly with TODOs to revisit; 
  never fabricate data; never overclaim ("not yet recovered/decoded", never "unrecoverable").
- **Commits:** commit ONLY your own files, by **explicit path** — never
  `git add -A`/`-u` (the tree carries untracked files that are not yours, e.g.
  `build*/`, throwaway probe scripts, the gitignored `corpus/`). Put `git commit`
  on its own line. Keep `dart analyze` clean and the relevant test suites green
  before committing. Prefer small, reviewable PRs over large unfocused pushes.
- **Background tasks:** be tidy — reap background shells; don't accumulate strays.

## Code style

- Match the surrounding code's idiom, naming, and comment density.
- Catalogs of constants → one enhanced `enum` with strong doc comments (a single
  documented source of truth), not scattered magic numbers.
- Prefer composable, layered primitives; build the general primitive and expose
  it, with optional convenience wrappers.
- Prefer local/in-process over a network hop for co-located work.

## Testing

- Per package: `dart analyze <pkg>` + `dart test <pkg>` (Flutter apps use
  `flutter test`). Corpus-tagged tests need `corpus/vi/` (see above).
- Coverage/structure regressions are guarded by ratchet tests + machine-written
  baselines (`corpus/baseline.json`, `corpus/snapshot.json`) — re-run the tool to
  record a genuine improvement; never hand-edit a baseline down.
