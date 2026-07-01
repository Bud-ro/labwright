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

## Test tiers: fast sample vs. whole corpus

The corpus-tagged tests run in two tiers so the inner dev loop stays fast:

- **Fast (default `dart test`).** The heavy binary tests iterate a small,
  deterministic, evenly-strided *sample* (~30 binary `.seq`), so each test finishes
  well under a second. The cheap XML/INI exact-count tests still run over the whole
  corpus.
- **Whole corpus (opt-in).** `LABWRIGHT_FULL_CORPUS=1 dart test packages/labwright_seq`
  runs the heavy binary tests over every file and asserts their absolute-count
  floors.

The selection lives in `test/corpus_dirs.dart` (`seqCorpusSample()` + the
`corpusFull` flag). The sample is a fixed stride over the sorted corpus, so it is
reproducible run-to-run; it only shifts if the corpus is refetched.

## Committed indices

- `seq-sources.json` — TestStand corpus sources (GitHub repos + pinned commits),
  with an `encoding` field.

## Fetched samples (gitignored)

- `seq/` — `dart run packages/labwright_seq/tool/fetch_seq_corpus.dart`

The fetch tool downloads each source repo's tarball but **extracts only the
`.seq`/config files**, discarding the rest — so a fresh corpus is a fraction of the
old whole-repo checkout. To reclaim space from a corpus fetched by an older
whole-repo version of the tool, delete the folder and re-fetch.
