# labwright_teststand

Clean-room reader for NI **TestStand** sequence (`.seq`) and related files —
the TestStand counterpart to the LabVIEW VI reader (`labwright_viparse` /
`labwright_videcode`). Goal: maximum visibility into the hidden structure, a
faithful sequence-editor-like view, and export of the sequence *logic* as Dart.
See `docs/teststand-viewer-spec.md` for the full spec and `NOTES.md` for the
reverse-engineering notes.

**Status: M0 — format reconnaissance.** Decoded so far: the file-header encoding
sniffer ([`detectSeqFormat`]/[`detectSeqHeader`]). A `.seq` is one of three
encodings of the same logical content — **XML**, **binary (`TOF1`)**, or legacy
**INI** — and this tells them apart and reads the header (file type, product,
version) without the TestStand engine.

```dart
import 'package:labwright_teststand/labwright_teststand.dart';

final header = detectSeqHeader(bytes); // SeqFileHeader(xml, type=SequenceFile, ...)
```

## Corpus

The `.seq`/config files are not committed (clean-room + licensing). Fetch the
pinned, reproducible corpus:

```
dart run packages/labwright_teststand/tool/fetch_seq_corpus.dart
```

→ the gitignored `corpus/seq/` at the repo root (catalog: `corpus/seq-sources.json`).
