# labwright_seq

Clean-room reader for NI TestStand™ software sequence (`.seq`) and related files.
The primary goal is to open up the binary format, allow for
viewing of logic and sequences without having TestStand™ software installed, and
allow for export of Labwright compatible E2E tests (with TODO comments
for any function calls to `.vi`'s). 

```dart
import 'package:labwright_seq/labwright_seq.dart';

final f = parseSeqFile(bytes); // SeqFile(header, types, data)
for (final seq in f.sequences) {
  print(seq.name);
  for (final step in seq.steps) {
    print('  ${step.name} : ${step.type}'); // e.g. "Pass : Statement"
  }
}
```

## Writing

`writeSeqFileXml(SeqFile)` and `writeIniSeq(IniSeqFile)` write the two text
flavors back out, proven **byte-exact** over the whole corpus (36/36 XML,
58/58 INI): `write(parse(f)) == f`. Every byte the writer could not reproduce
was treated as a reader/model bug and fixed, so the model now retains
elemproto trees, verbatim array bounds, extdata, numeric formats, protected
typelist blobs, interleaved INI line order, quoting, 120-char continuation
splits, and per-file line terminators. INI writing works at the
`IniSeqFile` section level deliberately: the derived property tree is
inheritance-expanded, and writing it would fabricate lines the source file
omits. Binary `TOF1` writing is out of scope until the binary model is
complete.

## Notes On Development

There are plenty of sequences available online, with paired documentation. 
The development thus centers around corpus-based reverse engineering.
If running tests against sequences, fetch them with:

```bash
dart run packages/labwright_seq/tool/fetch_seq_corpus.dart
```

## Trademarks

TestStand™ is a trademark of National Instruments. Neither Labwright, nor any software
programs or other goods or services offered by Labwright, are affiliated with, endorsed by,
or sponsored by National Instruments. This package is a clean-room reader for the `.seq` file
format and is not an NI product.
