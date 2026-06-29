# TestStand (`.seq`) coverage — what "done" means

The goal is **total understanding of every TestStand sequence file**, across all
three encodings NI uses (XML, legacy INI, and binary TOF1). As with the VI side,
that goal is split into independent **0–100 %** axes, each listed here up front so
no axis is a hidden "part 2".

> **A `.seq` corpus is fully understood IFF every axis below reads 100 %.**

All numbers come from `tool/coverage.dart` over the corpus (`corpus/seq`); the
gitignored `corpus/seq/REPORT.md` is the live scorecard.

## The axes

| Axis | Definition | 100 % means | Latest |
|---|---|---|---|
| `formatDetected` | `.seq` files classified into a known encoding (xml/ini/binary) / all `.seq` | every file's encoding is recognized | ~100 % |
| `xmlModel` | XML `Data`-tree property nodes the typed lens surfaces / total XML nodes | the XML model is fully decoded | see REPORT.md |
| `iniModel` | INI `Data`-tree property nodes surfaced / total INI nodes | the legacy INI model is fully decoded | see REPORT.md |
| **`binaryModel`** | binary-TOF1 property nodes surfaced / total | the binary record grammar is decoded | **0.0 % — frontier** |

### Why `binaryModel` is 0 % (and why that's stated, not hidden)

Binary TOF1 `.seq` files are **detected** and **recon'd** today — `labwright_seq`
inflates the zlib body and recovers the string/name pool (so you can see *what's*
in a file: sequence names, step names, expressions, module paths) — but the
**record grammar that links those names into the PropertyObject tree is not yet
decoded**. So there is no typed model for binary files, and `binaryModel%` is
honestly **0**. Taking it 0 → 100 is the single largest remaining piece of work on
the TestStand side; it is declared here from the start so reaching 100 % on the
XML/INI axes never reads as "done".

`iniModel%` runs lower than `xmlModel%` by construction (each INI step inlines its
step-type definition, which XML centralizes in `<typelist>`), not because instance
data is missing — see the report card footnote.

## Notes / tracked work

- Corpus currently lives at repo-root `corpus/seq`. Siloing it under this package
  is tracked with the corpus-slimming work, not here.
- INI files > 300 KB are skipped by the coverage tool as an OOM guard; with the
  INI parser now O(N) (it was O(paths²)) that guard can likely be lifted later.
