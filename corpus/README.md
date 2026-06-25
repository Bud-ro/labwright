# Diverse VI test corpus

A pinned catalog of **20 open-source LabVIEW `.vi` sources** (~7,500 VIs) used to
test the clean-room Labwright VI reader against a *diverse* population — multiple
vendors, frameworks, domains, and LabVIEW eras — so the format work does not
overfit to a single mono-culture.

- **[`sources.json`](sources.json)** — the catalog: each source's GitHub repo,
  branch, **pinned commit hash**, VI count, and category.
- **[`../packages/labwright_videcode/tool/fetch_corpus.dart`](../packages/labwright_videcode/tool/fetch_corpus.dart)**
  — fetches every source at its pinned commit into the gitignored
  **`<repoRoot>/vi-corpus/`** folder (override with an arg). Requires an
  authenticated `gh`. Run with
  `dart run packages/labwright_videcode/tool/fetch_corpus.dart`. The `.vi` files
  are **not committed** (clean-room + licensing); re-fetch with this script. Kept
  at the repo root (not `/tmp`) for visibility into what the tests consume.

## The "% deliberately parsed" metric

`packages/labwright_videcode/tool/coverage.dart` walks the corpus and reports
container-parse success, section-decode success, and the headline **% deliberately
parsed** — the fraction of object/type-heap (`BDHb`/`BDHP`/`FPHb`/`FPHP`/`DTHP`)
body bytes that fall inside a record the walker **deliberately frames** (a
specific `recordSkip` case), as opposed to the bytes after the first opcode it
does not yet handle. It is a *framing* metric (boundaries recognized by intent),
not a claim that every value is decoded — hence "deliberately parsed", not
"understood".

```
dart run tool/coverage.dart [corpusRoot=<repoRoot>/vi-corpus] [perSourceCap=120]
```

The tool also writes a human-readable scorecard to the gitignored
`vi-corpus/REPORT.md` on every run (per-source + total), so the format "report
card" is regenerated from the live decoders rather than hand-maintained in prose.
Durable structural facts live in `apps/labwright_vi_inspector/NOTES.md`.

The figure is **never hand-maintained**: the tool computes it and writes the
deterministic picotech-first-60 number to **[`baseline.json`](baseline.json)**.
`packages/labwright_videcode/test/corpus_coverage_test.dart` reads that file and
asserts the current run is at or above it, so the metric can only **ratchet
upward** — re-run the tool to record a genuine improvement; a regression fails
the test. (CI skips the test when the corpus isn't fetched.)

The tool also prints the overall figure across all fetched sources. Earlier
"~100%" figures were measured on a single heap (`BDEx`) in one corpus and did
not generalize; the corpus-wide number is the honest one.

### Three tiers: framed vs value-kind-known vs decoded

Framing is near-complete, so the tool reports two deeper figures. Every framed
record falls in exactly one tier (see `HeapDecodeTier` / `heapDecodeTier` in
`heap.dart` — the single source of truth shared by the tool and its test):

- **% deliberately parsed** (framing) — bytes inside a record the walker frames.
- **% semantically decoded** (meaning) — bytes in a record we assign a typed
  *meaning* to: an object header (class+oid), bracket structure (group
  open/close), a typed object reference, a decoded `C4` opcode, or a *named*
  attribute/property-token of **confirmed/inferred** confidence.
- **% value-kind known** — bytes where the value's *kind/width* is known but its
  meaning is not: a `kindOnly`-confidence catalog entry (a value-kind label, not
  a decoded role). These are honestly **not** "decoded" — counting them as
  semantic would inflate the headline, so they get their own tier.

`semanticallyDecoded + valueKindKnown = % classified` (≤ framing).
`semanticallyDecoded` is the real frontier: drive it up by turning `kindOnly`
entries into confirmed/inferred ones (with evidence) or decoding new families,
then refresh `baseline.json`. All figures are machine-written to
[`baseline.json`](baseline.json), and `corpus_coverage_test.dart` ratchets BOTH
`deliberatelyParsed` and `semanticallyDecoded` so neither can silently regress.

## TestStand `.seq` corpus

A parallel catalog for the TestStand reader (`packages/labwright_teststand`):

- **[`seq-sources.json`](seq-sources.json)** — 9 pinned sources (NI examples +
  community + real-world), each with its observed `encoding` (XML / binary-TOF1 /
  mixed).
- **[`../packages/labwright_teststand/tool/fetch_seq_corpus.dart`](../packages/labwright_teststand/tool/fetch_seq_corpus.dart)**
  — fetches them into the gitignored **`<repoRoot>/seq-corpus/`**. Run with
  `dart run packages/labwright_teststand/tool/fetch_seq_corpus.dart`.

RE findings live in `packages/labwright_teststand/NOTES.md`.
