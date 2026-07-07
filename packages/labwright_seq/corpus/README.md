# TestStand Test Corpus

The `.seq`/`.ini`/config sample files used to develop and measure the TestStand
parser, plus the committed source index beside them. The sample files themselves
are gitignored and fetched on demand (clean-room + licensing); only the JSON and
this README are committed. The VI corpus lives under its own package
(`packages/labwright_rsrc_parse/corpus/`) — the two formats are unrelated.

## What "coverage" means

The complete metric taxonomy — every axis, what 0 % and 100 % mean, and the rule
that the format is fully understood **iff every axis reads 100 %** — is documented
in [`../COVERAGE.md`](../COVERAGE.md). Regenerate the live scorecard with:

```
dart run packages/labwright_seq/tool/coverage.dart          # -> corpus/seq/REPORT.md
```

## How the corpus tests run (whole corpus, streaming)

Every corpus-tagged test iterates the WHOLE corpus — there is no sampling
tier. The sweeps read one file at a time and keep only counters/summaries, so
peak data memory ≈ one file's bytes + its parsed model (largest corpus file
~2.3 MB). Measured 2026-07 (388 `.seq`: 26 XML / 288 binary / 58 INI plus the
16 rosetta twins): full package suite ~20 s wall, ~0.5 GB peak RSS.

Corpus resolution lives in `test/corpus_dirs.dart` (`corpusSeqDir`).

## Committed indices

- `seq-sources.json` — TestStand corpus sources (GitHub repos + pinned commits),
  with an `encoding` field.

## Fetched samples (gitignored)

- `seq/` — `dart run packages/labwright_seq/tool/fetch_seq_corpus.dart`

The fetch tool downloads each source repo's tarball but **extracts only the
`.seq`/config files**, discarding the rest — so a fresh corpus is a fraction of the
old whole-repo checkout. To reclaim space from a corpus fetched by an older
whole-repo version of the tool, delete the folder and re-fetch.

## Provenance policy

Every source added to `seq-sources.json` must clear this bar, and existing
sources are re-screened against it whenever the manifest changes.

**Acceptable sources**

- User-authored sequences published by their author (personal projects, demos,
  custom steps, plugins, CI examples).
- Vendor-published examples released deliberately by the vendor (e.g. repos
  under vendor-owned organizations such as `ni/*`, `NISystemsEngineering/*`,
  `NIVeriStandAdd-Ons/*`, `NI-Measurement-Plug-Ins/*`).
- Open-source projects that carry sequences as part of their own codebase.

**Unacceptable sources**

- Mirrored NI-internal or confidential material: internal QA pages, build- or
  release-validation suites, internal test-report archives, or any file marked
  confidential.
- Wholesale re-uploads of NI-shipped product content by third parties, e.g. a
  product install tree (`Components/`, `Models/`, shipped examples) copied
  verbatim at scale.
- Leaked archives, or bulk uploads of employer/institutional material by
  accounts unrelated to the content's author.

**Screening checklist (per repo)**

1. **Owner plausibility** — organization vs personal account; account age vs
   upload pattern. A one-shot bulk upload of a complete company/institution
   test station onto a personal or unrelated account is disqualifying.
2. **License and fork status** — prefer explicitly licensed repos; identify
   whether the repo is a fork or an untracked re-upload of another repo.
3. **Tree shape** — user-project shapes (own sequences, code modules, custom
   steps, UI work, active commit history) are acceptable; mirrored product
   install trees, internal-document trees, or third-party proprietary SDK
   dumps are not.
4. **Content sampling where suspicious** — "National Instruments Confidential"
   markings or NI copyright headers in non-shipped file types (internal docs,
   HTML, spreadsheets) are disqualifying for the whole source.

An NI copyright inside a `.seq` file is **not** by itself disqualifying:
NI-authored default, process-model, and example sequences ship with the product
and legitimately appear in user repos in small numbers. The taint test is
wholesale mirroring and internal-only material — a couple of process-model or
example files inside a user project are fine; a large verbatim product tree is
not. Ambiguous cases are recorded for the maintainer's decision rather than
silently added.
