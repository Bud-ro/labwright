# labwright_vi_text

A VI as Dart code. `viSpecOf(bytes)` reads a `.vi` (or a snippet PNG's embedded VI) into a
`ViSpec`: the file's own sections in file order, each as the records it is made of.
`ViSpec.encode()` writes it back as a file, and `emitViSpecDart` prints it as Dart source
that constructs the same `ViSpec` when run.

```
dart run packages/labwright_vi_text/bin/vi_text.dart path/to/some.vi some.dart
dart run packages/labwright_vi_text/bin/vi_text.dart --corpus corpus/text
```

## What a section is

- A heap (`FPHb`, `BDHb`) is its records as a tree: `ObjectSpec` for an object from its
  header to its close, `GroupSpec` for a group, and inside them `C4Spec` (with `bounds` and
  `caption` for the two decoded shapes), `AttrSpec` for a scalar or flag attribute by its
  ten-bit id, `RefSpec` for a reference, `WireTableSpec` for a signal's route table as its
  point count, modes and segment lengths, and `RawSpec` for any record whose bytes are not yet
  decided by decoded fields (string blobs, containers, floats, the walk's unframed tail).
- The type pool (`VCTP`) is its descriptors, each the bytes `ViType.encode` produces, and the
  top-level list.
- Every other section is `RawSection` over its bytes.

A record is typed only when re-encoding its decoded fields gives back its own bytes; the
reader checks that record by record, so a typed record is exact by construction.

## Laws

- Every corpus VI, control and snippet builds back from its text form section for section,
  with the same tags, indices and envelopes, and the file `encode` writes reads back to the
  same sections (`test/corpus_text_test.dart`, 11 s over the corpus).
- The generated `test/generated/crc8.g.dart` is executed against its snippet
  (`test/generated_test.dart`).
- In the inspector, the block diagram of a VI rebuilt from its text form rasterises to the
  same pixels as the original's (`apps/labwright_vi_inspector/test/text_form_render_test.dart`).

## What is not yet in the text

The container's own words (descriptor words, gaps) are not carried: `encode` lays the
container out canonically, so a rebuilt file is section-exact, not byte-exact. The sections
written as bytes (`LVSR`, `vers`, `CONP`, icons, link info, …) have layouts in
`labwright_rsrc_parse`; constructors from those layouts are the next step. Group open
records and string and container attributes are carried as bytes; a wire is its signal
object, its segment objects and the route table's words, not yet endpoints and a polyline.
