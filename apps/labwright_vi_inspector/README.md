# labwright_vi_inspector (example)

A Flutter **VI viewer/importer**: open a LabVIEW `.vi` / `.ctl` file and see what
it *is and does* — file type (VI vs control), creator, RSRC format version,
capability flags (front panel / block diagram / connector pane / sub-VI links),
and the full resource-block inventory — via the clean-room `labwright_viparse`
reader. It also decodes (via `labwright_videcode`) the **LabVIEW version + VI
title** and a **searchable list of the human-readable strings** embedded in the
heaps (control labels, help text, value lists). Point it at VIs from anywhere;
the parse/decode path is fuzz-proven *total* (any bytes → a summary or a clean
error) and the app adds a defense-in-depth catch, so a file from the wild never
crashes it — at worst you get a friendly "not a VI" message.

```
+-- Labwright · VI Inspector ---------------------------------------+
| [ /path/to/My.vi    ] [ Browse… ] [ Open path ] [ Load demo VI ]  |
|                                                                   |
|   ( drag a .vi anywhere onto this area )                          |
|  demo.vi                                                          |
|  VI — 5 resource blocks; has front panel, block diagram …         |
|  Identity:   Kind VI · Creator LBVW · Format 3 · Blocks 5         |
|  Capabilities: [✓ Front panel] [✓ Block diagram] …                |
|  Inventory:  [vers][FPHb][BDHb][CONP][LIvi]                       |
+-------------------------------------------------------------------+
```

## Run it

```sh
cd apps/labwright_vi_inspector
flutter pub get
flutter run -d linux        # (or -d macos / -d windows / -d chrome)
flutter analyze             # clean
flutter test                # model + widget + importer-robustness tests
```

Three ways to load a VI: **drag-and-drop** a `.vi` onto the window, click
**Browse…** for the native file dialog (filtered to `.vi` / `.ctl` / `.llb`), or
paste a path and click **Open path**.
**Load demo VI** synthesizes a valid VI so you can try it with no file on hand.

> On Linux the native **Browse…** dialog uses `zenity` (or `kdialog`/`qarma`) —
> install one if it's missing (`sudo apt install zenity`). Drag-and-drop and the
> demo need nothing extra.

## Scope / honesty

This is a **read-only viewer**, not an editor. It reads the RSRC *container*
(what the VI is and its component inventory). Recovering the block-diagram
*logic* from the `BDHb` heap — the step needed to render the actual graph or
migrate it to Dart, and the prerequisite for any editing — is deliberately
deferred until a corpus of real, non-trivial VI samples is available (see the
repo ADRs). Standalone Flutter app (path-depends on `labwright_viparse`; kept out
of the Dart pub workspace since its `flutter` SDK dep is incompatible with plain
`dart` tooling).

Part of the Labwright monorepo · BSD-3-Clause.
