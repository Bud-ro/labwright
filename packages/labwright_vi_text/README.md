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
  point count, modes and segment lengths, `WireSpec` for a signal as the terminals it joins
  and its route as `WireLeg`s (direction and length per segment), and `RawSpec` for any
  record whose bytes are not yet decided by decoded fields (string blobs, containers,
  floats, the walk's unframed tail).
- The type pool (`VCTP`) is its descriptors, each the bytes `ViType.encode` produces, and the
  top-level list.
- A section a block view in `labwright_rsrc_parse` decodes is a `TypedSection` whose named
  arguments are the layout's fields (`lib/src/section_specs.dart`): icons as their pixel rows
  (`IconSection`), `LVSR` (`SaveRecordSection`), `VITS` (`TagStoreSection` of `TagSpec`s),
  `BDPW`, the `RTSG`/`OBSG`/`CCSG` signatures, link info (`LinkInfoSection` of
  `LinkEntrySpec`s), `vers`, `CONP`/`CPC2`, `MUID`, `FPSE`/`BDSE`, `FPEx`/`BDEx`, `DTHP`,
  `FTAB` (`FontTableSection` of `FontSpec`s), `STRG`/`HLPT`, `HIST`, `PICC`, `PRT `, `TM80`,
  `NUID`, `SUID`/`BNID`, `CPMp`, `TITL`, `SCSR`, `CNST`/`LPIN`, `DLDR` and `BKMK`. Each
  payload is written through the block's own `encode`, which writes the layout's fields.
- Every other section is `RawSection` over its bytes.

A record or section is typed only when re-encoding its decoded fields gives back its own
bytes; the reader checks that one by one, so a typed one is exact by construction.

## Laws

- Every corpus VI, control and snippet builds back from its text form section for section,
  with the same tags, indices and envelopes, and the file `encode` writes reads back to the
  same sections (`test/corpus_text_test.dart`, 14 s over the corpus).
- The generated `test/generated/crc8.g.dart` is executed against its snippet
  (`test/generated_test.dart`).
- In the inspector, the block diagram of a VI rebuilt from its text form rasterises to the
  same pixels as the original's (`apps/labwright_vi_inspector/test/text_form_render_test.dart`).

## What is not yet in the text

The container's own words (descriptor words, gaps) are not carried: `encode` lays the
container out canonically, so a rebuilt file is section-exact, not byte-exact, and an embedded
VI (`VINS`) is carried as bytes for that reason. A typed section still carries as bytes what
its layout does not decode: `Unknown` ranges (named `unknown…`), digests, flattened variants
in `VITS`, link-entry bodies and any link-info region the entry grammar does not walk. The
inline type-pool forms of `CONP`/`CPC2`, `DTHP` and `TM80`, a font table whose records do
not name its packed names in order, and the sections with no constructor yet (`VICD`,
`DSIM`, `DFDS`, `WEMF`, `MNGI`, `BFAL`, `GCDI`, `GCPR`, `VPDP`, `FPHc`/`BDHc`, …) are
`RawSection`. Group open records and string and container attributes are carried as bytes.
A wire's route is relative to its first terminal: placing it on the diagram needs the
terminals' positions, and a branching route (a table with a header) is carried as its words,
not yet as a tree.
