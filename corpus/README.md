# Test corpora

`repos.json` pins, per group, the corpus repositories the parsers are measured
against and the commit of each: the `vi` group for the RSRC/VI reader
([vi-corpus](https://github.com/Bud-ro/vi-corpus) and
[vi-snippets](https://github.com/Bud-ro/vi-snippets)) and the `seq` group for
the TestStand reader ([seq-corpus](https://github.com/Bud-ro/seq-corpus)). The
files themselves are never committed here; fetch them with

```
dart run tool/fetch_corpus.dart
```

which checks each repository out into the gitignored `corpus/vi/` and
`corpus/seq/`, restricted to the `paths` an entry lists so that only the sources
the tests pin are downloaded. Tests that read the corpora are tagged `corpus`,
locate the data through `tool/corpus.dart`, and fail when it is missing. Their
pins are per file: each law names the files that violate it today, so adding a
source never churns an assertion and a regression names the file.

Provenance, licenses and the list of surveyed-but-not-vendored repositories
live in the corpus repositories themselves; `dart run tool/vendor_corpus.dart`
adds an upstream repository to one of them.
