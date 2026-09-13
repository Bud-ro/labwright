# Test corpora

`sources.json` pins every public repository the parsers are measured against:
the `vi` group for the RSRC/VI reader and the `seq` group for the TestStand
reader. The files themselves are never committed; fetch them with

```
dart run tool/fetch_corpus.dart
```

which extracts only the extensions each group keeps into the gitignored
`corpus/vi/` and `corpus/seq/` directories and skips sources already present.
The `seq` group's `files` entries are single files pinned by sha256 (paired
sequences saved in different encodings, under `seq/rosetta/`).

Tests that read the corpora are tagged `corpus`, locate the data through
`tool/corpus.dart`, and fail when it is missing. Their pins are per file:
each law names the files that violate it today, so adding a source never
churns an assertion and a regression names the file.

VI snippets are PNGs that embed their `.vi` in a `niVI` chunk beside LabVIEW's
own render of the block diagram; sources with `keep: [".png"]` supply them as
paired render oracles.

## Provenance policy

Corpus sources must be legitimately public: author-published projects,
vendor-org publications and open-source repositories. Mirrors of NI-internal
or NI-confidential material, and wholesale re-uploads of NI-shipped product
content by third parties, are never accepted regardless of how they surfaced.
Check candidate repositories for NI copyright or confidential markers and
product-tree shapes before adding them. An NI copyright inside an individual
file is not by itself disqualifying; the test is wholesale mirroring.
