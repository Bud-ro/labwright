# labwright_teststand

Clean-room reader for NI **TestStand** sequence (`.seq`) and related files —
the TestStand counterpart to the LabVIEW VI reader (`labwright_vi_parse`).
Goal: maximum visibility into the hidden structure, a faithful
sequence-editor-like view, and export of the sequence *logic* as Dart.
See `NOTES.md` for the reverse-engineering notes.

**Status: XML + INI decoded; binary `TOF1` recon.** A `.seq` is one of three
encodings of the same logical content — **XML**, legacy **INI**, or
**binary (`TOF1`)**. Decoded so far:

- the file-header encoding sniffer ([`detectSeqFormat`]/[`detectSeqHeader`]);
- the **XML** encoding into a faithful PropertyObject tree, with a typed lens
  over sequences and their steps; the legacy **INI** form maps onto the same
  typed model through a shared lens;
- the **binary (`TOF1`)** form so far as a *recon* view — header, inflated body,
  recovered strings, named scalar values, and a named-record census — its full
  record tree is **not yet decoded**, so `parseSeqFile` honestly refuses binary
  rather than guessing.

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

Validated on the corpus: 26/26 XML files parse, 33 sequences / 214 steps recovered.

## Corpus

The `.seq`/config files are not committed (clean-room + licensing). Fetch the
pinned, reproducible corpus:

```
dart run packages/labwright_teststand/tool/fetch_seq_corpus.dart
```

→ the gitignored `corpus/seq/` at the repo root (catalog: `corpus/seq-sources.json`).
