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
~2.3 MB). Measured 2026-07 over the 83-source manifest (384 `.seq`: 32 XML /
45 INI / 291 binary plus the 16 rosetta twins; 574 corpus files including
`.ini`/`.cfg`/`.tsw`/`.tpj` configs): full package suite ~27 s wall.

Corpus resolution lives in `test/corpus_dirs.dart` (`corpusSeqDir`).

## Committed indices

- `seq-sources.json` — TestStand corpus sources (GitHub repos + pinned commits),
  with an `encoding` field.

The corpus tests assert laws per file: each pins the files that violate it
today, so adding a source never churns an assertion and a regression names
the file.

## Fetched samples (gitignored)

- `seq/` — `dart run packages/labwright_seq/tool/fetch_seq_corpus.dart`

The fetch tool downloads each source repo's tarball but **extracts only the
`.seq`/config files**, discarding the rest — so a fresh corpus is a fraction of the
old whole-repo checkout. To reclaim space from a corpus fetched by an older
whole-repo version of the tool, delete the folder and re-fetch.

## Provenance policy

Corpus sources must be legitimately public: author-published projects,
vendor-org publications (e.g. `ni/*`), and open-source repositories.
Mirrors of NI-internal or NI-confidential material, and wholesale
re-uploads of NI-shipped product content by third parties, are never
accepted regardless of how they surfaced. Check candidate repos for NI
copyright/confidential markers and product-tree shapes before adding
them to the manifest. An NI copyright inside an individual `.seq` is not
by itself disqualifying (small numbers of shipped process-model files
appear legitimately in user projects); the test is wholesale mirroring.
