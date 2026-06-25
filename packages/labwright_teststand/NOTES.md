# TestStand reader — format notes & scratch

Clean-room RE notes for NI TestStand files, derived **solely from real `.seq`
binary/text files** (the pinned corpus in `corpus/seq-sources.json`), not from
TestStand itself. Mirrors `apps/labwright_vi_inspector/NOTES.md` for the VI side.
Structure lives here; live metrics belong in tooling (not yet built for seq).

## M0 reconnaissance — what a `.seq` actually is (confirmed on the corpus)

A TestStand 4.0+ sequence file holds the same logical content — sequences, the
set of types it uses, and shared global variables — in one of **three encodings**.
All three were/are offered by NI; which one a file uses is a save-time choice.

| encoding | recognized by | confirmed | notes |
|---|---|---|---|
| **XML** | optional UTF-8 BOM `EF BB BF`, then `<?xml …?>`, root `<teststandfileheader …>` | ✅ M0 | text; the common form in open-source NI examples |
| **binary** | ASCII magic **`TOF1`** at offset 0 | ✅ M0 | NI proprietary flat container; default for size/speed |
| **INI** | INI sections + a TestStand marker | 🔬 inferred | legacy (TS 3.x); NI deprecating; no sample in corpus yet |

### XML form (decoded enough to parse next)

```
EF BB BF                                  (UTF-8 BOM, optional)
<?xml version="1.0" encoding="UTF-8"?>
<teststandfileheader type='SequenceFile' fileversion='920' productname='TestStand' ...>
  ... element tree: sequences, steps, properties, types, globals ...
```

- `type` = file kind (`SequenceFile`, `TypePaletteFile`, …).
- `fileversion` = format/engine stamp; corpus shows `920` (TS ~2017) and `962`
  (newer). Attributes use **single quotes**.
- Self-describing → M1 is a straightforward XML tree walk into the typed model.

### Binary form (`TOF1`) — header only, grammar undecoded

```
00  "TOF1"                                magic (NOT OLE2/CFBF — ruled out)
04  6 bytes                               reserved/zero (role TBD)
0A  <NUL-terminated ASCII>                file-type token, e.g. "SequenceFile"
..  "TestStand" … "2019" …               product/version ASCII appear later
```

Offsets past the file-type token are **not yet decoded** — the record grammar is
the work of M1/M2. The header magic + type token are confirmed across real-world
(`caizikun`) and TS2017/2019 example (`joshuaprewitt`, `bienieck`) files.

## Implication for milestones

XML and binary are *two encodings of one model*. Plan: decode the **XML** tree
first (M1) to establish the typed `SeqFile → sequences → steps → properties`
model and the viewer/export against a known-good structure, then map the **binary
`TOF1`** container onto that same model (M2+). This de-risks the model design
before tackling the proprietary binary, and gives a cross-check (the same example
may exist in both encodings).

## Honest gaps (do NOT model yet)

- **Binary record grammar** past the header — not yet recovered.
- **INI form** — not yet verified against a real sample (heuristic detection only).
- **Config / station files** — `corpus/seq-sources.json` captures `.ini/.cfg/.tsw/.tpj`
  when present, but the open-source corpus is sequence-heavy; type-palette and
  station-config samples are sparse. (CN-IOT's `.ini` files are *localization
  string packs*, not structural config — excluded.)
- **Module-adapter bindings** (which VI/DLL/.NET/expression a step calls, + param
  mapping) — the link to the VI reader; deferred to M3.

Project honesty rule (CLAUDE.md): mark undecoded ranges explicitly; say "not yet
recovered", never "unrecoverable".
</content>
