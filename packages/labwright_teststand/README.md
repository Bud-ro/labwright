# labwright_teststand

Clean-room reader for NI **TestStand** sequence (`.seq`) and related files —
the TestStand counterpart to the LabVIEW VI reader (`labwright_viparse` /
`labwright_videcode`). Goal: maximum visibility into the hidden structure, a
faithful sequence-editor-like view, and export of the sequence *logic* as Dart.
See `docs/teststand-viewer-spec.md` for the full spec and `NOTES.md` for the
reverse-engineering notes.

**Status: M1 — XML decode.** A `.seq` is one of three encodings of the same
logical content — **XML**, **binary (`TOF1`)**, or legacy **INI**. Decoded so far:

- the file-header encoding sniffer ([`detectSeqFormat`]/[`detectSeqHeader`]);
- the **XML** encoding into a faithful PropertyObject tree, with a typed lens
  over sequences and their steps. The binary `TOF1` form maps onto the same model
  and is the next milestone (it is refused, not guessed).

```dart
import 'package:labwright_teststand/labwright_teststand.dart';

final f = parseSeqFile(bytes); // SeqFile(header, types, data)
for (final seq in f.sequences) {
  print(seq.name);
  for (final step in seq.steps) {
    print('  ${step.name} : ${step.type}'); // e.g. "Pass : Statement"
  }
}
```

Validated on the corpus: 20/20 XML files parse, 24 sequences / 121 steps recovered.

## Corpus

The `.seq`/config files are not committed (clean-room + licensing). Fetch the
pinned, reproducible corpus:

```
dart run packages/labwright_teststand/tool/fetch_seq_corpus.dart
```

→ the gitignored `corpus/seq/` at the repo root (catalog: `corpus/seq-sources.json`).
