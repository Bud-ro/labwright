# TestStand inspector — app notes

A standalone Flutter **desktop** app for inspecting NI **TestStand** `.seq` files
through the clean-room [`labwright_seq`](../../packages/labwright_seq)
reader. Its job is to make the reader's output *visible* — catch obvious errors,
and give inspectability into what the parser actually recovers. It reads only; it
never writes `.seq` files.

**Read this for the app's shape; read the reader for format facts.** The
on-disk format details live in `packages/labwright_seq` (its `NOTES.md` and
`docs/teststand-viewer-spec.md`). This file documents the *UI* and how it's wired.

---

## What you see

Open a `.seq` via the toolbar button, drag-and-drop, or `flutter run -- file.seq`.
`SeqDocument.parse(bytes)` sniffs the encoding and returns one of three variants,
and the UI switches on it:

- **XML sequence files** → a tabbed view:
  - **Dump** — the faithful, sequence-editor-like text dump (`dumpSeqFile`):
    sequences with parameters/locals, and Setup/Main/Cleanup steps showing type,
    module/adapter binding, limits, flow/mode/loop/precondition.
  - **Sequences** — a tree (`ExpansionTile`s): each sequence → Setup/Main/Cleanup
    groups → step rows with name `[type]` and chips for adapter→target, limits,
    and flow/mode notes. In-file `SequenceCall` steps render a tappable
    `→ go to sequence` chip that jumps to and expands the called sequence;
    external calls show the target file when known.
  - **Properties** — the raw PropertyObject model (`SeqFile.data`) as a lazy,
    expandable tree: every node's name, kind (`className · typeName`, or
    `className[N]` for arrays), all attributes, and leaf scalar values. A search
    box filters by name/value/type/attribute, keeps matching nodes' ancestors,
    and force-expands so deep matches are visible. This is the "every attribute
    kept" lens — it surfaces data the typed views don't.
  - A slim **coverage strip** under the file path shows how much of the raw
    PropertyObject tree the typed lens accounts for, e.g.
    `model coverage 13.5% (1895/14016)` (`measureCoverage`). The gap is honest
    and visible on purpose.

- **Binary `TOF1` files** → a structured **recon view** (`BinaryView`): a
  header/facts table (encoding, file type, product, file version, inflated body
  size, string counts), an explicit note that **the record tree is not yet
  decoded**, and the recovered string table in a scrollable list with offsets.
  Binary is honestly partial — header + inflated body + recovered strings only.

- **Anything else** → the sniffed header plus the parse error.

## Architecture — pure helpers, thin widgets

The load-bearing rule: **all real logic lives in Flutter-free helpers under
`lib/src/`, and only `*_view.dart` + `main.dart` import Flutter.** That keeps the
shaping logic unit-testable without a Flutter binding, and mirrors
`apps/labwright_vi_inspector`.

| Pure helper (no Flutter)      | Widget (Flutter)        |
|-------------------------------|-------------------------|
| `document_view.dart` — `documentText`, `documentTitle`, `coverageLabel`, `binaryHeaderRows` | `binary_view.dart` — `BinaryView` |
| `sequence_outline.dart` — `SeqOutline`/`SequenceOutline`/`StepOutline`/… | `sequences_view.dart` — `SequencesView` |
| `property_outline.dart` — `PropertyNode`, `propertyTree`, `filterTree`, `matchesQuery` | `properties_view.dart` — `PropertiesView` |
|                               | `main.dart` — open path, tab scaffold |

Every helper is exercised by `test/document_view_test.dart` (unit tests on a
small XML/binary fixture). `test/corpus_smoke_test.dart` drives **every** real
`corpus/seq/*.seq` through the same helper path the app uses — asserting no
throws, a sane variant per file, and non-empty rendered output — and self-skips
when the gitignored corpus is absent (so the default `flutter test` stays green).

## Running it

The app is **not** in the root Dart pub workspace (its Flutter SDK dependency is
incompatible with plain `dart` tooling), so it carries its own
`analysis_options.yaml` and is built with `flutter`, not `dart`:

```sh
flutter pub get
flutter analyze          # expect: No issues found
flutter test             # unit tests + corpus smoke (skips if no corpus)
flutter run -d macos     # or -d linux / -d windows
flutter run -d macos -- path/to/file.seq   # open a file at launch
```

## Honest status

- **XML** is fully modeled by the typed lens (`SeqFile`/`Sequence`/`Step`), and
  the corpus smoke test confirms every XML file in the corpus parses and renders.
  How complete the *raw-tree* coverage is, is reported live by the coverage strip
  — don't quote a number from here, it drifts; open a file and read the strip.
- **Binary `TOF1`** is partially recovered: the header is decoded and the body is
  inflated and string-mined, but **the record tree is not yet decoded** into the
  typed model. The recon view is explicit about this.

## Next ideas

- Search/filter for the Sequences tab (mirror the Properties filter).
- Recent-files list and keyboard shortcuts (open, focus search).
- Richer step **Limits** display (low/high/nominal as a small table).
- A hex pane for binary files alongside the recovered strings.
- Decode the binary `TOF1` record tree → unlock the typed views for binary too.

## Implementation notes (non-obvious)

- `ListView`'s `key: ValueKey(_query)` in the Properties/Sequences filters exists to
  force a rebuild on query change so `ExpansionTile`s pick up the new force-expanded
  state while filtering. Removing the key silently breaks filter expansion.
- `_keys`/`_expanded` in the sequences view are indexed by **original** outline position
  (not filtered position), so jump targets stay correct while a filter is applied.
- The attribute chips in `properties_view`'s `_subtitle` deliberately exclude the
  `classname`/`typename` keys — those are already surfaced via `node.typeLabel`.
- `document_view.binaryRecoverySections`: the "Inline numeric values" section is a
  superset of "Named scalar values" (it includes inline numbers not yet tied to a named
  record).
