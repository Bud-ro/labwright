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
flavors back out **byte-exactly** — `write(parse(f)) == f` for the whole
corpus (36/36 XML, 58/58 INI), asserted by the round-trip gates in
`test/seq_write_xml_test.dart` and `test/seq_write_ini_test.dart`. The model
retains everything the encodings carry: elemproto trees, verbatim array
bounds, extdata, numeric formats, protected typelist blobs, interleaved INI
line order, quoting, 120-char continuation splits, and per-file line
terminators. INI writing works at the
`IniSeqFile` section level deliberately: the derived property tree is
inheritance-expanded, and writing it would fabricate lines the source file
omits. Binary `TOF1` writing is out of scope until the binary model is
complete.

## Exporting a source tree with its VIs

`dart run tool/export_seq.dart <source tree> <output directory>` (library:
`exportSeqTree`) writes a Dart package from every text sequence file under a
tree together with the LabVIEW VIs its steps call:

```
pubspec.yaml                      path dependencies on labwright and labwright_lv_runtime
analysis_options.yaml
main.dart                         registers every sequence module
lw_runtime.dart                   shared StationGlobals, when more than one module reads them
lv_types.dart                     the typedefs, clusters and enums the VIs share
<dir>/<stem>.seq.dart             one module per sequence file, beside its source
<dir>/<stem>.vi.dart              one function per VI a step calls, and per VI those call
```

Directories mirror the source tree with each segment snake-cased; function
and type names follow `labwright_vi_transpile`'s naming, so identifiers are
valid Dart while the layout stays the source's. A step's VI is located from
its `VIPath` one of five ways — relative to the sequence file, through the
`.lvproj` and `.lvlib` item lists for a `My Computer\Lib.lvlib\…` item path,
through the step's namespace for a bare class-member name — while `<vilib>`
and absolute paths stay unlocated and keep the module-call stub. A step binds
its `Parms` to the function by connector-pane index: inputs become named
arguments (translated expressions, or `ts.eval` for what does not translate),
outputs are stored to the locals or parameters they name, error clusters
become throws. A VI whose lowering refuses keeps the signature its connector
pane gives it over a body that throws `UnimplementedError`, and its doc
comment states what is not decoded, so the package always analyzes clean.

`test/export_corpus_test.dart` exports every corpus source tree and pins the
measures. Over 43 trees (1.9 s): 45 sequence files, 89 LabVIEW steps, 87 of
which locate their VI (2 name project items whose files are not vendored);
110 VI functions are emitted, 26 with lowered bodies and 84 refused — 33 on
constants (29 of them saved by LabVIEW 9.0 or earlier, which keep no value in
the heap record), 13 on sub-VI calls, 12 on wire types, 12 on Property and
Invoke Nodes, 9 on structures, 5 on primitives — and 13 call sites reach a
lowered body. 61 call sites (one
repository's legacy-prototype VIs) leave required inputs unwired and are
emitted as throws naming them; 36 arguments translate, 9 fall back to `eval`;
3 outputs store to locals, 2 target engine state the export has no variable
for.

## Notes On Development

There are plenty of sequences available online, with paired documentation. 
The development thus centers around corpus-based reverse engineering.
If running tests against sequences, fetch them with:

```bash
dart run tool/fetch_corpus.dart
```

## Trademarks

TestStand™ is a trademark of National Instruments. Neither Labwright, nor any software
programs or other goods or services offered by Labwright, are affiliated with, endorsed by,
or sponsored by National Instruments. This package is a clean-room reader for the `.seq` file
format and is not an NI product.
