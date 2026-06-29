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
